module workspaced.com.dub;

import core.sync.mutex;
import core.exception;
import core.thread;

import std.algorithm;
import std.conv;
import std.exception;
import std.json : JSONValue, JSON_TYPE;
import std.parallelism;
import std.regex;
import std.stdio;
import std.string;

import painlessjson : toJSON, fromJSON;

import workspaced.api;

import dub.description;
import dub.dub;
import dub.package_;
import dub.project;

import dub.compilers.compiler;
import dub.generators.build;
import dub.generators.generator;

import dub.compilers.buildsettings;

import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.url;

@component("dub")
class DubComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	static void registered()
	{
		setLogLevel(LogLevel.none);
	}

	protected void load()
	{
		if (!refInstance)
			throw new Exception("dub requires to be instanced");

		if (config.get!bool("dub", "registerImportProvider", true))
			importPathProvider = &imports;
		if (config.get!bool("dub", "registerStringImportProvider", true))
			stringImportPathProvider = &stringImports;
		if (config.get!bool("dub", "registerImportFilesProvider", false))
			importFilesProvider = &fileImports;

		try
		{
			start();

			_configuration = _dub.project.getDefaultConfiguration(_platform);
			if (!_dub.project.configurations.canFind(_configuration))
			{
				stderr.writeln("Dub Error: No configuration available");
				workspaced.broadcast(refInstance, JSONValue(["type" : JSONValue("warning"),
						"component" : JSONValue("dub"), "detail" : JSONValue("invalid-default-config")]));
			}
			else
				updateImportPaths(false);
		}
		catch (Exception e)
		{
			if (!_dub || !_dub.project)
				throw e;
			stderr.writeln("Dub Error (ignored): ", e);
		}
		/*catch (AssertError e)
		{
			if (!_dub || !_dub.project)
				throw e;
			stderr.writeln("Dub Error (ignored): ", e);
		}*/
	}

	private void start()
	{
		_dubRunning = false;
		_dub = new Dub(instance.cwd, null, SkipPackageSuppliers.none);
		_dub.packageManager.getOrLoadPackage(NativePath(instance.cwd));
		_dub.loadPackage();
		_dub.project.validate();

		// mark all packages as optional so we don't crash
		int missingPackages;
		auto optionalified = optionalifyPackages;
		foreach (ref pkg; _dub.project.getTopologicalPackageList())
		{
			optionalifyRecipe(pkg);
			foreach (dep; pkg.getAllDependencies().filter!(a => optionalified.canFind(a.name)))
			{
				auto d = _dub.project.getDependency(dep.name, true);
				if (!d)
					missingPackages++;
				else
					optionalifyRecipe(d);
			}
		}

		if (!_compilerBinaryName.length)
			_compilerBinaryName = _dub.defaultCompiler;
		setCompiler(_compilerBinaryName);
		if (missingPackages > 0)
		{
			upgrade(false);
			optionalifyPackages();
		}

		_dubRunning = true;
	}

	private string[] optionalifyPackages()
	{
		bool[Package] visited;
		string[] optionalified;
		foreach (pkg; _dub.project.dependencies)
			optionalified ~= optionalifyRecipe(cast() pkg);
		return optionalified;
	}

	private string[] optionalifyRecipe(Package pkg)
	{
		string[] optionalified;
		foreach (key, ref value; pkg.recipe.buildSettings.dependencies)
		{
			if (!value.optional)
			{
				value.optional = true;
				value.default_ = true;
				optionalified ~= key;
			}
		}
		foreach (ref config; pkg.recipe.configurations)
			foreach (key, ref value; config.buildSettings.dependencies)
			{
				if (!value.optional)
				{
					value.optional = true;
					value.default_ = true;
					optionalified ~= key;
				}
			}
		return optionalified;
	}

	private void restart()
	{
		_dub.destroy();
		_dubRunning = false;
		start();
	}

	bool isRunning()
	{
		return _dub !is null && _dub.project !is null && _dub.project.rootPackage !is null
			&& _dubRunning;
	}

	/// Reloads the dub.json or dub.sdl file from the cwd
	/// Returns: `false` if there are no import paths available
	Future!bool update()
	{
		restart();
		auto ret = new Future!bool;
		new Thread({ /**/
			try
			{
				auto result = updateImportPaths(false);
				ret.finish(result);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		}).start();
		return ret;
	}

	bool updateImportPaths(bool restartDub = true)
	{
		validateConfiguration();

		if (restartDub)
			restart();

		GeneratorSettings settings;
		settings.platform = _platform;
		settings.config = _configuration;
		settings.buildType = _buildType;
		settings.compiler = _compiler;
		settings.buildSettings = _settings;
		settings.buildSettings.addOptions(BuildOption.syntaxOnly);
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
			workspaced.broadcast(refInstance, JSONValue(["type" : JSONValue("error"), "component"
					: JSONValue("dub"), "detail"
					: JSONValue("Error while listing import paths: " ~ e.toString)]));
			_importPaths = [];
			_stringImportPaths = [];
			return false;
		}
	}

	/// Calls `dub upgrade`
	void upgrade(bool save = true)
	{
		if (save)
			_dub.upgrade(UpgradeOptions.select | UpgradeOptions.upgrade);
		else
			_dub.upgrade(UpgradeOptions.noSaveSelections);
	}

	/// Throws if configuration is invalid, otherwise does nothing.
	void validateConfiguration()
	{
		if (!_dub.project.configurations.canFind(_configuration))
			throw new Exception("Cannot use dub with invalid configuration");
	}

	/// Throws if configuration is invalid or targetType is none or source library, otherwise does nothing.
	void validateBuildConfiguration()
	{
		if (!_dub.project.configurations.canFind(_configuration))
			throw new Exception("Cannot use dub with invalid configuration");
		if (_settings.targetType == TargetType.none)
			throw new Exception("Cannot build with dub with targetType == none");
		if (_settings.targetType == TargetType.sourceLibrary)
			throw new Exception("Cannot build with dub with targetType == sourceLibrary");
	}

	/// Lists all dependencies. This will go through all dependencies and contain the dependencies of dependencies. You need to create a tree structure from this yourself.
	/// Returns: `[{dependencies: [string], ver: string, name: string}]`
	auto dependencies() @property
	{
		validateConfiguration();

		return _dub.project.listDependencies();
	}

	/// Lists dependencies of the root package. This can be used as a base to create a tree structure.
	string[] rootDependencies() @property
	{
		validateConfiguration();

		return _dub.project.rootPackage.listDependencies();
	}

	/// Returns the path to the root package recipe (dub.json/dub.sdl)
	///
	/// Note that this can be empty if the package is not in the local file system.
	string recipePath() @property
	{
		return _dub.project.rootPackage.recipePath.toString;
	}

	/// Lists all import paths
	string[] imports() @property
	{
		return _importPaths;
	}

	/// Lists all string import paths
	string[] stringImports() @property
	{
		return _stringImportPaths;
	}

	/// Lists all import paths to files
	string[] fileImports() @property
	{
		return _importFiles;
	}

	/// Lists all configurations defined in the package description
	string[] configurations() @property
	{
		return _dub.project.configurations;
	}

	/// Lists all build types defined in the package description AND the predefined ones from dub ("plain", "debug", "release", "release-debug", "release-nobounds", "unittest", "docs", "ddox", "profile", "profile-gc", "cov", "unittest-cov")
	string[] buildTypes() @property
	{
		string[] types = [
			"plain", "debug", "release", "release-debug", "release-nobounds",
			"unittest", "docs", "ddox", "profile", "profile-gc", "cov", "unittest-cov"
		];
		foreach (type, info; _dub.project.rootPackage.recipe.buildTypes)
			types ~= type;
		return types;
	}

	/// Gets the current selected configuration
	string configuration() @property
	{
		return _configuration;
	}

	/// Selects a new configuration and updates the import paths accordingly
	/// Returns: `false` if there are no import paths in the new configuration
	bool setConfiguration(string configuration)
	{
		if (!_dub.project.configurations.canFind(configuration))
			return false;
		_configuration = configuration;
		return updateImportPaths(false);
	}

	/// List all possible arch types for current set compiler
	string[] archTypes() @property
	{
		string[] types = ["x86_64", "x86"];

		string compilerName = _compiler.name;

		version (Windows)
		{
			if (compilerName == "dmd")
			{
				types ~= "x86_mscoff";
			}
		}
		if (compilerName == "gdc")
		{
			types ~= ["arm", "arm_thumb"];
		}

		return types;
	}

	/// Returns the current selected arch type
	string archType() @property
	{
		return _archType;
	}

	/// Selects a new arch type and updates the import paths accordingly
	/// Returns: `false` if there are no import paths in the new arch type
	bool setArchType(JSONValue request)
	{
		enforce(request.type == JSON_TYPE.OBJECT && "arch-type" in request, "arch-type not in request");
		auto type = request["arch-type"].fromJSON!string;
		if (archTypes.canFind(type))
		{
			_archType = type;
			return updateImportPaths(false);
		}
		else
		{
			return false;
		}
	}

	/// Returns the current selected build type
	string buildType() @property
	{
		return _buildType;
	}

	/// Selects a new build type and updates the import paths accordingly
	/// Returns: `false` if there are no import paths in the new build type
	bool setBuildType(JSONValue request)
	{
		enforce(request.type == JSON_TYPE.OBJECT && "build-type" in request,
				"build-type not in request");
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
	string compiler() @property
	{
		return _compilerBinaryName;
	}

	/// Selects a new compiler for building
	/// Returns: `false` if the compiler does not exist
	bool setCompiler(string compiler)
	{
		try
		{
			_compilerBinaryName = compiler;
			_compiler = getCompiler(compiler); // make sure it gets a valid compiler
		}
		catch (Exception e)
		{
			return false;
		}
		_platform = _compiler.determinePlatform(_settings, _compilerBinaryName, _archType);
		return true;
	}

	/// Returns the project name
	string name() @property
	{
		return _dub.projectName;
	}

	/// Returns the project path
	auto path() @property
	{
		return _dub.projectPath;
	}

	/// Returns whether there is a target set to build. If this is false then build will throw an exception.
	bool canBuild() @property
	{
		if (_settings.targetType == TargetType.none || _settings.targetType == TargetType.sourceLibrary
				|| !_dub.project.configurations.canFind(_configuration))
			return false;
		return true;
	}

	/// Asynchroniously builds the project WITHOUT OUTPUT. This is intended for linting code and showing build errors quickly inside the IDE.
	Future!(BuildIssue[]) build()
	{
		validateBuildConfiguration();

		// copy to this thread
		auto compiler = _compiler;
		auto buildPlatform = _platform;

		GeneratorSettings settings;
		settings.platform = buildPlatform;
		settings.config = _configuration;
		settings.buildType = _buildType;
		settings.compiler = compiler;
		settings.tempBuild = true;
		settings.buildSettings = _settings;
		settings.buildSettings.addOptions(BuildOption.syntaxOnly);
		settings.buildSettings.addDFlags("-o-");

		auto ret = new Future!(BuildIssue[]);
		new Thread({
			try
			{
				BuildIssue[] issues;

				settings.compileCallback = (status, output) {
					string[] lines = output.splitLines;
					foreach (line; lines)
					{
						auto match = line.matchFirst(errorFormat);
						if (match)
						{
							issues ~= BuildIssue(match[2].to!int, match[3].toOr!int(0),
								match[1], match[4].to!ErrorType, match[5]);
						}
						else
						{
							if (line.canFind("from"))
							{
								auto contMatch = line.matchFirst(errorFormatCont);
								if (contMatch)
								{
									issues ~= BuildIssue(contMatch[2].to!int,
										contMatch[3].toOr!int(1), contMatch[1], ErrorType.Error, contMatch[4]);
								}
							}
							if (line.canFind("is deprecated"))
							{
								auto deprMatch = line.matchFirst(deprecationFormat);
								if (deprMatch)
								{
									issues ~= BuildIssue(deprMatch[2].to!int, deprMatch[3].toOr!int(1),
										deprMatch[1], ErrorType.Deprecation,
										deprMatch[4] ~ " is deprecated, use " ~ deprMatch[5] ~ " instead.");
									// TODO: maybe add special type or output
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
					if (!e.msg.matchFirst(harmlessExceptionFormat))
						throw e;
				}
				ret.finish(issues);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		}).start();
		return ret;
	}

	/// Converts the root package recipe to another format.
	/// Params:
	///     format = either "json" or "sdl".
	string convertRecipe(string format)
	{
		import dub.recipe.io : serializePackageRecipe;
		import std.array : appender;

		auto dst = appender!string;
		serializePackageRecipe(dst, _dub.project.rootPackage.rawRecipe, "dub." ~ format);
		return dst.data;
	}

private:
	Dub _dub;
	bool _dubRunning = false;
	string _configuration;
	string _archType = "x86_64";
	string _buildType = "debug";
	string _compilerBinaryName;
	Compiler _compiler;
	BuildSettings _settings;
	BuildPlatform _platform;
	string[] _importPaths, _stringImportPaths, _importFiles;
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

/// Returned by build
struct BuildIssue
{
	///
	int line, column;
	///
	string file;
	///
	ErrorType type;
	///
	string text;
}

private:

T toOr(T)(string s, T defaultValue)
{
	if (!s || !s.length)
		return defaultValue;
	return s.to!T;
}

enum harmlessExceptionFormat = ctRegex!(`failed with exit code`, "g");
enum errorFormat = ctRegex!(`(.*?)\((\d+)(?:,(\d+))?\): (Deprecation|Warning|Error): (.*)`, "gi");
enum errorFormatCont = ctRegex!(`(.*?)\((\d+)(?:,(\d+))?\): (.*)`, "g");
enum deprecationFormat = ctRegex!(
			`(.*?)\((\d+)(?:,(\d+))?\): (.*?) is deprecated, use (.*?) instead.$`, "g");

struct DubPackageInfo
{
	string[string] dependencies;
	string ver;
	string name;
	string path;
	string description;
	string homepage;
	const(string)[] authors;
	string copyright;
	string license;
	DubPackageInfo[] subPackages;

	void fill(in PackageRecipe recipe)
	{
		description = recipe.description;
		homepage = recipe.homepage;
		authors = recipe.authors;
		copyright = recipe.copyright;
		license = recipe.license;

		foreach (subpackage; recipe.subPackages)
		{
			DubPackageInfo info;
			info.ver = subpackage.recipe.version_;
			info.name = subpackage.recipe.name;
			info.path = subpackage.path;
			info.fill(subpackage.recipe);
		}
	}
}

DubPackageInfo getInfo(in Package dep)
{
	DubPackageInfo info;
	info.name = dep.name;
	info.ver = dep.version_.toString;
	info.path = dep.path.toString;
	info.fill(dep.recipe);
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

string[] listDependencies(Package pkg)
{
	auto deps = pkg.getAllDependencies();
	string[] dependencies;
	if (deps is null)
		return dependencies;
	foreach (dep; deps)
		dependencies ~= dep.name;
	return dependencies;
}
