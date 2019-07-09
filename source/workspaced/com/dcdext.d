module workspaced.com.dcdext;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.thread;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.file;
import std.functional;
import std.json;
import std.range;
import std.string;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.dparseext;

import workspaced.visitors.classifier;
import workspaced.visitors.methodfinder;

@component("dcdext")
class DCDExtComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	static immutable CodeRegionProtection[] mixableProtection = [
		CodeRegionProtection.public_ | CodeRegionProtection.default_,
		CodeRegionProtection.package_, CodeRegionProtection.packageIdentifier,
		CodeRegionProtection.protected_, CodeRegionProtection.private_
	];

	/// Loads dcd extension methods. Call with `{"cmd": "load", "components": ["dcdext"]}`
	void load()
	{
		if (!refInstance)
			return;

		config.stringBehavior = StringBehavior.source;
	}

	/// Extracts calltips help information at a given position.
	/// The position must be within the arguments of the function and not
	/// outside the parentheses or inside some child call.
	/// When generating the call parameters for a function definition, the position must be inside the normal parameters,
	/// otherwise the template arguments will be put as normal arguments.
	/// Returns: the position of significant locations for parameter extraction.
	/// Params:
	///   code = code to analyze
	///   position = byte offset where to check for function arguments
	///   definition = true if this hints is a function definition (templates don't have an exclamation point '!')
	CalltipsSupport extractCallParameters(scope const(char)[] code, int position,
			bool definition = false)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto queuedToken = tokens.countUntil!(a => a.index >= position) - 1;
		if (queuedToken == -2)
			queuedToken = cast(ptrdiff_t) tokens.length - 1;
		else if (queuedToken == -1)
			return CalltipsSupport.init;

		bool inTemplate;
		int depth, subDepth;
		// contains opening parentheses location for arguments or exclamation point for templates.
		auto startParen = queuedToken;
		while (startParen >= 0)
		{
			const c = tokens[startParen];
			const p = startParen > 0 ? tokens[startParen - 1] : Token.init;

			if (c.type == tok!"{")
			{
				if (subDepth == 0)
				{
					// we went too far, probably not inside a function (or we are in a delegate, where we don't want calltips)
					return CalltipsSupport.init;
				}
				else
					subDepth--;
			}
			else if (c.type == tok!"}")
			{
				subDepth++;
			}
			else if (depth == 0 && !definition && c.type == tok!"!" && p.type == tok!"identifier")
			{
				inTemplate = true;
				break;
			}
			else if (c.type == tok!")")
			{
				depth++;
			}
			else if (c.type == tok!"(")
			{
				if (depth == 0 && subDepth == 0)
				{
					if (startParen > 1 && p.type == tok!"!" && tokens[startParen - 2].type
							== tok!"identifier")
					{
						startParen--;
						inTemplate = true;
					}
					break;
				}
				else
					depth--;
			}
			startParen--;
		}

		if (startParen <= 0)
			return CalltipsSupport.init;

		auto templateOpen = inTemplate ? startParen : 0;
		auto functionOpen = inTemplate ? 0 : startParen;

		if (inTemplate)
		{
			// go forwards to function arguments
			if (templateOpen + 2 < tokens.length && tokens[templateOpen + 1].type != tok!"(")
			{
				// single template arg (can only be one token)
				// https://dlang.org/spec/grammar.html#TemplateSingleArgument
				if (tokens[templateOpen + 2] == tok!"(")
					functionOpen = templateOpen + 2;
			}
			else
			{
				functionOpen = findClosingParenForward(tokens, templateOpen + 2);

				if (functionOpen >= tokens.length)
					functionOpen = 0;
			}
		}
		else
		{
			// go backwards to template arguments
			if (functionOpen > 0 && tokens[functionOpen - 1].type == tok!")")
			{
				// multi template args
				depth = 0;
				subDepth = 0;
				templateOpen = functionOpen - 1;
				while (templateOpen >= 1)
				{
					const c = tokens[templateOpen];

					if (c == tok!")")
						depth++;
					else
					{
						if (depth == 0 && templateOpen > 2 && c == tok!"(" && (definition
								|| (tokens[templateOpen - 1].type == tok!"!"
								&& tokens[templateOpen - 2].type == tok!"identifier")))
							break;
						else if (depth == 0)
						{
							templateOpen = 0;
							break;
						}

						if (c == tok!"(")
							depth--;
					}

					templateOpen--;
				}

				if (templateOpen <= 1)
					templateOpen = 0;
			}
			else
			{
				// single template arg (can only be one token)
				if (functionOpen <= 2)
					return CalltipsSupport.init;

				if (tokens[functionOpen - 2] == tok!"!" && tokens[functionOpen - 3] == tok!"identifier")
				{
					templateOpen = functionOpen - 2;
				}
			}
		}

		bool hasTemplateParens = templateOpen && templateOpen == functionOpen - 2;

		depth = 0;
		subDepth = 0;
		bool inFuncName = true;
		auto callStart = (templateOpen ? templateOpen : functionOpen) - 1;
		auto funcNameStart = callStart;
		while (callStart >= 0)
		{
			const c = tokens[callStart];
			const p = callStart > 0 ? tokens[callStart - 1] : Token.init;

			if (c.type == tok!"]")
				depth++;
			else if (c.type == tok!"[")
			{
				if (depth == 0)
				{
					// this is some sort of `foo[(4` situation
					return CalltipsSupport.init;
				}
				depth--;
			}
			else if (c.type == tok!")")
				subDepth++;
			else if (c.type == tok!"(")
			{
				if (subDepth == 0)
				{
					// this is some sort of `foo((4` situation
					return CalltipsSupport.init;
				}
				subDepth--;
			}
			else if (depth == 0)
			{

				if (c.type.isCalltipable)
				{
					if (c.type == tok!"identifier" && p.type == tok!"." && (callStart < 2
							|| !tokens[callStart - 2].type.among!(tok!";", tok!",",
							tok!"{", tok!"}", tok!"(")))
					{
						// member function, traverse further...
						if (inFuncName)
						{
							funcNameStart = callStart;
							inFuncName = false;
						}
						callStart--;
					}
					else
					{
						break;
					}
				}
				else
				{
					// this is some sort of `4(5` or `if(4` situtation
					return CalltipsSupport.init;
				}
			}
			// we ignore stuff inside brackets and parens such as `foo[4](5).bar[6](a`
			callStart--;
		}

		if (inFuncName)
			funcNameStart = callStart;

		auto templateClose = templateOpen ? (hasTemplateParens ? (functionOpen
				? functionOpen - 1 : findClosingParenForward(tokens, templateOpen + 1)) : templateOpen + 2)
			: 0;
		auto functionClose = functionOpen ? findClosingParenForward(tokens, functionOpen) : 0;

		CalltipsSupport.Argument[] templateArgs;
		if (templateOpen)
			templateArgs = splitArgs(tokens[templateOpen + 1 .. templateClose]);

		CalltipsSupport.Argument[] functionArgs;
		if (functionOpen)
			functionArgs = splitArgs(tokens[functionOpen + 1 .. functionClose]);

		return CalltipsSupport([
				tokens.tokenIndex(templateOpen), tokens.tokenIndex(templateClose)
				], hasTemplateParens, templateArgs, [
				tokens.tokenIndex(functionOpen), tokens.tokenIndex(functionClose)
				], functionArgs, funcNameStart != callStart,
				tokens.tokenIndex(funcNameStart), tokens.tokenIndex(callStart));
	}

	/// Finds the immediate surrounding code block at a position or returns CodeBlockInfo.init for none/module block.
	/// See_Also: CodeBlockInfo
	CodeBlockInfo getCodeBlockRange(scope const(char)[] code, int position)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, "getCodeBlockRange_input.d", &rba);
		auto reader = new CodeBlockInfoFinder(position);
		reader.visit(parsed);
		return reader.block;
	}

	/// Inserts a generic method after the corresponding block inside the scope where position is.
	/// If it can't find a good spot it will insert the code properly indented ata fitting location.
	// make public once usable
	private CodeReplacement[] insertCodeInContainer(string insert, scope const(char)[] code,
			int position, bool insertInLastBlock = true, bool insertAtEnd = true)
	{
		auto container = getCodeBlockRange(code, position);

		scope const(char)[] codeBlock = code[container.innerRange[0] .. container.innerRange[1]];

		scope tokensInsert = getTokensForParser(cast(ubyte[]) insert, config,
				&workspaced.stringCache);
		scope parsedInsert = parseModule(tokensInsert, "insertCode_insert.d", &rba);

		scope insertReader = new CodeDefinitionClassifier(insert);
		insertReader.visit(parsedInsert);
		scope insertRegions = insertReader.regions.sort!"a.type < b.type".uniq.array;

		scope tokens = getTokensForParser(cast(ubyte[]) codeBlock, config, &workspaced.stringCache);
		scope parsed = parseModule(tokens, "insertCode_code.d", &rba);

		scope reader = new CodeDefinitionClassifier(codeBlock);
		reader.visit(parsed);
		scope regions = reader.regions;

		CodeReplacement[] ret;

		foreach (CodeDefinitionClassifier.Region toInsert; insertRegions)
		{
			auto insertCode = insert[toInsert.region[0] .. toInsert.region[1]];
			scope existing = regions.enumerate.filter!(a => a.value.sameBlockAs(toInsert));
			if (existing.empty)
			{
				const checkProtection = CodeRegionProtection.init.reduce!"a | b"(
						mixableProtection.filter!(a => (a & toInsert.protection) != 0));

				bool inIncompatible = false;
				bool lastFit = false;
				int fittingProtection = -1;
				int firstStickyProtection = -1;
				int regionAfterFitting = -1;
				foreach (i, stickyProtection; regions)
				{
					if (stickyProtection.affectsFollowing
							&& stickyProtection.protection != CodeRegionProtection.init)
					{
						if (firstStickyProtection == -1)
							firstStickyProtection = cast(int) i;

						if ((stickyProtection.protection & checkProtection) != 0)
						{
							fittingProtection = cast(int) i;
							lastFit = true;
							if (!insertInLastBlock)
								break;
						}
						else
						{
							if (lastFit)
							{
								regionAfterFitting = cast(int) i;
								lastFit = false;
							}
							inIncompatible = true;
						}
					}
				}
				assert(firstStickyProtection != -1 || !inIncompatible);
				assert(regionAfterFitting != -1 || fittingProtection == -1 || !inIncompatible);

				if (inIncompatible)
				{
					int insertRegion = fittingProtection == -1 ? firstStickyProtection : regionAfterFitting;
					insertCode = text(indent(insertCode, regions[insertRegion].minIndentation), "\n\n");
					auto len = cast(uint) insertCode.length;

					toInsert.region[0] = regions[insertRegion].region[0];
					toInsert.region[1] = regions[insertRegion].region[0] + len;
					foreach (ref r; regions[insertRegion .. $])
					{
						r.region[0] += len;
						r.region[1] += len;
					}
				}
				else
				{
					auto lastRegion = regions.back;
					insertCode = indent(insertCode, lastRegion.minIndentation).idup;
					auto len = cast(uint) insertCode.length;
					toInsert.region[0] = lastRegion.region[1];
					toInsert.region[1] = lastRegion.region[1] + len;
				}
				regions ~= toInsert;
				ret ~= CodeReplacement([toInsert.region[0], toInsert.region[0]], insertCode);
			}
			else
			{
				auto target = insertInLastBlock ? existing.tail(1).front : existing.front;

				insertCode = text("\n\n", indent(insertCode, regions[target.index].minIndentation));
				const codeLength = cast(int) insertCode.length;

				if (insertAtEnd)
				{
					ret ~= CodeReplacement([
							target.value.region[1], target.value.region[1]
							], insertCode);
					toInsert.region[0] = target.value.region[1];
					toInsert.region[1] = target.value.region[1] + codeLength;
					regions[target.index].region[1] = toInsert.region[1];
					foreach (ref other; regions[target.index + 1 .. $])
					{
						other.region[0] += codeLength;
						other.region[1] += codeLength;
					}
				}
				else
				{
					ret ~= CodeReplacement([
							target.value.region[0], target.value.region[0]
							], insertCode);
					regions[target.index].region[1] += codeLength;
					foreach (ref other; regions[target.index + 1 .. $])
					{
						other.region[0] += codeLength;
						other.region[1] += codeLength;
					}
				}
			}
		}

		return ret;
	}

	/// Implements the interfaces or abstract classes of a specified class/interface.
	Future!string implement(scope const(char)[] code, int position)
	{
		auto ret = new Future!string;
		gthreads.create({
			mixin(traceTask);
			try
			{
				struct InterfaceTree
				{
					InterfaceDetails details;
					InterfaceTree[] inherits;
				}

				auto baseInterface = getInterfaceDetails("stdin", code, position);

				string[] implementedMethods = baseInterface.methods
					.filter!"!a.needsImplementation"
					.map!"a.identifier"
					.array;

				// start with private, add all the public ones later in traverseTree
				FieldDetails[] availableVariables = baseInterface.fields.filter!"a.isPrivate".array;
				InterfaceTree tree = InterfaceTree(baseInterface);

				InterfaceTree* treeByName(InterfaceTree* tree, string name)
				{
					if (tree.details.name == name)
						return tree;
					foreach (ref parent; tree.inherits)
					{
						InterfaceTree* t = treeByName(&parent, name);
						if (t !is null)
							return t;
					}
					return null;
				}

				void traverseTree(ref InterfaceTree sub)
				{
					availableVariables ~= sub.details.fields.filter!"!a.isPrivate".array;
					foreach (i, parent; sub.details.parentPositions)
					{
						string parentName = sub.details.normalizedParents[i];
						if (treeByName(&tree, parentName) is null)
						{
							auto details = lookupInterface(sub.details.code, parent);
							sub.inherits ~= InterfaceTree(details);
						}
					}
					foreach (ref inherit; sub.inherits)
						traverseTree(inherit);
				}

				traverseTree(tree);

				string changes;
				void processTree(ref InterfaceTree tree)
				{
					auto details = tree.details;
					if (details.methods.length)
					{
						bool first = true;
						foreach (fn; details.methods)
						{
							if (implementedMethods.canFind(fn.identifier))
								continue;
							if (!fn.needsImplementation)
							{
								implementedMethods ~= fn.identifier;
								continue;
							}
							if (first)
							{
								changes ~= "// implement " ~ details.name ~ "\n\n";
								first = false;
							}
							if (details.needsOverride)
								changes ~= "override ";
							changes ~= fn.signature[0 .. $ - 1];
							changes ~= " {";
							if (fn.optionalImplementation)
							{
								changes ~= "\n\t// TODO: optional implementation\n";
							}

							string propertySearch;
							if (fn.signature.canFind("@property") && fn.arguments.length <= 1)
								propertySearch = fn.name;
							else if ((fn.name.startsWith("get") && fn.arguments.length == 0)
								|| (fn.name.startsWith("set") && fn.arguments.length == 1))
								propertySearch = fn.name[3 .. $];

							string foundProperty;
							if (propertySearch)
							{
								foreach (variable; availableVariables)
								{
									if (fieldNameMatches(variable.name, propertySearch))
									{
										foundProperty = variable.name;
										break;
									}
								}
							}

							if (foundProperty.length)
							{
								changes ~= "\n\t";
								if (fn.returnType != "void")
									changes ~= "return ";
								if (fn.name.startsWith("set") || fn.arguments.length == 1)
									changes ~= foundProperty ~ " = " ~ fn.arguments[0].name;
								else
									changes ~= foundProperty;
								changes ~= ";\n";
							}
							else if (fn.hasBody)
							{
								changes ~= "\n\t";
								if (fn.returnType != "void")
									changes ~= "return ";
								changes ~= "super." ~ fn.name;
								if (fn.arguments.length)
									changes ~= "(" ~ format("%(%s, %)", fn.arguments) ~ ")";
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

					foreach (parent; tree.inherits)
						processTree(parent);
				}

				processTree(tree);

				ret.finish(changes);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

private:
	RollbackAllocator rba;
	LexerConfig config;

	InterfaceDetails lookupInterface(scope const(char)[] code, int position)
	{
		auto data = get!DCDComponent.findDeclaration(code, position).getBlocking;
		string file = data.file;
		int newPosition = data.position;

		if (!file.length)
			return InterfaceDetails.init;

		auto newCode = code;
		if (file != "stdin")
			newCode = readText(file);

		return getInterfaceDetails(file, newCode, newPosition);
	}

	InterfaceDetails getInterfaceDetails(string file, scope const(char)[] code, int position)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, file, &rba);
		auto reader = new InterfaceMethodFinder(code, position);
		reader.visit(parsed);
		return reader.details;
	}
}

///
enum CodeRegionType : int
{
	/// null region (unset)
	init,
	/// Imports inside the block
	imports = 1 << 0,
	/// Aliases `alias foo this;`, `alias Type = Other;`
	aliases = 1 << 1,
	/// Nested classes/structs/unions/etc.
	types = 1 << 2,
	/// Raw variables `Type name;`
	fields = 1 << 3,
	/// Normal constructors `this(Args args)`
	ctor = 1 << 4,
	/// Copy constructors `this(this)`
	copyctor = 1 << 5,
	/// Destructors `~this()`
	dtor = 1 << 6,
	/// Properties (functions annotated with `@property`)
	properties = 1 << 7,
	/// Regular functions
	methods = 1 << 8,
}

///
enum CodeRegionProtection : int
{
	/// null protection (unset)
	init,
	/// default (unmarked) protection
	default_ = 1 << 0,
	/// public protection
	public_ = 1 << 1,
	/// package (automatic) protection
	package_ = 1 << 2,
	/// package (manual package name) protection
	packageIdentifier = 1 << 3,
	/// protected protection
	protected_ = 1 << 4,
	/// private protection
	private_ = 1 << 5,
}

///
enum CodeRegionStatic : int
{
	/// null static (unset)
	init,
	/// non-static code
	instanced = 1 << 0,
	/// static code
	static_ = 1 << 1,
}

/// Represents a class/interface/struct/union/template with body.
struct CodeBlockInfo
{
	///
	enum Type : int
	{
		// keep the underlines in these values for range checking properly

		///
		class_,
		///
		interface_,
		///
		struct_,
		///
		union_,
		///
		template_,
	}

	static immutable string[] typePrefixes = [
		"class ", "interface ", "struct ", "union ", "template "
	];

	///
	Type type;
	///
	string name;
	/// Outer range inside the code spanning curly braces and name but not type keyword.
	uint[2] outerRange;
	/// Inner range of body of the block touching, but not spanning curly braces.
	uint[2] innerRange;

	string prefix() @property
	{
		return typePrefixes[cast(int) type];
	}
}

///
struct CalltipsSupport
{
	///
	struct Argument
	{
		/// Ranges of type, name and value not including commas or parentheses, but being right next to them. For calls this is the only important and accurate value.
		int[2] contentRange;
		/// Range of just the type, or for templates also `alias`
		int[2] typeRange;
		/// Range of just the name
		int[2] nameRange;
		/// Range of just the default value
		int[2] valueRange;

		/// Creates Argument(range, range, range, 0)
		static Argument templateType(int[2] range)
		{
			return Argument(range, range, range);
		}

		/// Creates Argument(range, 0, range, range)
		static Argument templateValue(int[2] range)
		{
			return Argument(range, typeof(range).init, range, range);
		}
	}

	bool hasTemplate() @property
	{
		return hasTemplateParens || templateArgumentsRange != typeof(templateArgumentsRange).init;
	}

	/// Range starting inclusive at exclamation point until exclusive at closing bracket or function opening bracket.
	int[2] templateArgumentsRange;
	///
	bool hasTemplateParens;
	///
	Argument[] templateArgs;
	/// Range starting inclusive at opening parentheses until exclusive at closing parentheses.
	int[2] functionParensRange;
	///
	Argument[] functionArgs;
	/// True if the function is UFCS or a member function of some object or namespace.
	/// False if this is a global function call.
	bool hasParent;
	/// Start of the function itself.
	int functionStart;
	/// Start of the whole call going up all call parents. (`foo.bar.function` having `foo.bar` as parents)
	int parentStart;
}

private:

bool isCalltipable(IdType type)
{
	return type == tok!"identifier" || type == tok!"assert" || type == tok!"import"
		|| type == tok!"mixin" || type == tok!"super" || type == tok!"this" || type == tok!"__traits";
}

int[2] tokenRange(const Token token)
{
	return [cast(int) token.index, cast(int)(token.index + token.text.length)];
}

int tokenEnd(const Token token)
{
	return cast(int)(token.index + token.text.length);
}

int tokenIndex(const(Token)[] tokens, ptrdiff_t i)
{
	if (i > 0 && i == tokens.length)
		return cast(int)(tokens[$ - 1].index + tokens[$ - 1].text.length);
	return i >= 0 ? cast(int) tokens[i].index : 0;
}

int tokenEndIndex(const(Token)[] tokens, ptrdiff_t i)
{
	if (i > 0 && i == tokens.length)
		return cast(int)(tokens[$ - 1].index + tokens[$ - 1].text.length);
	return i >= 0 ? cast(int)(tokens[i].index + tokens[i].text.length) : 0;
}

ptrdiff_t findClosingParenForward(const(Token)[] tokens, ptrdiff_t open)
in(tokens[open].type == tok!"(")
{
	if (open >= tokens.length || open < 0)
		return open;

	open++;

	int depth = 1;
	int subDepth = 0;
	while (open < tokens.length)
	{
		const c = tokens[open];

		if (c == tok!"(")
			depth++;
		else if (c == tok!"{")
			subDepth++;
		else if (c == tok!"}")
		{
			if (subDepth == 0)
				break;
			subDepth--;
		}
		else
		{
			if (c == tok!";" && subDepth == 0)
				break;

			if (c == tok!")")
				depth--;

			if (depth == 0)
				break;
		}

		open++;
	}
	return open;
}

CalltipsSupport.Argument[] splitArgs(const(Token)[] tokens)
{
	auto ret = appender!(CalltipsSupport.Argument[]);
	size_t start = 0;
	size_t valueStart = 0;

	int depth, subDepth;
	bool gotValue;

	void putArg(size_t end)
	{
		if (start >= end || start >= tokens.length)
			return;

		CalltipsSupport.Argument arg;

		auto typename = tokens[start .. end];
		arg.contentRange = [cast(int) typename[0].index, typename[$ - 1].tokenEnd];
		if (typename.length == 1)
		{
			auto t = typename[0];
			if (t.type == tok!"identifier" || t.type.isBasicType)
				arg = CalltipsSupport.Argument.templateType(t.tokenRange);
			else
				arg = CalltipsSupport.Argument.templateValue(t.tokenRange);
		}
		else
		{
			if (gotValue && valueStart > start && valueStart <= end)
			{
				typename = tokens[start .. valueStart];
				auto val = tokens[valueStart .. end];
				if (val.length)
					arg.valueRange = [cast(int) val[0].index, val[$ - 1].tokenEnd];
			}

			else if (typename.length == 1)
			{
				auto t = typename[0];
				if (t.type == tok!"identifier" || t.type.isBasicType)
					arg.typeRange = arg.nameRange = t.tokenRange;
				else
					arg.typeRange = t.tokenRange;
			}
			else if (typename.length)
			{
				if (typename[$ - 1].type == tok!"identifier")
				{
					arg.nameRange = typename[$ - 1].tokenRange;
					typename = typename[0 .. $ - 1];
				}
				arg.typeRange = [cast(int) typename[0].index, typename[$ - 1].tokenEnd];
			}
		}

		ret.put(arg);

		gotValue = false;
		start = end + 1;
	}

	foreach (i, token; tokens)
	{
		if (token.type == tok!"{")
			subDepth++;
		else if (token.type == tok!"}")
		{
			if (subDepth == 0)
				break;
			subDepth--;
		}
		else if (token.type == tok!"(" || token.type == tok!"[")
			depth++;
		else if (token.type == tok!")" || token.type == tok!"]")
		{
			if (depth == 0)
				break;
			depth--;
		}

		if (token.type == tok!",")
			putArg(i);
		else if (token.type == tok!":" || token.type == tok!"=")
		{
			if (!gotValue)
			{
				valueStart = i + 1;
				gotValue = true;
			}
		}
	}
	putArg(tokens.length);

	return ret.data;
}

auto indent(scope const(char)[] code, string indentation)
{
	return code.lineSplitter!(KeepTerminator.yes)
		.map!(a => a.length ? indentation ~ a : a)
		.join;
}

bool fieldNameMatches(string field, in char[] expected)
{
	import std.uni : sicmp;

	if (field.startsWith("_"))
		field = field[1 .. $];
	else if (field.startsWith("m_"))
		field = field[2 .. $];
	else if (field.length >= 2 && field[0] == 'm' && field[1].isUpper)
		field = field[1 .. $];

	return field.sicmp(expected) == 0;
}

final class CodeBlockInfoFinder : ASTVisitor
{
	this(int targetPosition)
	{
		this.targetPosition = targetPosition;
	}

	override void visit(const ClassDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.class_, dec.structBody);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.interface_, dec.structBody);
	}

	override void visit(const StructDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.struct_, dec.structBody);
	}

	override void visit(const UnionDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.union_, dec.structBody);
	}

	override void visit(const TemplateDeclaration dec)
	{
		if (cast(int) targetPosition >= cast(int) dec.name.index && targetPosition < dec.endLocation)
		{
			block = CodeBlockInfo.init;
			block.type = CodeBlockInfo.Type.template_;
			block.name = dec.name.text;
			block.outerRange = [
				cast(uint) dec.name.index, cast(uint) dec.endLocation + 1
			];
			block.innerRange = [
				cast(uint) dec.startLocation + 1, cast(uint) dec.endLocation
			];
			dec.accept(this);
		}
	}

	private void visitContainer(const Token name, CodeBlockInfo.Type type, const StructBody structBody)
	{
		if (!structBody)
			return;
		if (cast(int) targetPosition >= cast(int) name.index && targetPosition < structBody.endLocation)
		{
			block = CodeBlockInfo.init;
			block.type = type;
			block.name = name.text;
			block.outerRange = [
				cast(uint) name.index, cast(uint) structBody.endLocation + 1
			];
			block.innerRange = [
				cast(uint) structBody.startLocation + 1, cast(uint) structBody.endLocation
			];
			structBody.accept(this);
		}
	}

	alias visit = ASTVisitor.visit;

	CodeBlockInfo block;
	int targetPosition;
}

