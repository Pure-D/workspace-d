import Compiler = std.compiler;
import std.file;
import std.json;
import std.path;
import std.stdio;
import std.string;
import std.traits;

import workspaced.api;
import workspaced.coms;

WorkspaceD backend;

void main()
{
	string dir = buildNormalizedPath(getcwd, "..", "tc_fsworkspace");
	backend = new WorkspaceD();
	backend.register!DubComponent;

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
	DubComponent dub;
	try
	{
		if (exists(buildNormalizedPath(getcwd, path, ".dub")))
			rmdirRecurse(buildNormalizedPath(getcwd, path, ".dub"));
		if (exists(buildNormalizedPath(getcwd, path, "dub.selections.json")))
			remove(buildNormalizedPath(getcwd, path, "dub.selections.json"));

		auto dir = buildNormalizedPath(getcwd, path);
		backend.addInstance(dir);
		dub = backend.get!DubComponent(dir);
	}
	catch (Exception e)
	{
		stderr.writeln(path, ": ", e.msg);
		return false;
	}

	auto tryRun(string fn, Args...)(string trace, Args args)
	{
		try
		{
			scope (success)
				stderr.writeln(trace, ": pass ", fn);
			mixin("return dub." ~ fn ~ "(args);");
		}
		catch (Exception e)
		{
			stderr.writeln(trace, ": failed to run ", fn, ": ", e.msg);
			static if (!is(typeof(return) == void))
				return typeof(return).init;
		}
		catch (Error e)
		{
			stderr.writeln(trace, ": assert error in ", fn, ": ", e.msg);
			throw e;
		}
	}

	foreach (step; 0 .. 2)
	{
		tryRun!"upgrade"(path);
		tryRun!"dependencies"(path);
		tryRun!"rootDependencies"(path);
		tryRun!"imports"(path);
		tryRun!"stringImports"(path);
		tryRun!"fileImports"(path);
		tryRun!"configurations"(path);
		tryRun!"buildTypes"(path);
		tryRun!"configuration"(path);
		tryRun!"setConfiguration"(path, dub.configuration);
		tryRun!"archTypes"(path);
		tryRun!"archType"(path);
		tryRun!"setArchType"(path, JSONValue(["arch-type" : JSONValue("x86")]));
		tryRun!"buildType"(path);
		tryRun!"setBuildType"(path, JSONValue(["build-type" : JSONValue("debug")]));
		tryRun!"compiler"(path);
		static if (Compiler.vendor == Compiler.Vendor.gnu)
			tryRun!"setCompiler"(path, "gdc");
		else static if (Compiler.vendor == Compiler.Vendor.llvm)
			tryRun!"setCompiler"(path, "ldc");
		else
			tryRun!"setCompiler"(path, "dmd");
		tryRun!"name"(path);
		tryRun!"path"(path);
		tryRun!"build.getBlocking"(path);
		// restart
		tryRun!"update.getBlocking"(path);
	}

	return true;
}
