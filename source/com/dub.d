module workspaced.com.dub;

import workspaced.com.component;
import workspaced.util.filewatch;

import std.json;
import std.algorithm;

import painlessjson;

import core.thread;

import dub.dub;
import dub.project;
import dub.package_;
import dub.compilers.compiler;
import dub.compilers.buildsettings;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.url;

private struct DubInit
{
	string dir;
	bool watchFile = true;
	bool registerImportProvider = true;
	bool registerStringImportProvider = true;
}

private struct DubPackageInfo
{
	string[string] dependencies;
	string ver;
	string name;
}

class DubComponent : Component, IImportPathProvider, IStringImportPathProvider
{
public:
	override void load(JSONValue args)
	{
		DubInit value = fromJSON!DubInit(args);
		assert(value.dir, "dub initialization requires a 'dir' field");

		if (value.registerImportProvider)
			setImportPathProvider(this);
		if (value.registerStringImportProvider)
			setStringImportPathProvider(this);

		_dub = new Dub(null, value.dir, SkipRegistry.none);
		_dub.packageManager.getOrLoadPackage(Path(value.dir));
		_dub.loadPackageFromCwd();
		_dub.project.validate();
		string compilerName = defaultCompiler;
		_compiler = getCompiler(compilerName);
		BuildPlatform platform = _compiler.determinePlatform(_settings, compilerName);
		_platform = platform; // Workaround for strange bug
		_configuration = dub.project.getDefaultConfiguration(_platform);

		updateImportPaths();

		static if (__traits(compiles, { WatchedFile f = WatchedFile("path"); }))
		{
			if (value.watchFile)
			{
				_dubFileWatch = WatchedFile(dub.project.rootPackage.packageInfoFilename.toString());
				new Thread(&checkUpdate).start();
			}
		}
		else
		{
			if (value.watchFile)
				stderr.writeln("Unsupported file watch!");
		}
	}

	void updateImportPaths()
	{
		_importPaths = dub.project.listImportPaths(_platform, _configuration, _buildType, false);
		_stringImportPaths = dub.project.listStringImportPaths(_platform, _configuration, _buildType, false);
	}

	override void unload(JSONValue args)
	{
		_dub.shutdown();
	}

	@property auto dependencies()
	{
		return dub.project.listDependencies();
	}

	@property string[] importPaths()
	{
		return _importPaths;
	}

	@property string[] stringImportPaths()
	{
		return _stringImportPaths;
	}

	@property auto configurations()
	{
		return dub.project.configurations;
	}

	void upgrade()
	{
		_dub.upgrade(UpgradeOptions.upgrade);
	}

	@property auto dub()
	{
		return _dub;
	}

	@property auto configuration()
	{
		return _configuration;
	}

	bool setConfiguration(string value)
	{
		if (!dub.project.configurations.canFind(value))
			return false;
		_configuration = value;
		updateImportPaths();
		return true;
	}

	@property auto buildType()
	{
		return _buildType;
	}

	bool setBuildType(string value)
	{
		try
		{
			_buildType = value;
			updateImportPaths();
			return true;
		}
		catch (Exception e)
		{
			return false;
		}
	}

	@property auto compiler()
	{
		return _compiler.name;
	}

	bool setCompiler(string value)
	{
		try
		{
			_compiler = getCompiler(value);
			return true;
		}
		catch (Exception e)
		{ // No public function to get compilers
			return false;
		}
	}

	override JSONValue process(JSONValue args)
	{
		string cmd = args.getString("subcmd");
		switch (cmd)
		{
		case "update":
			updateImportPaths();
			break;
		case "upgrade":
			upgrade();
			break;
		case "list:dep":
			return dependencies.toJSON();
		case "list:import":
			return importPaths.toJSON();
		case "list:string-import":
			return stringImportPaths.toJSON();
		case "list:configurations":
			return configurations.toJSON();
		case "set:configuration":
			return setConfiguration(args.getString("configuration")).toJSON();
		case "get:configuration":
			return configuration.toJSON();
		case "set:build-type":
			return setBuildType(args.getString("build-type")).toJSON();
		case "get:build-type":
			return buildType.toJSON();
		case "set:compiler":
			return setCompiler(args.getString("compiler")).toJSON();
		case "get:compiler":
			return compiler.toJSON();
		case "get:name":
			return dub.projectName.toJSON();
		case "get:path":
			return dub.projectPath.toJSON();
		default:
			throw new Exception("Unknown command: '" ~ cmd ~ "'");
		}
		return JSONValue(null);
	}

private:
	void checkUpdate()
	{
		while (_dubFileWatch.isWatching)
		{
			_dubFileWatch.wait();
			updateImportPaths();
		}
	}

	Dub _dub;
	WatchedFile _dubFileWatch;
	string _configuration;
	string _buildType = "debug";
	BuildSettings _settings;
	Compiler _compiler;
	BuildPlatform _platform;
	string[] _importPaths, _stringImportPaths;
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

shared static this()
{
	components["dub"] = new DubComponent();
}
