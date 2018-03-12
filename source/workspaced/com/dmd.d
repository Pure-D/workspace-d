module workspaced.com.dmd;

import core.thread;
import std.array;
import std.datetime;
import std.datetime.stopwatch : StopWatch;
import std.file;
import std.json;
import std.path;
import std.process;
import std.random;

import painlessjson;

import workspaced.api;

///
@load void start(string dir, string dmdPath = "dmd")
{
	_cwd = dir;
	_dmd = dmdPath;
}

/// Unloads dfmt. Has no purpose right now.
@unload void stop()
{
}

/// Tries to compile a snippet of code with the import paths in the current directory. The arguments `-c -o-` are implicit.
/// The sync function may be used to prevent other measures from running while this is running.
/// Params:
///   cb = async callback
///   code = small code snippet to try to compile
///   dmdArguments = additional arguments to pass to dmd before file name
///   count = how often to compile (duration is divided by either this or less in case timeout is reached)
///   timeoutMsecs = when to abort compilation after, note that this will not abort mid-compilation but not do another iteration if this timeout has been reached.
/// Returns: [DMDMeasureReturn] containing logs from only the first compilation pass
/// Call_With: `{"subcmd": "measure"}`
@arguments("subcmd", "measure")
@async void measure(AsyncCallback cb, string code, string[] dmdArguments = [],
		int count = 1, int timeoutMsecs = 5000)
{
	new Thread({
		try
		{
			cb(null, measureSync(code, dmdArguments, count, timeoutMsecs).toJSON);
		}
		catch (Throwable t)
		{
			cb(t, JSONValue(null));
		}
	}).start();
}

/// ditto
@arguments("subcmd", "measure-sync")
DMDMeasureReturn measureSync(string code, string[] dmdArguments = [],
		int count = 1, int timeoutMsecs = 5000)
{
	dmdArguments ~= ["-c", "-o-"];
	DMDMeasureReturn ret;

	auto timeout = timeoutMsecs.msecs;

	StopWatch sw;

	int effective;

	foreach (i; 0 .. count)
	{
		if (sw.peek >= timeout)
			break;
		string[] baseArgs = [_dmd];
		foreach (path; importPathProvider())
			baseArgs ~= "-I=" ~ path;
		foreach (path; stringImportPathProvider())
			baseArgs ~= "-J=" ~ path;
		auto pipes = pipeProcess(baseArgs ~ dmdArguments ~ "-",
			Redirect.stderrToStdout | Redirect.stdout | Redirect.stdin, null, Config.none, _cwd);
		pipes.stdin.write(code);
		pipes.stdin.close();
		if (i == 0)
		{
			sw.start();
			ret.log = pipes.stdout.byLineCopy().array;
			auto status = pipes.pid.wait();
			sw.stop();
			ret.success = status == 0;
			ret.crash = status < 0;
		}
		else
		{
			sw.start();
			pipes.pid.wait();
			sw.stop();
			pipes.stdout.close();
		}
		effective++;
		if (!ret.success)
			break;
	}

	ret.duration = sw.peek;

	if (effective > 0)
		ret.duration = ret.duration / effective;

	return ret;
}

///
unittest
{
	import std.stdio;

	start(".", "dmd");
	scope (exit)
		stop();
	auto measure = DMDMeasureReturn.fromJSON(syncBlocking!measure("import std.stdio;", null, 100));
	assert(measure.success);
	assert(measure.duration < 5.seconds);
}

///
struct DMDMeasureReturn
{
	/// true if dmd returned 0
	bool success;
	/// true if an ICE occured (segfault / negative return code)
	bool crash;
	/// compilation output
	string[] log;
	/// how long compilation took (serialized to msecs float in json)
	Duration duration;

	/// Converts a json object to [DMDMeasureReturn]
	static DMDMeasureReturn fromJSON(JSONValue value)
	{
		DMDMeasureReturn ret;
		if (auto success = "success" in value)
			ret.success = success.type == JSON_TYPE.TRUE;
		if (auto crash = "crash" in value)
			ret.crash = crash.type == JSON_TYPE.TRUE;
		if (auto log = "log" in value)
			ret.log = (*log).fromJSON!(string[]);
		if (auto duration = "duration" in value)
			ret.duration = (cast(long)(duration.floating * 10_000)).hnsecs;
		return ret;
	}

	/// Converts this object to a [JSONValue]
	JSONValue toJSON() const
	{
		//dfmt off
		return JSONValue([
			"success": JSONValue(success),
			"crash": JSONValue(crash),
			"log": log.toJSON,
			"duration": JSONValue(duration.total!"hnsecs" / cast(double) 10_000)
		]);
		//dfmt on
	}
}

private __gshared:

string _cwd, _dmd;
