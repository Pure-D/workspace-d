module workspaced.api;

import core.time;
import dparse.lexer;
import painlessjson;
import standardpaths;
import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.json;
import std.meta;
import std.path;
import std.regex;
import std.traits;
import std.typecons;

///
alias ImportPathProvider = string[]delegate();
///
alias BroadcastCallback = void delegate(WorkspaceD, WorkspaceD.Instance, JSONValue);
///
alias ComponentBindFailCallback = void delegate(WorkspaceD.Instance, ComponentFactory);

/// Will never call this function
enum ignoredFunc;

/// Component call
struct ComponentInfo
{
	/// Name of the component
	string name;
}

ComponentInfo component(string name)
{
	return ComponentInfo(name);
}

mixin template DefaultComponentWrapper()
{
	@ignoredFunc
	{
		WorkspaceD workspaced;
		WorkspaceD.Instance refInstance;

		WorkspaceD.Instance instance() const @property
		{
			if (refInstance)
				return cast() refInstance;
			else
				throw new Exception("Attempted to access instance in a global context");
		}

		WorkspaceD.Instance instance(WorkspaceD.Instance instance) @property
		{
			return refInstance = instance;
		}

		string[] importPaths() const @property
		{
			return instance.importPathProvider ? instance.importPathProvider() : [];
		}

		string[] stringImportPaths() const @property
		{
			return instance.stringImportPathProvider ? instance.stringImportPathProvider() : [];
		}

		string[] importFiles() const @property
		{
			return instance.importFilesProvider ? instance.importFilesProvider() : [];
		}

		ref ImportPathProvider importPathProvider() @property
		{
			return instance.importPathProvider;
		}

		ref ImportPathProvider stringImportPathProvider() @property
		{
			return instance.stringImportPathProvider;
		}

		ref ImportPathProvider importFilesProvider() @property
		{
			return instance.importFilesProvider;
		}

		ref Configuration config() @property
		{
			if (refInstance)
				return refInstance.config;
			else if (workspaced)
				return workspaced.globalConfiguration;
			else
				assert(false, "Unbound component trying to access config.");
		}

		T get(T)()
		{
			if (refInstance)
				return refInstance.get!T;
			else if (workspaced)
				return workspaced.get!T;
			else
				assert(false, "Unbound component trying to get component " ~ T.stringof ~ ".");
		}

		string cwd() @property const
		{
			return instance.cwd;
		}

		override void bind(WorkspaceD workspaced, WorkspaceD.Instance instance)
		{
			this.workspaced = workspaced;
			this.instance = instance;
			static if (__traits(hasMember, typeof(this).init, "load"))
				load();
		}

		import std.conv;
		import std.json : JSONValue;
		import std.traits : isFunction, hasUDA, ParameterDefaults, Parameters,
			ReturnType;
		import painlessjson;

		override Future!JSONValue run(string method, JSONValue[] args)
		{
			static foreach (member; __traits(derivedMembers, typeof(this)))
				static if (member[0] != '_' && __traits(compiles, __traits(getMember,
						typeof(this).init, member)) && __traits(getProtection, __traits(getMember, typeof(this).init,
						member)) == "public" && __traits(compiles, isFunction!(__traits(getMember,
						typeof(this).init, member))) && isFunction!(__traits(getMember,
						typeof(this).init, member)) && !hasUDA!(__traits(getMember, typeof(this).init,
						member), ignoredFunc) && !__traits(isTemplate, __traits(getMember,
						typeof(this).init, member)))
					if (method == member)
						return runMethod!member(args);
			throw new Exception("Method " ~ method ~ " not found.");
		}

		Future!JSONValue runMethod(string method)(JSONValue[] args)
		{
			int matches;
			static foreach (overload; __traits(getOverloads, typeof(this), method))
			{
				if (matchesOverload!overload(args))
					matches++;
			}
			if (matches == 0)
				throw new Exception("No suitable overload found for " ~ method ~ ".");
			if (matches > 1)
				throw new Exception("Multiple overloads found for " ~ method ~ ".");
			static foreach (overload; __traits(getOverloads, typeof(this), method))
			{
				if (matchesOverload!overload(args))
					return runOverload!overload(args);
			}
			assert(false);
		}

		Future!JSONValue runOverload(alias fun)(JSONValue[] args)
		{
			mixin(generateOverloadCall!fun);
		}

		static string generateOverloadCall(alias fun)()
		{
			string call = "fun(";
			static foreach (i, T; Parameters!fun)
				call ~= "args[" ~ i.to!string ~ "].fromJSON!(" ~ T.stringof ~ "), ";
			call ~= ")";
			static if (is(ReturnType!fun : Future!T, T))
			{
				static if (is(T == void))
					string conv = "ret.finish(JSONValue(null));";
				else
					string conv = "ret.finish(v.value.toJSON);";
				return "auto ret = new Future!JSONValue; auto v = " ~ call
					~ "; v.onDone = { if (v.exception) ret.error(v.exception); else "
					~ conv ~ " }; return ret;";
			}
			else static if (is(ReturnType!fun == void))
				return call ~ "; return Future!JSONValue.fromResult(JSONValue(null));";
			else
				return "return Future!JSONValue.fromResult(" ~ call ~ ".toJSON);";
		}
	}
}

