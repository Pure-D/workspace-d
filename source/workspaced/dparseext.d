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
