module workspaced.com.moduleman;

import dparse.parser;
import dparse.lexer;
import dparse.ast;
import dparse.rollback_allocator;

import std.algorithm;
import std.array;
import std.stdio;
import std.file;
import std.path;

import workspaced.api;

@component("moduleman") :

/// Initializes the module & import parser. Call with `{"cmd": "load", "components": ["moduleman"]}`
@load void start(string projectRoot)
{
	config.stringBehavior = StringBehavior.source;
	cache = new StringCache(StringCache.defaultBucketCount);
	.projectRoot = projectRoot;
}

/// Has no purpose right now.
@unload void stop()
{
}

/// Renames a module to something else (only in the project root).
/// Params:
/// 	renameSubmodules: when `true`, this will rename submodules of the module too. For example when renaming `lib.com` to `lib.coms` this will also rename `lib.com.*` to `lib.coms.*`
/// Returns: all changes that need to happen to rename the module. If no module statement could be found this will return an empty array.
/// Call_With: `{"subcmd": "rename"}`
@arguments("subcmd", "rename")
FileChanges[] rename(string mod, string rename, bool renameSubmodules = true)
{
	FileChanges[] changes;
	bool foundModule = false;
	auto from = mod.split('.');
	auto to = rename.split('.');
	foreach (file; dirEntries(projectRoot, SpanMode.depth))
	{
		if (file.extension != ".d")
			continue;
		string code = readText(file);
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, cache);
		auto parsed = parseModule(tokens, file, &rba, &doNothing);
		auto reader = new ModuleChangerVisitor(file, from, to, renameSubmodules);
		reader.visit(parsed);
		if (reader.changes.replacements.length)
			changes ~= reader.changes;
		if (reader.foundModule)
			foundModule = true;
	}
	if (!foundModule)
		return [];
	return changes;
}

/// Renames/adds/removes a module from a file to match the majority of files in the folder.
/// Params:
/// 	file: File path to the file to normalize
/// 	code: Current code inside the text buffer
CodeReplacement[] normalizeModules(string file, string code)
{
	int[string] modulePrefixes;
	modulePrefixes[""] = 0;
	string modName = file.replace("\\", "/").stripExtension;
	if (modName.baseName == "package")
		modName = modName.dirName;
	if (modName.startsWith(projectRoot.replace("\\", "/")))
		modName = modName[projectRoot.length .. $];
	modName = modName.stripLeft('/');
	foreach (imp; importPathProvider())
	{
		imp = imp.replace("\\", "/");
		if (imp.startsWith(projectRoot.replace("\\", "/")))
			imp = imp[projectRoot.length .. $];
		imp = imp.stripLeft('/');
		if (modName.startsWith(imp))
		{
			modName = modName[imp.length .. $];
			break;
		}
	}
	modName = modName.stripLeft('/').replace("/", ".");
	auto existing = fetchModule(file, code);
	if (modName == existing.moduleName)
	{
		return [];
	}
	else
	{
		if (modName == "")
			return [CodeReplacement([existing.outerFrom, existing.outerTo], "")];
		else
			return [CodeReplacement([existing.outerFrom, existing.outerTo], "module " ~ modName ~ ";")];
	}
}

/// Returns the module name of a D code
const(string)[] getModule(string code)
{
	return fetchModule("", code).raw;
}

private __gshared:
RollbackAllocator rba;
LexerConfig config;
StringCache* cache;
string projectRoot;

ModuleFetchVisitor fetchModule(string file, string code)
{
	auto tokens = getTokensForParser(cast(ubyte[]) code, config, cache);
	auto parsed = parseModule(tokens, file, &rba, &doNothing);
	auto reader = new ModuleFetchVisitor();
	reader.visit(parsed);
	return reader;
}

class ModuleFetchVisitor : ASTVisitor
{
	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration decl)
	{
		outerFrom = decl.startLocation;
		outerTo = decl.endLocation + 1; // + semicolon

		raw = decl.moduleName.identifiers.map!(a => a.text).array;
		moduleName = raw.join(".");
		from = decl.moduleName.identifiers[0].index;
		to = decl.moduleName.identifiers[$ - 1].index + decl.moduleName.identifiers[$ - 1].text.length;
	}

	const(string)[] raw;
	string moduleName = "";
	Token fileName;
	size_t from, to;
	size_t outerFrom, outerTo;
}

