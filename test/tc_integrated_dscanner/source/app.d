import std.file;
import std.stdio;

import workspaced.api;
import workspaced.coms;

import painlessjson;

enum mainLine = __LINE__ + 1;
void main()
{
	dscanner.start(getcwd);
	scope (exit)
		dscanner.stop();
	auto issues = syncBlocking!(dscanner.lint)("", "dscanner.ini",
			"void main() { int unused = 0; } void undocumented() { }").fromJSON!(
			dscanner.DScannerIssue[]);
	assert(issues.length >= 3);
	dscanner.DefinitionElement[] defs = syncBlocking!(dscanner.listDefinitions)("app.d",
			import("app.d")).fromJSON!(dscanner.DefinitionElement[]);
	assert(defs.length == 2);
	assert(defs[0].name == "mainLine");
	assert(defs[0].line == mainLine - 1);
	assert(defs[0].type == "v");

	assert(defs[1].name == "main");
	assert(defs[1].line == mainLine);
	assert(defs[1].type == "f");
	assert(defs[1].attributes.length == 1);
	assert(defs[1].attributes["signature"] == "()");

	fsworkspace.start(getcwd);
	scope (exit)
		fsworkspace.stop();
	fsworkspace.addImports(["source"]);
	assert(syncBlocking!(dscanner.findSymbol)("main")
			.fromJSON!(dscanner.FileLocation[]) == [dscanner.FileLocation("./source/app.d", mainLine, 6)]);
}
