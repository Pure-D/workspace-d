module workspaced.com.fsworkspace;

import std.json;
import workspaced.api;

@component("fsworkspace") :

/// Load function for custom import management. Call with `{"cmd": "load", "components": ["fsworkspace"]}`
/// Calling this will make fsworkspace the (string) import path provider!
@load void start(string dir, string[] additionalPaths = [])
{
	paths = dir ~ additionalPaths;
	importPathProvider = &imports;
	stringImportPathProvider = &imports;
}

/// Unloads allocated strings
@unload void stop()
{
	paths.length = 0;
}

/// Adds new (string) import paths to the workspace
/// Call_With: `{"subcmd": "add:imports"}`
@arguments("subcmd", "add:imports")
void addImports(string[] values)
{
	paths ~= values;
}

/// Lists all (string) import paths
/// Call_With: `{"subcmd": "list:import"}`
@arguments("subcmd", "list:import")
string[] imports()
{
	return paths;
}

__gshared:
string[] paths;