class ModuleChangerVisitor : ASTVisitor
{
	this(string file, string[] from, string[] to, bool renameSubmodules)
	{
		changes.file = file;
		this.from = from;
		this.to = to;
		this.renameSubmodules = renameSubmodules;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration decl)
	{
		auto mod = decl.moduleName.identifiers.map!(a => a.text).array;
		auto orig = mod;
		if (mod.startsWith(from) && renameSubmodules)
			mod = to ~ mod[from.length .. $];
		else if (mod == from)
			mod = to;
		if (mod != orig)
		{
			foundModule = true;
			changes.replacements ~= CodeReplacement([decl.moduleName.identifiers[0].index,
					decl.moduleName.identifiers[$ - 1].index + decl.moduleName.identifiers[$ - 1].text.length],
					mod.join('.'));
		}
	}

	override void visit(const SingleImport imp)
	{
		auto mod = imp.identifierChain.identifiers.map!(a => a.text).array;
		auto orig = mod;
		if (mod.startsWith(from) && renameSubmodules)
			mod = to ~ mod[from.length .. $];
		else if (mod == from)
			mod = to;
		if (mod != orig)
		{
			changes.replacements ~= CodeReplacement([imp.identifierChain.identifiers[0].index,
					imp.identifierChain.identifiers[$ - 1].index
					+ imp.identifierChain.identifiers[$ - 1].text.length], mod.join('.'));
		}
	}

	override void visit(const ImportDeclaration decl)
	{
		if (decl)
		{
			return decl.accept(this);
		}
	}

	override void visit(const BlockStatement content)
	{
		if (content)
		{
			return content.accept(this);
		}
	}

	string[] from, to;
	FileChanges changes;
	bool renameSubmodules, foundModule;
}

void doNothing(string, size_t, size_t, string, bool)
{
}

unittest
{
	auto workspace = makeTemporaryTestingWorkspace;
	workspace.createDir("source/newmod");
	workspace.writeFile("source/newmod/color.d", "module oldmod.color;void foo(){}");
	workspace.writeFile("source/newmod/render.d", "module oldmod.render;import std.color,oldmod.color;import oldmod.color.oldmod:a=b, c;import a=oldmod.a;void bar(){}");
	workspace.writeFile("source/newmod/display.d", "module newmod.displaf;");
	workspace.writeFile("source/newmod/input.d", "");
	workspace.writeFile("source/newmod/package.d", "");

	importPathProvider = () => ["source"];

	start(workspace.directory);

	FileChanges[] changes = rename("oldmod", "newmod").sort!"a.file < b.file".array;

	assert(changes.length == 2);
	assert(changes[0].file.endsWith("color.d"));
	assert(changes[1].file.endsWith("render.d"));

	assert(changes[0].replacements == [CodeReplacement([7, 19], "newmod.color")]);
	assert(changes[1].replacements == [CodeReplacement([7, 20], "newmod.render"),
			CodeReplacement([38, 50], "newmod.color"), CodeReplacement([58, 77],
				"newmod.color.oldmod"), CodeReplacement([94, 102], "newmod.a")]);

	foreach (change; changes)
	{
		string code = readText(change.file);
		foreach_reverse (op; change.replacements)
			code = op.apply(code);
		std.file.write(change.file, code);
	}

	auto nrm = normalizeModules(workspace.getPath("source/newmod/input.d"), "");
	assert(nrm == [CodeReplacement([0, 0], "module newmod.input;")]);

	nrm = normalizeModules(workspace.getPath("source/newmod/package.d"), "");
	assert(nrm == [CodeReplacement([0, 0], "module newmod;")]);

	nrm = normalizeModules(workspace.getPath("source/newmod/display.d"), "module oldmod.displaf;");
	assert(nrm == [CodeReplacement([0, 22], "module newmod.display;")]);

	stop();
}
