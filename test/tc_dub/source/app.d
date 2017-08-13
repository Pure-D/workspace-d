import std.file;
import std.path;
import std.string;

import workspaced.api;
import workspaced.coms;

void main()
{
	dub.startup(buildNormalizedPath(getcwd, "..", "tc_fsworkspace"));
	scope (exit)
		dub.stop();
	dub.upgrade();
	assert(dub.dependencies.length > 2);
	assert(dub.rootDependencies == ["workspace-d"]);
	assert(dub.imports.length > 5);
	assert(dub.stringImports[0].endsWith("views")
			|| dub.stringImports[0].endsWith("views/") || dub.stringImports[0].endsWith("views\\"));
	assert(dub.fileImports.length > 10);
	assert(dub.configurations.length == 2);
	assert(dub.buildTypes.length);
	assert(dub.configuration == "application");
	assert(dub.archTypes.length);
	assert(dub.archType.length);
	assert(dub.buildType == "debug");
	assert(dub.compiler.length);
	assert(dub.name == "test-fsworkspace");
	assert(dub.path.toString.endsWith("tc_fsworkspace")
			|| dub.path.toString.endsWith("tc_fsworkspace/") || dub.path.toString.endsWith("tc_fsworkspace\\"));
	assert(syncBlocking!(dub.build).array.length == 0);
}
