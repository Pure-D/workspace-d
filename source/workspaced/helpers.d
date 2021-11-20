module workspaced.helpers;

import std.ascii;
import std.string;

string determineIndentation(scope const(char)[] code)
{
	const(char)[] indent = null;
	foreach (line; code.lineSplitter)
	{
		if (line.strip.length == 0)
			continue;
		indent = line[0 .. $ - line.stripLeft.length];
	}
	return indent.idup;
}

int stripLineEndingLength(scope const(char)[] code)
{
	if (code.endsWith("\r\n"))
		return 2;
	else if (code.endsWith("\r", "\n"))
		return 1;
	else
		return 0;
}

bool isIdentifierChar(dchar c)
{
	return c.isAlphaNum || c == '_';
}

ptrdiff_t indexOfKeyword(scope const(char)[] code, string keyword, ptrdiff_t start = 0)
{
	ptrdiff_t index = start;
	while (true)
	{
		index = code.indexOf(keyword, index);
		if (index == -1)
			break;

		if ((index > 0 && code[index - 1].isIdentifierChar)
				|| (index + keyword.length < code.length && code[index + keyword.length].isIdentifierChar))
		{
			index++;
			continue;
		}
		else
			break;
	}
	return index;
}

bool endsWithKeyword(scope const(char)[] code, string keyword)
{
	return code == keyword || (code.endsWith(keyword) && code[$ - 1 - keyword.length]
			.isIdentifierChar);
}

bool isIdentifierSeparatingChar(dchar c)
{
	return c < 48 || (c > 57 && c < 65) || c == '[' || c == '\\' || c == ']'
		|| c == '`' || (c > 122 && c < 128) || c == '\u2028' || c == '\u2029'; // line separators
}

version (unittest)
{
	import std.json;

	/// Iterates over all files in the given folder, reads them as D files until
	/// a __EOF__ token is encountered, then parses the following lines in this
	/// format per file:
	/// - If the line is empty or starts with `//` ignore it
	/// - If the line starts with `:` it's a variable assignment in form `:variable=JSON`
	/// - Otherwise it's a tab separated line like `1	2	3`
	/// Finally, it's tested that at least one test has been tested.
	void runTestDataFileTests(string dir,
		void delegate() onFileStart,
		void delegate(string code, string variable, JSONValue value) setVariable,
		void delegate(string code, string[] parts, string line) onTestLine,
		void delegate(string code) onFileFinished)
	{
		import std.algorithm;
		import std.array;
		import std.file;
		import std.stdio;

		int noTested = 0;
		foreach (testFile; dirEntries(dir, SpanMode.shallow))
		{
			auto testCode = appender!string;
			bool inCode = true;
			if (onFileStart)
				onFileStart();
			foreach (line; File(testFile, "r").byLine)
			{
				if (line == "__EOF__")
				{
					inCode = false;
					continue;
				}

				if (inCode)
				{
					testCode ~= line;
					testCode ~= '\n'; // normalize CRLF to LF
				}
				else if (!line.length || line.startsWith("//"))
				{
					continue;
				}
				else if (line[0] == ':')
				{
					auto variable = line[1 .. $].idup.findSplit("=");
					if (setVariable)
						setVariable(testCode.data, variable[0], parseJSON(variable[2]));
				}
				else
				{
					if (onTestLine)
					{
						string lineDup = line.idup;
						onTestLine(testCode.data, lineDup.split("\t"), lineDup);
					}
				}
			}

			if (onFileFinished)
				onFileFinished(testCode.data);
			noTested++;
		}

		assert(noTested > 0);
	}
}
