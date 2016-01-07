module workspaced.app;

import core.sync.mutex;
import core.exception;

import painlessjson;

import workspaced.api;

import workspaced.com.dub;

import std.exception;
import std.bitmanip;
import std.process;
import std.traits;
import std.stdio;
import std.json;
import std.meta;
import std.conv;

static immutable Version = [2, 0, 0];

void sendFinal(int id, JSONValue value)
{
	ubyte[] data = nativeToBigEndian(id) ~ (cast(ubyte[]) value.toString());
	stdout.rawWrite(nativeToBigEndian(cast(int) data.length) ~ data);
	stdout.flush();
}

void send(int id, JSONValue[] values)
{
	if (values.length == 0)
	{
		throw new Exception("Unknown arguments!");
	}
	else if (values.length == 1)
	{
		sendFinal(id, values[0]);
	}
	else
	{
		sendFinal(id, JSONValue(values));
	}
}

JSONValue toJSONArray(T)(T value)
{
	JSONValue[] vals;
	foreach (val; value)
	{
		vals ~= JSONValue(val);
	}
	return JSONValue(vals);
}

/*
JSONValue handleRequest(JSONValue value)
{
	assert(value.type == JSON_TYPE.OBJECT, "Request must be an object!");
	auto cmd = "cmd" in value;
	assert(cmd, "No command specified!");
	assert(cmd.type == JSON_TYPE.STRING, "Command must be a string!");
	string command = cmd.str;
	switch (command)
	{
	case "version":
		// dfmt off
		return JSONValue([
			"major": JSONValue(Version[0]),
			"minor": JSONValue(Version[1]),
			"patch": JSONValue(Version[2])
		]);
		// dfmt on
	case "load":
		auto comsp = "components" in value;
		assert(comsp, "No components specified");
		auto coms = *comsp;
		string[] toLoad;
		switch (coms.type)
		{
		case JSON_TYPE.STRING:
			toLoad ~= coms.str;
			break;
		case JSON_TYPE.ARRAY:
			foreach (val; coms.array)
			{
				assert(val.type == JSON_TYPE.STRING, "Components must either be a string or a string array");
				toLoad ~= val.str;
			}
			break;
		default:
		}
		foreach (name; toLoad)
		{
			if ((name in components) is null)
				throw new Exception("Component '" ~ name ~ "' not found!");
			components[name].initialize(value);
		}
		return JSONValue(["loaded" : toLoad.toJSONArray()]);
	case "unload":
		auto comsp = "components" in value;
		assert(comsp, "No components specified");
		auto coms = *comsp;
		string[] toLoad;
		switch (coms.type)
		{
		case JSON_TYPE.STRING:
			if (coms.str == "*")
			{
				foreach (name, com; components)
				{
					if (com.initialized)
					{
						toLoad ~= name;
						com.deinitialize(value);
					}
				}
				return JSONValue(["unloaded" : toLoad.toJSONArray()]);
			}
			else
			{
				toLoad ~= coms.str;
			}
			break;
		case JSON_TYPE.ARRAY:
			foreach (val; coms.array)
			{
				assert(val.type == JSON_TYPE.STRING, "Components must either be a string or a string array");
				toLoad ~= val.str;
			}
			break;
		default:
		}
		foreach (name; toLoad)
		{
			components[name].deinitialize(value);
		}
		return JSONValue(["unloaded" : toLoad.toJSONArray()]);
	default:
		if ((command in components) !is null)
		{
			auto com = components[command];
			if (!com.initialized)
				throw new Exception("Component not initialized: " ~ command);
			return com.process(value);
		}
		else
		{
			throw new Exception("Unknown command: " ~ command);
		}
	}
}*/

alias Identity(I...) = I;

template JSONType(T, string value)
{
	static if (isSomeString!T)
		enum JSONType = value ~ ".str";
	else static if (isNumeric!T)
		enum JSONType = value ~ ".integer";
	else static if (isBoolean!T)
		enum JSONType = value ~ ".type != JSON_TYPE.FALSE && " ~ value ~ ".type != JSON_TYPE.NULL";
	else static if (isFloatingPoint!T)
		enum JSONType = value ~ ".floating";
	else
		static assert("Not implemented type " ~ T.stringof);
}

template JSONCallBody(alias T, string fn, string jsonvar, size_t i, Args...)
{
	static if (Args.length == i)
		enum JSONCallBody = "";
	else static if (is(ParameterDefaults!T[i] == void))
		enum JSONCallBody = "(assert(`" ~ Args[i] ~ "` in " ~ jsonvar ~ ", `" ~ Args[i] ~ " has no default value and is not in the JSON request`), " ~ JSONType!(
				Parameters!T[i], jsonvar ~ "[`" ~ Args[i] ~ "`]") ~ ")," ~ JSONCallBody!(T, fn, jsonvar, i + 1, Args);
	else
		enum JSONCallBody = "(`" ~ Args[i] ~ "` in " ~ jsonvar ~ ") ? " ~ JSONType!(Parameters!T[i], jsonvar ~ "[`" ~ Args[i] ~ "`]") ~ " : ParameterDefaults!(" ~ fn ~ ")[" ~ i
				.to!string ~ "]," ~ JSONCallBody!(T, fn, jsonvar, i + 1, Args);
}

