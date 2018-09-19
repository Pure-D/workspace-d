import std.algorithm;
import std.conv;
import std.file;
import std.stdio;
import std.string;
import std.process;

import workspaced.api;
import workspaced.coms;

int main()
{
	string dir = getcwd;
	auto backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);
	backend.register!FSWorkspaceComponent;
	backend.register!DCDComponent(false);
	backend.register!DCDExtComponent;

	if (!backend.attach(instance, "dcd"))
	{
		// dcd not installed
		stderr.writeln("WARNING: skipping test tc_implement_interface because DCD is not installed");
		return 0;
	}

	auto fsworkspace = backend.get!FSWorkspaceComponent(dir);
	auto dcd = backend.get!DCDComponent(dir);
	auto dcdext = backend.get!DCDExtComponent(dir);

	fsworkspace.addImports(["source"]);

	dcd.setupServer();

	scope (exit)
		dcd.stopServerSync();

	int status = 0;

	foreach (test; dirEntries("tests", SpanMode.shallow))
	{
		if (!test.name.endsWith(".d"))
			continue;
		auto expect = test ~ ".expected";
		if (!expect.exists)
		{
			stderr.writeln("Warning: tests/", expect, " does not exist!");
			continue;
		}
		auto source = test.readText;
		auto reader = File(expect).byLine;
		auto cmd = reader.front.splitter;
		string code, message;
		bool success;
		if (cmd.front == "implement")
		{
			cmd.popFront;
			code = dcdext.implement(source, cmd.front.to!uint).getBlocking;
			reader.popFront;

			success = true;
			size_t index;
			foreach (line; reader)
			{
				if (line.startsWith("!"))
				{
					if (code.indexOf(line[1 .. $], index) != -1)
					{
						success = false;
						message = "Did not expect to find line " ~ line[1 .. $].idup
							~ " in (after " ~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
				}
				else
				{
					auto pos = code.indexOf(line, index);
					if (pos == -1)
					{
						success = false;
						message = "Could not find " ~ line.idup ~ " in remaining (after "
							~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
					else
					{
						index = pos + line.length;
					}
				}
			}
		}
		else if (cmd.front == "failimplement")
		{
			cmd.popFront;
			code = dcdext.implement(source, cmd.front.to!uint).getBlocking;
			if (code.length != 0)
			{
				message = "Code: " ~ code;
				success = false;
			}
			else
			{
				success = true;
			}
		}
		else
			throw new Exception("Unknown command in " ~ expect ~ ": " ~ reader.front.idup);

		if (success)
			writeln("Pass ", expect);
		else
		{
			writeln("Expected fail in ", expect, " but it succeeded. ", message);
			status = 1;
		}
	}

	return status;
}
