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

/// Load function for dub. Call with `{"cmd": "load", "components": ["dub"]}`
/// This will start dub and load all import paths. All dub methods are used with `"cmd": "dub"`
/// Note: This will block any incoming requests while loading.
@load void startup(string dir, bool registerImportProvider = true,
		bool registerStringImportProvider = true, bool registerImportFilesProvider = true)
{
	setLogLevel(LogLevel.none);

	if (registerImportProvider)
		importPathProvider = &imports;
	if (registerStringImportProvider)
		stringImportPathProvider = &stringImports;
	if (registerImportFilesProvider)
		importFilesProvider = &fileImports;

	_cwdStr = dir;
	_cwd = Path(dir);

	start();
	upgrade();

	string compilerName = _dub.defaultCompiler;
	_compiler = getCompiler(compilerName);
	BuildSettings settings;
	_platform = _compiler.determinePlatform(settings, compilerName);
	_settings = settings;

	_configuration = _dub.project.getDefaultConfiguration(_platform);
	assert(_dub.project.configurations.canFind(_configuration), "No configuration available");
	updateImportPaths(false);
}

/// Stops dub when called.
@unload void stop()
{
	_dub.destroy();
}

private void start()
{
	_dub = new Dub(_cwdStr, null, SkipPackageSuppliers.none);
	_dub.packageManager.getOrLoadPackage(_cwd);
	_dub.loadPackage();
	_dub.project.validate();
}

private void restart()
{
	stop();
	start();
}

/// Reloads the dub.json or dub.sdl file from the cwd
/// Returns: `false` if there are no import paths available
/// Call_With: `{"subcmd": "update"}`
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

	auto compiler = getCompiler(.compiler);
	auto buildPlatform = compiler.determinePlatform(_settings, .compiler);

	GeneratorSettings settings;
	settings.platform = buildPlatform;
	settings.config = _configuration;
	settings.buildType = _buildType;
	settings.compiler = compiler;
	settings.buildSettings = _settings;
	settings.buildSettings.options |= BuildOption.syntaxOnly;
	settings.combined = true;
	settings.run = false;

	try
	{
		auto paths = _dub.project.listBuildSettings(settings, ["import-paths",
				"string-import-paths", "source-files"], ListBuildSettingsFormat.listNul);
		_importPaths = paths[0].split('\0');
		_stringImportPaths = paths[1].split('\0');
		_importFiles = paths[2].split('\0');
		return _importPaths.length > 0 || _importFiles.length > 0;
	}
	catch (Exception e)
	{
		stderr.writeln("Exception while listing import paths: ", e);
		_importPaths = [];
		_stringImportPaths = [];
		return false;
	}
}

/// Calls `dub upgrade`
/// Call_With: `{"subcmd": "upgrade"}`
@arguments("subcmd", "upgrade")
void upgrade()
{
	_dub.upgrade(UpgradeOptions.select | UpgradeOptions.upgrade);
}

/// Lists all dependencies
/// Returns: `[{dependencies: [string], ver: string, name: string}]`
/// Call_With: `{"subcmd": "list:dep"}`
@arguments("subcmd", "list:dep")
auto dependencies() @property
{
	return _dub.project.listDependencies();
}

/// Lists all import paths
/// Call_With: `{"subcmd": "list:import"}`
@arguments("subcmd", "list:import")
string[] imports() @property
{
	return _importPaths;
}

/// Lists all string import paths
/// Call_With: `{"subcmd": "list:string-import"}`
@arguments("subcmd", "list:string-import")
string[] stringImports() @property
{
	return _stringImportPaths;
}

/// Lists all import paths to files
/// Call_With: `{"subcmd": "list:file-import"}`
@arguments("subcmd", "list:file-import")
string[] fileImports() @property
{
	return _importFiles;
}

/// Lists all configurations defined in the package description
/// Call_With: `{"subcmd": "list:configurations"}`
@arguments("subcmd", "list:configurations")
string[] configurations() @property
{
	return _dub.project.configurations;
}

