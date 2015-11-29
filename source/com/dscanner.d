module workspaced.com.dscanner;

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

private struct OutlineTreeNode
{
	string definition;
	int line;
	OutlineTreeNode[] children;
}

private struct DefinitionElement
{
	string name;
	int line;
	string type;
	string[string] attributes;
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
		{
			string file = args.getString("file");
			ProcessPipes pipes = raw([execPath, "-S", file]);
			string[] res;
			while(pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DScannerIssue[] issues;
			foreach(line; res)
			{
				if(!line.length)
					continue;
				auto match = line[0 .. $ - 1].matchFirst(dscannerIssueRegex);
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
		}
		case "list-definitions":
		{
			string file = args.getString("file");
			ProcessPipes pipes = raw([execPath, "-c", file]);
			string[] res;
			while(pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DefinitionElement[] definitions;
			foreach(line; res)
			{
				if(!line.length || line[0] == '!')
					continue;
				line = line[0 .. $ - 1];
				string[] splits = line.split('\t');
				DefinitionElement definition;
				definition.name = splits[0];
				definition.type = splits[3];
				definition.line = toImpl!int(splits[4][5 .. $]);
				if(splits.length > 5)
					foreach(attribute; splits[5 .. $])
					{
						string[] sides = attribute.split(':');
						definition.attributes[sides[0]] = sides[1 .. $].join(':');
					}
				definitions ~= definition;
			}
			return definitions.toJSON();
		}
		case "outline":
		{
			OutlineTreeNode[] outline;
			return outline.toJSON();
		}
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
