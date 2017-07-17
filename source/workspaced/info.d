module source.workspaced.info;

import Compiler = std.compiler;
import OS = std.system;
import std.json;
import std.conv;

static immutable Version = [2, 11, 0];

version (Windows) static assert(Compiler.name != "Digital Mars D",
		"Use LDC instead of DMD on Windows! See Also: https://github.com/Pure-D/code-d/issues/38");

string getVersionInfoString()
{
	return Version[0].to!string ~ '.' ~ Version[1].to!string ~ '.'
		~ Version[2].to!string ~ " compiled with " ~ Compiler.name ~ " v"
		~ Compiler.version_major.to!string ~ "."
		~ Compiler.version_minor.to!string ~ " - " ~ OS.os.to!string ~ " " ~ OS.endian.to!string;
}

JSONValue getVersionInfoJson()
{
	//dfmt off
	return JSONValue([
		"major": JSONValue(Version[0]),
		"minor": JSONValue(Version[1]),
		"patch": JSONValue(Version[2]),
		"compiler": JSONValue([
			"name": JSONValue(Compiler.name),
			"vendor": JSONValue(Compiler.vendor.to!string),
			"major": JSONValue(Compiler.version_major.to!string),
			"minor": JSONValue(Compiler.version_minor.to!string)
		]),
		"os": JSONValue(OS.os.to!string),
		"endian": JSONValue(OS.endian.to!string),
		"summary": JSONValue(getVersionInfoString)
	]);
	//dfmt on
}
