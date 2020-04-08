module workspaced.backend;

import painlessjson;
import dparse.lexer : StringCache;

import std.algorithm : canFind, max, min, remove, startsWith;
import std.conv;
import std.file : exists, mkdir, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue;
import std.parallelism : defaultPoolThreads, TaskPool;
import std.path : buildNormalizedPath, buildPath;
import std.range : chain;
import std.traits : getUDAs;

import workspaced.api;

struct Configuration
{
	/// JSON containing base configuration formatted as {[component]:{key:value pairs}}
	JSONValue base;

	bool get(string component, string key, out JSONValue val)
	{
		if (base.type != JSONType.object)
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
		if (base.type != JSONType.object)
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
		if (global.base.type != JSONType.object)
			return;

		if (base.type != JSONType.object)
			base = global.base.dupJson;
		else
		{
			foreach (component, config; global.base.object)
			{
				auto existing = component in base.object;
				if (!existing || config.type != JSONType.object)
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
	case JSONType.object:
		return JSONValue(v.object.dup);
	case JSONType.array:
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

		string[] importPaths() const @property nothrow
		{
			return importPathProvider ? importPathProvider() : [];
		}

		string[] stringImportPaths() const @property nothrow
		{
			return stringImportPathProvider ? stringImportPathProvider() : [];
		}

		string[] importFiles() const @property nothrow
		{
			return importFilesProvider ? importFilesProvider() : [];
		}

		void shutdown(bool dtor = false)
		{
			foreach (ref com; instanceComponents)
				com.wrapper.shutdown(dtor);
			instanceComponents = null;
		}

		ImportPathProvider importPathProvider;
		ImportPathProvider stringImportPathProvider;
		ImportPathProvider importFilesProvider;

		Future!JSONValue run(WorkspaceD workspaced, string component,
				string method, JSONValue[] args)
		{
			foreach (ref com; instanceComponents)
				if (com.info.name == component)
					return com.wrapper.run(method, args);
			throw new Exception("Component '" ~ component ~ "' not found");
		}

		inout(T) get(T)() inout
		{
			auto name = getUDAs!(T, ComponentInfo)[0].name;
			foreach (com; instanceComponents)
				if (com.info.name == name)
					return cast(inout T) com.wrapper;
			throw new Exception(
					"Attempted to get unknown instance component " ~ T.stringof
					~ " in instance cwd:" ~ cwd);
		}

		bool has(T)() const
		{
			auto name = getUDAs!(T, ComponentInfo)[0].name;
			foreach (com; instanceComponents)
				if (com.info.name == name)
					return true;
			return false;
		}

		/// Shuts down an attached component and removes it from this component
		/// list. If you plan to remove all components, call $(LREF shutdown)
		/// instead.
		/// Returns: `true` if the component was loaded and is now unloaded and
		///          removed or `false` if the component wasn't found.
		bool detach(T)()
		{
			auto name = getUDAs!(T, ComponentInfo)[0].name;
			foreach (i, com; instanceComponents)
				if (com.info.name == name)
				{
					instanceComponents = instanceComponents.remove(i);
					com.wrapper.shutdown(false);
					return true;
				}
			return false;
		}

		/// Loads a registered component which didn't have auto register on just for this instance.
		/// Returns: false instead of using the onBindFail callback on failure.
		/// Throws: Exception if component was not registered in workspaced.
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

	/// Event which is called when $(LREF broadcast) is called
	BroadcastCallback onBroadcast;
	/// Called when ComponentFactory.create is called and errored (when the .bind call on a component fails)
	/// See_Also: $(LREF ComponentBindFailCallback)
	ComponentBindFailCallback onBindFail;

	Instance[] instances;
	/// Base global configuration for new instances, does not modify existing ones.
	Configuration globalConfiguration;
	ComponentWrapperInstance[] globalComponents;
	ComponentFactoryInstance[] components;
	StringCache stringCache;

	TaskPool _gthreads;

	this()
	{
		stringCache = StringCache(StringCache.defaultBucketCount * 4);
	}

	~this()
	{
		shutdown(true);
	}

	void shutdown(bool dtor = false)
	{
		foreach (ref instance; instances)
			instance.shutdown(dtor);
		instances = null;
		foreach (ref com; globalComponents)
			com.wrapper.shutdown(dtor);
		globalComponents = null;
		components = null;
		if (_gthreads)
			_gthreads.finish(true);
		_gthreads = null;
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

	Instance getBestInstanceByDependency(WithComponent)(string file) nothrow
	{
		Instance best;
		size_t bestLength;
		foreach (instance; instances)
		{
			foreach (folder; chain(instance.importPaths, instance.importFiles,
					instance.stringImportPaths))
			{
				if (folder.length > bestLength && file.startsWith(folder)
						&& instance.has!WithComponent)
				{
					best = instance;
					bestLength = folder.length;
				}
			}
		}
		return best;
	}

	Instance getBestInstanceByDependency(string file) nothrow
	{
		Instance best;
		size_t bestLength;
		foreach (instance; instances)
		{
			foreach (folder; chain(instance.importPaths, instance.importFiles,
					instance.stringImportPaths))
			{
				if (folder.length > bestLength && file.startsWith(folder))
				{
					best = instance;
					bestLength = folder.length;
				}
			}
		}
		return best;
	}

	Instance getBestInstance(WithComponent)(string file, bool fallback = true) nothrow
	{
		file = buildNormalizedPath(file);
		Instance ret = null;
		size_t best;
		foreach (instance; instances)
		{
			if (instance.cwd.length > best && file.startsWith(instance.cwd)
					&& instance.has!WithComponent)
			{
				ret = instance;
				best = instance.cwd.length;
			}
		}
		if (!ret && fallback)
		{
			ret = getBestInstanceByDependency!WithComponent(file);
			if (ret)
				return ret;
			foreach (instance; instances)
				if (instance.has!WithComponent)
					return instance;
		}
		return ret;
	}

	Instance getBestInstance(string file, bool fallback = true) nothrow
	{
		file = buildNormalizedPath(file);
		Instance ret = null;
		size_t best;
		foreach (instance; instances)
		{
			if (instance.cwd.length > best && file.startsWith(instance.cwd))
			{
				ret = instance;
				best = instance.cwd.length;
			}
		}
		if (!ret && fallback && instances.length)
		{
			ret = getBestInstanceByDependency(file);
			if (!ret)
				ret = instances[0];
		}
		return ret;
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

	T best(T)(string file, bool fallback = true)
	{
		if (!file.length)
			return this.get!T;
		auto inst = getBestInstance!T(file);
		if (inst is null)
			throw new Exception("cwd for '" ~ file ~ "' not found");
		return inst.get!T;
	}

	bool hasBest(T)(string cwd, bool fallback = true)
	{
		auto inst = getBestInstance!T(cwd);
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
		Exception error;
		auto glob = factory.create(this, null, error);
		if (glob)
			globalComponents ~= ComponentWrapperInstance(glob, info);
		else if (onBindFail)
			onBindFail(null, factory, error);

		if (autoRegister)
			foreach (ref instance; instances)
			{
				auto inst = factory.create(this, instance, error);
				if (inst)
					instance.instanceComponents ~= ComponentWrapperInstance(inst, info);
				else if (onBindFail)
					onBindFail(instance, factory, error);
			}
		static if (__traits(compiles, T.registered(this)))
			T.registered(this);
		else static if (__traits(compiles, T.registered()))
			T.registered();
		return factory;
	}

	/// Creates a new workspace with the given cwd with optional config overrides and preload components for non-autoRegister components.
	/// Throws: Exception if normalized cwd already exists as instance.
	Instance addInstance(string cwd, Configuration configOverrides = Configuration.none,
			string[] preloadComponents = [])
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
					Exception error;
					auto wrap = factory.create(this, inst, error);
					if (wrap)
						inst.instanceComponents ~= ComponentWrapperInstance(wrap, factory.info);
					else if (onBindFail)
						onBindFail(inst, factory, error);
					break;
				}
			}
		}
		foreach (factory; components)
		{
			if (factory.autoRegister)
			{
				Exception error;
				auto wrap = factory.create(this, inst, error);
				if (wrap)
					inst.instanceComponents ~= ComponentWrapperInstance(wrap, factory.info);
				else if (onBindFail)
					onBindFail(inst, factory, error);
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

	deprecated("Use overload taking an out Exception error or attachSilent instead") bool attach(
			Instance instance, string component)
	{
		return attachSilent(instance, component);
	}

	bool attachSilent(Instance instance, string component)
	{
		Exception error;
		return attach(instance, component, error);
	}

	bool attach(Instance instance, string component, out Exception error)
	{
		foreach (factory; components)
		{
			if (factory.info.name == component)
			{
				auto wrap = factory.create(this, instance, error);
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

	TaskPool gthreads()
	{
		if (!_gthreads)
			synchronized (this)
				if (!_gthreads)
					_gthreads = new TaskPool(max(2, min(6, defaultPoolThreads)));
		return _gthreads;
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

		return TestingWorkspace(buildPath(tempDir,
				"workspace-d-test-" ~ uniform(0, long.max).to!string(36)));
	}
}
