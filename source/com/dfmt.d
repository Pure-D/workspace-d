module workspaced.com.dfmt;

import std.json;
import std.conv;
import std.regex;
import std.process;
import core.thread;

import painlessjson;

import workspaced.api;

@component("dfmt") :

/// Load function for dfmt. Call with `{"cmd": "load", "components": ["dfmt"]}`
/// This will store the working directory and executable name for future use. All dub methods are used with `"cmd": "dfmt"`
@load void start(string dir, string dfmtPath = "dfmt")
{
	cwd = dir;
	execPath = dfmtPath;
	auto features = execute([execPath, "--version"]).output;
	needsConfigFolder = features.hasConfigFolder;
}

enum verRegex = ctRegex!`(\d+)\.(\d+)\.\d+`;
bool hasConfigFolder(string ver)
{
	auto match = ver.matchFirst(verRegex);
	assert(match);
	int major = match[1].to!int;
	int minor = match[2].to!int;
	if (major > 0)
		return true;
	if (major == 0 && minor >= 5)
		return true;
	return false;
}

/// Unloads dfmt. Has no purpose right now.
@unload void stop()
{
}

/// Will format the code passed in asynchronously.
/// Returns: the formatted code as string
/// Call_With: `{"cmd": "dfmt"}`
@any @async void format(AsyncCallback cb, string code)
{
	new Thread({
		try
		{
			auto args = [execPath];
			if (needsConfigFolder)
				args ~= ["--config", cwd];
			auto pipes = pipeProcess(args, Redirect.all, null, Config.none, cwd);
			scope (exit)
				pipes.pid.wait();
			pipes.stdin.write(code);
			pipes.stdin.close();
			ubyte[4096] buffer;
			ubyte[] data;
			size_t len;
			do
			{
				auto appended = pipes.stdout.rawRead(buffer);
				len = appended.length;
				data ~= appended;
			}
			while (len == 4096);
			cb(null, JSONValue(cast(string) data));
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

__gshared:
string cwd, execPath;
bool needsConfigFolder = false;
