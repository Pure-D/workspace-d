module workspaced.com.dcdext;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.thread;

import std.ascii;
import std.file;
import std.functional;
import std.json;
import std.string;

import workspaced.api;
import workspaced.dparseext;

private import dcd = workspaced.com.dcd;

@component("dcdext") :

/// Loads dcd extension methods. Call with `{"cmd": "load", "components": ["dcdext"]}`
@load void start()
{
	config.stringBehavior = StringBehavior.source;
	cache = new StringCache(StringCache.defaultBucketCount);
}

/// Has no purpose right now.
@unload void stop()
{
}

/// Implements an interface or abstract class
/// Returns: string
/// Call_With: `{"subcmd": "implement"}`
@arguments("subcmd", "implement")
@async void implement(AsyncCallback cb, string code, int position)
{
	new Thread({
		try
		{
			string changes;
			void prependInterface(InterfaceDetails details, int maxDepth = 50)
			{
				if (maxDepth <= 0)
					return;
				if (details.methods.length)
				{
					changes ~= "// implement " ~ details.name ~ "\n\n";
					foreach (fn; details.methods)
					{
						if (details.needsOverride)
							changes ~= "override ";
						changes ~= fn.signature[0 .. $ - 1];
						changes ~= " {";
						if (fn.signature[$ - 1] == '{') // has body
						{
							changes ~= "\n\t";
							if (fn.returnType != "void")
								changes ~= "return ";
							changes ~= "super." ~ fn.name;
							if (fn.arguments.length)
								changes ~= "(" ~ fn.arguments ~ ")";
							else if (fn.returnType == "void")
								changes ~= "()"; // make functions that don't return add (), otherwise they might be attributes and don't need that
							changes ~= ";\n";
						}
						else if (fn.returnType != "void")
						{
							changes ~= "\n\t";
							if (fn.isNothrowOrNogc)
							{
								if (fn.returnType.endsWith("[]"))
									changes ~= "return null; // TODO: implement";
								else
									changes ~= "return " ~ fn.returnType ~ ".init; // TODO: implement";
							}
							else
								changes ~= `assert(false, "Method ` ~ fn.name ~ ` not implemented");`;
							changes ~= "\n";
						}
						changes ~= "}\n\n";
					}
				}
				if (!details.needsOverride || details.methods.length)
					foreach (parent; details.parentPositions)
						prependInterface(lookupInterface(details.code, parent), maxDepth - 1);
			}

			prependInterface(lookupInterface(code, position));
			cb(null, JSONValue(changes));
		}
		catch (Throwable t)
		{
			cb(t, JSONValue.init);
		}
	}).start();
}

private __gshared:
RollbackAllocator rba;
LexerConfig config;
StringCache* cache;

struct MethodDetails
{
	string name, signature, arguments, returnType;
	bool isNothrowOrNogc;
}

struct InterfaceDetails
{
	/// Entire code of the file
	string code;
	bool needsOverride;
	string name;
	MethodDetails[] methods;
	string[] parents;
	int[] parentPositions;
}

InterfaceDetails lookupInterface(string code, int position)
{
	auto data = syncBlocking!(dcd.findDeclaration)(code, position);
	if (data.type != JSON_TYPE.ARRAY)
		return InterfaceDetails.init;
	string file = data.array[0].str;
	int newPosition = cast(int) data.array[1].integer;

	string newCode = code;
	if (file != "stdin")
		newCode = readText(file);

	return getInterfaceDetails(file, newCode, newPosition);
}

InterfaceDetails getInterfaceDetails(string file, string code, int position)
{
	auto tokens = getTokensForParser(cast(ubyte[]) code, config, cache);
	auto parsed = parseModule(tokens, file, &rba, (&doNothing).toDelegate);
	auto reader = new InterfaceMethodFinder(code, position);
	reader.visit(parsed);
	return reader.details;
}

final class InterfaceMethodFinder : ASTVisitor
{
	this(string code, int targetPosition)
	{
		this.code = code;
		details.code = code;
		this.targetPosition = targetPosition;
	}

	override void visit(const ClassDeclaration dec)
	{
		visitInterface(dec.name, dec.baseClassList, dec.structBody, true);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		visitInterface(dec.name, dec.baseClassList, dec.structBody, false);
	}

