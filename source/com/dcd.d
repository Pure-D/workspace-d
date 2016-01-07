module workspaced.com.dcd;

import std.json;
import std.conv;
import std.stdio;
import std.string;
import std.process;
import core.thread;

import painlessjson;

import workspaced.api;

@component("dcd") :

@load void start(string dir, string clientPath = "dcd-client", string serverPath = "dcd-server", ushort port = 9166, bool autoStart = true)
{
	.cwd = dir;
	.serverPath = serverPath;
	.clientPath = clientPath;
	.port = port;
	if (autoStart)
		startServer();
}

@unload void stop()
{
	stopServerSync();
}

@arguments("subcmd", "setup-server")
@arguments("subcmd", "start-server")
void startServer()
{
	if (isPortRunning(port))
		throw new Exception("Already running dcd on port " ~ port.to!string);
	runningPort = port;
	serverPipes = raw([serverPath, "--port", runningPort.to!string], Redirect.stdin | Redirect.stdoutToStderr);
	updateImports();
	new Thread({
		while (!serverPipes.stderr.eof)
		{
			stderr.writeln("Server: ", serverPipes.stderr.readln());
		}
		stderr.writeln("DCD-Server stopped with code ", serverPipes.pid.wait());
	}).start();
}

void stopServerSync()
{
	doClient(["--shutdown"]).pid.wait;
}

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

@arguments("subcmd", "kill-server")
void killServer()
{
	if (!serverPipes.pid.tryWait().terminated)
		serverPipes.pid.kill();
}

@async @arguments("subcmd", "restart-server")
void restartServer(AsyncCallback cb)
{
	new Thread({ /**/
		try
		{
			stopServerSync();
			startServer();
			cb(null, JSONValue(null));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

@arguments("subcmd", "status")
auto serverStatus() @property
{
	DCDServerStatus status;
	if (serverPipes.pid.tryWait().terminated)
		status.isRunning = false;
	else
		status.isRunning = isPortRunning(runningPort) == 0;
	return status;
}

@arguments("subcmd", "search-symbol")
@async auto searchSymbol(AsyncCallback cb, string query)
{
	new Thread({
		try
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
			cb(null, results.toJSON);
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

@arguments("subcmd", "refresh-imports")
void refreshImports()
{
	addImports(importPathProvider());
}

@arguments("subcmd", "add-imports")
void addImports(string[] imports)
{
	knownImports ~= imports;
	updateImports();
}

@arguments("subcmd", "find-and-select-port")
@async void findAndSelectPort(AsyncCallback cb, ushort port = 9166)
{
	new Thread({ /**/
		try
		{
			auto newPort = findOpen(port);
			port = newPort;
			cb(null, port.toJSON());
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

@arguments("subcmd", "find-declaration")
@async void findDeclaration(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			auto pipes = doClient(["-c", pos.to!string, "--symbolLocation"]);
			scope (exit)
				pipes.pid.wait();
			pipes.stdin.write(code);
			pipes.stdin.close();
			string line = pipes.stdout.readln();
			if (line.length == 0)
			{
				cb(null, JSONValue(null));
				return;
			}
			string[] splits = line[0 .. $ - 1].split('\t');
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

@arguments("subcmd", "get-documentation")
@async void getDocumentation(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			auto pipes = doClient(["--doc", "-c", pos.to!string]);
			pipes.stdin.write(code);
			pipes.stdin.close();
			string data;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
			{
				string line = pipes.stdout.readln();
				if (line.length)
					data ~= line[0 .. $ - 1];
			}
			cb(null, JSONValue(data.replace("\\n", "\n")));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

@arguments("subcmd", "list-completion")
@async void listCompletion(AsyncCallback cb, string code, int pos)
{
	new Thread({
		try
		{
			auto pipes = doClient(["-c", pos.to!string]);
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
			{
				cb(null, JSONValue(["type" : JSONValue("identifiers"), "identifiers" : emptyArr.toJSON()]));
				return;
			}
			if (data[0] == "calltips")
			{
				cb(null, JSONValue(["type" : JSONValue("calltips"), "calltips" : data[1 .. $].toJSON()]));
				return;
			}
			else if (data[0] == "identifiers")
			{
				DCDIdentifier[] identifiers;
				foreach (line;
				data[1 .. $])
				{
					string[] splits = line.split('\t');
					identifiers ~= DCDIdentifier(splits[0], splits[1]);
				}
				cb(null, JSONValue(["type" : JSONValue("identifiers"), "identifiers" : identifiers.toJSON()]));
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
	string[] args;
	foreach (path; knownImports)
		args ~= "-I" ~ path;
	doClient(args).pid.wait();
}

private __gshared:

string clientPath, serverPath, cwd;
ProcessPipes serverPipes;
ushort port, runningPort;
string[] knownImports;

auto doClient(string[] args)
{
	return raw([clientPath, "--port", runningPort.to!string] ~ args);
}

auto raw(string[] args, Redirect redirect = Redirect.all)
{
	auto pipes = pipeProcess(args, redirect, null, Config.none, cwd);
	return pipes;
}

bool isPortRunning(ushort port)
{
	auto pipes = raw([clientPath, "-q", "--port", port.to!string]);
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
