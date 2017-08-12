import std.file;
import std.string;

import workspaced.api;
import workspaced.coms;

void main()
{
	assert(importPathProvider().length == 0);
	fsworkspace.start(getcwd);
	fsworkspace.addImports(["source"]);
	assert(importPathProvider() == [getcwd, "source"]);
	fsworkspace.stop();
	assert(importPathProvider().length == 0);
}
