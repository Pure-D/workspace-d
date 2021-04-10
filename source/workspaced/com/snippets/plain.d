module workspaced.com.snippets.plain;

import std.regex;

import workspaced.api;
import workspaced.com.snippets;

///
struct PlainSnippet
{
	/// Grammar scopes in which to complete this snippet
	SnippetLevel[] levels;
	/// Shortcut to type for this snippet
	string shortcut;
	/// Label for this snippet.
	string title;
	/// Text with interactive snippet locations to insert assuming global indentation.
	string snippet;
	/// Markdown documentation for this snippet
	string documentation;
	/// Plain text to insert assuming global level indentation. Optional if snippet is a simple string only using plain variables and snippet locations.
	string plain;
	/// true if this snippet shouldn't be formatted before inserting.
	bool unformatted;

	/// Creates a resolved snippet based on this plain snippet, filling in plain if neccessary. This drops the levels value.
	/// Params:
	///     provider = the providerId to fill in
	Snippet buildSnippet(string provider) const
	{
		Snippet built;
		built.providerId = provider;
		built.title = this.title;
		built.shortcut = this.shortcut;
		built.documentation = this.documentation;
		built.snippet = this.snippet;
		built.plain = this.plain.length ? this.plain
			: this.snippet.replaceAll(ctRegex!`\$(\d+|[A-Z_]+|\{.*?\})`, "");
		built.resolved = true;
		built.unformatted = unformatted;
		return built;
	}
}

