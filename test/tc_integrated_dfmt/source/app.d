import std.file;
import std.string;

import workspaced.api;
import workspaced.coms;

void main()
{
	assert(syncBlocking!(dfmt.format)("void main(){}").str.splitLines.length > 1);
}