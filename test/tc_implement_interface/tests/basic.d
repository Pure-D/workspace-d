module basic;

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