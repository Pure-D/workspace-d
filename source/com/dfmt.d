module workspaced.com.dfmt;

import std.json;
import std.process;
import core.thread;

import painlessjson;

import workspaced.api;

@component("dfmt") :

@load void start(string dir, string dfmtPath = "dfmt")
{
	cwd = dir;
	execPath = dfmtPath;
}

@unload void stop()
{
}

@any @async void format(AsyncCallback cb, string code)
{
	new Thread({
		try
		{
			auto pipes = pipeProcess([execPath], Redirect.all, null, Config.none, cwd);
			scope (exit)
				pipes.pid.wait();
			pipes.stdin.write(code);
			pipes.stdin.close();
			ubyte[4096] buffer;
			ubyte[] data;
			size_t len;
			do
			{
				auto appended = pipes.stdout.rawRead(buffer);
				len = appended.length;
				data ~= appended;
			}
			while (len == 4096);
			cb(null, JSONValue(cast(string) data));
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

__gshared:
string cwd, execPath;