	private void visitInterface(const Token name, const BaseClassList baseClassList,
			const StructBody structBody, bool needsOverride)
	{
		if (!structBody)
			return;
		if (targetPosition >= name.index && targetPosition < structBody.endLocation)
		{
			details.name = name.text;
			if (baseClassList)
				foreach (base; baseClassList.items)
				{
					if (!base.type2 || !base.type2.symbol || !base.type2.symbol.identifierOrTemplateChain
							|| !base.type2.symbol.identifierOrTemplateChain.identifiersOrTemplateInstances.length)
						continue;
					details.parents ~= astToString(base.type2);
					details.parentPositions ~= cast(
							int) base.type2.symbol.identifierOrTemplateChain
						.identifiersOrTemplateInstances[0].identifier.index + 1;
				}
			inTarget = true;
			details.needsOverride = needsOverride;
			context.notInheritable = needsOverride;
			structBody.accept(this);
			inTarget = false;
		}
	}

	override void visit(const FunctionDeclaration dec)
	{
		if (!inTarget || context.notInheritable)
			return;
		dec.accept(this);
		auto origBody = (cast() dec).functionBody;
		auto origComment = (cast() dec).comment;
		(cast() dec).functionBody = null;
		(cast() dec).comment = null;
		scope (exit)
		{
			(cast() dec).functionBody = origBody;
			(cast() dec).comment = origComment;
		}
		string method = astToString(dec, context.attributes).strip;
		if (origBody)
			method = method[0 .. $ - 1] ~ '{'; // replace ; with { to indicate that there is a body
		string arguments;
		if (dec.parameters)
			foreach (arg; dec.parameters.parameters)
			{
				if (arguments.length)
					arguments ~= ", ";
				arguments ~= arg.name.text;
			}
		details.methods ~= MethodDetails(dec.name.text, method, arguments,
				dec.returnType ? astToString(dec.returnType) : "void", context.isNothrowOrNogc);
	}

	override void visit(const FunctionBody)
	{
	}

	override void visit(const MemberFunctionAttribute attribute)
	{
		if (attribute.tokenType == tok!"nothrow")
			context.isNothrowOrNogc = true;
		attribute.accept(this);
	}

	override void visit(const FunctionAttribute attribute)
	{
		if (attribute.token.text == "nothrow")
			context.isNothrowOrNogc = true;
		attribute.accept(this);
	}

	override void visit(const AtAttribute attribute)
	{
		if (attribute.identifier.text == "nogc")
			context.isNothrowOrNogc = true;
		attribute.accept(this);
	}

	override void visit(const Attribute attribute)
	{
		attribute.accept(this);
		if (attribute.attribute != tok!"")
		{
			switch (attribute.attribute.type)
			{
			case tok!"private":
			case tok!"final":
			case tok!"static":
				context.notInheritable = true;
				break;
			case tok!"abstract":
				context.notInheritable = false;
				return;
			case tok!"nothrow":
				context.isNothrowOrNogc = true;
				break;
			default:
			}
		}
		context.attributes ~= attribute;
	}

	override void visit(const AttributeDeclaration dec)
	{
		resetAst = false;
		dec.accept(this);
	}

	override void visit(const Declaration dec)
	{
		auto c = context.save;
		dec.accept(this);

		if (resetAst)
		{
			context.restore(c);
			if (details.needsOverride)
				context.notInheritable = true;
		}
		resetAst = true;
	}

	alias visit = ASTVisitor.visit;

	string code;
	bool inTarget;
	int targetPosition;
	bool resetAst;
	ASTContext context;
	InterfaceDetails details;
}

struct ASTContext
{
	const(Attribute)[] attributes;
	bool notInheritable;
	bool isNothrowOrNogc;

	ASTContext save() const
	{
		return ASTContext(attributes[], notInheritable, isNothrowOrNogc);
	}

	void restore(in ASTContext c)
	{
		attributes = c.attributes;
		notInheritable = c.notInheritable;
		isNothrowOrNogc = c.isNothrowOrNogc;
	}
}

void doNothing(string, size_t, size_t, string, bool)
{
}