/// Lists all build types defined in the package description AND the predefined ones from dub ("plain", "debug", "release", "release-nobounds", "unittest", "docs", "ddox", "profile", "profile-gc", "cov", "unittest-cov")
/// Call_With: `{"subcmd": "list:build-types"}`
@arguments("subcmd", "list:build-types")
string[] buildTypes() @property
{
	string[] types = [
		"plain", "debug", "release", "release-nobounds", "unittest", "docs",
		"ddox", "profile", "profile-gc", "cov", "unittest-cov"
	];
	foreach (type, info; _dub.project.rootPackage.recipe.buildTypes)
		types ~= type;
	return types;
}

/// Gets the current selected configuration
/// Call_With: `{"subcmd": "get:configuration"}`
@arguments("subcmd", "get:configuration")
string configuration() @property
{
	return _configuration;
}

/// Selects a new configuration and updates the import paths accordingly
/// Returns: `false` if there are no import paths in the new configuration
/// Call_With: `{"subcmd": "set:configuration"}`
@arguments("subcmd", "set:configuration")
bool setConfiguration(string configuration)
{
	if (!_dub.project.configurations.canFind(configuration))
		return false;
	_configuration = configuration;
	return updateImportPaths(false);
}

/// Returns the current selected build type
/// Call_With: `{"subcmd": "get:build-type"}`
@arguments("subcmd", "get:build-type")
string buildType() @property
{
	return _buildType;
}

/// Selects a new build type and updates the import paths accordingly
/// Returns: `false` if there are no import paths in the new build type
/// Call_With: `{"subcmd": "set:build-type"}`
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

/// Returns the current selected compiler
/// Call_With: `{"subcmd": "get:compiler"}`
@arguments("subcmd", "get:compiler")
string compiler() @property
{
	return _compiler.name;
}

/// Selects a new compiler for building
/// Returns: `false` if the compiler does not exist
/// Call_With: `{"subcmd": "set:compiler"}`
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

/// Returns the project name
/// Call_With: `{"subcmd": "get:name"}`
@arguments("subcmd", "get:name")
string name() @property
{
	return _dub.projectName;
}

/// Returns the project path
/// Call_With: `{"subcmd": "get:path"}`
@arguments("subcmd", "get:path")
auto path() @property
{
	return _dub.projectPath;
}

/// Asynchroniously builds the project WITHOUT OUTPUT. This is intended for linting code and showing build errors quickly inside the IDE.
/// Returns: `[{line: int, column: int, type: ErrorType, text: string}]` where type is an integer
/// Call_With: `{"subcmd": "build"}`
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
			settings.buildSettings.addDFlags("-o-");
			settings.direct = true;
			settings.combined = false;
			settings.tempBuild = true;
			settings.run = false;
			settings.rdmd = false;

			BuildIssue[] issues;

			settings.compileCallback = (status, output) {
				string[] lines = output.splitLines;
				foreach (line; lines)
				{
					auto match = line.matchFirst(errorFormat);
					if (match)
					{
						issues ~= BuildIssue(match[2].to!int,
							match[3].to!int, match[1], match[4].to!ErrorType, match[5]);
					}
					else
					{
						if (line.canFind("from"))
						{
							auto contMatch = line.matchFirst(errorFormatCont);
							if (contMatch)
							{
								issues ~= BuildIssue(contMatch[2].to!int, contMatch[3].to!int,
									contMatch[1], ErrorType.Error, contMatch[4]);
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

///
enum ErrorType : ubyte
{
	///
	Error = 0,
	///
	Warning = 1,
	///
	Deprecation = 2
}

private:

__gshared
{
	Dub _dub;
	Path _cwd;
	string _configuration;
	string _buildType = "debug";
	string _cwdStr;
	BuildSettings _settings;
	Compiler _compiler;
	BuildPlatform _platform;
	string[] _importPaths, _stringImportPaths, _importFiles;
}

enum errorFormat = ctRegex!(`(.*?)\((\d+),(\d+)\): (Deprecation|Warning|Error): (.*)`, "gi"); // `
enum errorFormatCont = ctRegex!(`(.*?)\((\d+),(\d+)\): (.*)`, "g"); // `

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
	info.ver = dep.version_.toString;
	foreach (subDep; dep.getAllDependencies())
	{
		info.dependencies[subDep.name] = subDep.spec.toString;
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
