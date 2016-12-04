module workspaced.com.importer;

import dparse.parser;
import dparse.lexer;
import dparse.ast;
import dparse.rollback_allocator;

import std.algorithm;
import std.array;
import std.stdio;

import workspaced.api;

@component("importer") :

/// Initializes the import parser. Call with `{"cmd": "load", "components": ["importer"]}`
@load void start()
{
	config.stringBehavior = StringBehavior.source;
	cache = new StringCache(StringCache.defaultBucketCount);
}

/// Has no purpose right now.
@unload void stop()
{
}

/// Returns all imports available at some code position.
/// Call_With: `{"subcmd": "get"}`
@arguments("subcmd", "get")
ImportInfo[] get(string code, int pos)
{
	auto tokens = getTokensForParser(cast(ubyte[]) code, config, cache);
	auto mod = parseModule(tokens, "code", &rba, &doNothing);
	auto reader = new ImporterReaderVisitor(pos);
	reader.visit(mod);
	return reader.imports;
}

/// Returns a list of code patches for adding an import.
/// If `insertOutermost` is false, the import will get added to the innermost block.
/// Call_With: `{"subcmd": "add"}`
@arguments("subcmd", "add")
ImportModification add(string importName, string code, int pos, bool insertOutermost = true)
{
	auto tokens = getTokensForParser(cast(ubyte[]) code, config, cache);
	auto mod = parseModule(tokens, "code", &rba, &doNothing);
	auto reader = new ImporterReaderVisitor(pos);
	reader.visit(mod);
	foreach (i; reader.imports)
	{
		if (i.name.join('.') == importName)
		{
			if (i.selectives.length == 0)
				return ImportModification(i.rename, []);
			else
				insertOutermost = false;
		}
	}
	string indentation = "";
	if (insertOutermost)
	{
		indentation = reader.outerImportLocation == 0 ? "" : (cast(ubyte[]) code)
			.getIndentation(reader.outerImportLocation);
		return ImportModification("", [CodeReplacement([reader.outerImportLocation, reader.outerImportLocation],
				indentation ~ "import " ~ importName ~ ";" ~ (reader.outerImportLocation == 0 ? "\n" : ""))]);
	}
	else
	{
		indentation = (cast(ubyte[]) code).getIndentation(reader.innermostBlockStart);
		return ImportModification("", [CodeReplacement([reader.innermostBlockStart,
				reader.innermostBlockStart], indentation ~ "import " ~ importName ~ ";")]);
	}
}

/// Information about how to add an import
struct ImportModification
{
	/// Set if there was already an import which was renamed. (for example import io = std.stdio; would be "io")
	string rename;
	/// Array of replacements to add the import to the code
	CodeReplacement[] replacements;
}

/// Describes what to insert/replace/delete to do something
struct CodeReplacement
{
	/// Range what to replace. If both indices are the same its inserting.
	size_t[2] range;
	/// Content to replace it with. Empty means remove.
	string content;

	package string apply(string code)
	{
		size_t min = range[0];
		size_t max = range[1];
		if (min > max)
		{
			min = range[1];
			max = range[0];
		}
		if (min >= code.length)
			return code ~ content;
		if (max >= code.length)
			return code[0 .. min] ~ content;
		return code[0 .. min] ~ content ~ code[max .. $];
	}
}

/// Name and (if specified) rename of a symbol
struct SelectiveImport
{
	/// Original name (always available)
	string name;
	/// Rename if specified
	string rename;
}

/// Information about one import statement
struct ImportInfo
{
	/// Parts of the imported module. (std.stdio -> ["std", "stdio"])
	string[] name;
	/// Available if the module has been imported renamed
	string rename;
	/// Array of selective imports or empty if the entire module has been imported
	SelectiveImport[] selectives;
}

private __gshared:
RollbackAllocator rba;
LexerConfig config;
StringCache* cache;

string getIndentation(ubyte[] code, size_t index)
{
	import std.ascii : isWhite;

	while (index > 0)
	{
		if (code[index - 1] == cast(ubyte) '\n')
			break;
		index--;
	}
	size_t end = index;
	while (end < code.length)
	{
		if (!code[end].isWhite)
			break;
		end++;
	}
	auto indent = cast(string) code[index .. end];
	if (!indent.length)
		return " ";
	return "\n" ~ indent;
}

unittest
{
	auto code = cast(ubyte[]) "void foo() {\n\tfoo();\n}";
	auto indent = getIndentation(code, 20);
	assert(indent == "\n\t", '"' ~ indent ~ '"');
	code = cast(ubyte[]) "void foo() { foo(); }";
	indent = getIndentation(code, 19);
	assert(indent == " ", '"' ~ indent ~ '"');
}

class ImporterReaderVisitor : ASTVisitor
{
	this(int pos)
	{
		this.pos = pos;
		inBlock = false;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const ImportDeclaration decl)
	{
		if (decl.startIndex >= pos)
			return;
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
		if (content && pos >= content.startLocation && pos < content.endLocation)
		{
			if (content.startLocation + 1 >= innermostBlockStart)
				innermostBlockStart = content.startLocation + 1;
			inBlock = true;
			return content.accept(this);
		}
	}

	private int pos;
	private bool inBlock;
	ImportInfo[] imports;
	size_t outerImportLocation;
	size_t innermostBlockStart;
}

void doNothing(string, size_t, size_t, string, bool)
{
}

unittest
{
	import std.conv;

	start();
	auto imports = get("import std.stdio; void foo() { import fs = std.file; import std.algorithm : map, each2 = each; writeln(\"hi\"); } void bar() { import std.string; import std.regex : ctRegex; }",
			81);
	bool equalsImport(ImportInfo i, string s)
	{
		return i.name.join('.') == s;
	}

	void assertEquals(T)(T a, T b)
	{
		assert(a == b, "'" ~ a.to!string ~ "' != '" ~ b.to!string ~ "'");
	}

	assertEquals(imports.length, 3);
	assert(equalsImport(imports[0], "std.stdio"));
	assert(equalsImport(imports[1], "std.file"));
	assertEquals(imports[1].rename, "fs");
	assert(equalsImport(imports[2], "std.algorithm"));
	assertEquals(imports[2].selectives.length, 2);
	assertEquals(imports[2].selectives[0].name, "map");
	assertEquals(imports[2].selectives[1].name, "each");
	assertEquals(imports[2].selectives[1].rename, "each2");
	string code = "void foo() { import std.stdio : stderr; writeln(\"hi\"); }";
	auto mod = add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"void foo() { import std.stdio : stderr; import std.stdio; writeln(\"hi\"); }");
	code = "void foo() {\n\timport std.stdio : stderr;\n\twriteln(\"hi\");\n}";
	mod = add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"void foo() {\n\timport std.stdio : stderr;\n\timport std.stdio;\n\twriteln(\"hi\");\n}");
	stop();
	code = "void foo() {\n\timport std.file : readText;\n\twriteln(\"hi\");\n}";
	mod = add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.stdio;\nvoid foo() {\n\timport std.file : readText;\n\twriteln(\"hi\");\n}");
	code = "void foo() { import io = std.stdio; io.writeln(\"hi\"); }";
	mod = add("std.stdio", code, 45);
	assertEquals(mod.rename, "io");
	assertEquals(mod.replacements.length, 0);
	stop();
}
