module workspaced.com.dcd;

import std.file : tempDir;

import core.thread;
import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.datetime;
import std.experimental.logger;
import std.experimental.logger : trace;
import std.json;
import std.path;
import std.process;
import std.random;
import std.stdio;
import std.string;

import painlessjson;

import workspaced.api;
import workspaced.helpers;

version (OSX) version = haveUnixSockets;
version (linux) version = haveUnixSockets;
version (BSD) version = haveUnixSockets;
version (FreeBSD) version = haveUnixSockets;

@component("dcd")
class DCDComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	enum latestKnownVersion = [0, 12, 0];
	void load()
	{
		installedVersion = workspaced.globalConfiguration.get("dcd", "_installedVersion", "");

		if (installedVersion.length && this.clientPath == workspaced.globalConfiguration.get("dcd",
				"_clientPath", "")
				&& this.serverPath == workspaced.globalConfiguration.get("dcd", "_serverPath", ""))
		{
			version (haveUnixSockets)
				hasUnixDomainSockets = config.get("dcd", "_hasUnixDomainSockets", false);
			supportsFullOutput = config.get("dcd", "_supportsFullOutput", false);
			trace("Reusing previously identified DCD ", installedVersion);
		}
		else
		{
			reloadBinaries();
		}
	}

	void reloadBinaries()
	{
		string clientPath = this.clientPath;
		string serverPath = this.serverPath;

		installedVersion = clientPath.getVersionAndFixPath;
		string clientPathInfo = clientPath != "dcd-client" ? "(" ~ clientPath ~ ") " : "";
		trace("Detected dcd-client ", clientPathInfo, installedVersion);

		string serverInstalledVersion = serverPath.getVersionAndFixPath;
		string serverPathInfo = serverPath != "dcd-server" ? "(" ~ serverPath ~ ") " : "";
		trace("Detected dcd-server ", serverPathInfo, serverInstalledVersion);

		if (serverInstalledVersion != installedVersion)
			throw new Exception("client & server version mismatch");

		config.set("dcd", "clientPath", clientPath);
		config.set("dcd", "serverPath", serverPath);

		assert(this.clientPath == clientPath);
		assert(this.serverPath == serverPath);

		version (haveUnixSockets)
			hasUnixDomainSockets = supportsUnixDomainSockets(installedVersion);

		//dfmt off
		if (isOutdated)
			workspaced.broadcast(refInstance, JSONValue([
				"type": JSONValue("outdated"),
				"component": JSONValue("dcd")
			]));
		//dfmt on
		supportsFullOutput = rawExec([clientPath, "--help"]).output.canFind("--extended");

		workspaced.globalConfiguration.set("dcd", "_clientPath", clientPath);
		workspaced.globalConfiguration.set("dcd", "_serverPath", serverPath);
		version (haveUnixSockets)
			workspaced.globalConfiguration.set("dcd", "_hasUnixDomainSockets", hasUnixDomainSockets);
		workspaced.globalConfiguration.set("dcd", "_supportsFullOutput", supportsFullOutput);
		workspaced.globalConfiguration.set("dcd", "_installedVersion", installedVersion);
	}

	/// Returns: true if DCD version is less than latestKnownVersion or if server and client mismatch or if it doesn't exist.
	bool isOutdated()
	{
		if (!installedVersion)
		{
			string clientPath = this.clientPath;
			string serverPath = this.serverPath;

			try
			{
				installedVersion = clientPath.getVersionAndFixPath;
				if (serverPath.getVersionAndFixPath != installedVersion)
					return true;
			}
			catch (ProcessException)
			{
				return true;
			}
		}

		if (installedVersion == "vbin") // locally compiled
			return false;

		return !checkVersion(installedVersion, latestKnownVersion);
	}

	/// Returns: the current detected installed version of dcd-client.
	string clientInstalledVersion() @property const
	{
		return installedVersion;
	}

	private auto serverThreads()
	{
		return threads(1, 2);
	}

	/// This stops the dcd-server instance safely and waits for it to exit
	override void shutdown(bool dtor = false)
	{
		stopServerSync();
		if (!dtor && _threads)
			serverThreads.finish();
	}

	/// This will start the dcd-server and load import paths from the current provider
	void setupServer(string[] additionalImports = [], bool quietServer = false)
	{
		startServer(importPaths ~ importFiles ~ additionalImports, quietServer);
	}

	/// This will start the dcd-server
	void startServer(string[] additionalImports = [], bool quietServer = false)
	{
		if (isPortRunning(port))
			throw new Exception("Already running dcd on port " ~ port.to!string);
		string[] imports;
		foreach (i; additionalImports)
			if (i.length)
				imports ~= "-I" ~ i;
		this.runningPort = port;
		this.socketFile = buildPath(tempDir,
				"workspace-d-sock" ~ thisProcessID.to!string ~ "-" ~ uniform!ulong.to!string(36));
		serverPipes = raw([serverPath] ~ clientArgs ~ imports,
				Redirect.stdin | Redirect.stderr | Redirect.stdoutToStderr);
		while (!serverPipes.stderr.eof)
		{
			string line = serverPipes.stderr.readln();
			if (!quietServer)
				trace("Server: ", line);
			if (line.canFind("Startup completed in "))
				break;
		}
		running = true;
		serverThreads.create({
			mixin(traceTask);
			if (quietServer)
				foreach (block; serverPipes.stderr.byChunk(4096))
				{
				}
			else
				while (serverPipes.stderr.isOpen && !serverPipes.stderr.eof)
				{
					auto line = serverPipes.stderr.readln();
					trace("Server: ", line); // evaluates lazily, so read before
				}
			auto code = serverPipes.pid.wait();
			info("DCD-Server stopped with code ", code);
			if (code != 0)
			{
				info("Broadcasting dcd server crash.");
				workspaced.broadcast(refInstance, JSONValue([
						"type": JSONValue("crash"),
						"component": JSONValue("dcd")
					]));
				running = false;
			}
		});
	}

	void stopServerSync()
	{
		if (!running)
			return;
		int i = 0;
		running = false;
		doClient(["--shutdown"]).pid.wait;
		while (serverPipes.pid && !serverPipes.pid.tryWait().terminated)
		{
			Thread.sleep(10.msecs);
			if (++i > 200) // Kill after 2 seconds
			{
				killServer();
				return;
			}
		}
	}

	/// This stops the dcd-server asynchronously
	/// Returns: null
	Future!void stopServer()
	{
		auto ret = new Future!void();
		gthreads.create({
			mixin(traceTask);
			try
			{
				stopServerSync();
				ret.finish();
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// This will kill the process associated with the dcd-server instance
	void killServer()
	{
		if (serverPipes.pid && !serverPipes.pid.tryWait().terminated)
			serverPipes.pid.kill();
	}

	/// This will stop the dcd-server safely and restart it again using setup-server asynchronously
	/// Returns: null
	Future!void restartServer(bool quiet = false)
	{
		auto ret = new Future!void;
		gthreads.create({
			mixin(traceTask);
			try
			{
				stopServerSync();
				setupServer([], quiet);
				ret.finish();
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// This will query the current dcd-server status
	/// Returns: `{isRunning: bool}` If the dcd-server process is not running anymore it will return isRunning: false. Otherwise it will check for server status using `dcd-client --query`
	auto serverStatus() @property
	{
		DCDServerStatus status;
		if (serverPipes.pid && serverPipes.pid.tryWait().terminated)
			status.isRunning = false;
		else if (hasUnixDomainSockets)
			status.isRunning = true;
		else
			status.isRunning = isPortRunning(runningPort);
		return status;
	}

	/// Searches for a symbol across all files using `dcd-client --search`
	Future!(DCDSearchResult[]) searchSymbol(string query)
	{
		auto ret = new Future!(DCDSearchResult[]);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running)
				{
					ret.finish(null);
					return;
				}
				auto pipes = doClient(["--search", query]);
				scope (exit)
				{
					pipes.pid.wait();
					pipes.destroy();
				}
				pipes.stdin.close();
				DCDSearchResult[] results;
				while (pipes.stdout.isOpen && !pipes.stdout.eof)
				{
					string line = pipes.stdout.readln();
					if (line.length == 0)
						continue;
					string[] splits = line.chomp.split('\t');
					if (splits.length >= 3)
						results ~= DCDSearchResult(splits[0], splits[2].to!int, splits[1]);
				}
				ret.finish(results);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Reloads import paths from the current provider. Call reload there before calling it here.
	void refreshImports()
	{
		addImports(importPaths ~ importFiles);
	}

	/// Manually adds import paths as string array
	void addImports(string[] imports)
	{
		knownImports = multiwayUnion([knownImports.filterNonEmpty, imports.filterNonEmpty]).array;
		updateImports();
	}

	/// Manually removes import paths using a string array. Note that trying to
	/// remove import paths from the import paths provider will result in them
	/// being readded as soon as refreshImports is called again.
	void removeImports(string[] imports)
	{
		knownImports = setDifference(knownImports, imports.filterNonEmpty).array;
		updateImports();
	}

	string clientPath() @property @ignoredFunc
	{
		return config.get("dcd", "clientPath", "dcd-client");
	}

	string serverPath() @property @ignoredFunc
	{
		return config.get("dcd", "serverPath", "dcd-server");
	}

	ushort port() @property @ignoredFunc
	{
		return cast(ushort) config.get!int("dcd", "port", 9166);
	}

	/// Searches for an open port to spawn dcd-server in asynchronously starting with `port`, always increasing by one.
	/// Returns: 0 if not available, otherwise the port as number
	Future!ushort findAndSelectPort(ushort port = 9166)
	{
		if (hasUnixDomainSockets)
		{
			return Future!ushort.fromResult(0);
		}
		auto ret = new Future!ushort;
		gthreads.create({
			mixin(traceTask);
			try
			{
				auto newPort = findOpen(port);
				port = newPort;
				ret.finish(port);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Finds the declaration of the symbol at position `pos` in the code
	Future!DCDDeclaration findDeclaration(scope const(char)[] code, int pos)
	{
		auto ret = new Future!DCDDeclaration;
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running || pos >= code.length)
				{
					ret.finish(DCDDeclaration.init);
					return;
				}

				// We need to move by one character on identifier characters to ensure the start character fits.
				if (!isIdentifierSeparatingChar(code[pos]))
					pos++;

				auto pipes = doClient(["-c", pos.to!string, "--symbolLocation"]);
				scope (exit)
				{
					pipes.pid.wait();
					pipes.destroy();
				}
				pipes.stdin.write(code);
				pipes.stdin.close();
				string line = pipes.stdout.readln();
				if (line.length == 0)
				{
					ret.finish(DCDDeclaration.init);
					return;
				}
				string[] splits = line.chomp.split('\t');
				if (splits.length != 2)
				{
					ret.finish(DCDDeclaration.init);
					return;
				}
				ret.finish(DCDDeclaration(splits[0], splits[1].to!int));
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Finds the documentation of the symbol at position `pos` in the code
	Future!string getDocumentation(scope const(char)[] code, int pos)
	{
		auto ret = new Future!string;
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running)
				{
					ret.finish("");
					return;
				}
				auto pipes = doClient(["--doc", "-c", pos.to!string]);
				scope (exit)
				{
					pipes.pid.wait();
					pipes.destroy();
				}
				pipes.stdin.write(code);
				pipes.stdin.close();
				string data;
				while (pipes.stdout.isOpen && !pipes.stdout.eof)
				{
					string line = pipes.stdout.readln();
					if (line.length)
						data ~= line.chomp;
				}
				ret.finish(data.unescapeTabs);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Returns the used socket file. Only available on OSX, linux and BSD with DCD >= 0.8.0
	/// Throws an error if not available.
	string getSocketFile()
	{
		if (!hasUnixDomainSockets)
			throw new Exception("Unix domain sockets not supported");
		return socketFile;
	}

	/// Returns the used running port. Throws an error if using unix sockets instead
	ushort getRunningPort()
	{
		if (hasUnixDomainSockets)
			throw new Exception("Using unix domain sockets instead of a port");
		return runningPort;
	}

	/// Queries for code completion at position `pos` in code
	/// Raw is anything else than identifiers and calltips which might not be implemented by this point.
	/// calltips.symbols and identifiers.definition, identifiers.file, identifiers.location and identifiers.documentation are only available with dcd ~master as of now.
	Future!DCDCompletions listCompletion(scope const(char)[] code, int pos)
	{
		auto ret = new Future!DCDCompletions;
		gthreads.create({
			mixin(traceTask);
			try
			{
				DCDCompletions completions;
				if (!running)
				{
					info("DCD not running!");
					ret.finish(completions);
					return;
				}
				auto pipes = doClient((supportsFullOutput ? ["--extended"] : []) ~ [
						"-c", pos.to!string
					]);
				scope (exit)
				{
					pipes.pid.wait();
					pipes.destroy();
				}
				pipes.stdin.write(code);
				pipes.stdin.close();
				string[] data;
				while (pipes.stdout.isOpen && !pipes.stdout.eof)
				{
					string line = pipes.stdout.readln();
					trace("DCD Client: ", line);
					if (line.length == 0)
						continue;
					data ~= line.chomp;
				}
				completions.raw = data;
				int[] emptyArr;
				if (data.length == 0)
				{
					completions.type = DCDCompletions.Type.identifiers;
					ret.finish(completions);
					return;
				}
				if (data[0] == "calltips")
				{
					if (supportsFullOutput)
					{
						foreach (line; data[1 .. $])
						{
							auto parts = line.split("\t");
							if (parts.length < 5)
								continue;
							completions._calltips ~= parts[2];
							string location = parts[3];
							string file;
							int index;
							if (location.length)
							{
								auto space = location.lastIndexOf(' ');
								if (space != -1)
								{
									file = location[0 .. space];
									if (location[space + 1 .. $].all!isDigit)
										index = location[space + 1 .. $].to!int;
								}
								else
									file = location;
							}
							completions._symbols ~= DCDCompletions.Symbol(file, index, parts[4].unescapeTabs);
						}
					}
					else
					{
						completions._calltips = data[1 .. $];
						completions._symbols.length = completions._calltips.length;
					}
					completions.type = DCDCompletions.Type.calltips;
					ret.finish(completions);
					return;
				}
				else if (data[0] == "identifiers")
				{
					DCDIdentifier[] identifiers;
					foreach (line; data[1 .. $])
					{
						string[] splits = line.split('\t');
						DCDIdentifier symbol;
						if (supportsFullOutput)
						{
							if (splits.length < 5)
								continue;
							string location = splits[3];
							string file;
							int index;
							if (location.length)
							{
								auto space = location.lastIndexOf(' ');
								if (space != -1)
								{
									file = location[0 .. space];
									if (location[space + 1 .. $].all!isDigit)
										index = location[space + 1 .. $].to!int;
								}
								else
									file = location;
							}
							symbol = DCDIdentifier(splits[0], splits[1], splits[2], file,
								index, splits[4].unescapeTabs);
						}
						else
						{
							if (splits.length < 2)
								continue;
							symbol = DCDIdentifier(splits[0], splits[1]);
						}
						identifiers ~= symbol;
					}
					completions.type = DCDCompletions.Type.identifiers;
					completions._identifiers = identifiers;
					ret.finish(completions);
					return;
				}
				else
				{
					completions.type = DCDCompletions.Type.raw;
					ret.finish(completions);
					return;
				}
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	void updateImports()
	{
		if (!running)
			return;
		string[] args;
		foreach (path; knownImports)
			if (path.length)
				args ~= "-I" ~ path;
		execClient(args);
	}

	bool fromRunning(bool supportsFullOutput, string socketFile, ushort runningPort)
	{
		if (socketFile.length ? isSocketRunning(socketFile) : isPortRunning(runningPort))
		{
			running = true;
			this.supportsFullOutput = supportsFullOutput;
			this.socketFile = socketFile;
			this.runningPort = runningPort;
			this.hasUnixDomainSockets = !!socketFile.length;
			return true;
		}
		else
			return false;
	}

	bool getSupportsFullOutput() @property
	{
		return supportsFullOutput;
	}

	bool isUsingUnixDomainSockets() @property
	{
		return hasUnixDomainSockets;
	}

	bool isActive() @property
	{
		return running;
	}

private:
	string installedVersion;
	bool supportsFullOutput;
	bool hasUnixDomainSockets = false;
	bool running = false;
	ProcessPipes serverPipes;
	ushort runningPort;
	string socketFile;
	string[] knownImports;

	string[] clientArgs()
	{
		if (hasUnixDomainSockets)
			return ["--socketFile", socketFile];
		else
			return ["--port", runningPort.to!string];
	}

	auto doClient(string[] args)
	{
		return raw([clientPath] ~ clientArgs ~ args);
	}

	auto raw(string[] args, Redirect redirect = Redirect.all)
	{
		return pipeProcess(args, redirect, null, Config.none, refInstance ? instance.cwd : null);
	}

	auto execClient(string[] args)
	{
		return rawExec([clientPath] ~ clientArgs ~ args);
	}

	auto rawExec(string[] args)
	{
		return execute(args, null, Config.none, size_t.max, refInstance ? instance.cwd : null);
	}

	bool isSocketRunning(string socket)
	{
		if (!hasUnixDomainSockets)
			return false;
		auto ret = execute([clientPath, "-q", "--socketFile", socket]);
		return ret.status == 0;
	}

	bool isPortRunning(ushort port)
	{
		if (hasUnixDomainSockets)
			return false;
		auto ret = execute([clientPath, "-q", "--port", port.to!string]);
		return ret.status == 0;
	}

	ushort findOpen(ushort port)
	{
		--port;
		bool isRunning;
		do
		{
			isRunning = isPortRunning(++port);
		}
		while (isRunning);
		return port;
	}
}

bool supportsUnixDomainSockets(string ver)
{
	return checkVersion(ver, [0, 8, 0]);
}

unittest
{
	assert(supportsUnixDomainSockets("0.8.0-beta2+9ec55f40a26f6bb3ca95dc9232a239df6ed25c37"));
	assert(!supportsUnixDomainSockets("0.7.9-beta3"));
	assert(!supportsUnixDomainSockets("0.7.0"));
	assert(supportsUnixDomainSockets("v0.9.8 c7ea7e081ed9ad2d85e9f981fd047d7fcdb2cf51"));
	assert(supportsUnixDomainSockets("1.0.0"));
}

private string unescapeTabs(string val)
{
	if (!val.length)
		return val;

	auto ret = appender!string;
	size_t i = 0;
	while (i < val.length)
	{
		size_t index = val.indexOf('\\', i);
		if (index == -1 || cast(int) index == cast(int) val.length - 1)
		{
			if (!ret.data.length)
			{
				return val;
			}
			else
			{
				ret.put(val[i .. $]);
				break;
			}
		}
		else
		{
			char c = val[index + 1];
			switch (c)
			{
			case 'n':
				c = '\n';
				break;
			case 't':
				c = '\t';
				break;
			default:
				break;
			}
			ret.put(val[i .. index]);
			ret.put(c);
			i = index + 2;
		}
	}
	return ret.data;
}

unittest
{
	shouldEqual("hello world", "hello world".unescapeTabs);
	shouldEqual("hello\nworld", "hello\\nworld".unescapeTabs);
	shouldEqual("hello\\nworld", "hello\\\\nworld".unescapeTabs);
	shouldEqual("hello\\\nworld", "hello\\\\\\nworld".unescapeTabs);
}

/// Returned by findDeclaration
struct DCDDeclaration
{
	string file;
	int position;
}

/// Returned by listCompletion
/// When identifiers: `{type:"identifiers", identifiers:[{identifier:string, type:string, definition:string, file:string, location:number, documentation:string}]}`
/// When calltips: `{type:"calltips", calltips:[string], symbols:[{file:string, location:number, documentation:string}]}`
/// When raw: `{type:"raw", raw:[string]}`
struct DCDCompletions
{
	/// Type of a completion
	enum Type
	{
		/// Unknown/Unimplemented raw output
		raw,
		/// Completion after a dot or a variable name
		identifiers,
		/// Completion for arguments in a function call
		calltips,
	}

	struct Symbol
	{
		string file;
		int location;
		string documentation;
	}

	/// Type of the completion (identifiers, calltips, raw)
	Type type;
	/// Contains the raw DCD output
	string[] raw;
	union
	{
		DCDIdentifier[] _identifiers;
		struct
		{
			string[] _calltips;
			Symbol[] _symbols;
		}
	}

	enum DCDCompletions empty = DCDCompletions(Type.identifiers);

	/// Only set with type==identifiers.
	inout(DCDIdentifier[]) identifiers() inout @property
	{
		if (type != Type.identifiers)
			throw new Exception("Type is not identifiers but attempted to access identifiers");
		return _identifiers;
	}

	/// Only set with type==calltips.
	inout(string[]) calltips() inout @property
	{
		if (type != Type.calltips)
			throw new Exception("Type is not calltips but attempted to access calltips");
		return _calltips;
	}

	/// Only set with type==calltips.
	inout(Symbol[]) symbols() inout @property
	{
		if (type != Type.calltips)
			throw new Exception("Type is not calltips but attempted to access symbols");
		return _symbols;
	}
}

/// Returned by status
struct DCDServerStatus
{
	///
	bool isRunning;
}

/// Type of the identifiers value in listCompletion
struct DCDIdentifier
{
	///
	string identifier;
	///
	string type;
	///
	string definition;
	///
	string file;
	/// byte location
	int location;
	///
	string documentation;
}

/// Returned by search-symbol
struct DCDSearchResult
{
	///
	string file;
	///
	int position;
	///
	string type;
}

private auto filterNonEmpty(T)(T range)
{
	return range.filter!(a => a.length);
}
