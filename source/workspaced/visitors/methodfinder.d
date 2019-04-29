/// Finds methods in a specified interface or class location.
module workspaced.visitors.methodfinder;

import workspaced.visitors.attributes;

import workspaced.dparseext;

import dparse.ast;
import dparse.formatter;
import dparse.lexer;

import std.algorithm;
import std.array;
import std.range;
import std.string;

struct ArgumentInfo
{
	string signature, type, name;

	string toString() const
	{
		return name;
	}
}

struct MethodDetails
{
	string name, signature, returnType;
	ArgumentInfo[] arguments;
	bool isNothrowOrNogc;
	bool hasBody;
	bool needsImplementation;
	bool optionalImplementation;

	string identifier()
	{
		return format("%s %s(%(%s,%))", returnType, name, arguments.map!"a.type");
	}
}

struct FieldDetails
{
	string name, type;
	bool isPrivate;
}

struct InterfaceDetails
{
	/// Entire code of the file
	const(char)[] code;
	bool needsOverride;
	string name;
	FieldDetails[] fields;
	MethodDetails[] methods;
	string[] parents;
	string[] normalizedParents;
	int[] parentPositions;
}

class InterfaceMethodFinder : AttributesVisitor
{
	this(const(char)[] code, int targetPosition)
	{
		this.code = code;
		details.code = code;
		this.targetPosition = targetPosition;
	}

	override void visit(const ClassDeclaration dec)
	{
		auto c = context.save();
		context.pushContainer(ASTContext.ContainerAttribute.Type.class_, dec.name.text);
		visitInterface(dec.name, dec.baseClassList, dec.structBody, true);
		context.restore(c);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		auto c = context.save();
		context.pushContainer(ASTContext.ContainerAttribute.Type.interface_, dec.name.text);
		visitInterface(dec.name, dec.baseClassList, dec.structBody, false);
		context.restore(c);
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
					if (!base.type2 || !base.type2.typeIdentifierPart
							|| !base.type2.typeIdentifierPart.identifierOrTemplateInstance)
						continue;
					// TODO: template support!
					details.parents ~= astToString(base.type2);
					details.normalizedParents ~= astToString(base.type2);
					details.parentPositions ~= cast(
							int) base.type2.typeIdentifierPart.identifierOrTemplateInstance.identifier.index + 1;
				}
			details.needsOverride = needsOverride;
			inTarget = true;
			super.visit(structBody);
			inTarget = false;
		}
	}

	override void visit(const FunctionDeclaration dec)
	{
		if (!inTarget)
			return;
		auto origBody = (cast() dec).functionBody;
		const hasBody = !!origBody && origBody.missingFunctionBody is null;
		auto origComment = (cast() dec).comment;
		const implLevel = context.requiredImplementationLevel;
		const optionalImplementation = implLevel == 1 && !hasBody;
		const needsImplementation = implLevel == 9 || optionalImplementation;
		(cast() dec).functionBody = null;
		(cast() dec).comment = null;
		scope (exit)
		{
			(cast() dec).functionBody = origBody;
			(cast() dec).comment = origComment;
		}
		auto t = appender!string;
		format(t, dec);
		string method = context.localFormattedAttributes.chain([t.data.strip])
			.filter!(a => a.length > 0 && !a.among!("abstract", "final")).join(" ");
		ArgumentInfo[] arguments;
		if (dec.parameters)
			foreach (arg; dec.parameters.parameters)
				arguments ~= ArgumentInfo(astToString(arg), astToString(arg.type), arg.name.text);
		string returnType = dec.returnType ? astToString(dec.returnType) : "void";
		details.methods ~= MethodDetails(dec.name.text, method, returnType, arguments,
				context.isNothrow || context.isNogc, hasBody, needsImplementation, optionalImplementation);
	}

	override void visit(const FunctionBody)
	{
	}

	override void visit(const VariableDeclaration variable)
	{
		if (!inTarget)
			return;
		if (!variable.type)
			return;
		string type = astToString(variable.type);
		auto isPrivate = context.protectionType == tok!"private";

		foreach (decl; variable.declarators)
			details.fields ~= FieldDetails(decl.name.text, type, isPrivate);
	}

	alias visit = AttributesVisitor.visit;

	const(char)[] code;
	bool inTarget;
	int targetPosition;
	InterfaceDetails details;
}