bool matchesOverload(alias fun)(JSONValue[] args)
{
	if (args.length > Parameters!fun.length)
		return false;
	static foreach (i, def; ParameterDefaults!fun)
	{
		static if (is(def == void))
		{
			if (i >= args.length)
				return false;
			else if (!checkType!(Parameters!fun[i])(args[i]))
				return false;
		}
	}
	return true;
}

bool checkType(T)(JSONValue value)
{
	final switch (value.type)
	{
	case JSON_TYPE.ARRAY:
		static if (isStaticArray!T)
			return T.length == value.array.length
				&& value.array.all!(checkType!(typeof(T.init[0])));
		else static if (isDynamicArray!T) return value.array.all!(checkType!(typeof(T.init[0])));
		else static if (is(T : Tuple!Args, Args...))
				{
				if (value.array.length != Args.length)
					return false;
				static foreach (i, Arg; Args)
					if (!checkType!Arg(value.array[i]))
						return false;
				return true;
			}
		else
			return false;
	case JSON_TYPE.FALSE:
	case JSON_TYPE.TRUE:
		return is(T : bool);
	case JSON_TYPE.FLOAT:
		return isNumeric!T;
	case JSON_TYPE.INTEGER:
	case JSON_TYPE.UINTEGER:
		return isIntegral!T;
	case JSON_TYPE.NULL:
		static if (is(T == class) || isArray!T || isPointer!T || is(T : Nullable!U, U))
			return true;
		else
			return false;
	case JSON_TYPE.OBJECT:
		return is(T == class) || is(T == struct);
	case JSON_TYPE.STRING:
		return isSomeString!T;
	}
}

interface ComponentWrapper
{
	void bind(WorkspaceD workspaced, WorkspaceD.Instance instance);
	Future!JSONValue run(string method, JSONValue[] args);
}

interface ComponentFactory
{
	ComponentWrapper create(WorkspaceD workspaced, WorkspaceD.Instance instance);
	ComponentInfo info() @property;
}

struct ComponentFactoryInstance
{
	ComponentFactory factory;
	bool autoRegister;
	alias factory this;
}

struct ComponentWrapperInstance
{
	ComponentWrapper wrapper;
	ComponentInfo info;
}

struct Configuration
{
	/// JSON containing base configuration formatted as {[component]:{key:value pairs}}
	JSONValue base;

	bool get(string component, string key, out JSONValue val)
	{
		if (base.type != JSON_TYPE.OBJECT)
		{
			JSONValue[string] tmp;
			base = JSONValue(tmp);
		}
		auto com = component in base.object;
		if (!com)
			return false;
		auto v = key in *com;
		if (!v)
			return false;
		val = *v;
		return true;
	}

	T get(T)(string component, string key, T defaultValue = T.init)
	{
		JSONValue ret;
		if (!get(component, key, ret))
			return defaultValue;
		return ret.fromJSON!T;
	}

	bool set(T)(string component, string key, T value)
	{
		if (base.type != JSON_TYPE.OBJECT)
		{
			JSONValue[string] tmp;
			base = JSONValue(tmp);
		}
		auto com = component in base.object;
		if (!com)
		{
			JSONValue[string] val;
			val[key] = value.toJSON;
			base.object[component] = JSONValue(val);
		}
		else
		{
			com.object[key] = value.toJSON;
		}
		return true;
	}

	/// Same as init but might make nicer code.
	static immutable Configuration none = Configuration.init;

	/// Loads unset keys from global, keeps existing keys
	void loadBase(Configuration global)
	{
		if (global.base.type != JSON_TYPE.OBJECT)
			return;

		if (base.type != JSON_TYPE.OBJECT)
			base = global.base.dupJson;
		else
		{
			foreach (component, config; global.base.object)
			{
				auto existing = component in base.object;
				if (!existing || config.type != JSON_TYPE.OBJECT)
					base.object[component] = config.dupJson;
				else
				{
					foreach (key, value; config.object)
					{
						auto existingValue = key in *existing;
						if (!existingValue)
							(*existing)[key] = value.dupJson;
					}
				}
			}
		}
	}
}

