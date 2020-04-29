module workspaced.dparseext;

import std.algorithm;
import std.array;
import std.string;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;
import dsymbol.builtin.names;
import dsymbol.modulecache : ASTAllocator, ModuleCache;

string makeString(in IdentifierOrTemplateChain c)
{
	return c.identifiersOrTemplateInstances.map!(a => a.identifier.text).join(".");
}

string astToString(T, Args...)(in T ast, Args args)
{
	import dparse.formatter : Formatter;

	if (!ast)
		return null;

	auto app = appender!string();
	auto formatter = new Formatter!(typeof(app))(app);
	formatter.format(ast, args);
	return app.data;
}

string paramsToString(Dec)(const Dec dec)
{
	import dparse.formatter : Formatter;

	auto app = appender!string();
	auto formatter = new Formatter!(typeof(app))(app);

	static if (is(Dec == FunctionDeclaration) || is(Dec == Constructor))
	{
		formatter.format(dec.parameters);
	}
	else static if (is(Dec == TemplateDeclaration))
	{
		formatter.format(dec.templateParameters);
	}

	return app.data;
}

/// Other tokens
private enum dynamicTokens = [
		"specialTokenSequence", "comment", "identifier", "scriptLine", "whitespace",
		"doubleLiteral", "floatLiteral", "idoubleLiteral", "ifloatLiteral",
		"intLiteral", "longLiteral", "realLiteral", "irealLiteral", "uintLiteral",
		"ulongLiteral", "characterLiteral", "dstringLiteral", "stringLiteral",
		"wstringLiteral"
	];

string tokenText(const Token token)
{
	switch (token.type)
	{
		static foreach (T; dynamicTokens)
		{
	case tok!T:
		}
		return token.text;
	default:
		return str(token.type);
	}
}

/// Performs a binary search to find the token containing the search location.
/// Params:
///   tokens = the token array to search in.
///   bytes  = the byte index the token should be in.
/// Returns: the index of the token inside the given tokens array which
/// contains the character specified at the given byte. This will be the first
/// token that is `tok.index == bytes` or before the next token that is too far.
/// If no tokens match, this will return `tokens.length`.
///
/// This is equivalent to the following code:
/// ---
/// foreach (i, tok; tokens)
/// {
/// 	if (tok.index == bytes)
/// 		return i;
/// 	else if (tok.index > bytes)
/// 		return i - 1;
/// }
/// return tokens.length;
/// ---
size_t tokenIndexAtByteIndex(scope const(Token)[] tokens, size_t bytes)
	out(v; v <= tokens.length)
{
	if (!tokens.length || tokens[0].index >= bytes)
		return 0;

	// find where to start using binary search
	size_t l = 0;
	size_t r = tokens.length - 1;
	while (l < r)
	{
		size_t m = (l + r) / 2;
		if (tokens[m].index < bytes)
			l = m + 1;
		else
			r = m - 1;
	}
	size_t start = r;

	// search remaining with linear search
	foreach (i, tok; tokens[start .. $])
	{
		if (tok.index == bytes)
			return start + i;
		else if (tok.index > bytes)
			return start + i - 1;
	}
	return tokens.length;
}

///
unittest
{
	StringCache stringCache = StringCache(StringCache.defaultBucketCount);
	const(Token)[] tokens = getTokensForParser(cast(ubyte[]) `module foo.bar;

// ok
void main(string[] args)
{
}

/// documentation
void foo()
{
}
`, LexerConfig.init, &stringCache);

	auto get(size_t bytes)
	{
		auto i = tokens.tokenIndexAtByteIndex(bytes);
		if (i == tokens.length)
			return tok!"__EOF__";
		return tokens[i].type;
	}

	assert(get(0) == tok!"module");
	assert(get(4) == tok!"module");
	assert(get(6) == tok!"module");
	assert(get(7) == tok!"identifier");
	assert(get(9) == tok!"identifier");
	assert(get(10) == tok!".");
	assert(get(11) == tok!"identifier");
	assert(get(16) == tok!";");
	assert(get(49) == tok!"{");
	assert(get(48) == tok!"{");
	assert(get(47) == tok!")");
	assert(get(1000) == tok!"__EOF__");

	// TODO: process trivia fields in libdparse >=0.15.0 when it releases
	//assert(get(20) == tok!"comment");
	assert(get(20) == tok!";");

	// assert(get(57) == tok!"comment");
}
