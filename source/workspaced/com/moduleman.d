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
FileChanges[] rename(string code, string mod, string rename, bool renameSubmodules = true)
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
		auto mod = parseModule(tokens, file, &rba, &doNothing);
		auto reader = new ModuleChangerVisitor(pos);
		reader.changes.file = file;
		reader.from = from;
		reader.to = to;
		reader.renameSubmodules = renameSubmodules;
		reader.visit(mod);
		if (reader.changes.replacements.length)
			changes ~= reader.changes;
		if (reader.foundModule)
			foundModule = true;
	}
	if (!foundModule)
		return [];
	return changes;
}

private __gshared:
RollbackAllocator rba;
LexerConfig config;
StringCache* cache;
string projectRoot;

class ModuleChangerVisitor : ASTVisitor
{
	this(int pos)
	{
		this.pos = pos;
		inBlock = false;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration decl)
	{
		string[] mod = decl.moduleName.identifiers.map!(a => a.text).array;
		auto orig = mod;
		if (mod.startsWith(from) && renameSubmodules)
			mod = to ~ mod[from.length .. $];
		else if (mod == from)
			mod = to;
		if (mod != orig)
		{
			foundModule = true;
			changes.replacements ~= CodeReplacement([
				decl.moduleName.identifiers[0].index,
				decl.moduleName.identifiers[$ - 1].index + decl.moduleName.identifiers[$ - 1].text.length
			], mod.join('.'));
		}
	}

	override void visit(const ImportDeclaration decl)
	{
		if (decl.startIndex >= pos)
			return;
		isModule = false;
		if (inBlock)
			innermostBlockStart = decl.endIndex;
		else
			outerImportLocation = decl.endIndex;
		foreach (i; decl.singleImports)
			imports ~= ImportInfo(i.identifierChain.identifiers.map!(tok => tok.text.idup)
					.array, i.rename.text);
		if (decl.importBindings)
		{
			ImportInfo info;
			if (!decl.importBindings.singleImport)
				return;
			info.name = decl.importBindings.singleImport.identifierChain.identifiers.map!(
					tok => tok.text.idup).array;
			info.rename = decl.importBindings.singleImport.rename.text;
			foreach (bind; decl.importBindings.importBinds)
			{
				if (bind.right.text)
					info.selectives ~= SelectiveImport(bind.right.text, bind.left.text);
				else
					info.selectives ~= SelectiveImport(bind.left.text);
			}
			if (info.selectives.length)
				imports ~= info;
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
	import std.conv;

	start();

	stop();
}
