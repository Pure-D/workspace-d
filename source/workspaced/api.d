module workspaced.api;

import std.conv;
import std.json;
import std.file;
import std.path;
import std.regex;
import core.time;
import painlessjson;
import standardpaths;

///
alias AsyncCallback = void delegate(Throwable, JSONValue);

/// Will get called asynchronously (Must prepend AsyncCallback as argument)
enum async = 2603248026;

/// Will get called for loading components
enum load = 2603248027;

/// Will get called for unloading components
enum unload = 2603248028;

/// Will call this function in any case (cmd: component)
enum any = 2603248029;

/// Component call
struct component
{
	/// Name of the component
	string name;
}

/// Will get called when some argument matches
struct Arguments
{
	/// Arguments to match
	Argument[] arguments;
}

private struct Argument
{
	/// Key in JSON object node at root level to match
	string key;
	/// Value in JSON object node at root level to match
	JSONValue value;
}

private template ArgumentPair(size_t i)
{
	static if (i > 0)
		enum ArgumentPair = "ret.arguments[" ~ (i / 2 - 1)
				.to!string ~ "] = Argument(args[" ~ (i - 2).to!string ~ "], args[" ~ (i - 1)
				.to!string ~ "].toJSON);" ~ ArgumentPair!(i - 2);
	else
					enum ArgumentPair = "";
}

package Arguments arguments(T...)(T args)
{
	if (args.length < 2)
		return Arguments.init;
	Arguments ret;
	ret.arguments.length = args.length / 2;
	mixin(ArgumentPair!(args.length));
	return ret;
}

unittest
{
	Arguments args = arguments("foo", 5, "bar", "str");
	assert(args.arguments[0].key == "foo");
	assert(args.arguments[0].value.integer == 5);
	assert(args.arguments[1].key == "bar");
	assert(args.arguments[1].value.str == "str");
}

/// Describes what to insert/replace/delete to do something
struct CodeReplacement
{
	/// Range what to replace. If both indices are the same its inserting.
	size_t[2] range;
	/// Content to replace it with. Empty means remove.
	string content;

	/// Applies this edit to a string.
	string apply(string code)
	{
		size_t min = range[0];
		size_t max = range[1];
		if (min > max)
		{
			min = range[1];
			max = range[0];
		}
		if (min >= code.length)
			return code ~ content;
		if (max >= code.length)
			return code[0 .. min] ~ content;
		return code[0 .. min] ~ content ~ code[max .. $];
	}
}

/// Code replacements mapped to a file
struct FileChanges
{
	/// File path to change.
	string file;
	/// Replacements to apply.
	CodeReplacement[] replacements;
}

package bool getConfigPath(string file, ref string retPath)
{
	foreach (dir; standardPaths(StandardPath.config, "workspace-d"))
	{
		auto path = buildPath(dir, file);
		if (path.exists)
		{
			retPath = path;
			return true;
		}
	}
	return false;
}

alias ImportPathProvider = string[]function();

private string[] noImports()
{
	return [];
}

ImportPathProvider importPathProvider = &noImports, stringImportPathProvider = &noImports;

enum verRegex = ctRegex!`(\d+)\.(\d+)\.(\d+)`;
bool checkVersion(string ver, int[3] target)
{
	auto match = ver.matchFirst(verRegex);
	assert(match);
	int major = match[1].to!int;
	int minor = match[2].to!int;
	int patch = match[3].to!int;
	if (major > target[0])
		return true;
	if (major == target[0] && minor >= target[1])
		return true;
	if (major == target[0] && minor == target[1] && patch >= target[2])
		return true;
	return false;
}

alias BroadcastCallback = void function(JSONValue);
/// Broadcast callback which might get called by commands. For example when a component is outdated. Will be called in caller thread of function / while function executes.
BroadcastCallback broadcastCallback;
/// Must get called in caller thread
package void broadcast(JSONValue value)
{
	if (broadcastCallback)
		broadcastCallback(value);
	else
		throw new Exception("broadcastCallback not set!");
}

package string getVersionAndFixPath(ref string execPath)
{
	import std.process;

	try
	{
		return execute([execPath, "--version"]).output;
	}
	catch (ProcessException e)
	{
		auto newPath = buildPath(thisExePath.dirName, execPath.baseName);
		if (exists(newPath))
		{
			execPath = newPath;
			return execute([execPath, "--version"]).output;
		}
		throw e;
	}
}

/// Calls an asynchronous function and blocks until it returns using Thread.sleep
JSONValue syncBlocking(alias fn, alias sleepDur = 1.msecs, Args...)(Args args)
{
	import core.thread;

	Throwable ex;
	JSONValue ret;
	bool done = false;
	AsyncCallback cb = (err, data) { ex = err; ret = data; done = true; };
	fn(cb, args);
	while (!done)
		Thread.sleep(sleepDur);
	if (ex)
		throw ex;
	return ret;
}

/// Calls an asynchronous function and blocks until it returns using Fiber.yield
JSONValue syncYield(alias fn, Args...)(Args args)
{
	import core.thread;

	Throwable ex;
	JSONValue ret;
	bool done = false;
	AsyncCallback cb = (err, data) { ex = err; ret = data; done = true; };
	fn(cb, args);
	while (!done)
		Fiber.yield;
	if (ex)
		throw ex;
	return ret;
}

version(unittest)
{
	struct TestingWorkspace
	{
		string directory;

		this(string path)
		{
			if (path.exists)
				throw new Exception("Path already exists");
			directory = path;
			mkdir(path);
		}

		~this()
		{
			rmdirRecurse(directory);
		}

		string getPath(string path)
		{
			return buildPath(directory, path);
		}

		void createDir(string dir)
		{
			mkdirRecurse(getPath(dir));
		}

		void writeFile(string path, string content)
		{
			write(getPath(path), content);
		}
	}

	TestingWorkspace makeTemporaryTestingWorkspace()
	{
		import std.random;

		return TestingWorkspace(buildPath(tempDir, "workspace-d-test-" ~ uniform(0, int.max).to!string(36)));
	}
}
