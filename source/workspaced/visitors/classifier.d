/// Visitor classifying types and groups of regions of root definitions.
module workspaced.visitors.classifier;

import workspaced.visitors.attributes;

import workspaced.com.dcdext;

import std.algorithm;
import std.ascii;
import std.range;
import std.meta;

import dparse.ast;
import dparse.lexer;

class CodeDefinitionClassifier : AttributesVisitor
{
	struct Region
	{
		CodeOrderType type;
		ProtectionOrderType protection;
		StaticOrderType staticness;
		string minIndentation;
		uint[2] region;

		bool sameBlockAs(in Region other)
		{
			return type == other.type && protection == other.protection && staticness == other.staticness;
		}
	}

	this(string code)
	{
		this.code = code;
	}

	override void visit(const AliasDeclaration aliasDecl)
	{
		putRegion(CodeOrderType.aliases);
	}

	override void visit(const AliasThisDeclaration aliasDecl)
	{
		putRegion(CodeOrderType.aliases);
	}

	override void visit(const ClassDeclaration typeDecl)
	{
		putRegion(CodeOrderType.types);
	}

	override void visit(const InterfaceDeclaration typeDecl)
	{
		putRegion(CodeOrderType.types);
	}

	override void visit(const StructDeclaration typeDecl)
	{
		putRegion(CodeOrderType.types);
	}

	override void visit(const UnionDeclaration typeDecl)
	{
		putRegion(CodeOrderType.types);
	}

	override void visit(const EnumDeclaration typeDecl)
	{
		putRegion(CodeOrderType.types);
	}

	override void visit(const AnonymousEnumDeclaration typeDecl)
	{
		putRegion(CodeOrderType.types);
	}

	override void visit(const AutoDeclaration field)
	{
		putRegion(CodeOrderType.fields);
	}

	override void visit(const VariableDeclaration field)
	{
		putRegion(CodeOrderType.fields);
	}

	override void visit(const Constructor ctor)
	{
		putRegion(CodeOrderType.ctor);
	}

	override void visit(const StaticConstructor ctor)
	{
		putRegion(CodeOrderType.ctor);
	}

	override void visit(const SharedStaticConstructor ctor)
	{
		putRegion(CodeOrderType.ctor);
	}

	override void visit(const Postblit copyctor)
	{
		putRegion(CodeOrderType.copyctor);
	}

	override void visit(const Destructor dtor)
	{
		putRegion(CodeOrderType.dtor);
	}

	override void visit(const StaticDestructor dtor)
	{
		putRegion(CodeOrderType.dtor);
	}

	override void visit(const SharedStaticDestructor dtor)
	{
		putRegion(CodeOrderType.dtor);
	}

	override void visit(const FunctionDeclaration method)
	{
		putRegion((method.attributes && method.attributes.any!(a => a.atAttribute
				&& a.atAttribute.identifier.text == "property")) ? CodeOrderType.properties
				: CodeOrderType.methods);
	}

	override void visit(const Declaration dec)
	{
		writtenRegion = false;
		currentRange = [cast(uint) dec.tokens[0].index,
			cast(uint)(dec.tokens[$ - 1].index + dec.tokens[$ - 1].text.length + 1)];
		super.visit(dec);
		if (writtenRegion && regions.length >= 2 && regions[$ - 2].sameBlockAs(regions[$ - 1]))
		{
			auto range = regions[$ - 1].region;
			if (regions[$ - 1].minIndentation.scoreIndent < regions[$ - 2].minIndentation.scoreIndent)
				regions[$ - 2].minIndentation = regions[$ - 1].minIndentation;
			regions[$ - 2].region[1] = range[1];
			regions.length--;
		}
	}

	void putRegion(CodeOrderType type, uint[2] range = typeof(uint.init)[2].init)
	{
		if (range == typeof(uint.init)[2].init)
			range = currentRange;

		ProtectionOrderType protection;
		StaticOrderType staticness;

		auto prot = context.protectionAttribute;
		if (prot)
		{
			if (prot[0].type == tok!"private")
				protection = ProtectionOrderType.private_;
			else if (prot[0].type == tok!"protected")
				protection = ProtectionOrderType.protected_;
			else if (prot[0].type == tok!"package")
			{
				if (prot.length > 1)
					protection = ProtectionOrderType.packageIdentifier;
				else
					protection = ProtectionOrderType.package_;
			}
			else if (prot[0].type == tok!"public")
				protection = ProtectionOrderType.public_;
		}

		staticness = context.isStatic ? StaticOrderType.static_ : StaticOrderType.instanced;

		//dfmt off
		Region r = {
			type: type,
			protection: protection,
			staticness: staticness,
			region: range
		};
		//dfmt on
		regions ~= r;
		writtenRegion = true;
	}

	alias visit = AttributesVisitor.visit;

	bool writtenRegion;
	string code;
	Region[] regions;
	uint[2] currentRange;
}

private int scoreIndent(string indent)
{
	auto len = indent.countUntil!(a => !a.isWhite);
	if (len == -1)
		return cast(int) indent.length;
	return indent[0 .. len].map!(a => a == ' ' ? 1 : 4).sum;
}
