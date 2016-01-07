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
	_compiler = getCompiler(compilerName);
	BuildSettings settings;
	_platform = _compiler.determinePlatform(settings, compilerName);
	_settings = settings;

	setConfiguration(_dub.project.getDefaultConfiguration(_platform));
}

@unload void stop()
{
	_dub.shutdown();
}

private void start()
{
	_dub = new Dub(null, _cwdStr, SkipRegistry.none);
	_dub.packageManager.getOrLoadPackage(_cwd);
	_dub.loadPackageFromCwd();
	_dub.project.validate();
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

	ProjectDescription desc = _dub.project.describe(_platform, _configuration, _buildType);

	// target-type: none (no import paths)
	if (desc.targets.length > 0 && desc.targetLookup.length > 0 && (desc.rootPackage in desc.targetLookup) !is null)
	{
		_importPaths = _dub.project.listImportPaths(_platform, _configuration, _buildType, false);
		_stringImportPaths = _dub.project.listStringImportPaths(_platform, _configuration, _buildType, false);
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
	_dub.upgrade(UpgradeOptions.upgrade);
}

@arguments("subcmd", "list:dep")
auto dependencies() @property
{
	return _dub.project.listDependencies();
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
	return _dub.project.configurations;
}

@arguments("subcmd", "get:configuration")
auto configuration() @property
{
	return _configuration;
}

@arguments("subcmd", "set:configuration")
bool setConfiguration(string value)
{
	if (!_dub.project.configurations.canFind(value))
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
	return _compiler.name;
}

@arguments("subcmd", "set:compiler")
bool setCompiler(string value)
{
	try
	{
		_compiler = getCompiler(value);
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
	return _dub.projectName;
}

@arguments("subcmd", "get:path")
auto path() @property
{
	return _dub.projectPath;
}

private __gshared:

Dub _dub;
Path _cwd;
string _configuration;
string _buildType = "debug";
string _cwdStr;
BuildSettings _settings;
Compiler _compiler;
BuildPlatform _platform;
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
