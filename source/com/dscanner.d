module workspaced.com.dscanner;

import std.json;
import std.conv;
import std.path;
import std.stdio;
import std.regex;
import std.string;
import std.process;
import std.algorithm;
import core.thread;

import painlessjson;

import workspaced.api;

@component("dscanner") :

/// Load function for dscanner. Call with `{"cmd": "load", "components": ["dscanner"]}`
/// This will store the working directory and executable name for future use. All dub methods are used with `"cmd": "dscanner"`
@load void start(string dir, string dscannerPath = "dscanner")
{
	cwd = dir;
	execPath = dscannerPath;
}

/// Unloads dscanner. Has no purpose right now.
@unload void stop()
{
}

/// Asynchronously lints the file passed.
/// Returns: `[{file: string, line: int, column: int, type: string, description: string}]`
/// Call_With: `{"subcmd": "lint"}`
@arguments("subcmd", "lint")
@async void lint(AsyncCallback cb, string file, string ini = "dscanner.ini")
{
	new Thread({
		try
		{
			auto args = [execPath, "-S", file];
			if (getConfigPath("dscanner.ini", ini))
				stderr.writeln("Overriding Dscanner ini with workspace-d dscanner.ini config file");
			else if (ini && ini.length)
			{
				if (ini.isAbsolute)
					args ~= ["--config", ini];
				else
					args ~= ["--config", buildPath(cwd, ini)];
			}
			ProcessPipes pipes = raw(args);
			scope (exit)
				pipes.pid.wait();
			string[] res;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DScannerIssue[] issues;
			foreach (line; res)
			{
				if (!line.length)
					continue;
				auto match = line.chomp.matchFirst(dscannerIssueRegex);
				if (!match)
					continue;
				DScannerIssue issue;
				issue.file = match[1];
				issue.line = match[2].to!int;
				issue.column = match[3].to!int;
				issue.type = match[4];
				issue.description = match[5];
				issues ~= issue;
			}
			cb(null, issues.toJSON);
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

/// Asynchronously lists all definitions in the specified file.
/// Returns: `[{name: string, line: int, type: string, attributes: string[string]}]`
/// Call_With: `{"subcmd": "list-definitions"}`
@arguments("subcmd", "list-definitions")
@async void listDefinitions(AsyncCallback cb, string file)
{
	new Thread({
		try
		{
			ProcessPipes pipes = raw([execPath, "-c", file]);
			scope (exit)
				pipes.pid.wait();
			string[] res;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DefinitionElement[] definitions;
			foreach (line; res)
			{
				if (!line.length || line[0] == '!')
					continue;
				line = line.chomp;
				string[] splits = line.split('\t');
				DefinitionElement definition;
				definition.name = splits[0];
				definition.type = splits[3];
				definition.line = splits[4][5 .. $].to!int;
				if (splits.length > 5)
					foreach (attribute; splits[5 .. $])
					{
						string[] sides = attribute.split(':');
						definition.attributes[sides[0]] = sides[1 .. $].join(':');
					}
				definitions ~= definition;
			}
			cb(null, definitions.toJSON);
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

/// Asynchronously finds all definitions of a symbol in the import paths.
/// Returns: `[{name: string, line: int, column: int}]`
/// Call_With: `{"subcmd": "find-symbol"}`
@arguments("subcmd", "find-symbol")
@async void findSymbol(AsyncCallback cb, string symbol)
{
	new Thread({
		try
		{
			ProcessPipes pipes = raw([execPath, "-d", symbol] ~ importPathProvider());
			scope (exit)
				pipes.pid.wait();
			string[] res;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			FileLocation[] files;
			foreach (line; res)
			{
				auto match = line.chomp.matchFirst(dscannerFileRegex);
				if (!match)
					continue;
				FileLocation file;
				file.file = match[1];
				file.line = match[2].to!int;
				file.column = match[3].to!int;
				files ~= file;
			}
			cb(null, files.toJSON);
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

private:

__gshared
{
	string cwd, execPath;
}

auto raw(string[] args, Redirect redirect = Redirect.all)
{
	auto pipes = pipeProcess(args, redirect, null, Config.none, cwd);
	return pipes;
}

auto dscannerIssueRegex = ctRegex!`^(.+?)\((\d+)\:(\d+)\)\[(.*?)\]: (.*)`;
auto dscannerFileRegex = ctRegex!`^(.*?)\((\d+):(\d+)\)`;
struct DScannerIssue
{
	string file;
	int line, column;
	string type;
	string description;
}

struct FileLocation
{
	string file;
	int line, column;
}

struct OutlineTreeNode
{
	string definition;
	int line;
	OutlineTreeNode[] children;
}

struct DefinitionElement
{
	string name;
	int line;
	string type;
	string[string] attributes;
}