version (unittest) static immutable string SimpleClassTestCode = q{
module foo;

class FooBar
{
public:
	int i; // default instanced fields
	string s;
	long l;

	public this() // public instanced ctor
	{
		i = 4;
	}

protected:
	int x; // protected instanced field

private:
	static const int foo() @nogc nothrow pure @system // private static methods
	{
		if (s == "a")
		{
			i = 5;
		}
	}

	static void bar1() {}

	void bar2() {} // private instanced methods
	void bar3() {}
}};

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 123) == CodeBlockInfo(CodeBlockInfo.Type.class_,
			"FooBar", [20, SimpleClassTestCode.length], [
				28, SimpleClassTestCode.length - 1
			]));
	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 19) == CodeBlockInfo.init);
	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 20) != CodeBlockInfo.init);

	auto replacements = dcdext.insertCodeInContainer("void foo()\n{\n\twriteln();\n}",
			SimpleClassTestCode, 123);
	import std.stdio;

	stderr.writeln(replacements);
}

unittest
{
	import std.conv;

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	import std.stdio;

	auto extract = dcdext.extractCallParameters("int x; foo.bar(4, fgerg\n\nfoo(); int y;", 23);
	assert(!extract.hasTemplate);
	assert(extract.parentStart == 7);
	assert(extract.functionStart == 11);
	assert(extract.functionParensRange[0] == 14);
	assert(extract.functionParensRange[1] <= 31);
	assert(extract.functionArgs.length == 2);
	assert(extract.functionArgs[0].contentRange == [15, 16]);
	assert(extract.functionArgs[1].contentRange[0] == 18);
	assert(extract.functionArgs[1].contentRange[1] <= 31);

	extract = dcdext.extractCallParameters("int x; foo.bar(4, fgerg)\n\nfoo(); int y;", 23);
	assert(!extract.hasTemplate);
	assert(extract.parentStart == 7);
	assert(extract.functionStart == 11);
	assert(extract.functionParensRange == [14, 23]);
	assert(extract.functionArgs.length == 2);
	assert(extract.functionArgs[0].contentRange == [15, 16]);
	assert(extract.functionArgs[1].contentRange == [18, 23]);
}
