module workspaced.com.dcd;

import std.file : tempDir;

import core.thread;
import std.algorithm;
import std.conv;
import std.datetime;
import std.json;
import std.path;
import std.process;
import std.random;
import std.stdio;
import std.string;

import painlessjson;

import workspaced.api;

version (OSX) version = haveUnixSockets;
version (linux) version = haveUnixSockets;
version (BSD) version = haveUnixSockets;
version (FreeBSD) version = haveUnixSockets;

@component("dcd") :
enum currentVersion = [0, 9, 0];

/// Load function for dcd. Call with `{"cmd": "load", "components": ["dcd"]}`
/// This will start dcd-server and load all import paths specified by previously loaded modules such as dub if autoStart is true.
/// It also checks for the version. All dcd methods are used with `"cmd": "dcd"`
/// Note: This will block any incoming requests while loading.
@load void start(string dir, string clientPath = "dcd-client",
		string serverPath = "dcd-server", ushort port = 9166, bool autoStart = true)
{
	.cwd = dir;
	.serverPath = serverPath;
	.clientPath = clientPath;
	.port = port;
	installedVersion = .clientPath.getVersionAndFixPath;
	if (.serverPath.getVersionAndFixPath != installedVersion)
		throw new Exception("client & server version mismatch");
	version (haveUnixSockets)
		hasUnixDomainSockets = supportsUnixDomainSockets(installedVersion);
	if (autoStart)
		startServer();
	//dfmt off
	if (isOutdated)
		broadcast(JSONValue([
			"type": JSONValue("outdated"),
			"component": JSONValue("dcd")
		]));
	//dfmt on
	running = true;
}

///
bool isOutdated()
{
	return !checkVersion(.clientPath.getVersionAndFixPath, currentVersion);
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
	assert(supportsUnixDomainSockets("1.0.0"));
}

/// This stops the dcd-server instance safely and waits for it to exit
@unload void stop()
{
	stopServerSync();
}

/// This will start the dcd-server and load import paths from the current provider
/// Call_With: `{"subcmd": "setup-server"}`
@arguments("subcmd", "setup-server")
void setupServer(string[] additionalImports = [])
{
	startServer(importPathProvider() ~ importFilesProvider() ~ additionalImports);
}

/// This will start the dcd-server
/// Call_With: `{"subcmd": "start-server"}`
@arguments("subcmd", "start-server")
void startServer(string[] additionalImports = [])
{
	if (isPortRunning(port))
		throw new Exception("Already running dcd on port " ~ port.to!string);
	string[] imports;
	foreach (i; additionalImports)
		if (i.length)
			imports ~= "-I" ~ i;
	.runningPort = port;
	.socketFile = buildPath(tempDir, "workspace-d-sock" ~ thisProcessID.to!string(36));
	serverPipes = raw([serverPath] ~ clientArgs ~ imports,
			Redirect.stdin | Redirect.stderr | Redirect.stdoutToStderr);
	while (!serverPipes.stderr.eof)
	{
		string line = serverPipes.stderr.readln();
		stderr.writeln("Server: ", line);
		stderr.flush();
		if (line.canFind(" Startup completed in "))
			break;
	}
	new Thread({
		while (!serverPipes.stderr.eof)
		{
			stderr.writeln("Server: ", serverPipes.stderr.readln());
		}
		auto code = serverPipes.pid.wait();
		stderr.writeln("DCD-Server stopped with code ", code);
		if (code != 0)
		{
			stderr.writeln("Broadcasting dcd server crash.");
			broadcast(JSONValue(["type" : JSONValue("crash"), "component" : JSONValue("dcd")]));
		}
	}).start();
}

