module workspaced.com.dub;

import core.sync.mutex;
import core.thread;

import std.json : JSONValue;
import std.conv;
import std.stdio;
import std.regex;
import std.string;
import std.parallelism;
import std.algorithm;

import painlessjson;

import workspaced.api;

import dub.dub;
import dub.project;
import dub.package_;
import dub.description;

import dub.generators.generator;
import dub.compilers.compiler;

import dub.compilers.buildsettings;

import dub.internal.vibecompat.inet.url;
import dub.internal.vibecompat.core.log;

@component("dub") :

@load void startup(string dir, bool registerImportProvider = true, bool registerStringImportProvider = true)
{
	setLogLevel(LogLevel.none);

	if (registerImportProvider)
		importPathProvider = &imports;
	if (registerStringImportProvider)
		stringImportPathProvider = &stringImports;

	_cwdStr = dir;
	_cwd = Path(dir);

	start();

	string compilerName = defaultCompiler;
	_compiler = getCompiler(compilerName);
	BuildSettings settings;
	_platform = _compiler.determinePlatform(settings, compilerName);
	_settings = settings;

	_configuration = _dub.project.getDefaultConfiguration(_platform);
	assert (_dub.project.configurations.canFind(_configuration), "No configuration available");
	updateImportPaths(false);
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
	new Thread({ /**/
		try
		{
			auto result = updateImportPaths(false);
			callback(null, result.toJSON);
		}
		catch (Throwable t)
		{
			callback(t, null.toJSON);
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

@arguments("subcmd", "list:build-types")
auto buildTypes() @property
{
	string[] types = ["plain", "debug", "release", "release-nobounds", "unittest", "docs", "ddox", "profile", "profile-gc", "cov", "unittest-cov"];
	foreach (type, info; _dub.project.rootPackage.info.buildTypes)
		types ~= type;
	return types;
}

@arguments("subcmd", "get:configuration")
auto configuration() @property
{
	return _configuration;
}

@arguments("subcmd", "set:configuration")
bool setConfiguration(string configuration)
{
	if (!_dub.project.configurations.canFind(configuration))
		return false;
	_configuration = configuration;
	return updateImportPaths(false);
}

@arguments("subcmd", "get:build-type")
auto buildType() @property
{
	return _buildType;
}

@arguments("subcmd", "set:build-type")
bool setBuildType(JSONValue request)
{
	assert("build-type" in request, "build-type not in request");
	auto type = request["build-type"].fromJSON!string;
	if (buildTypes.canFind(type))
	{
		_buildType = type;
		return updateImportPaths(false);
	}
	else
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
bool setCompiler(string compiler)
{
	try
	{
		_compiler = getCompiler(compiler);
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

@arguments("subcmd", "build")
@async void build(AsyncCallback cb)
{
	new Thread({
		try
		{
			string compilerName = .compiler;
			auto compiler = getCompiler(compilerName);
			auto buildPlatform = compiler.determinePlatform(_settings, compilerName);

			GeneratorSettings settings;
			settings.platform = buildPlatform;
			settings.config = _configuration;
			settings.buildType = _buildType;
			settings.compiler = compiler;
			settings.buildSettings = _settings;
			settings.buildSettings.options |= BuildOption.syntaxOnly;
			settings.combined = true;
			settings.run = false;

			BuildIssue[] issues;

			settings.compileCallback = (status, output) {
				string[] lines = output.splitLines;
				foreach (line;
				lines)
				{
					auto match = line.matchFirst(errorFormat);
					if (match)
					{
						issues ~= BuildIssue(match[2].to!int, match[3].to!int, match[1], match[4].to!ErrorType, match[5]);
					}
					else
					{
						if (line.canFind("from"))
						{
							auto contMatch = line.matchFirst(errorFormatCont);
							if (contMatch)
							{
								issues ~= BuildIssue(contMatch[2].to!int, contMatch[3].to!int, contMatch[1], ErrorType.Error, contMatch[4]);
							}
						}
					}
				}
			};
			try
			{
				_dub.generateProject("build", settings);
			}
			catch (Exception e)
			{
			}
			cb(null, issues.toJSON);
		}
		catch (Throwable t)
		{
			ubyte[] empty;
			cb(t, empty.toJSON);
		}
	}).start();
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

auto errorFormat = ctRegex!(`(.*?)\((\d+),(\d+)\): (Deprecation|Warning|Error): (.*)`, "gi"); // `
auto errorFormatCont = ctRegex!(`(.*?)\((\d+),(\d+)\): (.*)`, "g"); // `

enum ErrorType : ubyte
{
	Error = 0,
	Warning = 1,
	Deprecation = 2
}

struct BuildIssue
{
	int line, column;
	string file;
	ErrorType type;
	string text;
}

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
