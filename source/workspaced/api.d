module workspaced.api;

// debug = Tasks;

import standardpaths;

import std.algorithm : all;
import std.array : array;
import std.conv;
import std.file : exists, thisExePath;
import std.json : JSONType, JSONValue;
import std.path : baseName, chainPath, dirName;
import std.regex : ctRegex, matchFirst;
import std.string : strip;
import std.traits;

public import workspaced.backend;
public import workspaced.future;

version (unittest)
{
	version (Have_unit_threaded) package import unit_threaded.assertions;

	package import std.experimental.logger : trace;
}
else
{
	// dummy
	package void trace(Args...)(lazy Args)
	{
	}
}

///
alias ImportPathProvider = string[] delegate() nothrow;
///
alias BroadcastCallback = void delegate(WorkspaceD, WorkspaceD.Instance, JSONValue);
/// Called when ComponentFactory.create is called and errored (when the .bind call on a component fails)
/// Params:
/// 	instance = the instance for which the component was attempted to initialize (or null for global component registration)
/// 	factory = the factory on which the error occured with
/// 	error = the stacktrace that was catched on the bind call
alias ComponentBindFailCallback = void delegate(WorkspaceD.Instance instance,
		ComponentFactory factory, Exception error);

/// UDA; will never try to call this function from rpc
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

void traceTaskLog(lazy string msg)
{
	import std.stdio : stderr;

	debug (Tasks)
		stderr.writeln(msg);
}

static immutable traceTask = `traceTaskLog("new task in " ~ __PRETTY_FUNCTION__); scope (exit) traceTaskLog(__PRETTY_FUNCTION__ ~ " exited");`;

mixin template DefaultComponentWrapper(bool withDtor = true)
{
	@ignoredFunc
	{
		import std.algorithm : min, max;
		import std.parallelism : TaskPool, Task, task, defaultPoolThreads;

		WorkspaceD workspaced;
		WorkspaceD.Instance refInstance;

		TaskPool _threads;

		static if (withDtor)
		{
			~this()
			{
				shutdown(true);
			}
		}

		TaskPool gthreads()
		{
			return workspaced.gthreads;
		}

		TaskPool threads(int minSize, int maxSize)
		{
			if (!_threads)
				synchronized (this)
					if (!_threads)
						_threads = new TaskPool(max(minSize, min(maxSize, defaultPoolThreads)));
			return _threads;
		}

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

		bool has(T)()
		{
			if (refInstance)
				return refInstance.has!T;
			else if (workspaced)
				return workspaced.has!T;
			else
				assert(false, "Unbound component trying to check for component " ~ T.stringof ~ ".");
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

		auto getCachedTokens(const(ubyte)[] code, string file)
		{
			import dparse.lexer : getTokensForParser, LexerConfig;

			if (file.length)
			{
				return workspaced.sourceCache.cacheFile(file, code).tokens;
			}
			else
			{
				LexerConfig config;
				config.fileName = "stdin";
				config.stringBehavior = StringBehavior.source;
				return getTokensForParser(code, config, &workspaced.stringCache);
			}
		}

		override void shutdown(bool dtor = false)
		{
			if (!dtor && _threads)
				_threads.finish();
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
		import std.traits : isFunction, hasUDA, ParameterDefaults, Parameters, ReturnType;
		import painlessjson;

		override Future!JSONValue run(string method, JSONValue[] args)
		{
			static foreach (member; __traits(derivedMembers, typeof(this)))
				static if (member[0] != '_' && __traits(compiles, __traits(getMember,
						typeof(this).init, member)) && __traits(getProtection, __traits(getMember, typeof(this).init,
						member)) == "public" && __traits(compiles, isFunction!(__traits(getMember, typeof(this)
						.init, member))) && isFunction!(__traits(getMember, typeof(this).init,
						member)) && !hasUDA!(__traits(getMember, typeof(this).init, member),
						ignoredFunc) && !__traits(isTemplate,
						__traits(getMember, typeof(this).init, member)))
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
			{
				static if (is(T : const(char)[]))
					call ~= "args[" ~ i.to!string ~ "].str, ";
				else
					call ~= "args[" ~ i.to!string ~ "].fromJSON!(" ~ T.stringof ~ "), ";
			}
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
	case JSONType.array:
		static if (isStaticArray!T)
			return T.length == value.array.length
				&& value.array.all!(checkType!(typeof(T.init[0])));
		else static if (isDynamicArray!T)
			return value.array.all!(checkType!(typeof(T.init[0])));
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
	case JSONType.false_:
	case JSONType.true_:
		return is(T : bool);
	case JSONType.float_:
		return isNumeric!T;
	case JSONType.integer:
	case JSONType.uinteger:
		return isIntegral!T;
	case JSONType.null_:
		static if (is(T == class) || isArray!T || isPointer!T
				|| is(T : Nullable!U, U))
			return true;
		else
			return false;
	case JSONType.object:
		return is(T == class) || is(T == struct);
	case JSONType.string:
		return isSomeString!T;
	}
}

interface ComponentWrapper
{
	void bind(WorkspaceD workspaced, WorkspaceD.Instance instance);
	Future!JSONValue run(string method, JSONValue[] args);
	void shutdown(bool dtor = false);
}

interface ComponentFactory
{
	ComponentWrapper create(WorkspaceD workspaced, WorkspaceD.Instance instance, out Exception error);
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

class DefaultComponentFactory(T : ComponentWrapper) : ComponentFactory
{
	ComponentWrapper create(WorkspaceD workspaced, WorkspaceD.Instance instance, out Exception error)
	{
		auto wrapper = new T();
		try
		{
			wrapper.bind(workspaced, instance);
			return wrapper;
		}
		catch (Exception e)
		{
			error = e;
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
		auto path = chainPath(dir, file);
		if (path.exists)
		{
			retPath = path.array;
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
	const major = match[1].to!int;
	const minor = match[2].to!int;
	const patch = match[3].to!int;
	return checkVersion([major, minor, patch], target);
}

bool checkVersion(int[3] ver, int[3] target)
{
	if (ver[0] > target[0])
		return true;
	if (ver[0] == target[0] && ver[1] > target[1])
		return true;
	if (ver[0] == target[0] && ver[1] == target[1] && ver[2] >= target[2])
		return true;
	return false;
}

package string getVersionAndFixPath(ref string execPath)
{
	import std.process;

	try
	{
		return execute([execPath, "--version"]).output.strip;
	}
	catch (ProcessException e)
	{
		auto newPath = chainPath(thisExePath.dirName, execPath.baseName);
		if (exists(newPath))
		{
			execPath = newPath.array;
			return execute([execPath, "--version"]).output.strip;
		}
		throw e;
	}
}
