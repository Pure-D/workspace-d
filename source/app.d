module workspaced.app;

import workspaced.com.component;

import core.exception;
import std.exception;
import std.bitmanip;
import std.process;
import std.stdio;
import std.json;

static immutable Version = [1, 0, 0];

void send(int id, JSONValue value)
{
	synchronized
	{
		ubyte[] data = nativeToBigEndian(id) ~ (cast(ubyte[]) value.toString());
		stdout.rawWrite(nativeToBigEndian(cast(int) data.length) ~ data);
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
				foreach(name, com; components)
				{
					if(com.initialized)
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
}

int main(string[] args)
{
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
			send(id, handleRequest(data));
		}
		catch (Exception e)
		{
			stderr.writeln(e);
			// dfmt off
			send(id, JSONValue([
				"error" : JSONValue(true),
				"msg": JSONValue(e.msg),
				"exception": JSONValue(e.toString())
			]));
			// dfmt on
		}
		catch (AssertError e)
		{
			stderr.writeln(e);
			// dfmt off
			send(id, JSONValue([
				"error" : JSONValue(true),
				"msg": JSONValue(e.msg),
				"exception": JSONValue(e.toString())
			]));
			// dfmt on
		}
		stdout.flush();
	}
	return 0;
}
