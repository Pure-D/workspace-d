module workspaced.com.dfmt;

import workspaced.com.component;

import std.json;
import std.conv;
import std.stdio;
import std.regex;
import std.string;
import std.process;
import std.algorithm;
import core.thread;

import painlessjson;

private struct DFMTInit
{
	string dfmtPath = "dfmt";
	string dir;
}

class DFMTComponent : Component
{
public:
	override void load(JSONValue args)
	{
		DFMTInit value = fromJSON!DFMTInit(args);
		assert(value.dir, "dfmt initialization requires a 'dir' field");

		execPath = value.dfmtPath;
		cwd = value.dir;
	}

	override void unload(JSONValue args)
	{
	}

	override JSONValue process(JSONValue args)
	{
		string code = args.getString("code");
		ProcessPipes pipes = raw([execPath]);
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
		return JSONValue(cast(string) data);
	}

private:
	auto raw(string[] args, Redirect redirect = Redirect.all)
	{
		auto pipes = pipeProcess(args, redirect, null, Config.none, cwd);
		return pipes;
	}

	string cwd, execPath;
}

shared static this()
{
	components["dfmt"] = new DFMTComponent();
}
