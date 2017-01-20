import workspaced.api;
import workspaced.coms;

import std.algorithm;
import std.file;
import std.json;
import std.path;
import std.stdio : writeln;
import std.string;

void broadcast(JSONValue val)
{
	writeln("Received callback: ", val);
}

unittest
{
	string projectRoot = buildPath(tempDir, "testProject");
	if (exists(projectRoot))
	{
		if (projectRoot.isDir)
			projectRoot.rmdirRecurse;
		else
			projectRoot.remove;
	}
	mkdir(projectRoot);
	write(buildPath(projectRoot, "dub.json"), `{"name":"test"}`);
	mkdir(buildPath(projectRoot, "source"));
	string source = q{
		import std.stdio;

		void main() {
			writeln("Hello World");
		}
	};
	write(buildPath(projectRoot, "source", "app.d"), source);
	broadcastCallback = &broadcast;
	dub.startup(projectRoot);
	scope (exit)
		dub.stop;
	dcd.start(projectRoot);
	scope (exit)
		dcd.stop;
	auto completion = syncBlocking!(dcd.listCompletion)(source, cast(int) source.indexOf("writeln") + 4);
	assert(completion["type"].str == "identifiers");
	assert(completion["identifiers"].array.canFind!`a["identifier"].str == b`("writeln"));
}
