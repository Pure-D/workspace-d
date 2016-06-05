module workspaced.com.fsworkspace;

import std.json;
import workspaced.api;

@component("fsworkspace") :

/// Load function for custom import management. Call with `{"cmd": "load", "components": ["fsworkspace"]}`
/// Calling this will make fsworkspace the import-, string import- & file import provider!
@load void start(string dir, string[] additionalPaths = [])
{
	paths = dir ~ additionalPaths;
	importPathProvider = &imports;
	stringImportPathProvider = &imports;
	importFilesProvider = &imports;
}

/// Unloads allocated strings
@unload void stop()
{
	paths.length = 0;
}

/// Adds new import paths to the workspace. You can add import paths, string import paths or file paths.
/// Call_With: `{"subcmd": "add:imports"}`
@arguments("subcmd", "add:imports")
void addImports(string[] values)
{
	paths ~= values;
}

/// Lists all import-, string import- & file import paths
/// Call_With: `{"subcmd": "list:import"}`
@arguments("subcmd", "list:import")
string[] imports()
{
	return paths;
}

private __gshared:
string[] paths;
