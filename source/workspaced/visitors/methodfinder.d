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

/// Information about an argument in a method defintion.
struct ArgumentInfo
{
	/// The whole definition of the argument including everything related to it as formatted code string.
	string signature;
	/// The type of the argument.
	string type;
	/// The name of the argument.
	string name;

	/// Returns just the name.
	string toString() const
	{
		return name;
	}
}

/// Information about a method definition.
struct MethodDetails
{
	/// The name of the method.
	string name;
	/// The type definition of the method without body, abstract or final.
	string signature;
	/// The return type of the method.
	string returnType;
	/// All (regular) arguments passable into this method.
	ArgumentInfo[] arguments;
	///
	bool isNothrowOrNogc;
	/// True if this function has an implementation.
	bool hasBody;
	/// True when the container is an interface or (optionally implicit) abstract class or when in class not having a body.
	bool needsImplementation;
	/// True when in a class and method doesn't have a body.
	bool optionalImplementation;
	/// Range starting at return type, going until last token before opening curly brace.
	size_t[2] definitionRange;
	/// Range containing the starting and ending braces of the body.
	size_t[2] blockRange;

	/// Signature without any attributes, constraints or parameter details other than types.
	/// Used to differentiate a method from others without computing the mangle.
	/// Returns: `"<type> <name>(<argument types>)"`
	string identifier()
	{
		return format("%s %s(%(%s,%))", returnType, name, arguments.map!"a.type");
	}
}

///
struct FieldDetails
{
	///
	string name, type;
	///
	bool isPrivate;
}

/// Information about an interface or class
struct InterfaceDetails
{
	/// Entire code of the file
	const(char)[] code;
	/// True if this is a class and therefore need to override methods using $(D override).
	bool needsOverride;
	/// Name of the interface or class.
	string name;
	/// Plain old variable fields in this container.
	FieldDetails[] fields;
	/// All methods defined in this container.
	MethodDetails[] methods;
	// reserved for future use with templates
	string[] parents;
	/// Name of all base classes or interfaces. Should use normalizedParents,
	string[] normalizedParents;
	/// Absolute code position after the colon where the corresponding parent name starts.
	int[] parentPositions;
	/// Range containing the starting and ending braces of the body.
	size_t[2] blockRange;
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
		details.blockRange = [structBody.startLocation, structBody.endLocation + 1];
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

		size_t[2] definitionRange = [dec.name.index, 0];
		size_t[2] blockRange;

		if (dec.returnType !is null && dec.returnType.tokens.length > 0)
			definitionRange[0] = dec.returnType.tokens[0].index;

		if (dec.functionBody !is null && dec.functionBody.tokens.length > 0)
		{
			definitionRange[1] = dec.functionBody.tokens[0].index;
			blockRange = [
				dec.functionBody.tokens[0].index, dec.functionBody.tokens[$ - 1].index + 1
			];
		}
		else if (dec.parameters !is null && dec.parameters.tokens.length > 0)
			definitionRange[1] = dec.parameters.tokens[$ - 1].index
				+ dec.parameters.tokens[$ - 1].text.length;

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

		// now visit to populate isNothrow, isNogc (before it would add to the localFormattedAttributes string)
		super.visit(dec);

		details.methods ~= MethodDetails(dec.name.text, method, returnType, arguments, context.isNothrowInContainer
				|| context.isNogcInContainer, hasBody, needsImplementation,
				optionalImplementation, definitionRange, blockRange);
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
