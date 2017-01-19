module workspaced.app;

import core.sync.mutex;
import core.exception;

import painlessjson;
import standardpaths;

import workspaced.api;

import std.exception;
import std.bitmanip;
import std.process;
import std.traits;
import std.stdio : stderr, File;

static import std.stdio;
import std.json;
import std.meta;
import std.conv;

import source.info;

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

static import workspaced.com.dcd;

static import workspaced.com.dfmt;

static import workspaced.com.dlangui;

static import workspaced.com.dscanner;

static import workspaced.com.dub;

static import workspaced.com.fsworkspace;

static import workspaced.com.importer;

__gshared Mutex writeMutex, commandMutex;

void sendFinal(int id, JSONValue value)
{
	synchronized (writeMutex)
	{
		ubyte[] data = nativeToBigEndian(id) ~ (cast(ubyte[]) value.toString());
		stdout.rawWrite(nativeToBigEndian(cast(int) data.length) ~ data);
		stdout.flush();
	}
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

alias Identity(I...) = I;

template JSONCallBody(alias T, string fn, string jsonvar, size_t i, Args...)
{
	static if (Args.length == 1 && Args[0] == "request" && is(Parameters!T[0] == JSONValue))
		enum JSONCallBody = jsonvar;
	else static if (Args.length == i)
		enum JSONCallBody = "";
	else static if (is(ParameterDefaults!T[i] == void))
		enum JSONCallBody = "(fromJSON!(Parameters!(" ~ fn ~ ")[" ~ i.to!string
				~ "])(*enforce(`" ~ Args[i] ~ "` in " ~ jsonvar ~ ", `"
				~ Args[i] ~ " has no default value and is not in the JSON request`))),"
				~ JSONCallBody!(T, fn, jsonvar, i + 1, Args);
	else
					enum JSONCallBody = "(`" ~ Args[i] ~ "` in " ~ jsonvar ~ ") ? fromJSON!(Parameters!("
							~ fn ~ ")[" ~ i.to!string ~ "])(" ~ jsonvar ~ "[`" ~ Args[i] ~ "`]"
							~ ") : ParameterDefaults!(" ~ fn ~ ")[" ~ i.to!string ~ "]," ~ JSONCallBody!(T,
									fn, jsonvar, i + 1, Args);
}

template JSONCallNoRet(alias T, string fn, string jsonvar, bool async)
{
	alias Args = ParameterIdentifierTuple!T;
	static if (Args.length > 0)
		enum JSONCallNoRet = fn ~ "(" ~ (async ? "asyncCallback,"
					: "") ~ JSONCallBody!(T, fn, jsonvar, async ? 1 : 0, Args) ~ ")";
	else
		enum JSONCallNoRet = fn ~ "(" ~ (async ? "asyncCallback" : "") ~ ")";
}

template JSONCall(alias T, string fn, string jsonvar, bool async)
{
	static if (async)
	{
		static assert(is(ReturnType!T == void),
				"Async functions cant have an return type! For function " ~ fn);
		enum JSONCall = JSONCallNoRet!(T, fn, jsonvar, async) ~ ";";
	}
	else
	{
		alias Ret = ReturnType!T;
		static if (is(Ret == void))
			enum JSONCall = JSONCallNoRet!(T, fn, jsonvar, async) ~ ";";
		else
			enum JSONCall = "values ~= " ~ JSONCallNoRet!(T, fn, jsonvar, async) ~ ".toJSON;";
	}
}

template compatibleGetUDAs(alias symbol, alias attribute)
{
	import std.typetuple : Filter;

	template isDesiredUDA(alias S)
	{
		static if (__traits(compiles, is(typeof(S) == attribute)))
		{
			enum isDesiredUDA = is(typeof(S) == attribute);
		}
		else
		{
			enum isDesiredUDA = isInstanceOf!(attribute, typeof(S));
		}
	}

	alias compatibleGetUDAs = Filter!(isDesiredUDA, __traits(getAttributes, symbol));
}

void handleRequestMod(alias T)(int id, JSONValue request, ref JSONValue[] values,
		ref int asyncWaiting, ref bool isAsync, ref bool hasArgs, in AsyncCallback asyncCallback)
{
	foreach (name; __traits(derivedMembers, T))
	{
		static if (__traits(compiles, __traits(getMember, T, name)))
		{
			alias symbol = Identity!(__traits(getMember, T, name));
			static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
			{
				bool matches = false;
				foreach (Arguments args; compatibleGetUDAs!(symbol, Arguments))
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
					if (("cmd" in request) !is null && request["cmd"].type == JSON_TYPE.STRING
							&& compatibleGetUDAs!(symbol, component)[0].name != request["cmd"].str)
						matches = false;
				}
				static if (hasUDA!(symbol, load) && hasUDA!(symbol, component))
				{
					if (("components" in request) !is null && ("cmd" in request) !is null
							&& request["cmd"].type == JSON_TYPE.STRING && request["cmd"].str == "load")
					{
						if (request["components"].type == JSON_TYPE.ARRAY)
						{
							foreach (com; request["components"].array)
								if (com.type == JSON_TYPE.STRING
										&& com.str == compatibleGetUDAs!(symbol, component)[0].name)
									matches = true;
						}
						else if (request["components"].type == JSON_TYPE.STRING
								&& request["components"].str == compatibleGetUDAs!(symbol, component)[0].name)
							matches = true;
					}
				}
				static if (hasUDA!(symbol, unload) && hasUDA!(symbol, component))
				{
					if (("components" in request) !is null && ("cmd" in request) !is null
							&& request["cmd"].type == JSON_TYPE.STRING && request["cmd"].str == "unload")
					{
						if (request["components"].type == JSON_TYPE.ARRAY)
						{
							foreach (com; request["components"].array)
								if (com.type == JSON_TYPE.STRING && (com.str == compatibleGetUDAs!(symbol,
										component)[0].name || com.str == "*"))
									matches = true;
						}
						else if (request["components"].type == JSON_TYPE.STRING
								&& (request["components"].str == compatibleGetUDAs!(symbol,
									component)[0].name || request["components"].str == "*"))
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
}

void handleRequest(int id, JSONValue request)
{
	if (("cmd" in request) && request["cmd"].type == JSON_TYPE.STRING
			&& request["cmd"].str == "version")
	{
		sendFinal(id, getVersionInfoJson);
		return;
	}

	JSONValue[] values;
	JSONValue[] asyncValues;
	int asyncWaiting = 0;
	bool isAsync = false;
	bool hasArgs = false;

	const AsyncCallback asyncCallback = (err, value) {
		synchronized (commandMutex)
		{
			try
			{
				assert(isAsync);
				if (err)
					throw err;
				asyncValues ~= value;
				asyncWaiting--;
				if (asyncWaiting <= 0)
					send(id, asyncValues);
			}
			catch (Exception e)
			{
				processException(id, e);
			}
			catch (AssertError e)
			{
				processException(id, e);
			}
		}
	};

	handleRequestMod!(workspaced.com.dub)(id, request, values, asyncWaiting,
			isAsync, hasArgs, asyncCallback);
	handleRequestMod!(workspaced.com.dcd)(id, request, values, asyncWaiting,
			isAsync, hasArgs, asyncCallback);
	handleRequestMod!(workspaced.com.dfmt)(id, request, values, asyncWaiting,
			isAsync, hasArgs, asyncCallback);
	handleRequestMod!(workspaced.com.dscanner)(id, request, values, asyncWaiting,
			isAsync, hasArgs, asyncCallback);
	handleRequestMod!(workspaced.com.dlangui)(id, request, values, asyncWaiting,
			isAsync, hasArgs, asyncCallback);
	handleRequestMod!(workspaced.com.fsworkspace)(id, request, values,
			asyncWaiting, isAsync, hasArgs, asyncCallback);
	handleRequestMod!(workspaced.com.importer)(id, request, values, asyncWaiting,
			isAsync, hasArgs, asyncCallback);

	if (isAsync)
	{
		if (values.length > 0)
			throw new Exception("Cannot mix sync and async functions! In request " ~ request.toString);
	}
	else
	{
		if (hasArgs && values.length == 0)
			sendFinal(id, JSONValue(null));
		else
			send(id, values);
	}
}

void processException(int id, Throwable e)
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

void processException(int id, JSONValue request, Throwable e)
{
	stderr.writeln(e);
	// dfmt off
	sendFinal(id, JSONValue([
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
		static if (is(typeof(registerMemoryErrorHandler)))
			registerMemoryErrorHandler();

		if (args.length > 1 && (args[1] == "-v" || args[1] == "--version" || args[1] == "-version"))
		{
			stdout.writeln(getVersionInfoString);
			return 0;
		}

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