private JSONValue dupJson(JSONValue v)
{
	switch (v.type)
	{
	case JSON_TYPE.OBJECT:
		return JSONValue(v.object.dup);
	case JSON_TYPE.ARRAY:
		return JSONValue(v.array.dup);
	default:
		return v;
	}
}

/// WorkspaceD instance holding plugins.
class WorkspaceD
{
	static class Instance
	{
		string cwd;
		ComponentWrapperInstance[] instanceComponents;
		Configuration config;

		string[] importPaths() const @property
		{
			return importPathProvider ? importPathProvider() : [];
		}

		string[] stringImportPaths() const @property
		{
			return stringImportPathProvider ? stringImportPathProvider() : [];
		}

		string[] importFiles() const @property
		{
			return importFilesProvider ? importFilesProvider() : [];
		}

		ImportPathProvider importPathProvider;
		ImportPathProvider stringImportPathProvider;
		ImportPathProvider importFilesProvider;

		Future!JSONValue run(WorkspaceD workspaced, string component, string method, JSONValue[] args)
		{
			foreach (ref com; instanceComponents)
				if (com.info.name == component)
					return com.wrapper.run(method, args);
			throw new Exception("Component '" ~ component ~ "' not found");
		}

		T get(T)()
		{
			auto name = getUDAs!(T, ComponentInfo)[0].name;
			foreach (com; instanceComponents)
				if (com.info.name == name)
					return cast(T) com.wrapper;
			throw new Exception(
					"Attempted to get unknown instance component " ~ T.stringof ~ " in instance cwd:" ~ cwd);
		}

		bool has(T)()
		{
			auto name = getUDAs!(T, ComponentInfo)[0].name;
			foreach (com; instanceComponents)
				if (com.info.name == name)
					return true;
			return false;
		}

		/// Loads a registered component which didn't have auto register on just for this instance.
		/// Returns: false instead of using the onBindFail callback on failure.
		/// Throws: Exception if component was not regsitered in workspaced.
		bool attach(T)(WorkspaceD workspaced)
		{
			string name = getUDAs!(T, ComponentInfo)[0].name;
			foreach (factory; workspaced.components)
			{
				if (factory.info.name == name)
				{
					auto inst = factory.create(workspaced, this);
					if (inst)
					{
						instanceComponents ~= ComponentWrapperInstance(inst, info);
						return true;
					}
					else
						return false;
				}
			}
			throw new Exception("Component not found");
		}
	}

	BroadcastCallback onBroadcast;
	ComponentBindFailCallback onBindFail;

	Instance[] instances;
	/// Base global configuration for new instances, does not modify existing ones.
	Configuration globalConfiguration;
	ComponentWrapperInstance[] globalComponents;
	ComponentFactoryInstance[] components;
	StringCache stringCache;

	this()
	{
		stringCache = StringCache(StringCache.defaultBucketCount);
	}

	void broadcast(WorkspaceD.Instance instance, JSONValue value)
	{
		if (onBroadcast)
			onBroadcast(this, instance, value);
	}

	Instance getInstance(string cwd) nothrow
	{
		cwd = buildNormalizedPath(cwd);
		foreach (instance; instances)
			if (instance.cwd == cwd)
				return instance;
		return null;
	}

	T get(T)()
	{
		auto name = getUDAs!(T, ComponentInfo)[0].name;
		foreach (com; globalComponents)
			if (com.info.name == name)
				return cast(T) com.wrapper;
		throw new Exception("Attempted to get unknown global component " ~ T.stringof);
	}

	bool has(T)()
	{
		auto name = getUDAs!(T, ComponentInfo)[0].name;
		foreach (com; globalComponents)
			if (com.info.name == name)
				return true;
		return false;
	}

	T get(T)(string cwd)
	{
		if (!cwd.length)
			return this.get!T;
		auto inst = getInstance(cwd);
		if (inst is null)
			throw new Exception("cwd '" ~ cwd ~ "' not found");
		return inst.get!T;
	}

	bool has(T)(string cwd)
	{
		auto inst = getInstance(cwd);
		if (inst is null)
			return false;
		return inst.has!T;
	}

	Future!JSONValue run(string cwd, string component, string method, JSONValue[] args)
	{
		auto instance = getInstance(cwd);
		if (instance is null)
			throw new Exception("cwd '" ~ cwd ~ "' not found");
		return instance.run(this, component, method, args);
	}