void stopServerSync()
{
	if (serverPipes.pid.tryWait().terminated)
		return;
	int i = 0;
	running = false;
	doClient(["--shutdown"]).pid.wait;
	while (!serverPipes.pid.tryWait().terminated)
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
/// Call_With: `{"subcmd": "stop-server"}`
@async @arguments("subcmd", "stop-server")
void stopServer(AsyncCallback cb)
{
	new Thread({ /**/
		try
		{
			stopServerSync();
			cb(null, JSONValue(null));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// This will kill the process associated with the dcd-server instance
/// Call_With: `{"subcmd": "kill-server"}`
@arguments("subcmd", "kill-server")
void killServer()
{
	if (!serverPipes.pid.tryWait().terminated)
		serverPipes.pid.kill();
}

/// This will stop the dcd-server safely and restart it again using setup-server asynchronously
/// Returns: null
/// Call_With: `{"subcmd": "restart-server"}`
@async @arguments("subcmd", "restart-server")
void restartServer(AsyncCallback cb)
{
	new Thread({ /**/
		try
		{
			stopServerSync();
			setupServer();
			cb(null, JSONValue(null));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// This will query the current dcd-server status
/// Returns: `{isRunning: bool}` If the dcd-server process is not running anymore it will return isRunning: false. Otherwise it will check for server status using `dcd-client --query`
/// Call_With: `{"subcmd": "status"}`
@arguments("subcmd", "status")
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
/// Returns: `[{file: string, position: int, type: string}]`
/// Call_With: `{"subcmd": "search-symbol"}`
@arguments("subcmd", "search-symbol")
@async auto searchSymbol(AsyncCallback cb, string query)
{
	new Thread({
		try
		{
			if (!running)
				return;
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
				results ~= DCDSearchResult(splits[0], splits[2].to!int, splits[1]);
			}
			cb(null, results.toJSON);
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Reloads import paths from the current provider. Call reload there before calling it here.
/// Call_With: `{"subcmd": "refresh-imports"}`
@arguments("subcmd", "refresh-imports")
void refreshImports()
{
	addImports(importPathProvider() ~ importFilesProvider());
}

/// Manually adds import paths as string array
/// Call_With: `{"subcmd": "add-imports"}`
@arguments("subcmd", "add-imports")
void addImports(string[] imports)
{
	knownImports ~= imports;
	updateImports();
}

/// Searches for an open port to spawn dcd-server in asynchronously starting with `port`, always increasing by one.
/// Returns: null if not available, otherwise the port as number
/// Call_With: `{"subcmd": "find-and-select-port"}`
@arguments("subcmd", "find-and-select-port")
@async void findAndSelectPort(AsyncCallback cb, ushort port = 9166)
{
	if (hasUnixDomainSockets)
	{
		cb(null, JSONValue(null));
		return;
	}
	new Thread({ /**/
		try
		{
			auto newPort = findOpen(port);
			.port = newPort;
			cb(null, .port.toJSON());
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Finds the declaration of the symbol at position `pos` in the code
/// Returns: `[0: file: string, 1: position: int]`
/// Call_With: `{"subcmd": "find-declaration"}`
@arguments("subcmd", "find-declaration")
@async void findDeclaration(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			if (!running)
				return;
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
				cb(null, JSONValue(null));
				return;
			}
			string[] splits = line.chomp.split('\t');
			if (splits.length != 2)
			{
				cb(null, JSONValue(null));
				return;
			}
			cb(null, JSONValue([JSONValue(splits[0]), JSONValue(splits[1].to!int)]));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Finds the documentation of the symbol at position `pos` in the code
/// Returns: `[string]`
/// Call_With: `{"subcmd": "get-documentation"}`
@arguments("subcmd", "get-documentation")
@async void getDocumentation(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			if (!running)
				return;
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
			cb(null, JSONValue(data.unescapeTabs));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// Returns the used socket file. Only available on OSX, linux and BSD with DCD >= 0.8.0
/// Throws an error if not available.
@arguments("subcmd", "get-socketfile")
string getSocketFile()
{
	if (!hasUnixDomainSockets)
		throw new Exception("Unix domain sockets not supported");
	return socketFile;
}

/// Returns the used running port. Throws an error if using unix sockets instead
@arguments("subcmd", "get-port")
ushort getRunningPort()
{
	if (hasUnixDomainSockets)
		throw new Exception("Using unix domain sockets instead of a port");
	return runningPort;
}

/// Queries for code completion at position `pos` in code
/// Returns: `{type:string}` where type is either identifiers, calltips or raw.
/// When identifiers: `{type:"identifiers", identifiers:[{identifier:string, type:string, definition:string, file:string, location:number, documentation:string}]}`
/// When calltips: `{type:"calltips", calltips:[string], symbols:[{file:string, location:number, documentation:string}]}`
/// When raw: `{type:"raw", raw:[string]}`
/// Raw is anything else than identifiers and calltips which might not be implemented by this point.
/// calltips.symbols and identifiers.definition, identifiers.file, identifiers.location and identifiers.documentation are only available with dcd ~master as of now.
/// Call_With: `{"subcmd": "list-completion"}`
@arguments("subcmd", "list-completion")
@async void listCompletion(AsyncCallback cb, string code, int pos, bool full)
{
	new Thread({
		try
		{
			if (!running)
				return;
			auto pipes = doClient((full ? ["--extended"] : []) ~ ["-c", pos.to!string]);
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
				if (line.length == 0)
					continue;
				data ~= line.chomp;
			}
			int[] emptyArr;
			if (data.length == 0)
			{
				cb(null, JSONValue(["type" : JSONValue("identifiers"), "identifiers" : emptyArr.toJSON()]));
				return;
			}
			if (data[0] == "calltips")
			{
				string[] calltips;
				JSONValue[] symbols;
				if (full)
				{
					foreach (line; data[1 .. $])
					{
						auto parts = line.split("\t");
						if (parts.length < 5)
							continue;
						calltips ~= parts[2];
						string location = parts[3];
						string file;
						int index;
						if (location.length)
						{
							auto space = location.indexOf(' ');
							if (space != -1)
							{
								file = location[0 .. space];
								index = location[space + 1 .. $].to!int;
							}
						}
						symbols ~= JSONValue(["file" : JSONValue(file), "location"
							: JSONValue(index), "documentation" : JSONValue(parts[4].unescapeTabs)]);
					}
				}
				else
				{
					calltips = data[1 .. $];
					symbols.length = calltips.length;
				}
				cb(null, JSONValue(["type" : JSONValue("calltips"), "calltips"
					: calltips.toJSON(), "symbols" : JSONValue(symbols)]));
				return;
			}
			else if (data[0] == "identifiers")
			{
				DCDIdentifier[] identifiers;
				foreach (line; data[1 .. $])
				{
					string[] splits = line.split('\t');
					DCDIdentifier symbol;
					if (full)
					{
						if (splits.length < 5)
							continue;
						string location = splits[3];
						string file;
						int index;
						if (location.length)
						{
							auto space = location.indexOf(' ');
							if (space != -1)
							{
								file = location[0 .. space];
								index = location[space + 1 .. $].to!int;
							}
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
				cb(null, JSONValue(["type" : JSONValue("identifiers"), "identifiers"
					: identifiers.toJSON()]));
				return;
			}
			else
			{
				cb(null, JSONValue(["type" : JSONValue("raw"), "raw" : data.toJSON()]));
				return;
			}
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
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

private:

__gshared
{
	string clientPath, serverPath, cwd;
	string installedVersion;
	bool hasUnixDomainSockets = false;
	bool running = false;
	ProcessPipes serverPipes;
	ushort port, runningPort;
	string socketFile;
	string[] knownImports;
}

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
	return pipeProcess(args, redirect, null, Config.none, cwd);
}

auto execClient(string[] args)
{
	return rawExec([clientPath] ~ clientArgs ~ args);
}

auto rawExec(string[] args)
{
	return execute(args, null, Config.none, size_t.max, cwd);
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

string unescapeTabs(string val)
{
	return val.replace("\\t", "\t").replace("\\n", "\n").replace("\\\\", "\\");
}
