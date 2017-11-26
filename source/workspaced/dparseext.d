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

string typeToString(in Type type)
{
	if (type.type2 !is null)
	{
		// TODO: templates, fixed arrays, etc
		string suffix;
		foreach (s; type.typeSuffixes)
		{
			if (s.array)
				suffix ~= "[]";
			if (s.star != tok!"")
				suffix ~= "*";
		}
		if (type.type2.builtinType != tok!"")
			return getBuiltinTypeName(type.type2.builtinType) ~ suffix;
		if (type.type2.identifierOrTemplateChain !is null)
			return type.type2.identifierOrTemplateChain.makeString ~ suffix;
		if (type.type2.symbol !is null && type.type2.symbol.identifierOrTemplateChain !is null)
			return type.type2.symbol.identifierOrTemplateChain.makeString ~ suffix;
		if (type.type2.type !is null)
			return type.type2.type.typeToString;
		return "";
	}
	else
		return "";
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
