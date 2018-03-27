import Compiler = std.compiler;
import std.file;
import std.json;
import std.path;
import std.stdio;
import std.string;
import std.traits;

import workspaced.api;
import workspaced.coms;

void main()
{
	assert(tryDub("valid"));
	assert(!tryDub("empty1"));
	assert(!tryDub("empty2"));
	assert(tryDub("empty3"));
	assert(!tryDub("invalid"));
	assert(tryDub("sourcelib"));
	version (Windows)
		assert(tryDub("empty_windows"));
	stderr.writeln("Success!");
}

bool tryDub(string path)
{
	try
	{
		if (exists(buildNormalizedPath(getcwd, path, ".dub")))
			rmdirRecurse(buildNormalizedPath(getcwd, path, ".dub"));
		if (exists(buildNormalizedPath(getcwd, path, "dub.selections.json")))
			remove(buildNormalizedPath(getcwd, path, "dub.selections.json"));

		dub.startup(buildNormalizedPath(getcwd, path));
	}
	catch (Exception e)
	{
		stderr.writeln(path, ": ", e.msg);
		return false;
	}

	scope (exit)
		dub.stop();
	foreach (step; 0 .. 2)
	{
		path.tryRun!(dub.upgrade)();
		path.tryRun!(dub.dependencies)();
		path.tryRun!(dub.rootDependencies)();
		path.tryRun!(dub.imports)();
		path.tryRun!(dub.stringImports)();
		path.tryRun!(dub.fileImports)();
		path.tryRun!(dub.configurations)();
		path.tryRun!(dub.buildTypes)();
		path.tryRun!(dub.configuration)();
		path.tryRun!(dub.setConfiguration)(dub.configuration);
		path.tryRun!(dub.archTypes)();
		path.tryRun!(dub.archType)();
		path.tryRun!(dub.setArchType)(JSONValue(["arch-type" : JSONValue("x86")]));
		path.tryRun!(dub.buildType)();
		path.tryRun!(dub.setBuildType)(JSONValue(["build-type" : JSONValue("debug")]));
		path.tryRun!(dub.compiler)();
		static if (Compiler.vendor == Compiler.Vendor.gnu)
			path.tryRun!(dub.setCompiler)("gdc");
		else static if (Compiler.vendor == Compiler.Vendor.llvm)
			path.tryRun!(dub.setCompiler)("ldc");
		else
			path.tryRun!(dub.setCompiler)("dmd");
		path.tryRun!(dub.name)();
		path.tryRun!(dub.path)();
		path.tryRun!(syncBlocking!(dub.build));
		// restart
		path.tryRun!(syncBlocking!(dub.update));
	}

	return true;
}

void tryRun(alias fn, Args...)(string trace, Args args)
{
	try
	{
		fn(args);
		stderr.writeln(trace, ": pass ", fullyQualifiedName!fn);
	}
	catch (Exception e)
	{
		stderr.writeln(trace, ": failed to run ", fullyQualifiedName!fn, ": ", e.msg);
	}
	catch (Error e)
	{
		stderr.writeln(trace, ": assert error in ", fullyQualifiedName!fn, ": ", e.msg);
		throw e;
	}
}
