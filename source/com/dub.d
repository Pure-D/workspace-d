module workspaced.com.dub;

import core.sync.mutex;
import core.thread;

import std.stdio;
import std.parallelism;
import std.algorithm;

import painlessjson;

import workspaced.api;

import dub.dub;
import dub.project;
import dub.package_;
import dub.description;
import dub.compilers.compiler;
import dub.compilers.buildsettings;
import dub.internal.vibecompat.inet.url;

@component("dub") :

@load void startup(string dir, bool registerImportProvider = true, bool registerStringImportProvider = true)
{
	if (registerImportProvider)
		importPathProvider = "dub";
	if (registerStringImportProvider)
		stringImportPathProvider = "dub";

	_cwdStr = dir;
	_cwd = Path(dir);

	start();

	string compilerName = defaultCompiler;
	_compiler = cast(shared Compiler) getCompiler(compilerName);
	BuildSettings settings;
	_platform = cast(shared BuildPlatform) (cast(Compiler) _compiler).determinePlatform(settings, compilerName);
	_settings = cast(shared BuildSettings) settings;

	setConfiguration((cast(Dub) _dub).project.getDefaultConfiguration(cast(BuildPlatform) _platform));
}

@unload void stop()
{
	(cast(Dub) _dub).shutdown();
}

private void start()
{
	_dub = cast(shared Dub) new Dub(null, _cwdStr, SkipRegistry.none);
	(cast(Dub) _dub).packageManager.getOrLoadPackage(_cwd);
	(cast(Dub) _dub).loadPackageFromCwd();
	(cast(Dub) _dub).project.validate();
}

private void restart()
{
	stop();
	start();
}

@arguments("subcmd", "update")
@async void update(AsyncCallback callback)
{
	restart();
	new Thread({
		try
		{
			auto result = updateImportPaths(false);
			callback(result.toJSON);
		}
		catch (Throwable t)
		{
			stderr.writeln(t);
			callback((false).toJSON);
		}
	}).start();
}

bool updateImportPaths(bool restartDub = true)
{
	if (restartDub)
		restart();

	ProjectDescription desc = (cast(Dub) _dub).project.describe(cast(BuildPlatform) _platform, cast(string) _configuration, cast(string) _buildType);

	// target-type: none (no import paths)
	if (desc.targets.length > 0 && desc.targetLookup.length > 0 && (desc.rootPackage in desc.targetLookup) !is null)
	{
		_importPaths = (cast(Dub) _dub).project.listImportPaths(cast(BuildPlatform) _platform, cast(string) _configuration, cast(string) _buildType, false);
		_stringImportPaths = (cast(Dub) _dub).project.listStringImportPaths(cast(BuildPlatform) _platform, cast(string) _configuration, cast(string) _buildType, false);
		return _importPaths.length > 0;
	}
	else
	{
		_importPaths = [];
		_stringImportPaths = [];
		return false;
	}
}

@arguments("subcmd", "upgrade")
void upgrade()
{
	(cast(Dub) _dub).upgrade(UpgradeOptions.upgrade);
}

@arguments("subcmd", "list:dep")
auto dependencies() @property
{
	return (cast(Dub) _dub).project.listDependencies();
}

@arguments("subcmd", "list:import")
auto imports() @property
{
	return _importPaths;
}

@arguments("subcmd", "list:string-import")
auto stringImports() @property
{
	return _stringImportPaths;
}

@arguments("subcmd", "list:configurations")
auto configurations() @property
{
	return (cast(Dub) _dub).project.configurations;
}

@arguments("subcmd", "get:configuration")
auto configuration() @property
{
	return _configuration;
}

@arguments("subcmd", "set:configuration")
bool setConfiguration(string value)
{
	if (!(cast(Dub) _dub).project.configurations.canFind(value))
		return false;
	_configuration = value;
	return updateImportPaths(false);
}

@arguments("subcmd", "get:build-type")
auto buildType() @property
{
	return _buildType;
}

@arguments("subcmd", "set:build-type")
bool setBuildType(string value)
{
	try
	{
		_buildType = value;
		return updateImportPaths(false);
	}
	catch (Exception e)
	{
		return false;
	}
}

@arguments("subcmd", "get:compiler")
auto compiler() @property
{
	return (cast(Compiler) _compiler).name;
}

@arguments("subcmd", "set:compiler")
bool setCompiler(string value)
{
	try
	{
		_compiler = cast(shared Compiler) getCompiler(value);
		return true;
	}
	catch (Exception e)
	{
		return false;
	}
}

@arguments("subcmd", "get:name")
string name() @property
{
	return (cast(Dub) _dub).projectName;
}

@arguments("subcmd", "get:path")
auto path() @property
{
	return (cast(Dub) _dub).projectPath;
}

private:

shared Dub _dub;
Path _cwd;
shared string _configuration;
shared string _buildType = "debug";
shared string _cwdStr;
shared BuildSettings _settings;
shared Compiler _compiler;
shared BuildPlatform _platform;
string[] _importPaths, _stringImportPaths;

struct DubPackageInfo
{
	string[string] dependencies;
	string ver;
	string name;
}

DubPackageInfo getInfo(in Package dep)
{
	DubPackageInfo info;
	info.name = dep.name;
	info.ver = dep.vers;
	foreach (name, subDep; dep.dependencies)
	{
		info.dependencies[name] = subDep.toString();
	}
	return info;
}

auto listDependencies(Project project)
{
	auto deps = project.dependencies;
	DubPackageInfo[] dependencies;
	if (deps is null)
		return dependencies;
	foreach (dep; deps)
	{
		dependencies ~= getInfo(dep);
	}
	return dependencies;
}
