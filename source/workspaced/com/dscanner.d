module workspaced.com.dscanner;

version (unittest)
debug = ResolveRange;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.file;
import std.json;
import std.stdio;
import std.typecons;
import std.meta : AliasSeq;

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
import workspaced.helpers;

static immutable LocalImportCheckKEY = "dscanner.suspicious.local_imports";
static immutable LongLineCheckKEY = "dscanner.style.long_line";

@component("dscanner")
class DscannerComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Asynchronously lints the file passed.
	/// If you provide code then the code will be used and file will be ignored.
	/// See_Also: $(LREF getConfig)
	Future!(DScannerIssue[]) lint(string file = "", string ini = "dscanner.ini",
			scope const(char)[] code = "", bool skipWorkspacedPaths = false,
			const StaticAnalysisConfig defaultConfig = StaticAnalysisConfig.init,
			bool resolveRanges = false)
	{
		auto ret = new Future!(DScannerIssue[]);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (code.length && !file.length)
					file = "stdin";
				auto config = getConfig(ini, skipWorkspacedPaths, defaultConfig);
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
					throw new Exception(text("parseModule returned null?! - file: '",
						file, "', code: '", code, "'"));

				// resolve syntax errors (immediately set by parseModule)
				if (resolveRanges)
				{
					foreach_reverse (i, ref issue; issues)
					{
						if (!resolveRange(tokens, issue))
							issues = issues.remove(i);
					}
				}

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
					if (resolveRanges)
					{
						if (!this.resolveRange(tokens, issue))
							continue;
					}
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

	/// Takes line & column from the D-Scanner issue array and resolves the
	/// start & end locations for the issues by changing the values in-place.
	/// In the JSON RPC this returns the modified array, in workspace-d as a
	/// library this changes the parameter values in place.
	void resolveRanges(scope const(char)[] code, scope ref DScannerIssue[] issues)
	{
		LexerConfig config;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		if (!tokens.length)
			return;

		foreach_reverse (i, ref issue; issues)
		{
			if (!resolveRange(tokens, issue))
				issues = issues.remove(i);
		}
	}

	/// Adjusts a D-Scanner line:column location to a start & end range, potentially
	/// improving the error message through tokens nearby.
	/// Returns: `false` if this issue should be discarded (handled by other issues)
	private bool resolveRange(scope const(Token)[] tokens, ref DScannerIssue issue)
	out
	{
		debug (ResolveRange) if (issue.range != typeof(issue.range).init)
		{
			assert(issue.range[0].line > 0);
			assert(issue.range[0].column > 0);
			assert(issue.range[1].line > 0);
			assert(issue.range[1].column > 0);
		}
	}
	do
	{
		auto tokenIndex = tokens.tokenIndexAtPosition(issue.line, issue.column);
		if (tokenIndex >= tokens.length)
		{
			if (tokens.length)
				issue.range = makeTokenRange(tokens[$ - 1]);
			else
				issue.range = typeof(issue.range).init;
			return true;
		}

		switch (issue.key)
		{
		case null:
			// syntax errors
			if (!adjustRangeForSyntaxError(tokens, tokenIndex, issue))
				return false;
			improveErrorMessage(issue);
			return true;
		case LocalImportCheckKEY:
			if (adjustRangeForLocalImportsError(tokens, tokenIndex, issue))
				return true;
			goto default;
		case LongLineCheckKEY:
			issue.range = makeTokenRange(tokens[tokenIndex], tokens[min($ - 1, tokens.tokenIndexAtPosition(issue.line, 1000))]);
			return true;
		default:
			issue.range = makeTokenRange(tokens[tokenIndex]);
			return true;
		}
	}

	private void improveErrorMessage(ref DScannerIssue issue)
	{
		// identifier is not literally expected
		issue.description = issue.description.replace("`identifier`", "identifier");

		static immutable expectedIdentifierStart = "Expected identifier instead of `";
		static immutable keywordReplacement = "Expected identifier instead of reserved keyword `";
		if (issue.description.startsWith(expectedIdentifierStart))
		{
			if (issue.description.length > expectedIdentifierStart.length + 1
				&& issue.description[expectedIdentifierStart.length].isIdentifierChar)
			{
				// expected identifier instead of keyword (probably) here because
				// first character of "instead of `..." is an identifier character.
				issue.description = keywordReplacement ~ issue.description[expectedIdentifierStart.length .. $];
			}
		}
	}

	private bool adjustRangeForSyntaxError(scope const(Token)[] tokens, size_t currentToken, ref DScannerIssue issue)
	{
		auto s = issue.description;

		if (s.startsWith("Expected `"))
		{
			s = s["Expected ".length .. $];
			if (s.startsWith("`;`"))
			{
				// span after last word
				size_t issueStartExclusive = currentToken;
				foreach_reverse (i, token; tokens[0 .. currentToken])
				{
					if (token.type == tok!";")
					{
						// this ain't right, expected semicolon issue but
						// semicolon is the first thing before this token
						// happens when syntax before is broken, let's discard!
						// for example in `foo.foreach(a;b)`
						return false;
					}
					issueStartExclusive = i;
					if (token.isLikeIdentifier)
						break;
				}

				size_t issueEnd = issueStartExclusive;
				auto line = tokens[issueEnd].line;

				// span until newline or next word character
				foreach (i, token; tokens[issueStartExclusive + 1 .. $])
				{
					if (token.line != line || token.isLikeIdentifier)
						break;
					issueEnd = issueStartExclusive + 1 + i;
				}

				issue.range = [makeTokenEnd(tokens[issueStartExclusive]), makeTokenEnd(tokens[issueEnd])];
				return true;
			}
			else if (s.startsWith("`identifier` instead of `"))
			{
				auto wanted = s["`identifier` instead of `".length .. $];
				if (wanted.length && wanted[0].isIdentifierChar)
				{
					// wants identifier instead of some keyword (probably)
					// happens e.g. after a . and then nothing written and next line contains a keyword
					// want to remove the "instead of" in case it's not in the same line
					if (currentToken > 0 && tokens[currentToken - 1].line != tokens[currentToken].line)
					{
						issue.description = "Expected identifier";
						issue.range = [makeTokenEnd(tokens[currentToken - 1]), makeTokenStart(tokens[currentToken])];
						return true;
					}
				}
			}

			// span from start of last word
			size_t issueStart = min(max(0, cast(ptrdiff_t)tokens.length - 1), currentToken + 1);
			// if a non-identifier was expected, include word before
			if (issueStart > 0 && s.length > 2 && s[1].isIdentifierSeparatingChar)
				issueStart--;
			foreach_reverse (i, token; tokens[0 .. issueStart])
			{
				issueStart = i;
				if (token.isLikeIdentifier)
					break;
			}

			// span to end of next word
			size_t searchStart = issueStart;
			if (tokens[searchStart].column + tokens[searchStart].tokenText.length <= issue.column)
				searchStart++;
			size_t issueEnd = min(max(0, cast(ptrdiff_t)tokens.length - 1), searchStart);
			foreach (i, token; tokens[searchStart .. $])
			{
				if (token.isLikeIdentifier)
					break;
				issueEnd = searchStart + i;
			}

			issue.range = makeTokenRange(tokens[issueStart], tokens[issueEnd]);
		}
		else
		{
			if (tokens[currentToken].type == tok!"auto")
			{
				// syntax error on the word "auto"
				// check for foreach (auto key; value)

				if (currentToken >= 2
					&& tokens[currentToken - 1].type == tok!"("
					&& (tokens[currentToken - 2].type == tok!"foreach" || tokens[currentToken - 2].type == tok!"foreach_reverse"))
				{
					// this is foreach (auto
					issue.key = "workspaced.foreach-auto";
					issue.description = "foreach (auto key; value) is not valid D "
						~ "syntax. Use foreach (key; value) instead.";
					// range is used in code_actions to remove auto
					issue.range = makeTokenRange(tokens[currentToken]);
					return true;
				}
			}

			issue.range = makeTokenRange(tokens[currentToken]);
		}
		return true;
	}

	// adjusts error location of
	// import |std.stdio;
	// to
	// ~import std.stdio;~
	private bool adjustRangeForLocalImportsError(scope const(Token)[] tokens, size_t currentToken, ref DScannerIssue issue)
	{
		size_t startIndex = currentToken;
		size_t endIndex = currentToken;

		while (startIndex > 0 && tokens[startIndex].type != tok!"import")
			startIndex--;
		while (endIndex < tokens.length && tokens[endIndex].type != tok!";")
			endIndex++;

		issue.range = makeTokenRange(tokens[startIndex], tokens[endIndex]);
		return true;
	}

	/// Gets the used D-Scanner config, optionally reading from a given
	/// dscanner.ini file.
	/// Params:
	///   ini = an ini to load. Only reading from it if it exists. If this is
	///         relative, this function will try both in getcwd and in the
	///         instance.cwd, if an instance is set.
	///   skipWorkspacedPaths = if true, don't attempt to override the given ini
	///         with workspace-d user configs.
	///   defaultConfig = default D-Scanner configuration to use if no user
	///         config exists (workspace-d specific or ini argument)
	StaticAnalysisConfig getConfig(string ini = "dscanner.ini",
		bool skipWorkspacedPaths = false,
		const StaticAnalysisConfig defaultConfig = StaticAnalysisConfig.init)
	{
		import std.path : buildPath;

		StaticAnalysisConfig config = defaultConfig is StaticAnalysisConfig.init
			? defaultStaticAnalysisConfig()
			: cast()defaultConfig;
		if (!skipWorkspacedPaths && getConfigPath("dscanner.ini", ini))
		{
			static bool didWarn = false;
			if (!didWarn)
			{
				warning("Overriding Dscanner ini with workspace-d dscanner.ini config file");
				didWarn = true;
			}
		}
		string cwd = getcwd;
		if (refInstance !is null)
			cwd = refInstance.cwd;

		if (ini.exists)
		{
			readINIFile(config, ini);
		}
		else
		{
			auto p = buildPath(cwd, ini);
			if (p != ini && p.exists)
				readINIFile(config, p);
		}
		return config;
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
	///
	/// If you provide code the file wont be manually read.
	///
	/// Set verbose to true if you want to receive more temporary symbols and
	/// things that could be considered clutter as well.
	Future!(DefinitionElement[]) listDefinitions(string file,
		scope const(char)[] code = "", bool verbose = false)
	{
		auto ret = new Future!(DefinitionElement[]);
		gthreads.create({
			mixin(traceTask);
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
				defFinder.verbose = verbose;
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
		gthreads.create({
			mixin(traceTask);
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
	/// one-based line & column (in bytes) of this diagnostic location
	int line, column;
	///
	string type;
	///
	string description;
	///
	string key;
	/// Resolved range for content that can be filled with a call to resolveRanges
	ResolvedLocation[2] range;

	/// Converts this object to a JSONValue
	JSONValue _toJSON() const
	{
		JSONValue[] rangeObj = [
			range[0].toJSON,
			range[1].toJSON
		];
		//dfmt off
		return JSONValue([
			"file": JSONValue(file),
			"line": JSONValue(line),
			"column": JSONValue(column),
			"type": JSONValue(type),
			"description": JSONValue(description),
			"key": JSONValue(key),
			"range": JSONValue(rangeObj),
		]);
		//dfmt on
	}
}

/// Describes a code location in exact byte offset, line number and column for a
/// given source code this was resolved against.
struct ResolvedLocation
{
	/// byte offset of the character in question - may be 0 if line and column are set
	ulong index;
	/// one-based line
	uint line;
	/// one-based character offset inside the line in bytes
	uint column;
}

ResolvedLocation[2] makeTokenRange(const Token token)
{
	return makeTokenRange(token, token);
}

ResolvedLocation[2] makeTokenRange(const Token start, const Token end)
{
	return [makeTokenStart(start), makeTokenEnd(end)];
}

ResolvedLocation makeTokenStart(const Token token)
{
	ResolvedLocation ret;
	ret.index = cast(uint) token.index;
	ret.line = cast(uint) token.line;
	ret.column = cast(uint) token.column;
	return ret;
}

ResolvedLocation makeTokenEnd(const Token token)
{
	import std.string : lineSplitter;

	ResolvedLocation ret;
	auto text = tokenText(token);
	ret.index = token.index + text.length;
	int numLines;
	size_t lastLength;
	foreach (line; lineSplitter(text))
	{
		numLines++;
		lastLength = line.length;
	}
	if (numLines > 1)
	{
		ret.line = cast(uint)(token.line + numLines - 1);
		ret.column = cast(uint)(lastLength + 1);
	}
	else
	{
		ret.line = cast(uint)(token.line);
		ret.column = cast(uint)(token.column + text.length);
	}
	return ret;
}

/// Returned by find-symbol
struct FileLocation
{
	///
	string file;
	/// 1-based line number and column byte offset
	int line, column;
}

/// Returned by list-definitions
struct DefinitionElement
{
	///
	string name;
	/// 1-based line number
	int line;
	/// One of
	/// * `c` = class
	/// * `s` = struct
	/// * `i` = interface
	/// * `T` = template
	/// * `f` = function/ctor/dtor
	/// * `g` = enum {}
	/// * `u` = union
	/// * `e` = enum member/definition
	/// * `v` = variable/invariant
	/// * `a` = alias
	/// * `U` = unittest (only in verbose mode)
	/// * `D` = debug specification (only in verbose mode)
	/// * `V` = version specification (only in verbose mode)
	/// * `C` = static module ctor (only in verbose mode)
	/// * `S` = shared static module ctor (only in verbose mode)
	/// * `Q` = static module dtor (only in verbose mode)
	/// * `W` = shared static module dtor (only in verbose mode)
	/// * `P` = postblit/copy ctor (only in verbose mode)
	string type;
	///
	string[string] attributes;
	///
	int[2] range;

	bool isVerboseType() const
	{
		import std.ascii : isUpper;

		return type.length == 1 && type[0] != 'T' && isUpper(type[0]);
	}
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
				[
					cast(int) dec.structBody.startLocation,
					cast(int) dec.structBody.endLocation
				]);
		auto c = context;
		context = ContextType(["class": dec.name.text], null, "public");
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
				[
					cast(int) dec.structBody.startLocation,
					cast(int) dec.structBody.endLocation
				]);
		auto c = context;
		context = ContextType(["struct": dec.name.text], null, "public");
		dec.accept(this);
		context = c;
	}

	override void visit(const InterfaceDeclaration dec)
	{
		if (!dec.structBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "i", context,
				[
					cast(int) dec.structBody.startLocation,
					cast(int) dec.structBody.endLocation
				]);
		auto c = context;
		context = ContextType(["interface:": dec.name.text], null, context.access);
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
		context = ContextType(["template": dec.name.text], null, context.access);
		dec.accept(this);
		context = c;
	}

	override void visit(const FunctionDeclaration dec)
	{
		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody
				|| !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		auto def = makeDefinition(dec.name.text, dec.name.line, "f", context,
				[
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation
				]);
		def.attributes["signature"] = paramsToString(dec);
		if (dec.returnType !is null)
			def.attributes["return"] = astToString(dec.returnType);
		definitions ~= def;
	}

	override void visit(const Constructor dec)
	{
		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody
				|| !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		auto def = makeDefinition("this", dec.line, "f", context,
				[
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation
				]);
		def.attributes["signature"] = paramsToString(dec);
		definitions ~= def;
	}

	override void visit(const Destructor dec)
	{
		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody
				|| !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		definitions ~= makeDefinition("~this", dec.line, "f", context,
				[
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation
				]);
	}

	override void visit(const Postblit dec)
	{
		if (!verbose)
			return;

		if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody
				|| !dec.functionBody.specifiedFunctionBody.blockStatement)
			return;
		definitions ~= makeDefinition("this(this)", dec.line, "f", context,
				[
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation
				]);
	}

	override void visit(const EnumDeclaration dec)
	{
		if (!dec.enumBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, "g", context,
				[cast(int) dec.enumBody.startLocation, cast(int) dec.enumBody.endLocation]);
		auto c = context;
		context = ContextType(["enum": dec.name.text], null, context.access);
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
				[
					cast(int) dec.structBody.startLocation,
					cast(int) dec.structBody.endLocation
				]);
		auto c = context;
		context = ContextType(["union": dec.name.text], null, context.access);
		dec.accept(this);
		context = c;
	}

	override void visit(const AnonymousEnumMember mem)
	{
		definitions ~= makeDefinition(mem.name.text, mem.name.line, "e", context,
				[
					cast(int) mem.name.index,
					cast(int) mem.name.index + cast(int) mem.name.text.length
				]);
	}

	override void visit(const EnumMember mem)
	{
		definitions ~= makeDefinition(mem.name.text, mem.name.line, "e", context,
				[
					cast(int) mem.name.index,
					cast(int) mem.name.index + cast(int) mem.name.text.length
				]);
	}

	override void visit(const VariableDeclaration dec)
	{
		foreach (d; dec.declarators)
			definitions ~= makeDefinition(d.name.text, d.name.line, "v", context,
					[
						cast(int) d.name.index,
						cast(int) d.name.index + cast(int) d.name.text.length
					]);
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
		context = ContextType(null, null, "public");
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
			string reason;
			if (attribute.deprecated_.assignExpression)
				reason = evaluateExpressionString(attribute.deprecated_.assignExpression);
			context.attr["deprecation"] = reason.length ? reason : "";
		}

		attribute.accept(this);
	}

	override void visit(const AtAttribute atAttribute)
	{
		if (atAttribute.argumentList)
		{
			foreach (item; atAttribute.argumentList.items)
			{
				auto str = evaluateExpressionString(item);

				if (str !is null)
					context.privateAttr["utName"] = str;
			}
		}
		atAttribute.accept(this);
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

	override void visit(const DebugSpecification dec)
	{
		if (!verbose)
			return;

		auto tok = dec.identifierOrInteger;
		auto def = makeDefinition(tok.tokenText, tok.line, "D", context,
				[
					cast(int) tok.index,
					cast(int) tok.index + cast(int) tok.text.length
				]);

		definitions ~= def;
		dec.accept(this);
	}

	override void visit(const VersionSpecification dec)
	{
		if (!verbose)
			return;

		auto tok = dec.token;
		auto def = makeDefinition(tok.tokenText, tok.line, "V", context,
				[
					cast(int) tok.index,
					cast(int) tok.index + cast(int) tok.text.length
				]);

		definitions ~= def;
		dec.accept(this);
	}

	override void visit(const Unittest dec)
	{
		if (!verbose)
			return;

		if (!dec.blockStatement)
			return;
		string testName = text("__unittest_L", dec.line, "_C", dec.column);
		definitions ~= makeDefinition(testName, dec.line, "U", context,
				[
					cast(int) dec.tokens[0].index,
					cast(int) dec.blockStatement.endLocation
				], "U");

		// TODO: decide if we want to include types nested in unittests
		// dec.accept(this);
	}

	private static immutable CtorTypes = ["C", "S", "Q", "W"];
	private static immutable CtorNames = [
		"static this()", "shared static this()",
		"static ~this()", "shared static ~this()"
	];
	static foreach (i, T; AliasSeq!(StaticConstructor, SharedStaticConstructor,
			StaticDestructor, SharedStaticDestructor))
	{
		override void visit(const T dec)
		{
			if (!verbose)
				return;

			if (!dec.functionBody || !dec.functionBody.specifiedFunctionBody
					|| !dec.functionBody.specifiedFunctionBody.blockStatement)
				return;
			definitions ~= makeDefinition(CtorNames[i], dec.line, CtorTypes[i], context,
				[
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.startLocation,
					cast(int) dec.functionBody.specifiedFunctionBody.blockStatement.endLocation
				]);
			dec.accept(this);
		}
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
				[
					cast(int) dec.name.index,
					cast(int) dec.name.index + cast(int) dec.name.text.length
				]);

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
	bool verbose;
}

DefinitionElement makeDefinition(string name, size_t line, string type,
		ContextType context, int[2] range, string forType = null)
{
	string[string] attr = context.attr.dup;
	if (context.access.length)
		attr["access"] = context.access;

	if (forType == "U")
	{
		if (auto utName = "utName" in context.privateAttr)
			attr["name"] = *utName;
	}
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
	string[string] privateAttr;
	string access;
}

unittest
{
	StaticAnalysisConfig check = StaticAnalysisConfig.init;
	assert(check is StaticAnalysisConfig.init);
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DscannerComponent;
	DscannerComponent dscanner = instance.get!DscannerComponent;

	string code = `module foo.bar;

version = Foo;
debug = Bar;

void hello() {
	int x = 1;
}

int y = 2;

int
bar()
{
}

unittest
{
}

@( "named" )
unittest
{
}

class X
{
	this(int x) {}
	this(this) {}
	~this() {}

	unittest
	{
	}
}

shared static this()
{
}

`;

	auto defs = dscanner.listDefinitions("stdin", code, false).getBlocking();

	assert(defs == [
			DefinitionElement("hello", 6, "f", [
					"signature": "()",
					"access": "public",
					"return": "void"
				], [59, 73]),
			DefinitionElement("y", 10, "v", ["access": "public"], [80, 81]),
			DefinitionElement("bar", 13, "f", [
					"signature": "()",
					"access": "public",
					"return": "int"
				], [98, 100]),
			DefinitionElement("X", 26, "c", ["access": "public"], [152,
					214]),
			DefinitionElement("this", 28, "f", [
					"signature": "(int x)",
					"access": "public",
					"class": "X"
				], [167, 168]),
			DefinitionElement("~this", 30, "f", [
					"access": "public",
					"class": "X"
				], [194, 195])
			]);

	// verbose definitions
	defs = dscanner.listDefinitions("stdin", code, true).getBlocking();

	assert(defs == [
			DefinitionElement("Foo", 3, "V", ["access": "public"], [27, 30]),
			DefinitionElement("Bar", 4, "D", ["access": "public"], [40, 43]),
			DefinitionElement("hello", 6, "f", [
					"signature": "()",
					"access": "public",
					"return": "void"
				], [59, 73]),
			DefinitionElement("y", 10, "v", ["access": "public"], [80, 81]),
			DefinitionElement("bar", 13, "f", [
					"signature": "()",
					"access": "public",
					"return": "int"
				], [98, 100]),
			DefinitionElement("__unittest_L17_C1", 17, "U",
				["access": "public"], [103,
					114]),
			DefinitionElement("__unittest_L22_C1", 22, "U",
				["access": "public", "name": "named"],
				[130, 141]),
			DefinitionElement("X", 26, "c", ["access": "public"], [152,
					214]),
			DefinitionElement("this", 28, "f", [
					"signature": "(int x)",
					"access": "public",
					"class": "X"
				], [167, 168]),
			DefinitionElement("this(this)", 29, "f", [
					"access": "public",
					"class": "X"
				], [182, 183]),
			DefinitionElement("~this", 30, "f", [
					"access": "public",
					"class": "X"
				], [194, 195]),
			DefinitionElement("__unittest_L32_C2", 32, "U", [
					"access": "public",
					"class": "X"
				], [199, 212]),
			DefinitionElement("shared static this()", 37, "S", [
					"access": "public"
				], [238, 240])
			]);

}
