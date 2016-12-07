module workspaced.com.dfmt;

import std.json;
import std.conv;
import std.regex;
import fs = std.file;
import std.stdio : stderr;
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
@any @async void format(AsyncCallback cb, string code, string[] arguments = [])
{
	new Thread({
		try
		{
			auto args = [execPath];
			string configPath;
			if (getConfigPath("dfmt.json", configPath))
			{
				stderr.writeln("Overriding dfmt arguments with workspace-d dfmt.json config file");
				try
				{
					auto json = parseJSON(fs.readText(configPath));
					json.tryFetchProperty!bool(arguments, "align_switch_statements");
					json.tryFetchProperty(arguments, "brace_style");
					json.tryFetchProperty(arguments, "end_of_line");
					json.tryFetchProperty!uint(arguments, "indent_size");
					json.tryFetchProperty(arguments, "indent_style");
					json.tryFetchProperty!uint(arguments, "max_line_length");
					json.tryFetchProperty!uint(arguments, "soft_max_line_length");
					json.tryFetchProperty!bool(arguments, "outdent_attributes");
					json.tryFetchProperty!bool(arguments, "space_after_cast");
					json.tryFetchProperty!bool(arguments, "split_operator_at_line_end");
					json.tryFetchProperty!uint(arguments, "tab_width");
					json.tryFetchProperty!bool(arguments, "selective_import_space");
					json.tryFetchProperty!bool(arguments, "compact_labeled_statements");
					json.tryFetchProperty(arguments, "template_constraint_style");
				}
				catch (Exception e)
				{
					stderr.writeln("dfmt.json in workspace-d config folder is malformed");
					stderr.writeln(e);
				}
			}
			else if (arguments.length)
				args ~= arguments;
			else if (needsConfigFolder)
				args ~= ["-c", cwd];
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
			if (data.length)
				cb(null, JSONValue(cast(string) data));
			else
				cb(null, JSONValue(code));
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

private __gshared:
string cwd, execPath;
bool needsConfigFolder = false;

void tryFetchProperty(T = string)(ref JSONValue json, ref string[] args, string name)
{
	auto ptr = name in json;
	if (ptr)
	{
		auto val = *ptr;
		static if (is(T == string))
		{
			if (val.type != JSON_TYPE.STRING)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a string");
			args ~= ["--" ~ name, val.str];
		}
		else static if (is(T == uint))
		{
			if (val.type != JSON_TYPE.INTEGER)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a number");
			if (val.integer < 0)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a positive number");
			args ~= ["--" ~ name, val.integer.to!string];
		}
		else static if (is(T == int))
		{
			if (val.type != JSON_TYPE.INTEGER)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a number");
			args ~= ["--" ~ name, val.integer.to!string];
		}
		else static if (is(T == bool))
		{
			if (val.type != JSON_TYPE.TRUE && val.type != JSON_TYPE.FALSE)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a boolean");
			args ~= ["--" ~ name, val.type == JSON_TYPE.TRUE ? "true" : "false"];
		}
		else static assert(false);
	}
}