	Future!JSONValue run(string component, string method, JSONValue[] args)
	{
		foreach (ref com; globalComponents)
			if (com.info.name == component)
				return com.wrapper.run(method, args);
		throw new Exception("Global component '" ~ component ~ "' not found");
	}

	ComponentFactory register(T)(bool autoRegister = true)
	{
		ComponentFactory factory;
		static foreach (attr; __traits(getAttributes, T))
			static if (is(attr == class) && is(attr : ComponentFactory))
				factory = new attr;
		if (factory is null)
			factory = new DefaultComponentFactory!T;
		components ~= ComponentFactoryInstance(factory, autoRegister);
		auto info = factory.info;
		auto glob = factory.create(this, null);
		if (glob)
			globalComponents ~= ComponentWrapperInstance(glob, info);
		if (autoRegister)
			foreach (ref instance; instances)
			{
				auto inst = factory.create(this, instance);
				if (inst)
					instance.instanceComponents ~= ComponentWrapperInstance(inst, info);
				else if (onBindFail)
					onBindFail(instance, factory);
			}
		static if (__traits(compiles, T.registered(this)))
			T.registered(this);
		else static if (__traits(compiles, T.registered()))
			T.registered();
		return factory;
	}

	/// Creates a new workspace with the given cwd with optional config overrides and preload components for non-autoRegister components.
	/// Throws: Exception if normalized cwd already exists as instance.
	Instance addInstance(string cwd,
			Configuration configOverrides = Configuration.none, string[] preloadComponents = [])
	{
		cwd = buildNormalizedPath(cwd);
		if (instances.canFind!(a => a.cwd == cwd))
			throw new Exception("Instance with cwd '" ~ cwd ~ "' already exists!");
		auto inst = new Instance();
		inst.cwd = cwd;
		configOverrides.loadBase(globalConfiguration);
		inst.config = configOverrides;
		instances ~= inst;
		foreach (name; preloadComponents)
		{
			foreach (factory; components)
			{
				if (!factory.autoRegister && factory.info.name == name)
				{
					auto wrap = factory.create(this, inst);
					if (wrap)
						inst.instanceComponents ~= ComponentWrapperInstance(wrap, factory.info);
					else if (onBindFail)
						onBindFail(inst, factory);
					break;
				}
			}
		}
		foreach (factory; components)
		{
			if (factory.autoRegister)
			{
				auto wrap = factory.create(this, inst);
				if (wrap)
					inst.instanceComponents ~= ComponentWrapperInstance(wrap, factory.info);
				else if (onBindFail)
					onBindFail(inst, factory);
			}
		}
		return inst;
	}

	bool removeInstance(string cwd)
	{
		cwd = buildNormalizedPath(cwd);
		foreach (i, instance; instances)
			if (instance.cwd == cwd)
			{
				foreach (com; instance.instanceComponents)
					destroy(com.wrapper);
				destroy(instance);
				instances = instances.remove(i);
				return true;
			}
		return false;
	}

	bool attach(Instance instance, string component)
	{
		foreach (factory; components)
		{
			if (factory.info.name == component)
			{
				auto wrap = factory.create(this, instance);
				if (wrap)
				{
					instance.instanceComponents ~= ComponentWrapperInstance(wrap, factory.info);
					return true;
				}
				else
					return false;
			}
		}
		return false;
	}
}

class DefaultComponentFactory(T : ComponentWrapper) : ComponentFactory
{
	ComponentWrapper create(WorkspaceD workspaced, WorkspaceD.Instance instance)
	{
		auto wrapper = new T();
		try
		{
			wrapper.bind(workspaced, instance);
			return wrapper;
		}
		catch (Exception e)
		{
			return null;
		}
	}

	ComponentInfo info() @property
	{
		alias udas = getUDAs!(T, ComponentInfo);
		static assert(udas.length == 1, "Can't construct default component factory for "
				~ T.stringof ~ ", expected exactly 1 ComponentInfo instance attached to the type");
		return udas[0];
	}
}

/// Describes what to insert/replace/delete to do something
struct CodeReplacement
{
	/// Range what to replace. If both indices are the same its inserting.
	size_t[2] range;
	/// Content to replace it with. Empty means remove.
	string content;

	/// Applies this edit to a string.
	string apply(string code)
	{
		size_t min = range[0];
		size_t max = range[1];
		if (min > max)
		{
			min = range[1];
			max = range[0];
		}
		if (min >= code.length)
			return code ~ content;
		if (max >= code.length)
			return code[0 .. min] ~ content;
		return code[0 .. min] ~ content ~ code[max .. $];
	}
}

