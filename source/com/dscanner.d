module workspaced.com.dscanner;

import workspaced.com.component;

import std.json;
import std.conv;
import std.stdio;
import std.regex;
import std.string;
import std.process;
import core.thread;

import painlessjson; 

private struct DScannerInit
{
	string dscannerPath = "dscanner";
	string dir;
}

private auto dscannerIssueRegex = ctRegex!`^(.+?)\((\d+)\:(\d+)\)\[(.*?)\]: (.*)`;
private struct DScannerIssue
{
	string file;
	int line, column;
	string type;
	string description;
}

class DScannerComponent : Component
{
public:
	override void load(JSONValue args)
	{
		DScannerInit value = fromJSON!DScannerInit(args);
		assert(value.dir, "dub initialization requires a 'dir' field");
		
		execPath = value.dscannerPath;
		cwd = value.dir;
	}

	override void unload(JSONValue args)
	{
	}

	override JSONValue process(JSONValue args)
	{
		string cmd = args.getString("subcmd");
		switch (cmd)
		{
		case "lint":
			string file = args.getString("file");
			ProcessPipes pipes = raw([execPath, "-S", file]);
			string[] res;
			while(pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DScannerIssue[] issues;
			foreach(line; res)
			{
				auto match = line.matchFirst(dscannerIssueRegex);
				if(!match)
					continue;
				DScannerIssue issue;
				issue.file = match[1];
				issue.line = toImpl!int(match[2]);
				issue.column = toImpl!int(match[3]);
				issue.type = match[4];
				issue.description = match[5];
				issues ~= issue;
			}
			return issues.toJSON();
		default:
			throw new Exception("Unknown command: '" ~ cmd ~ "'");
		}
		//return JSONValue(null);
	}

private:
	auto raw(string[] args, Redirect redirect = Redirect.all)
	{
		auto pipes = pipeProcess(args, redirect, null, Config.none, cwd);
		return pipes;
	}

	string execPath, cwd;
}

shared static this()
{
	components["dscanner"] = new DScannerComponent();
}
