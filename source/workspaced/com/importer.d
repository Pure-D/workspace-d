/// Component for adding imports to a file, reading imports at a location of code and sorting imports.
module workspaced.com.importer;

import dparse.ast;
import dparse.parser;
import dparse.rollback_allocator;
import dparse.lexer;

import std.algorithm;
import std.array;
import std.functional;
import std.stdio;
import std.string;

import workspaced.api;

/// ditto
@component("importer")
class ImporterComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		config.stringBehavior = StringBehavior.source;
	}

	/// Returns all imports available at some code position.
	ImportInfo[] get(string code, int pos)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(pos);
		reader.visit(mod);
		return reader.imports;
	}

	/// Returns a list of code patches for adding an import.
	/// If `insertOutermost` is false, the import will get added to the innermost block.
	ImportModification add(string importName, string code, int pos, bool insertOutermost = true)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
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
			if (reader.isModule)
				indentation = '\n' ~ indentation;
			return ImportModification("", [CodeReplacement([reader.outerImportLocation, reader.outerImportLocation],
					indentation ~ "import " ~ importName ~ ";" ~ (reader.outerImportLocation == 0 ? "\n" : ""))]);
		}
		else
		{
			indentation = (cast(ubyte[]) code).getIndentation(reader.innermostBlockStart);
			if (reader.isModule)
				indentation = '\n' ~ indentation;
			return ImportModification("", [CodeReplacement([reader.innermostBlockStart,
					reader.innermostBlockStart], indentation ~ "import " ~ importName ~ ";")]);
		}
	}

	/// Sorts the imports in a whitespace separated group of code
	/// Returns `ImportBlock.init` if no changes would be done.
	ImportBlock sortImports(string code, int pos)
	{
		bool startBlock = true;
		size_t start, end;
		// find block of code separated by empty lines
		foreach (line; code.lineSplitter!(KeepTerminator.yes))
		{
			if (startBlock)
				start = end;
			startBlock = line.strip.length == 0;
			if (startBlock && end >= pos)
				break;
			end += line.length;
		}
		if (end > start && end + 1 < code.length)
			end--;
		if (start >= end || end >= code.length)
			return ImportBlock.init;
		auto part = code[start .. end];
		auto tokens = getTokensForParser(cast(ubyte[]) part, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(-1);
		reader.visit(mod);
		auto imports = reader.imports;
		auto sorted = imports.map!(a => ImportInfo(a.name, a.rename,
				a.selectives.dup.sort!((c, d) => icmp(c.effectiveName, d.effectiveName) < 0).array)).array.sort!((a,
				b) => icmp(a.effectiveName, b.effectiveName) < 0).array;
		if (sorted == imports)
			return ImportBlock.init;
		return ImportBlock(cast(int) start, cast(int) end, sorted);
	}

private:
	RollbackAllocator rba;
	LexerConfig config;
}

