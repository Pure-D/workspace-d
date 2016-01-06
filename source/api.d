module workspaced.api;

import std.json;
import painlessjson;

///
alias AsyncCallback = void delegate(JSONValue);

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
	static if(i > 2)
		enum ArgumentPair = "ret.arguments ~= Argument(args[" ~ i.to!string ~ "], args[" ~ (i + 1).to!string ~ "].toJSON);" ~ ArgumentPair!(i - 2);
	else
		enum ArgumentPair = "";
}

Arguments arguments(T...)(T args)
{
	Arguments ret;
	mixin(ArgumentPair!(args.length));
	return ret;
}

unittest
{
	Arguments args = Arguments("foo", 5, "bar", "str");
	assert(args.arguments[0].key == "foo");
	assert(args.arguments[0].value.integer == 5);
	assert(args.arguments[1].key == "foo");
	assert(args.arguments[1].value.str == "str");
}

string importPathProvider, stringImportPathProvider;