/// Code replacements mapped to a file
struct FileChanges
{
	/// File path to change.
	string file;
	/// Replacements to apply.
	CodeReplacement[] replacements;
}

package bool getConfigPath(string file, ref string retPath)
{
	foreach (dir; standardPaths(StandardPath.config, "workspace-d"))
	{
		auto path = buildPath(dir, file);
		if (path.exists)
		{
			retPath = path;
			return true;
		}
	}
	return false;
}

enum verRegex = ctRegex!`(\d+)\.(\d+)\.(\d+)`;
bool checkVersion(string ver, int[3] target)
{
	auto match = ver.matchFirst(verRegex);
	if (!match)
		return false;
	int major = match[1].to!int;
	int minor = match[2].to!int;
	int patch = match[3].to!int;
	if (major > target[0])
		return true;
	if (major == target[0] && minor >= target[1])
		return true;
	if (major == target[0] && minor == target[1] && patch >= target[2])
		return true;
	return false;
}

package string getVersionAndFixPath(ref string execPath)
{
	import std.process;

	try
	{
		return execute([execPath, "--version"]).output;
	}
	catch (ProcessException e)
	{
		auto newPath = buildPath(thisExePath.dirName, execPath.baseName);
		if (exists(newPath))
		{
			execPath = newPath;
			return execute([execPath, "--version"]).output;
		}
		throw e;
	}
}

class Future(T)
{
	static if (!is(T == void))
		T value;
	Throwable exception;
	bool has;
	void delegate() _onDone;

	/// Sets the onDone callback if no value has been set yet or calls immediately if the value has already been set or was set during setting the callback.
	/// Crashes with an assert error if attempting to override an existing callback (i.e. calling this function on the same object twice).
	void onDone(void delegate() callback) @property
	{
		assert(!_onDone);
		if (has)
			callback();
		else
		{
			bool called;
			_onDone = { called = true; callback(); };
			if (has && !called)
				callback();
		}
	}

	static if (is(T == void))
		static Future!void finished()
		{
			auto ret = new Future!void;
			ret.has = true;
			return ret;
		}
	else
		static Future!T fromResult(T value)
		{
			auto ret = new Future!T;
			ret.value = value;
			ret.has = true;
			return ret;
		}

	static Future!T async(T delegate() cb)
	{
		import core.thread : Thread;

		auto ret = new Future!T;
		new Thread({
			try
			{
				static if (is(T == void))
				{
					cb();
					ret.finish();
				}
				else
					ret.finish(cb());
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		}).start();
		return ret;
	}

	static Future!T fromError(T)(Throwable error)
	{
		auto ret = new Future!T;
		ret.error = error;
		ret.has = true;
		return ret;
	}

	static if (is(T == void))
		void finish()
		{
			assert(!has);
			has = true;
			if (_onDone)
				_onDone();
		}
	else
		void finish(T value)
		{
			assert(!has);
			this.value = value;
			has = true;
			if (_onDone)
				_onDone();
		}

	void error(Throwable t)
	{
		assert(!has);
		exception = t;
		has = true;
		if (_onDone)
			_onDone();
	}

	/// Waits for the result of this future using Thread.sleep
	T getBlocking(alias sleepDur = 1.msecs)()
	{
		import core.thread : Thread;

		while (!has)
			Thread.sleep(sleepDur);
		if (exception)
			throw exception;
		static if (!is(T == void))
			return value;
	}

	/// Waits for the result of this future using Fiber.yield
	T getYield()
	{
		import core.thread : Fiber;

		while (!has)
			Fiber.yield();
		if (exception)
			throw exception;
		static if (!is(T == void))
			return value;
	}
}

version (unittest)
{
	struct TestingWorkspace
	{
		string directory;

		@disable this(this);

		this(string path)
		{
			if (path.exists)
				throw new Exception("Path already exists");
			directory = path;
			mkdir(path);
		}

		~this()
		{
			rmdirRecurse(directory);
		}

		string getPath(string path)
		{
			return buildPath(directory, path);
		}

		void createDir(string dir)
		{
			mkdirRecurse(getPath(dir));
		}

		void writeFile(string path, string content)
		{
			write(getPath(path), content);
		}
	}

	TestingWorkspace makeTemporaryTestingWorkspace()
	{
		import std.random;

		return TestingWorkspace(buildPath(tempDir, "workspace-d-test-" ~ uniform(0,
				int.max).to!string(36)));
	}
}