unittest
{
	import std.conv : to;

	void assertEqual(A, B)(A a, B b)
	{
		assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
	}

	auto backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!ImporterComponent;

	string code = `import std.stdio;
import std.algorithm;
import std.array;
import std.experimental.logger;
import std.regex;
import std.functional;
import std.file;
import std.path;

import core.thread;
import core.sync.mutex;

import gtk.HBox, gtk.VBox, gtk.MainWindow, gtk.Widget, gtk.Button, gtk.Frame,
	gtk.ButtonBox, gtk.Notebook, gtk.CssProvider, gtk.StyleContext, gtk.Main,
	gdk.Screen, gtk.CheckButton, gtk.MessageDialog, gtk.Window, gtkc.gtk,
	gtk.Label, gdk.Event;

import already;
import sorted;

import std.stdio : writeln, File, stdout, err = stderr;

void main() {}`;

	//dfmt off
	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 0), ImportBlock(0, 164, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "array"]),
		ImportInfo(["std", "experimental", "logger"]),
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "functional"]),
		ImportInfo(["std", "path"]),
		ImportInfo(["std", "regex"]),
		ImportInfo(["std", "stdio"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 192), ImportBlock(166, 209, [
		ImportInfo(["core", "sync", "mutex"]),
		ImportInfo(["core", "thread"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 238), ImportBlock(211, 457, [
		ImportInfo(["gdk", "Event"]),
		ImportInfo(["gdk", "Screen"]),
		ImportInfo(["gtk", "Button"]),
		ImportInfo(["gtk", "ButtonBox"]),
		ImportInfo(["gtk", "CheckButton"]),
		ImportInfo(["gtk", "CssProvider"]),
		ImportInfo(["gtk", "Frame"]),
		ImportInfo(["gtk", "HBox"]),
		ImportInfo(["gtk", "Label"]),
		ImportInfo(["gtk", "Main"]),
		ImportInfo(["gtk", "MainWindow"]),
		ImportInfo(["gtk", "MessageDialog"]),
		ImportInfo(["gtk", "Notebook"]),
		ImportInfo(["gtk", "StyleContext"]),
		ImportInfo(["gtk", "VBox"]),
		ImportInfo(["gtk", "Widget"]),
		ImportInfo(["gtk", "Window"]),
		ImportInfo(["gtkc", "gtk"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 467), ImportBlock.init);

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 546), ImportBlock(491, 546, [
		ImportInfo(["std", "stdio"], "", [
			SelectiveImport("stderr", "err"),
			SelectiveImport("File"),
			SelectiveImport("stdout"),
			SelectiveImport("writeln"),
		])
	]));
	//dfmt on
}

/// Information about how to add an import
struct ImportModification
{
	/// Set if there was already an import which was renamed. (for example import io = std.stdio; would be "io")
	string rename;
	/// Array of replacements to add the import to the code
	CodeReplacement[] replacements;
}

/// Name and (if specified) rename of a symbol
struct SelectiveImport
{
	/// Original name (always available)
	string name;
	/// Rename if specified
	string rename;

	/// Returns rename if set, otherwise name
	string effectiveName() const
	{
		return rename.length ? rename : name;
	}

	/// Returns a D source code part
	string toString() const
	{
		return (rename.length ? rename ~ " = " : "") ~ name;
	}
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

	/// Returns the rename if available, otherwise the name joined with dots
	string effectiveName() const
	{
		return rename.length ? rename : name.join('.');
	}

	/// Returns D source code for this import
	string toString() const
	{
		import std.conv : to;

		return "import " ~ (rename.length ? rename ~ " = "
				: "") ~ name.join('.') ~ (selectives.length
				? " : " ~ selectives.to!(string[]).join(", ") : "") ~ ';';
	}
}

/// A block of imports generated by the sort-imports command
struct ImportBlock
{
	/// Start & end byte index
	int start, end;
	///
	ImportInfo[] imports;
}

private:

string getIndentation(ubyte[] code, size_t index)
{
	import std.ascii : isWhite;

	bool atLineEnd = false;
	if (index < code.length && code[index] == '\n')
	{
		for (size_t i = index; i < code.length; i++)
			if (!code[i].isWhite)
				break;
		atLineEnd = true;
	}
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
	if (!indent.length && index == 0 && !atLineEnd)
		return " ";
	return "\n" ~ indent.stripLeft('\n');
}

unittest
{
	auto code = cast(ubyte[]) "void foo() {\n\tfoo();\n}";
	auto indent = getIndentation(code, 20);
	assert(indent == "\n\t", '"' ~ indent ~ '"');

	code = cast(ubyte[]) "void foo() { foo(); }";
	indent = getIndentation(code, 19);
	assert(indent == " ", '"' ~ indent ~ '"');

	code = cast(ubyte[]) "import a;\n\nvoid foo() {\n\tfoo();\n}";
	indent = getIndentation(code, 9);
	assert(indent == "\n", '"' ~ indent ~ '"');
}

class ImporterReaderVisitor : ASTVisitor
{
	this(int pos)
	{
		this.pos = pos;
		inBlock = false;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration decl)
	{
		if (pos != -1 && (decl.endLocation + 1 < outerImportLocation || inBlock))
			return;
		isModule = true;
		outerImportLocation = decl.endLocation + 1;
	}

	override void visit(const ImportDeclaration decl)
	{
		if (pos != -1 && decl.startIndex >= pos)
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
		if (pos == -1 || content && pos >= content.startLocation && pos < content.endLocation)
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
	bool isModule;
	size_t outerImportLocation;
	size_t innermostBlockStart;
}

unittest
{
	import std.conv;

	auto backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!ImporterComponent;
	auto imports = backend.get!ImporterComponent(workspace.directory).get("import std.stdio; void foo() { import fs = std.file; import std.algorithm : map, each2 = each; writeln(\"hi\"); } void bar() { import std.string; import std.regex : ctRegex; }",
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
	auto mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"void foo() { import std.stdio : stderr; import std.stdio; writeln(\"hi\"); }");

	code = "void foo() {\n\timport std.stdio : stderr;\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"void foo() {\n\timport std.stdio : stderr;\n\timport std.stdio;\n\twriteln(\"hi\");\n}");

	code = "void foo() {\n\timport std.file : readText;\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.stdio;\nvoid foo() {\n\timport std.file : readText;\n\twriteln(\"hi\");\n}");

	code = "void foo() { import io = std.stdio; io.writeln(\"hi\"); }";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "io");
	assertEquals(mod.replacements.length, 0);

	code = "import std.file : readText;\n\nvoid foo() {\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.file : readText;\nimport std.stdio;\n\nvoid foo() {\n\twriteln(\"hi\");\n}");

	code = "import std.file;\nimport std.regex;\n\nvoid foo() {\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 54);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.file;\nimport std.regex;\nimport std.stdio;\n\nvoid foo() {\n\twriteln(\"hi\");\n}");

	code = "module a;\n\nvoid foo() {\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 30);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"module a;\n\nimport std.stdio;\n\nvoid foo() {\n\twriteln(\"hi\");\n}");
}