//dfmt off
static immutable PlainSnippet[] plainSnippets = [

	// entry points

	PlainSnippet(
		[SnippetLevel.global],
		"main",
		"void main(string[] args)",
		"void main(string[] args) {\n\t$0\n}",
		"Normal D entry point main function with arguments and no return value"
	),
	PlainSnippet(
		[SnippetLevel.global],
		"maini",
		"int main(string[] args)",
		"int main(string[] args) {\n\t${0:return 0;}\n}",
		"Normal D entry point main function with arguments and integer status return value"
	),
	PlainSnippet(
		[SnippetLevel.global],
		"mainc",
		"-betterC void main(int argc, const(char)** argv)",
		"void main(int argc, const(char)** argv) {\n\t$0\n}",
		"C entry point when using D with -betterC with no return value"
	),
	PlainSnippet(
		[SnippetLevel.global],
		"mainci",
		"-betterC int main(int argc, const(char)** argv)",
		"int main(int argc, const(char)** argv) {\n\t${0:return 0;}\n}",
		"C entry point when using D with -betterC with integer status return value"
	),

	// properties

	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"refproperty",
		"ref property as getter + setter",
		"ref ${3:auto} ${1:value}() @property { return ${2:_${1:value}}; }",
		"property returning a value as ref for use as getter & setter",
		"ref auto value() @property { return _value; }"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"getset",
		"getter + setter",
		"void ${1:value}(${3:auto} value) @property { ${2:_${1:value}} = value; }\n" ~
			"${3:auto} ${1:value}() @property const { return ${2:_${1:value}}; }",
		"separate methods for getter and setter",
		"void value(auto value) @property { _value = value; }\n" ~
			"auto value() @property const { return _value; }"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"get",
		"getter property",
		"${3:auto} ${1:value}() @property const { return ${2:_${1:value}}; }",
		"methods for a getter of any value",
		"auto value() @property const { return _value; }"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"set",
		"setter property",
		"void ${1:value}(${3:auto} value) @property { ${2:_${1:value}} = value; }",
		"method for use as setter for any value",
		"void value(auto value) @property { _value = value; }"
	),

	// operator overloading
	// todo: automatic generation of types and differences in classes

	PlainSnippet(
		[SnippetLevel.type],
		"opUnary",
		"auto opUnary!(op)()",
		"${1:auto} opUnary(string op)() {\n\t$0\n}",
		"Unary operators in form of `<op>this` which only work on this object.\n\n"
			~ "Overloadable unary operators: `-`, `+`, `~`, `*`, `++` (pre-increment), `--` (pre-decrement)\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#unary]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndexUnary",
		"auto opIndexUnary!(op)(index)",
		"${1:auto} opIndexUnary(string op)(${2:size_t index}) {\n\t$0\n}",
		"Unary operators in form of `<op>this[index1, index2...]` which only work on this object.\n\n"
			~ "Valid unary operators: `-`, `+`, `~`, `*`, `++` (pre-increment), `--` (pre-decrement)\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#index_unary_operators]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndexUnarySlice",
		"auto opIndexUnary!(op)(slice)",
		"${1:auto} opIndexUnary(string op)($2) {\n\t$0\n}",
		"Unary operators in form of `<op>this[start .. end]` or `<op>this[]` which only work on this object.\n\n"
			~ "Valid unary operators: `-`, `+`, `~`, `*`, `++` (pre-increment), `--` (pre-decrement)\n\n"
			~ "The argument for this function is either empty to act on an entire slice like `<op>this[]` or a "
				~ "helper object returned by `opSlice`.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#slice_unary_operators]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opSliceUnary",
		"auto opSliceUnary!(op)(slice)",
		"${1:auto} opSliceUnary(string op)(${2:size_t start, size_t end}) {\n\t$0\n}",
		"Unary operators in form of `<op>this[start .. end]` or `<op>this[]` which only work on this object.\n\n"
			~ "Valid unary operators: `-`, `+`, `~`, `*`, `++` (pre-increment), `--` (pre-decrement)\n\n"
			~ "The argument for this function is either empty to act on an entire slice like `<op>this[]` or "
				~ "the start and end indices to operate on.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#slice_unary_operators]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opCast",
		"T opCast!(T)()",
		"${1:T} opCast(${1:T})() const {\n\t$0\n}",
		"Explicit cast operator in form of `cast(<T>)this` which works on this object.\n\n"
			~ "Used when explicitly casting to any type or when implicitly casting to bool.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#cast]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opCastBool",
		"bool opCast!(T : bool)()",
		"bool opCast(T : bool)() const {\n\t$0\n}",
		"Explicit cast operator in form of `cast(bool)this` or implicit boolean conversion with "
			~ "`!!this` or `if (this)` which works on this object.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#boolean_operators]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opBinary",
		"auto opBinary(rhs)",
		"${1:auto} opBinary(string op, R)(${2:const R rhs}) const {\n\t$0\n}",
		"Binary operators in form of `this <op> rhs` which return a new instance based off this object.\n\n"
			~ "Overloadable binary operators: `+`, `-`, `*`, `/`, `%`, `^^`, `&`, `|`, `^`, `<<`, `>>`, `>>>`, `~`, `in`\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#binary]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opBinaryRight",
		"auto opBinaryRight(lhs)",
		"${1:auto} opBinaryRight(string op, L)(${2:const L lhs}) const {\n\t$0\n}",
		"Binary operators in form of `lhs <op> this` which return a new instance based off this object.\n\n"
			~ "Overloadable binary operators: `+`, `-`, `*`, `/`, `%`, `^^`, `&`, `|`, `^`, `<<`, `>>`, `>>>`, `~`, `in`\n\n"
			~ "This overload has the same importance as opBinary. It is an error if both opBinary and opBinaryRight match with "
				~ "the same specificity.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#binary]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opEquals",
		"bool opEquals(other) in struct",
		"bool opEquals(R)(${1:const R other}) const {\n\t$0\n}",
		"Equality operators in form of `this == other` or `other == this` and also used for `!=`.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#equals]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opEqualsClass",
		"bool opEquals(other) in class",
		"override bool opEquals(${1:Object other}) {\n\t$0\n}",
		"Equality operators in form of `this == other` or `other == this` and also used for `!=`.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#equals]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"toHash",
		"size_t toHash() in struct",
		"size_t toHash() const @nogc @safe pure nothrow {\n\t$0\n}",
		"Hash generation for associative arrays.\n\n"
			~ "Reference: [https://dlang.org/spec/hash-map.html#using_struct_as_key]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"toHashClass",
		"size_t toHash() in class",
		"override size_t toHash() const @nogc @safe pure nothrow {\n\t$0\n}",
		"Hash generation for associative arrays.\n\n"
			~ "Reference: [https://dlang.org/spec/hash-map.html#using_classes_as_key]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"toString",
		"string toString() in struct",
		"string toString() const @safe pure nothrow {\n\t$0\n}",
		"Overriding how objects are serialized to strings with std.conv and writeln.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_format.html#.formatValue]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"toStringText",
		"string toString() in struct using std.conv:text",
		"string toString() const @safe {\n\timport std.conv : text;\n\n\treturn text($0);\n}",
		"Overriding how objects are serialized to strings with std.conv and writeln.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_format.html#.formatValue]"
	),
	// these don't get added as they are too error-prone (get silently ignored when there is a compilation error inside of them)
	// PlainSnippet(
	// 	[SnippetLevel.type],
	// 	"toStringApp",
	// 	"toString(ref W w) in struct with appender",
	// 	"void toString(W)(ref W w) {\n\t$0\n}",
	// 	"Overriding how objects are serialized to strings with std.conv and writeln.\n\n"
	// 		~ "This overload uses an appender as the first argument which allows the developer to avoid concatenation and GC use.\n\n"
	// 		~ "Reference: [https://dlang.org/phobos/std_format.html#.formatValue]"
	// ),
	// PlainSnippet(
	// 	[SnippetLevel.type],
	// 	"toStringAppSpec",
	// 	"toString(ref W w, FormatSpec) in struct with appender and format spec",
	// 	"void toString(W)(ref W w, scope const ref FormatSpec fmt) {\n\t$0\n}",
	// 	"Overriding how objects are serialized to strings with std.conv and writeln.\n\n"
	// 		~ "This overload uses an appender as the first argument which allows the developer to avoid concatenation and GC use.\n\n"
	// 		~ "Reference: [https://dlang.org/phobos/std_format.html#.formatValue]"
	// ),
	PlainSnippet(
		[SnippetLevel.type],
		"toStringClass",
		"string toString() in class",
		"override string toString() const @safe pure nothrow {\n\t$0\n}",
		"Overriding how objects are serialized to strings with std.conv and writeln.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_format.html#.formatValue]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"toStringTextClass",
		"string toString() in class using std.conv:text",
		"override string toString() const @safe {\n\timport std.conv : text;\n\n\treturn text($0);\n}",
		"Overriding how objects are serialized to strings with std.conv and writeln.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_format.html#.formatValue]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opCmp",
		"int opCmp(other) in struct",
		"int opCmp(R)(${1:const R other}) const {\n\t$0\n}",
		"Comparision operator in form of `this.opCmp(rhs) < 0` for `<`, `<=`, `>` and `>=`.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#compare]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opCmpClass",
		"int opCmp(other) in class",
		"override int opCmp(${1:Object other}) {\n\t$0\n}",
		"Comparision operator in form of `this.opCmp(rhs) < 0` for `<`, `<=`, `>` and `>=`.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#compare]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opCall",
		"auto opCall(args)",
		"${1:auto} opCall($2) {\n\t$0\n}",
		"Calling operator in form of `this(args)`.\n\n"
			~ "Note that inside a struct this automatically disables the struct literal syntax. "
				~ "You need to declare a constructor which takes priority to avoid this limitation.\n\n"
			~ "This operator can be overloaded statically too to mimic constructors as normal calls.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#function-call]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opAssign",
		"auto opAssign(value)",
		"auto opAssign(T)(${1:T value}) {\n\t$0\n\treturn this;\n}",
		"Assignment operator overload in form of `this = value`.\n\n"
			~ "For classes `value` may not be of the same type as `this` (identity assignment). However other values "
				~ "are still allowed. For structs no such restriction exists.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#assignment]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndexAssign",
		"auto opIndexAssign(value, indices...)",
		"auto opIndexAssign(T)(${1:T value}, ${2:size_t index}) {\n\t${0:return value;}\n}",
		"Assignment operator overload in form of `this[index1, index2...] = value`.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#index_assignment_operator]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndexAssignSlice",
		"auto opIndexAssign(value, slice)",
		"auto opIndexAssign(T)(${1:T value}) {\n\t${0:return value;}\n}",
		"Assignment operator overload in form of `this[start .. end] = value` or `this[] = value`.\n\n"
			~ "The argument for this function is either empty to act on an entire slice like `this[] = value` or a "
				~ "helper object returned by `opSlice` after the value to assign.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#index_assignment_operator]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opSliceAssign",
		"auto opSliceAssign(value, slice)",
		"auto opSliceAssign(T)(${1:T value}, ${2:size_t start, size_t end}) {\n\t${0:return value;}\n}",
		"Assignment operator overload in form of `this[start .. end] = value` or `this[] = value`.\n\n"
			~ "The argument for this function is either empty to act on an entire slice like `this[] = value` "
				~ "or the start and end indices after the value to assign.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#index_assignment_operator]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opOpAssign",
		"auto opOpAssign!(op)(value)",
		"auto opOpAssign(string op, T)(${1:T value}) {\n\t$0;\n\treturn this;\n}",
		"Operator assignment operator overload in form of `this op= value`.\n\n"
			~ "Overloadable operators: `+=`, `-=`, `*=`, `/=`, `%=`, `^^=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`, `~=`\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#op-assign]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndexOpAssign",
		"auto opIndexOpAssign!(op)(value, index)",
		"auto opIndexOpAssign(string op, T)(${1:T value}, ${2:size_t index}) {\n\t${0:return value;}\n}",
		"Operator index assignment operator overload in form of `this[index1, index2...] op= value`.\n\n"
			~ "Overloadable operators: `+=`, `-=`, `*=`, `/=`, `%=`, `^^=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`, `~=`\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#index_op_assignment]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndexOpAssignSlice",
		"auto opIndexOpAssign!(op)(value, slice)",
		"auto opIndexOpAssign(string op, T)(${1:T value}) {\n\t${0:return value;}\n}",
		"Operator index assignment operator overload in form of `this[start .. end] op= value`.\n\n"
			~ "Overloadable operators: `+=`, `-=`, `*=`, `/=`, `%=`, `^^=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`, `~=`\n\n"
			~ "The argument for this function is either empty to act on an entire slice like `this[] op= value` or a "
				~ "helper object returned by `opSlice` after the value to assign.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#slice_op_assignment]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opSliceOpAssign",
		"auto opSliceOpAssign!(op)(value, start, end)",
		"auto opSliceOpAssign(string op, T)(${1:T value}, ${2:size_t start, size_t end}) {\n\t${0:return value;}\n}",
		"Operator index assignment operator overload in form of `this[start .. end] op= value`.\n\n"
			~ "Overloadable operators: `+=`, `-=`, `*=`, `/=`, `%=`, `^^=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `>>>=`, `~=`\n\n"
			~ "The argument for this function is either empty to act on an entire slice like `this[] = value` "
				~ "or the start and end indices after the value to assign.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#slice_op_assignment]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opIndex",
		"auto opIndex(index)",
		"${1:ref auto} opIndex(${2:size_t index}) {\n\t$0\n}",
		"Array index operator overload in form of `this[index1, index2...]`.\n\n"
			~ "Indices may specify any type and may also be the helper objects returned by opSlice.\n\n"
			~ "Leaving the index arguments empty means this returns a slice of the whole object. (often a shallow copy)\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#array-ops]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opSlice",
		"auto opSlice(index)",
		"${1:size_t[2]} opSlice(${2:size_t start, size_t end}) {\n\t${0:return [start, end];}\n}",
		"Array slice operator overload in form of `this[start .. end]`.\n\n"
			~ "`opSlice` returns a helper object which is used in the index methods to operate on. "
				~ "It does not return the value of the array slice result, use opIndex for this.\n\n"
			~ "This snippet defines an overload for any dimension of the array (any comma count), "
				~ "use `opSliceN` for any dimensionality.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#array-ops]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opSliceN",
		"auto opSlice!(n)(index)",
		"${1:size_t[2]} opSlice(size_t dim : ${2:0})(${3:size_t start, size_t end}) {\n\t${0:return [start, end];}\n}",
		"Array slice operator overload in form of `this[start .. end]`.\n\n"
			~ "`opSlice` returns a helper object which is used in the index methods to operate on. "
				~ "It does not return the value of the array slice result, use opIndex for this.\n\n"
			~ "This snippet defines an overload for n-th dimension of the array, meaning this is the "
				~ "`n`th value in the comma separated index list, starting at n=0.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#array-ops]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opDollar",
		"auto opDollar()",
		"${1:size_t} opDollar() {\n\t${0:return length;}\n}",
		"Dollar operator overload in form of `this[$]`.\n\n"
			~ "`opDollar` returns a the value which the dollar sign in the index call returns. "
				~ "Commonly this is the length of the array.\n\n"
			~ "This snippet defines an overload for any dimension of the array (any comma count), "
				~ "use `opDollarN` for any dimensionality.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#array-ops]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opDollarN",
		"auto opDollar!(n)()",
		"${1:size_t} opDollar(size_t dim : ${2:0})() {\n\t${0:return length;}\n}",
		"Dollar operator overload in form of `this[$]`.\n\n"
			~ "`opDollar` returns a the value which the dollar sign in the index call returns. "
				~ "Commonly this is the length of the array.\n\n"
			~ "This snippet defines an overload for n-th dimension of the array, meaning this is the "
				~ "`n`th length in the comma separated index list, starting at n=0.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#array-ops]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opDispatch",
		"auto opDispatch!(member)()",
		"${1:auto} opDispatch(${2:string member})() {\n\t$0\n}",
		"Compile-Time dynamic dispatch operator forwarding unknown member calls and properties in form of `this.member`.\n\n"
			~ "`opDispatch` will be executed for any method call or property access not matching another one. This should "
				~ "be used on special wrapper types without many other fields to avoid false calls in case of non-matching "
				~ "overloads. Defining this operator may also cause issues when trying to use CTFE functions with matching "
				~ "names.\n\n"
			~ "Reference: [https://dlang.org/spec/operatoroverloading.html#dispatch]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opApply",
		"int opApply(dg)",
		"int opApply(scope int delegate(${1:ref Item}) ${2:dg}) {\n"
			~ "\tint result = 0;\n"
			~ "\n"
			~ "\t${3:foreach (item; array)} {\n"
			~ "\t\tresult = dg(item);\n"
			~ "\t\tif (result)\n"
			~ "\t\t\tbreak;\n"
			~ "\t}\n"
			~ "\n"
			~ "\treturn result;\n"
			~ "}",
		"Explicit foreach overload when calling `foreach (items...; this)`.\n\n"
			~ "Note that you can also implement this functionality through a forward range."
				~ "`opApply` has higher precedence over range functionality.\n\n"
			~ "Reference: [https://dlang.org/spec/statement.html#foreach_over_struct_and_classes]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"opApplyReverse",
		"int opApplyReverse(dg)",
		"int opApplyReverse(scope int delegate(${1:ref Item}) ${2:dg}) {\n"
			~ "\tint result = 0;\n"
			~ "\n"
			~ "\t${3:foreach_reverse (item; array)} {\n"
			~ "\t\tresult = dg(item);\n"
			~ "\t\tif (result)\n"
			~ "\t\t\tbreak;\n"
			~ "\t}\n"
			~ "\n"
			~ "\treturn result;\n"
			~ "}",
		"Explicit foreach overload when calling `foreach_reverse (items...; this)`.\n\n"
			~ "Note that you can also implement this functionality through a backward range. "
				~ "`opApplyReverse` has higher precedence over range functionality.\n\n"
			~ "Reference: [https://dlang.org/spec/statement.html#foreach_over_struct_and_classes]"
	),

	// Exception snippets

	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"Exception",
		"class MyException : Exception",
		"class ${1:MyException} : ${2:Exception} {\n"
			~ "\tthis(${3:string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null}) pure nothrow @nogc @safe {\n"
			~ "\t\tsuper(${4:msg, file, line, nextInChain});\n"
			~ "\t}\n"
			~ "}\n$0",
		"Class extending Exception. Use this for recoverable errors that may be catched in the application.\n\n"
			~ "Reference: [https://dlang.org/phobos/object.html#.Exception]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"Error",
		"class MyError : Error",
		"class ${1:MyError} : ${2:Error} {\n"
			~ "\tthis(${3:string msg, Throwable nextInChain = null}) pure nothrow @nogc @safe {\n"
			~ "\t\tsuper(${4:msg, nextInChain});\n"
			~ "\t}\n"
			~ "}\n$0",
		"Class extending Error. Use this for unrecoverable errors that applications should not catch.\n\n"
			~ "Reference: [https://dlang.org/phobos/object.html#.Exception]"
	),

	// Block keywords
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type],
		"unittest",
		"unittest",
		"unittest {\n\t$0\n}",
		"Defines a unittest block, which is a method that tests a part of the code in isolation. Unittests can be run with DUB using `dub test`. "
			~ "Unittests most often contain calls to assert to test results or throw exceptions for code that is not working as expected.\n\n"
			~ "Do NOT use inside templates / templated types (classes, structs, etc.) as they will not be run!\n\n"
			~ "Reference: [https://dlang.org/spec/unittest.html]"
	),
	PlainSnippet(
		[SnippetLevel.method],
		"assert",
		"assert",
		"assert($0);",
		"Enforces that the given expression in the first argument evaluates to `true`. "
			~ "If it does not evaluate to `true`, an AssertError will be thrown and an optional second argument may be passed as explanation message what went wrong.\n\n"
			~ "Asserts are not emitted at all in DUB release builds. Therefore **expressions in the first argument may not be run**. "
			~ "Don't use expressions like ~~`assert(i++)`~~ outside unittests and contracts as they might introduce bugs when building in release mode.\n\n"
			~ "```d\n"
			~ "assert(complexAlgorithm() == 4, \"an error message\");\n"
			~ "```\n\n"
			~ "Reference: [https://dlang.org/spec/expression.html#AssertExpression]",
		null, true
	),

	// Builtin Types (keywords)
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"import",
		"import module",
		"import ${1:std};\n$0",
		"Imports a module given a name.\n\nReference: [https://dlang.org/spec/module.html#import-declaration]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"class",
		"class MyClass",
		"class ${1:MyClass} {\n\t$0\n}",
		"Defines a simple class type.\n\nReference: [https://dlang.org/spec/class.html]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"interface",
		"interface MyInterface",
		"interface ${1:MyInterface} {\n\t$0\n}",
		"Defines a simple interface type.\n\nReference: [https://dlang.org/spec/interface.html]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"struct",
		"struct MyStruct",
		"struct ${1:MyStruct} {\n\t$0\n}",
		"Defines a simple struct type.\n\nReference: [https://dlang.org/spec/struct.html]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"union",
		"union MyUnion",
		"union ${1:MyUnion} {\n\t$0\n}",
		"Defines a simple union type.\n\nReference: [https://dlang.org/spec/struct.html]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"template",
		"template MyTemplate()",
		"template ${1:MyTemplate}($2) {\n\t$0\n}",
		"Defines a simple union type.\n\nReference: [https://dlang.org/spec/struct.html]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"enums",
		"enum MyEnum { ... }",
		"enum ${1:MyEnum} {\n\t${0:init,}\n}",
		"Defines a simple enumeration.\n\nReference: [https://dlang.org/spec/enum.html]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"enumv",
		"enum EnumValue = ...",
		"enum ${1:EnumValue} = $2;\n$0",
		"Defines a simple compile time constant using enum.\n\nReference: [https://dlang.org/spec/enum.html#manifest_constants]"
	),

	// Types using phobos or some code idioms
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"typedef",
		"typedef MyType : BaseType",
		"enum ${1:MyType} : ${2:BaseType} {\n\t${0:init = 0}\n}",
		"Creates a typesafe alias not allowing implicit casting from base type, but allows implicit conversion to "
			~ "the base type in most cases. Therefore the implicit casting works a lot like class/interface inheritance.\n\n"
			~ "Reference: (17.1.5) [https://dlang.org/spec/enum.html#named_enums]"
	),
	PlainSnippet(
		[SnippetLevel.global, SnippetLevel.type, SnippetLevel.method],
		"Proxy",
		"struct MyType { mixin Proxy }",
		"struct ${1:MyType} {\n\t${2:BaseType} base;\n\tmixin Proxy!(${2:BaseType});\n}",
		"Creates a typesafe alias not allowing implicit casting to the base type, but allows implicit conversion "
				~ "from the base type in most cases. Basically allows copying any base type with new properties and "
				~ "methods as new and separate type. Imports `std.typecons : Proxy`.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_typecons.html#Proxy]"
	),
	PlainSnippet(
		[SnippetLevel.global],
		"IUnknown",
		"interface COMInterface : IUnknown",
		"interface ${1:COMInterface} : IUnknown {\nextern(Windows):\n\t$0\n}",
		"Win32 COM interface without implementation to talk to other applications.\n\n"
			~ "Reference: [https://wiki.dlang.org/COM_Programming]"
	),
	PlainSnippet(
		[SnippetLevel.global],
		"ComObject",
		"class MyObject : ComObject",
		"class ${1:MyObject} : ComObject {\nextern(Windows):\n\t$0\n}",
		"Win32 COM interface with implementation to serve to other applications.\n\n"
			~ "Reference: [https://wiki.dlang.org/COM_Programming]"
	),

	// range methods

	PlainSnippet(
		[SnippetLevel.type],
		"InputRange",
		"InputRange (popFront, empty, front)",
		"${1:auto} front() @property { ${2:return myElement;} }\n"
			~ "bool empty() @property const { ${3:return true;} }\n"
			~ "void popFront() { $4 }\n$0",
		"Implements an input range for iteration support in range functions and foreach.\n\n"
			~ "Functions can only iterate over an InputRange exactly one time.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isInputRange]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"OutputRange",
		"OutputRange (put)",
		"void put(${1:Item} item) {\n\t$2\n}\n$0",
		"Implements the put function which allows to put one or more items into this range.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isOutputRange]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"ForwardRange",
		"ForwardRange (InputRange, save)",
		"${1:auto} front() @property { ${2:return myElement;} }\n"
			~ "bool empty() @property const { ${3:return true;} }\n"
			~ "void popFront() { $4 }\n"
			~ "typeof(this) save() { ${5:return this;} }\n$0",
		"Implements a forward range for iteration support in range functions and foreach.\n\n"
			~ "As opposed to InputRange this supports iterating over the same range multiple times.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isForwardRange]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"InfiniteRange",
		"InfiniteRange (empty = false)",
		"enum bool empty = false;\n$0",
		"Makes this range appear as infinite by adding `empty` as always `false` enum constant value.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isInfinite]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"BidirectionalRange",
		"BidirectionalRange (InputRange, back, popBack)",
		"${1:auto} front() @property { ${2:return myElement;} }\n"
			~ "${1:auto} back() @property { ${3:return myElement;} }\n"
			~ "bool empty() @property const { ${4:return true;} }\n"
			~ "void popFront() { $5 }\n"
			~ "void popBack() { $6 }\n$0",
		"Implements a bidirectional range for iteration support in range functions, foreach and foreach_reverse.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isBidirectionalRange]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"RandomAccessRange",
		"RandomAccessRange (BidirectionalRange, opIndex, length)",
		"${1:auto} front() @property { ${2:return myElement;} }\n"
			~ "${1:auto} back() @property { ${3:return myElement;} }\n"
			~ "bool empty() @property const { ${4:return true;} }\n"
			~ "void popFront() { $5 }\n"
			~ "void popBack() { $6 }\n"
			~ "ref ${1:auto} opIndex(${7:size_t index}) { $8 }\n"
			~ "size_t length() { $9 }\n"
			~ "alias opDollar = length;$0",
		"Implements a bidirectional range with random access indexing support for full array emulation.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isBidirectionalRange]"
	),
	PlainSnippet(
		[SnippetLevel.type],
		"RandomAccessRangeInf",
		"RandomAccessRange (InfiniteForwardRange, opIndex)",
		"${1:auto} front() @property { ${2:return myElement;} }\n"
			~ "enum bool empty = false;\n"
			~ "void popFront() { $3 }\n"
			~ "${1:auto} opIndex(${4:size_t index}) { $5 }\n$0",
		"Implements an infinite forward range with random access indexing support.\n\n"
			~ "Reference: [https://dlang.org/phobos/std_range_primitives.html#isBidirectionalRange]"
	),
	PlainSnippet(
		[SnippetLevel.method],
		"debug_writeln",
		"debug try-catch writeln",
		`debug { import std.stdio : writeln; try { writeln("$1"); } catch (Exception) {} }$0`,
		"A `writeln` call in a debug block with try-catch wrapping around it.\n\n"
			~ "Useful to do a debug output inside a pure or nothrow function.",
		null, true
	),
	PlainSnippet(
		[SnippetLevel.method],
		"debug_writefln",
		"debug try-catch writefln",
		`debug { import std.stdio : writefln; try { writefln!"$1"($2); } catch (Exception) {} }$0`,
		"A `writefln` call in a debug block with try-catch wrapping around it.\n\n"
			~ "Useful to do a debug output inside a pure or nothrow function.",
		null, true
	),
	PlainSnippet(
		[SnippetLevel.method],
		"debug_printf",
		"debug try-catch printf",
		`debug { import core.stdc.stdio : printf; printf("$1\\n"); }$0`,
		"A `printf` call in a debug block.\n\n"
			~ "Useful to do a debug output inside a pure, nothrow or @nogc function.",
		null, true
	),
];
//dfmt on

class PlainSnippetProvider : SnippetProvider
{
	protected Snippet[][SnippetLevel] prebuilt;

	this()
	{
		foreach (s; plainSnippets)
		{
			Snippet built = s.buildSnippet(typeid(this).name);

			foreach (level; s.levels)
				prebuilt[level] ~= built;
		}
	}

	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info)
	{
		Snippet[] ret;
		if (auto p = info.level in prebuilt)
			ret = *p;
		return Future!(Snippet[]).fromResult(ret);
	}

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet)
	{
		snippet.resolved = true;
		return Future!Snippet.fromResult(snippet);
	}
}
