import std.algorithm;
import std.file;
import std.stdio;
import std.string;
import std.process;

import workspaced.api;
import workspaced.coms;

void main()
{
	string dir = getcwd;
	auto backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);
	backend.register!FSWorkspaceComponent;
	backend.register!DCDComponent;
	backend.register!DCDExtComponent;

	auto fsworkspace = backend.get!FSWorkspaceComponent(dir);
	auto dcd = backend.get!DCDComponent(dir);
	auto dcdext = backend.get!DCDExtComponent(dir);

	fsworkspace.addImports(["source"]);

	try
	{
		dcd.start();
	}
	catch (ProcessException e)
	{
		// dcd not installed
		stderr.writeln("WARNING: skipping test tc_implement_interface because DCD is not installed");
		stderr.writeln(e);
		return;
	}

	scope (exit)
		dcd.stopServerSync();

	string code = dcdext.implement(q{
class Bar : Foo
{
}

class Foo : Foo0
{
	void virtualMethod();
	abstract int abstractMethod(string s) { return cast(int) s.length; }
}

import std.container.array;
import std.typecons;
interface Foo0 : Foo1, Foo2
{
	string stringMethod();
	Tuple!(int, string, Array!bool)[][] advancedMethod(int a, int b, string c);
	void normalMethod();
	int attributeSuffixMethod() nothrow @property @nogc;
	extern(C) @property @nogc ref immutable int attributePrefixMethod() const;
	final void alreadyImplementedMethod() {}
	deprecated("foo") void deprecatedMethod() {}
	static void staticMethod() {}
	protected void protectedMethod();
private:
	void barfoo();
}

interface Foo1
{
	void hello();
	int nothrowMethod() nothrow;
	int nogcMethod() @nogc;
	nothrow int prefixNothrowMethod();
	@nogc int prefixNogcMethod();
}

interface Foo2
{
	void world();
}
	}, 14).getBlocking;

	writeln(code);

	assert(code.canFind("override int abstractMethod"));
	assert(code.canFind("string stringMethod"));
	assert(code.canFind("Tuple!(int, string, Array!bool)[][] advancedMethod(int a, int b, string c)"));
	assert(code.canFind("void normalMethod()"));
	assert(code.canFind("int attributeSuffixMethod() nothrow @property @nogc"));
	assert(code.canFind("extern (C) @property @nogc ref immutable int attributePrefixMethod() const"));
	assert(code.canFind("void deprecatedMethod()"));
	assert(code.canFind("protected void protectedMethod()"));
	assert(code.canFind("void hello()"));
	assert(code.canFind("int nothrowMethod() nothrow"));
	assert(code.canFind("int nogcMethod() @nogc"));
	assert(code.canFind("nothrow int prefixNothrowMethod()"));
	assert(code.canFind("@nogc int prefixNogcMethod()"));
	assert(code.canFind("void world()"));
}
