module app;

import core.sync.mutex;
import core.exception;

import painlessjson;
import standardpaths;

import workspaced.api;
import workspaced.coms;

import std.algorithm;
import std.bitmanip;
import std.exception;
import std.functional;
import std.process;
import std.stdio : File, stderr;
import std.traits;

static import std.stdio;
import std.string;
import std.json;
import std.meta;
import std.conv;

import source.workspaced.info;

__gshared File stdin, stdout;
shared static this()
{
	stdin = std.stdio.stdin;
	stdout = std.stdio.stdout;
	version (Windows)
		std.stdio.stdin = File("NUL", "r");
	else version (Posix)
		std.stdio.stdin = File("/dev/null", "r");
	else
		stderr.writeln("warning: no /dev/null implementation on this OS");
	std.stdio.stdout = stderr;
}

__gshared Mutex writeMutex, commandMutex;

void sendResponse(int id, JSONValue message)
{
	synchronized (writeMutex)
	{
		ubyte[] data = nativeToBigEndian(id) ~ (cast(ubyte[]) message.toString());
		stdout.rawWrite(nativeToBigEndian(cast(int) data.length) ~ data);
		stdout.flush();
	}
}

void sendException(int id, Throwable t)
{
	JSONValue[string] message;
	message["error"] = JSONValue(true);
	message["msg"] = JSONValue(t.msg);
	message["exception"] = JSONValue(t.toString);
	sendResponse(id, JSONValue(message));
}

void broadcast(WorkspaceD workspaced, WorkspaceD.Instance instance, JSONValue message)
{
	sendResponse(0x7F000000, JSONValue([
		"workspace": JSONValue(instance ? instance.cwd : null),
		"data": message
	]));
}

WorkspaceD engine;

void handleRequest(int id, JSONValue request)
{
	if ("cmd" !in request || request["cmd"].type != JSON_TYPE.STRING)
	{
		goto printUsage;
	}
	else if (request["cmd"].str == "version")
	{
		sendResponse(id, getVersionInfoJson);
	}
	else if (request["cmd"].str == "load")
	{
		if ("component" !in request || request["component"].type != JSON_TYPE.STRING)
		{
			sendException(id,
					new Exception(`Expected load message to be in format {"cmd":"load", "component":string}`));
		}
		else
		{
			string[] allComponents;
			static foreach (Component; AllComponents)
				allComponents ~= getUDAs!(Component, ComponentInfo)[0].name;
		ComponentSwitch:
			switch (request["component"].str)
			{
				static foreach (Component; AllComponents)
				{
			case getUDAs!(Component, ComponentInfo)[0].name:
					engine.register!Component;
					break ComponentSwitch;
				}
			default:
				sendException(id,
						new Exception(
							"Unknown Component '" ~ request["component"].str ~ "', built-in are " ~ allComponents.join(
							", ")));
				return;
			}
			sendResponse(id, JSONValue(true));
		}
	}
	else if (request["cmd"].str == "new")
	{
		if ("cwd" !in request || request["cwd"].type != JSON_TYPE.STRING)
		{
			sendException(id,
					new Exception(
						`Expected new message to be in format {"cmd":"new", "cwd":string, ("config":object)}`));
		}
		else
		{
			string cwd = request["cwd"].str;
			if ("config" in request)
				engine.addInstance(cwd, Configuration(request["config"]));
			else
				engine.addInstance(cwd);
			sendResponse(id, JSONValue(true));
		}
	}
	else if (request["cmd"].str == "config")
	{
		throw new Exception("Not implemented");
	}
	else if (request["cmd"].str == "call")
	{
		JSONValue[] params;
		if ("params" in request)
		{
			if (request["params"].type != JSON_TYPE.ARRAY)
				goto callFail;
			params = request["params"].array;
		}
		if ("method" !in request || request["method"].type != JSON_TYPE.STRING
				|| "component" !in request || request["component"].type != JSON_TYPE.STRING)
		{
		callFail:
			sendException(id, new Exception(`Expected call message to be in format {"cmd":"call", "component":string, "method":string, ("cwd":string), ("params":object[])}`));
		}
		else
		{
			Future!JSONValue ret;
			string component = request["component"].str;
			string method = request["method"].str;
			if ("cwd" in request)
			{
				if (request["cwd"].type != JSON_TYPE.STRING)
				{
					goto callFail;
				}
				else
				{
					string cwd = request["cwd"].str;
					ret = engine.run(cwd, component, method, params);
				}
			}
			else
				ret = engine.run(component, method, params);

			ret.onDone = {
				if (ret.exception)
					sendException(id, ret.exception);
				else
					sendResponse(id, ret.value);
			};
		}
	}
	else
	{
	printUsage:
		sendException(id, new Exception(
				"Invalid request, must contain a cmd string key with one of the values [version, load, new, config, call]"));
	}
}

void processException(int id, Throwable e)
{
	stderr.writeln(e);
	// dfmt off
	sendResponse(id, JSONValue([
		"error": JSONValue(true),
		"msg": JSONValue(e.msg),
		"exception": JSONValue(e.toString())
	]));
	// dfmt on
}

void processException(int id, JSONValue request, Throwable e)
{
	stderr.writeln(e);
	// dfmt off
	sendResponse(id, JSONValue([
		"error": JSONValue(true),
		"msg": JSONValue(e.msg),
		"exception": JSONValue(e.toString()),
		"request": request
	]));
	// dfmt on
}

int main(string[] args)
{
	import std.file;
	import etc.linux.memoryerror;

	version (unittest)
	{
	}
	else
	{
		version (DigitalMars)
			static if (is(typeof(registerMemoryErrorHandler)))
				registerMemoryErrorHandler();

		if (args.length > 1 && (args[1] == "-v" || args[1] == "--version" || args[1] == "-version"))
		{
			stdout.writeln(getVersionInfoString);
			return 0;
		}

		engine = new WorkspaceD();
		engine.onBroadcast = (&broadcast).toDelegate;

		writeMutex = new Mutex;
		commandMutex = new Mutex;

		int length = 0;
		int id = 0;
		ubyte[4] intBuffer;
		ubyte[] dataBuffer;
		JSONValue data;

		scope (exit)
			handleRequest(int.min, JSONValue(["cmd" : "unload", "components" : "*"]));

		stderr.writeln("Config files stored in ", standardPaths(StandardPath.config, "workspace-d"));

		while (stdin.isOpen && stdout.isOpen && !stdin.eof)
		{
			dataBuffer = stdin.rawRead(intBuffer);
			assert(dataBuffer.length == 4, "Unexpected buffer data");
			length = bigEndianToNative!int(dataBuffer[0 .. 4]);

			assert(length >= 4, "Invalid request");

			dataBuffer = stdin.rawRead(intBuffer);
			assert(dataBuffer.length == 4, "Unexpected buffer data");
			id = bigEndianToNative!int(dataBuffer[0 .. 4]);

			dataBuffer.length = length - 4;
			dataBuffer = stdin.rawRead(dataBuffer);

			try
			{
				data = parseJSON(cast(string) dataBuffer);
			}
			catch (Exception e)
			{
				processException(id, e);
			}
			catch (AssertError e)
			{
				processException(id, e);
			}

			try
			{
				handleRequest(id, data);
			}
			catch (Exception e)
			{
				processException(id, data, e);
			}
			catch (AssertError e)
			{
				processException(id, data, e);
			}
			stdout.flush();
		}
	}
	return 0;
}
