module workspaced.api;

import std.conv;
import std.json;
import std.file;
import std.path;
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

Arguments arguments(T...)(T args)
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

bool getConfigPath(string file, ref string retPath)
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
