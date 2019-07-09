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
