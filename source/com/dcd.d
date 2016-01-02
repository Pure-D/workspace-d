module workspaced.com.dcd;

import workspaced.com.component;

import std.json;
import std.conv;
import std.stdio;
import std.string;
import std.process;
import core.thread;

import painlessjson;

private struct DCDInit
{
	ushort port = 9166;
	string clientPath = "dcd-client";
	string serverPath = "dcd-server";
	string dir;
	bool autoStart = true;
}

private struct DCDServerStatus
{
	bool isRunning;
}

private struct DCDIdentifier
{
	string identifier;
	string type;
}

private struct DCDSearchResult
{
	string file;
	int position;
	string type;
}

class DCDComponent : Component
{
public:
	override void load(JSONValue args)
	{
		DCDInit value = fromJSON!DCDInit(args);
		assert(value.dir, "dcd initialization requires a 'dir' field");
		cwd = value.dir;
		clientPath = value.clientPath;
		serverPath = value.serverPath;
		port = value.port;
		if (value.autoStart)
			startServer();
	}

	override void unload(JSONValue args)
	{
		auto pipes = stopServer();
		pipes.pid.wait();
	}

	void startServer()
	{
		if (isPortRunning(port))
			throw new Exception("Already running dcd on port " ~ to!string(port));
		runningPort = port;
		serverPipes = raw([serverPath, "--port", to!string(runningPort)], Redirect.stdin | Redirect.stdoutToStderr);
		new Thread({
			while (!serverPipes.stderr.eof)
			{
				stderr.writeln("Server: ", serverPipes.stderr.readln());
			}
			stderr.writeln("DCD-Server stopped with code ", serverPipes.pid.wait());
		}).start();
	}

	auto stopServer()
	{
		return doClient(["--shutdown"]);
	}

	void killServer()
	{
		if (!serverPipes.pid.tryWait().terminated)
			serverPipes.pid.kill();
	}

	void addImports(string[] imports)
	{
		string[] args;
		foreach (path; knownImports)
			args ~= "-I" ~ path;
		foreach (path; imports)
			args ~= "-I" ~ path;
		knownImports ~= imports;
		doClient(args).pid.wait();
	}

	@property auto serverStatus()
	{
		DCDServerStatus status;
		if (serverPipes.pid.tryWait().terminated)
			status.isRunning = false;
		else
			status.isRunning = isPortRunning(runningPort) == 0;
		return status;
	}

	string getDocumentation(string code, int location)
	{
		auto pipes = doClient(["--doc", "-c", to!string(location)]);
		pipes.stdin.write(code);
		pipes.stdin.close();
		string data;
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			string line = pipes.stdout.readln();
			if (line.length)
				data ~= line[0 .. $ - 1];
		}
		return data.replace("\\n", "\n");
	}

	JSONValue findDeclaration(string code, int location)
	{
		auto pipes = doClient(["-c", to!string(location), "--symbolLocation"]);
		scope (exit)
			pipes.pid.wait();
		pipes.stdin.write(code);
		pipes.stdin.close();
		string line = pipes.stdout.readln();
		if (line.length == 0)
			return JSONValue(null);
		string[] splits = line[0 .. $ - 1].split('\t');
		if (splits.length != 2)
			return JSONValue(null);
		return JSONValue([JSONValue(splits[0]), JSONValue(toImpl!int(splits[1]))]);
	}

	DCDSearchResult[] searchSymbol(string query)
	{
		auto pipes = doClient(["--search", query]);
		scope (exit)
			pipes.pid.wait();
		pipes.stdin.close();
		DCDSearchResult[] results;
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			string line = pipes.stdout.readln();
			if (line.length == 0)
				continue;
			string[] splits = line[0 .. $ - 1].split('\t');
			results ~= DCDSearchResult(splits[0], toImpl!(int)(splits[2]), splits[1]);
		}
		return results;
	}

	override JSONValue process(JSONValue args)
	{
		string cmd = args.getString("subcmd");
		switch (cmd)
		{
		case "status":
			return serverStatus.toJSON();
		case "setup-server":
			startServer();
			addImports(getImportPathProvider().importPaths);
			break;
		case "start-server":
			startServer();
			break;
		case "stop-server":
			stopServer().pid.wait();
			break;
		case "kill-server":
			killServer();
			break;
		case "restart-server":
			auto pipes = stopServer();
			pipes.pid.wait();
			startServer();
			break;
		case "find-and-select-port":
			auto newPort = findOpen(cast(ushort) args.getInt("port"));
			port = newPort;
			return port.toJSON();
		case "list-completion":
			string code = args.getString("code");
			auto pos = args.getInt("pos");
			auto pipes = doClient(["-c", to!string(pos)]);
			scope (exit)
				pipes.pid.wait();
			pipes.stdin.write(code);
			pipes.stdin.close();
			string[] data;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
			{
				string line = pipes.stdout.readln();
				if (line.length == 0)
					continue;
				data ~= line[0 .. $ - 1];
			}
			int[] emptyArr;
			if (data.length == 0)
				return JSONValue(["type" : JSONValue("identifiers"), "identifiers" : emptyArr.toJSON()]);
			if (data[0] == "calltips")
			{
				return JSONValue(["type" : JSONValue("calltips"), "calltips" : data[1 .. $].toJSON()]);
			}
			else if (data[0] == "identifiers")
			{
				DCDIdentifier[] identifiers;
				foreach (line; data[1 .. $])
				{
					string[] splits = line.split('\t');
					identifiers ~= DCDIdentifier(splits[0], splits[1]);
				}
				return JSONValue(["type" : JSONValue("identifiers"), "identifiers" : identifiers.toJSON()]);
			}
			else
			{
				return JSONValue(["type" : JSONValue("raw"), "raw" : data.toJSON()]);
			}
		case "get-documentation":
			return getDocumentation(args.getString("code"), cast(int) args.getInt("pos")).toJSON();
		case "find-declaration":
			return findDeclaration(args.getString("code"), cast(int) args.getInt("pos"));
		case "search-symbol":
			return searchSymbol(args.getString("query")).toJSON();
		case "refresh-imports":
			addImports(getImportPathProvider().importPaths);
			break;
		case "add-imports":
			assert("imports" in args, "No import paths specified");
			addImports(fromJSON!(string[])(args["imports"]));
			break;
		default:
			throw new Exception("Unknown command: '" ~ cmd ~ "'");
		}
		return JSONValue(null);
	}

private:
	auto doClient(string[] args)
	{
		return raw([clientPath, "--port", to!string(runningPort)] ~ args);
	}

	auto raw(string[] args, Redirect redirect = Redirect.all)
	{
		auto pipes = pipeProcess(args, redirect, null, Config.none, cwd);
		return pipes;
	}

	bool isPortRunning(ushort port)
	{
		auto pipes = raw([clientPath, "-q", "--port", to!string(port)]);
		return wait(pipes.pid) == 0;
	}

	ushort findOpen(ushort port)
	{
		port--;
		bool isRunning;
		do
		{
			port++;
			isRunning = isPortRunning(port);
		}
		while (isRunning);
		return port;
	}

	string clientPath, serverPath, cwd;
	ProcessPipes serverPipes;
	ushort port, runningPort;
	string[] knownImports;
}

shared static this()
{
	components["dcd"] = new DCDComponent();
}
