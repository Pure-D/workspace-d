module workspaced.com.dscanner;

import std.algorithm;
import std.array;
import std.file;
import std.json;
import std.stdio;
import std.typecons;

import core.sync.mutex;
import core.thread;

import dscanner.analysis.base;
import dscanner.analysis.config;
import dscanner.analysis.run;
import dscanner.symbol_finder;

import inifiled : INI, readINIFile;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;
import dsymbol.builtin.names;
import dsymbol.modulecache : ASTAllocator, ModuleCache;

import painlessjson;

import workspaced.api;
import workspaced.dparseext;

@component("dscanner")
class DscannerComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Asynchronously lints the file passed.
	/// If you provide code then the code will be used and file will be ignored.
	Future!(DScannerIssue[]) lint(string file = "", string ini = "dscanner.ini", string code = "")
	{
		auto ret = new Future!(DScannerIssue[]);
		threads.create({
			try
			{
				if (code.length && !file.length)
					file = "stdin";
				auto config = defaultStaticAnalysisConfig();
				if (getConfigPath("dscanner.ini", ini))
					stderr.writeln("Overriding Dscanner ini with workspace-d dscanner.ini config file");
				if (ini.exists)
					readINIFile(config, ini);
				if (!code.length)
					code = readText(file);
				DScannerIssue[] issues;
				if (!code.length)
				{
					ret.finish(issues);
					return;
				}
				RollbackAllocator r;
				const(Token)[] tokens;
				StringCache cache = StringCache(StringCache.defaultBucketCount);
				const Module m = parseModule(file, cast(ubyte[]) code, &r, cache, tokens, issues);
				if (!m)
					throw new Exception(
						"parseModule returned null?! - file: '" ~ file ~ "', code: '" ~ code ~ "'");
				MessageSet results;
				auto alloc = scoped!ASTAllocator();
				auto moduleCache = ModuleCache(alloc);
				results = analyze(file, m, config, moduleCache, tokens, true);
				if (results is null)
				{
					ret.finish(issues);
					return;
				}
				foreach (msg; results)
				{
					DScannerIssue issue;
					issue.file = msg.fileName;
					issue.line = cast(int) msg.line;
					issue.column = cast(int) msg.column;
					issue.type = typeForWarning(msg.key);
					issue.description = msg.message;
					issue.key = msg.key;
					issues ~= issue;
				}
				ret.finish(issues);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	private const(Module) parseModule(string file, ubyte[] code, RollbackAllocator* p,
			ref StringCache cache, ref const(Token)[] tokens, ref DScannerIssue[] issues)
	{
		LexerConfig config;
		config.fileName = file;
		config.stringBehavior = StringBehavior.source;
		tokens = getTokensForParser(code, config, &cache);

		void addIssue(string fileName, size_t line, size_t column, string message, bool isError)
		{
			issues ~= DScannerIssue(file, cast(int) line, cast(int) column, isError
					? "error" : "warn", message);
		}

		uint err, warn;
		return dparse.parser.parseModule(tokens, file, p, &addIssue, &err, &warn);
	}

	/// Asynchronously lists all definitions in the specified file.
	/// If you provide code the file wont be manually read.
	Future!(DefinitionElement[]) listDefinitions(string file, string code = "")
	{
		auto ret = new Future!(DefinitionElement[]);
		threads.create({
			try
			{
				if (code.length && !file.length)
					file = "stdin";
				if (!code.length)
					code = readText(file);
				if (!code.length)
				{
					DefinitionElement[] arr;
					ret.finish(arr);
					return;
				}

				RollbackAllocator r;
				LexerConfig config;
				auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);

				auto m = dparse.parser.parseModule(tokens.array, file, &r);

				auto defFinder = new DefinitionFinder();
				defFinder.visit(m);

				ret.finish(defFinder.definitions);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	/// Asynchronously finds all definitions of a symbol in the import paths.
	Future!(FileLocation[]) findSymbol(string symbol)
	{
		auto ret = new Future!(FileLocation[]);
		threads.create({
			try
			{
				import dscanner.utils : expandArgs;

				string[] paths = expandArgs([""] ~ importPaths);
				foreach_reverse (i, path; paths)
					if (path == "stdin")
						paths = paths.remove(i);
				FileLocation[] files;
				findDeclarationOf((fileName, line, column) {
					FileLocation file;
					file.file = fileName;
					file.line = cast(int) line;
					file.column = cast(int) column;
					files ~= file;
				}, symbol, paths);
				ret.finish(files);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	/// Returns: all keys & documentation that can be used in a dscanner.ini
	INIEntry[] listAllIniFields()
	{
		import std.traits : getUDAs;

		INIEntry[] ret;
		foreach (mem; __traits(allMembers, StaticAnalysisConfig))
			static if (is(typeof(__traits(getMember, StaticAnalysisConfig, mem)) == string))
			{
				alias docs = getUDAs!(__traits(getMember, StaticAnalysisConfig, mem), INI);
				ret ~= INIEntry(mem, docs.length ? docs[0].msg : "");
			}
		return ret;
	}
}

/// dscanner.ini setting type
struct INIEntry
{
	///
	string name, documentation;
}

/// Issue type returned by lint
struct DScannerIssue
{
	///
	string file;
	///
	int line, column;
	///
	string type;
	///
	string description;
	///
	string key;
}

/// Returned by find-symbol
struct FileLocation
{
	///
	string file;
	///
	int line, column;
}

/// Returned by list-definitions
struct DefinitionElement
{
	///
	string name;
	///
	int line;
	/// One of "c" (class), "s" (struct), "i" (interface), "T" (template), "f" (function/ctor/dtor), "g" (enum {}), "u" (union), "e" (enum member/definition), "v" (variable/invariant)
	string type;
	///
	string[string] attributes;
	///
	int[2] range;
}

private:

string typeForWarning(string key)
{
	switch (key)
	{
	case "dscanner.bugs.backwards_slices":
	case "dscanner.bugs.if_else_same":
	case "dscanner.bugs.logic_operator_operands":
	case "dscanner.bugs.self_assignment":
	case "dscanner.confusing.argument_parameter_mismatch":
	case "dscanner.confusing.brexp":
	case "dscanner.confusing.builtin_property_names":
	case "dscanner.confusing.constructor_args":
	case "dscanner.confusing.function_attributes":
	case "dscanner.confusing.lambda_returns_lambda":
	case "dscanner.confusing.logical_precedence":
	case "dscanner.confusing.struct_constructor_default_args":
	case "dscanner.deprecated.delete_keyword":
	case "dscanner.deprecated.floating_point_operators":
	case "dscanner.if_statement":
	case "dscanner.performance.enum_array_literal":
	case "dscanner.style.allman":
	case "dscanner.style.alias_syntax":
	case "dscanner.style.doc_missing_params":
	case "dscanner.style.doc_missing_returns":
	case "dscanner.style.doc_non_existing_params":
	case "dscanner.style.explicitly_annotated_unittest":
	case "dscanner.style.has_public_example":
	case "dscanner.style.imports_sortedness":
	case "dscanner.style.long_line":
	case "dscanner.style.number_literals":
	case "dscanner.style.phobos_naming_convention":
	case "dscanner.style.undocumented_declaration":
	case "dscanner.suspicious.auto_ref_assignment":
	case "dscanner.suspicious.catch_em_all":
	case "dscanner.suspicious.comma_expression":
	case "dscanner.suspicious.incomplete_operator_overloading":
	case "dscanner.suspicious.incorrect_infinite_range":
	case "dscanner.suspicious.label_var_same_name":
	case "dscanner.suspicious.length_subtraction":
	case "dscanner.suspicious.local_imports":
	case "dscanner.suspicious.missing_return":
	case "dscanner.suspicious.object_const":
	case "dscanner.suspicious.redundant_attributes":
	case "dscanner.suspicious.redundant_parens":
	case "dscanner.suspicious.static_if_else":
	case "dscanner.suspicious.unmodified":
	case "dscanner.suspicious.unused_label":
	case "dscanner.suspicious.unused_parameter":
	case "dscanner.suspicious.unused_variable":
	case "dscanner.suspicious.useless_assert":
	case "dscanner.unnecessary.duplicate_attribute":
	case "dscanner.useless.final":
	case "dscanner.useless-initializer":
	case "dscanner.vcall_ctor":
		return "warn";
	case "dscanner.syntax":
		return "error";
	default:
		stderr.writeln("Warning: unimplemented DScanner reason, assuming warning: ", key);
		return "warn";
	}
}

final class DefinitionFinder : ASTVisitor
{
	override void visit(const ClassDeclaration dec)
	{
		if (!dec.structBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "c", context,
				[cast(int) dec.structBody.startLocation, cast(int) dec.structBody.endLocation]);
		auto c = context;
		context = ContextType(["class" : dec.name.text], "public");
		dec.accept(this);
		context = c;
	}

	override void visit(const StructDeclaration dec)
	{
		if (!dec.structBody)
			return;
		if (dec.name == tok!"")
		{
			dec.accept(this);
			return;
		}
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "s", context,
				[cast(int) dec.structBody.startLocation, cast(int) dec.structBody.endLocation]);
		auto c = context;
		context = ContextType(["struct" : dec.name.text], "public");
		dec.accept(this);
		context = c;
	}

	override void visit(const InterfaceDeclaration dec)
	{
		if (!dec.structBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "i", context,
				[cast(int) dec.structBody.startLocation, cast(int) dec.structBody.endLocation]);
		auto c = context;
		context = ContextType(["interface:" : dec.name.text], context.access);
		dec.accept(this);
		context = c;
	}

	override void visit(const TemplateDeclaration dec)
	{
		auto def = makeDefinition(dec.name.text, dec.name.line, "T", context,
				[cast(int) dec.startLocation, cast(int) dec.endLocation]);
		def.attributes["signature"] = paramsToString(dec);
		definitions ~= def;
		auto c = context;
		context = ContextType(["template" : dec.name.text], context.access);
		dec.accept(this);
		context = c;
	}

	override void visit(const FunctionDeclaration dec)
	{
		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody || !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		auto def = makeDefinition(dec.name.text, dec.name.line, "f", context,
				[cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
				cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation]);
		def.attributes["signature"] = paramsToString(dec);
		if (dec.returnType !is null)
			def.attributes["return"] = astToString(dec.returnType);
		definitions ~= def;
	}

	override void visit(const Constructor dec)
	{
		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody || !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		auto def = makeDefinition("this", dec.line, "f", context,
				[cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
				cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation]);
		def.attributes["signature"] = paramsToString(dec);
		definitions ~= def;
	}

	override void visit(const Destructor dec)
	{
		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody || !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		definitions ~= makeDefinition("~this", dec.line, "f", context,
				[cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
				cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation]);
	}

	override void visit(const EnumDeclaration dec)
	{
		if (!dec.enumBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "g", context,
				[cast(int) dec.enumBody.startLocation, cast(int) dec.enumBody.endLocation]);
		auto c = context;
		context = ContextType(["enum" : dec.name.text], context.access);
		dec.accept(this);
		context = c;
	}

	override void visit(const UnionDeclaration dec)
	{
		if (!dec.structBody)
			return;
		if (dec.name == tok!"")
		{
			dec.accept(this);
			return;
		}
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "u", context,
				[cast(int) dec.structBody.startLocation, cast(int) dec.structBody.endLocation]);
		auto c = context;
		context = ContextType(["union" : dec.name.text], context.access);
		dec.accept(this);
		context = c;
	}

	override void visit(const AnonymousEnumMember mem)
	{
		definitions ~= makeDefinition(mem.name.text, mem.name.line, "e", context,
				[cast(int) mem.name.index, cast(int) mem.name.index + cast(int) mem.name.text.length]);
	}

	override void visit(const EnumMember mem)
	{
		definitions ~= makeDefinition(mem.name.text, mem.name.line, "e", context,
				[cast(int) mem.name.index, cast(int) mem.name.index + cast(int) mem.name.text.length]);
	}

	override void visit(const VariableDeclaration dec)
	{
		foreach (d; dec.declarators)
			definitions ~= makeDefinition(d.name.text, d.name.line, "v", context,
					[cast(int) d.name.index, cast(int) d.name.index + cast(int) d.name.text.length]);
		dec.accept(this);
	}

	override void visit(const AutoDeclaration dec)
	{
		foreach (i; dec.parts.map!(a => a.identifier))
			definitions ~= makeDefinition(i.text, i.line, "v", context,
					[cast(int) i.index, cast(int) i.index + cast(int) i.text.length]);
		dec.accept(this);
	}

	override void visit(const Invariant dec)
	{
		if (!dec.blockStatement)
			return;
		definitions ~= makeDefinition("invariant", dec.line, "v", context,
				[cast(int) dec.index, cast(int) dec.blockStatement.endLocation]);
	}

	override void visit(const ModuleDeclaration dec)
	{
		context = ContextType(null, "public");
		dec.accept(this);
	}

	override void visit(const Attribute attribute)
	{
		if (attribute.attribute != tok!"")
		{
			switch (attribute.attribute.type)
			{
			case tok!"export":
				context.access = "public";
				break;
			case tok!"public":
				context.access = "public";
				break;
			case tok!"package":
				context.access = "protected";
				break;
			case tok!"protected":
				context.access = "protected";
				break;
			case tok!"private":
				context.access = "private";
				break;
			default:
			}
		}
		else if (attribute.deprecated_ !is null)
		{
			// TODO: find out how to get deprecation message
			context.attr["deprecation"] = "";
		}

		attribute.accept(this);
	}

	override void visit(const AttributeDeclaration dec)
	{
		accessSt = AccessState.Keep;
		dec.accept(this);
	}

	override void visit(const Declaration dec)
	{
		auto c = context;
		dec.accept(this);

		final switch (accessSt) with (AccessState)
		{
		case Reset:
			context = c;
			break;
		case Keep:
			break;
		}
		accessSt = AccessState.Reset;
	}

	override void visit(const Unittest dec)
	{
		// skipping symbols inside a unit test to not clutter the ctags file
		// with "temporary" symbols.
		// TODO when phobos have a unittest library investigate how that could
		// be used to describe the tests.
		// Maybe with UDA's to give the unittest a "name".
	}

	override void visit(const AliasDeclaration dec)
	{
		// Old style alias
		if (dec.declaratorIdentifierList)
			foreach (i; dec.declaratorIdentifierList.identifiers)
				definitions ~= makeDefinition(i.text, i.line, "a", context,
						[cast(int) i.index, cast(int) i.index + cast(int) i.text.length]);
		dec.accept(this);
	}

	override void visit(const AliasInitializer dec)
	{
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "a", context,
				[cast(int) dec.name.index, cast(int) dec.name.index + cast(int) dec.name.text.length]);

		dec.accept(this);
	}

	override void visit(const AliasThisDeclaration dec)
	{
		auto name = dec.identifier;
		definitions ~= makeDefinition(name.text, name.line, "a", context,
				[cast(int) name.index, cast(int) name.index + cast(int) name.text.length]);

		dec.accept(this);
	}

	alias visit = ASTVisitor.visit;

	ContextType context;
	AccessState accessSt;
	DefinitionElement[] definitions;
}

DefinitionElement makeDefinition(string name, size_t line, string type,
		ContextType context, int[2] range)
{
	string[string] attr = context.attr;
	if (context.access.length)
		attr["access"] = context.access;
	return DefinitionElement(name, cast(int) line, type, attr, range);
}

enum AccessState
{
	Reset, /// when ascending the AST reset back to the previous access.
	Keep /// when ascending the AST keep the new access.
}

struct ContextType
{
	string[string] attr;
	string access;
}