template JSONCallNoRet(alias T, string fn, string jsonvar, bool async)
{
	alias Args = ParameterIdentifierTuple!T;
	static if (Args.length > 0)
		enum JSONCallNoRet = fn ~ "(" ~ (async ? "asyncCallback," : "") ~ JSONCallBody!(T, fn, jsonvar, async ? 1 : 0, Args) ~ ")";
	else
		enum JSONCallNoRet = fn ~ "(" ~ (async ? "asyncCallback" : "") ~ ")";
}

template JSONCall(alias T, string fn, string jsonvar, bool async)
{
	static if (async)
		enum JSONCall = JSONCallNoRet!(T, fn, jsonvar, async) ~ ";";
	else
	{
		alias Ret = ReturnType!T;
		static if (is(Ret == void))
			enum JSONCall = JSONCallNoRet!(T, fn, jsonvar, async) ~ ";";
		else
			enum JSONCall = "values ~= " ~ JSONCallNoRet!(T, fn, jsonvar, async) ~ ".toJSON;";
	}
}

void handleRequest(int id, JSONValue request)
{
	JSONValue[] values;
	int asyncWaiting = 0;
	bool isAsync = false;
	bool hasArgs = false;

	//dfmt off
	AsyncCallback asyncCallback = (value)
	{
		synchronized
		{
			assert(isAsync);
			values ~= value;
			asyncWaiting--;
			if (asyncWaiting == 0)
				send(id, values);
		}
	};
	//dfmt on

	foreach (name; __traits(allMembers, workspaced.com.dub))
	{
		static if (__traits(compiles, __traits(getMember, workspaced.com.dub, name)))
		{
			alias symbol = Identity!(__traits(getMember, workspaced.com.dub, name));
			static if (isSomeFunction!symbol)
			{
				bool matches = false;
				foreach (Arguments args; getUDAs!(symbol, Arguments))
				{
					if (!matches)
					{
						foreach (arg; args.arguments)
						{
							if (!matches)
							{
								auto nodeptr = arg.key in request;
								if (nodeptr && *nodeptr == arg.value)
									matches = true;
							}
						}
					}
				}
				static if (hasUDA!(symbol, any))
					matches = true;
				static if (hasUDA!(symbol, component))
				{
					if (("cmd" in request) !is null && request["cmd"].type == JSON_TYPE.STRING && getUDAs!(symbol, component)[0].name != request["cmd"].str)
						matches = false;
				}
				static if (hasUDA!(symbol, load) && hasUDA!(symbol, component))
				{
					if (("components" in request) !is null && ("cmd" in request) !is null && request["cmd"].type == JSON_TYPE.STRING && request["cmd"].str == "load")
					{
						if (request["components"].type == JSON_TYPE.ARRAY)
						{
							foreach (com; request["components"].array)
								if (com.type == JSON_TYPE.STRING && com.str == getUDAs!(symbol, component)[0].name)
									matches = true;
						}
						else if (request["components"].type == JSON_TYPE.STRING && request["components"].str == getUDAs!(symbol, component)[0].name)
							matches = true;
					}
				}
				static if (hasUDA!(symbol, unload) && hasUDA!(symbol, component))
				{
					if (("components" in request) !is null && ("cmd" in request) !is null && request["cmd"].type == JSON_TYPE.STRING && request["cmd"].str == "unload")
					{
						if (request["components"].type == JSON_TYPE.ARRAY)
						{
							foreach (com; request["components"].array)
								if (com.type == JSON_TYPE.STRING && com.str == getUDAs!(symbol, component)[0].name)
									matches = true;
						}
						else if (request["components"].type == JSON_TYPE.STRING && request["components"].str == getUDAs!(symbol, component)[0].name)
							matches = true;
					}
				}
				if (matches)
				{
					static if (hasUDA!(symbol, async))
					{
						assert(!hasArgs);
						isAsync = true;
						asyncWaiting++;
						mixin(JSONCall!(symbol[0], "symbol[0]", "request", true));
					}
					else
					{
						assert(!isAsync);
						hasArgs = true;
						mixin(JSONCall!(symbol[0], "symbol[0]", "request", false));
					}
				}
			}
		}
	}
	if (isAsync)
	{
		if (values.length > 0)
			throw new Exception("Cannot mix sync and async functions!");
	}
	else
	{
		if (hasArgs && values.length == 0)
			sendFinal(id, JSONValue(null));
		else
			send(id, values);
	}
}

int main(string[] args)
{
	import std.file;
	import etc.linux.memoryerror;

	static if (is(typeof(registerMemoryErrorHandler)))
		registerMemoryErrorHandler();

	int length = 0;
	int id = 0;
	ubyte[4] intBuffer;
	ubyte[] dataBuffer;
	while (stdin.isOpen && stdout.isOpen && !stdin.eof)
	{
		try
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

			auto data = parseJSON(cast(string) dataBuffer);
			handleRequest(id, data);
		}
		catch (Exception e)
		{
			stderr.writeln(e);
			// dfmt off
			sendFinal(id, JSONValue([
				"error": JSONValue(true),
				"msg": JSONValue(e.msg),
				"exception": JSONValue(e.toString())
			]));
			// dfmt on
		}
		catch (AssertError e)
		{
			stderr.writeln(e);
			// dfmt off
			sendFinal(id, JSONValue([
				"error": JSONValue(true),
				"msg": JSONValue(e.msg),
				"exception": JSONValue(e.toString())
			]));
			// dfmt on
		}
		stdout.flush();
	}
	return 0;
}
