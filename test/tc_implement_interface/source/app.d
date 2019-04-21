import std.algorithm;
import std.conv;
import std.file;
import std.stdio;
import std.string;
import std.process;

import workspaced.api;
import workspaced.coms;

int main(string[] args)
{
	string dir = getcwd;
	scope backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);
	backend.register!FSWorkspaceComponent;
	backend.register!DCDComponent(false);
	backend.register!DCDExtComponent;

	bool verbose = args.length > 1 && (args[1] == "-v" || args[1] == "--v" || args[1] == "--verbose");

	if (!backend.attachSilent(instance, "dcd"))
	{
		// dcd not installed
		stderr.writeln("WARNING: skipping test tc_implement_interface because DCD is not installed");
		return 0;
	}

	auto fsworkspace = backend.get!FSWorkspaceComponent(dir);
	auto dcd = backend.get!DCDComponent(dir);
	auto dcdext = backend.get!DCDExtComponent(dir);

	fsworkspace.addImports(["source"]);

	dcd.setupServer([], true);

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

			if (verbose)
				stderr.writeln(test, ": ", code);

			success = true;
			size_t index;
			foreach (line; reader)
			{
				if (line.startsWith("--- ") || !line.length)
					continue;

				if (line.startsWith("!"))
				{
					if (code.indexOf(line[1 .. $], index) != -1)
					{
						success = false;
						message = "Did not expect to find line " ~ line[1 .. $].idup
							~ " in (after " ~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
				}
				else if (line.startsWith("#"))
				{
					// count occurences
					line = line[1 .. $];
					char op = line[0];
					if (!op.among!('<', '=', '>'))
						throw new Exception("Malformed count line: " ~ line.idup);
					line = line[1 .. $];
					int expected = line.parse!uint;
					line = line[1 .. $];
					int actual = countText(code[index .. $], line);
					bool match;
					if (op == '<')
						match = actual < expected;
					else if (op == '=')
						match = actual == expected;
					else if (op == '>')
						match = actual > expected;
					else
						assert(false);
					if (!match)
					{
						success = false;
						message = "Expected to find the string '" ~ line.idup ~ "' " ~ op ~ " " ~ expected.to!string
							~ " times but actually found it " ~ actual.to!string
							~ " times (after " ~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
				}
				else
				{
					bool freeze = false;
					if (line.startsWith("."))
					{
						freeze = true;
						line = line[1 .. $];
					}
					auto pos = code.indexOf(line, index);
					if (pos == -1)
					{
						success = false;
						message = "Could not find " ~ line.idup ~ " in remaining (after "
							~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
					else if (!freeze)
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

int countText(in char[] text, in char[] search)
{
	int num = 0;
	ptrdiff_t index = text.indexOf(search);
	while (index != -1)
	{
		num++;
		index = text.indexOf(search, index + search.length);
	}
	return num;
}
