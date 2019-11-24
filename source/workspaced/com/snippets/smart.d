module workspaced.com.snippets.smart;

import workspaced.api;
import workspaced.com.snippets;

import std.conv;

class SmartSnippetProvider : SnippetProvider
{
	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info)
	{
		if (info.loopScope.supported)
		{
			Snippet[] res;
			if (info.loopScope.numItems > 1)
			{
				res ~= ndForeach(info.loopScope.numItems, info.loopScope.iterator);
				res ~= simpleForeach();
				res ~= stringIterators();
			}
			else if (info.loopScope.stringIterator)
			{
				res ~= simpleForeach();
				res ~= stringIterators(info.loopScope.iterator);
			}
			else
			{
				res ~= simpleForeach(info.loopScope.iterator, info.loopScope.type);
				res ~= stringIterators();
			}
			return Future!(Snippet[]).fromResult(res);
		}
		else
			return Future!(Snippet[]).fromResult(null);
	}

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet)
	{
		return Future!Snippet.fromResult(snippet);
	}

	Snippet ndForeach(int n, string name = null)
	{
		Snippet ret;
		ret.providerId = typeid(this).name;
		ret.id = "nd";
		ret.title = "foreach over " ~ n.to!string ~ " keys";
		if (name.length)
			ret.title ~= " (over " ~ name ~ ")";
		ret.shortcut = "foreach";
		ret.documentation = "Foreach over locally defined variable with " ~ n.to!string ~ " keys.";
		string keys;
		if (n == 2)
		{
			keys = "key, value";
		}
		else if (n <= 4)
		{
			foreach (i; 0 .. n - 1)
			{
				keys ~= cast(char)('i' + i) ~ ", ";
			}
			keys ~= "value";
		}
		else
		{
			foreach (i; 0 .. n - 1)
			{
				keys ~= "k" ~ (i + 1).to!string ~ ", ";
			}
			keys ~= "value";
		}

		if (name.length)
		{
			ret.plain = "foreach (" ~ keys ~ "; " ~ name ~ ") {\n\t\n}";
			ret.snippet = "foreach (${1:" ~ keys ~ "}; ${2:" ~ name ~ "}) {\n\t$0\n}";
		}
		else
		{
			ret.plain = "foreach (" ~ keys ~ "; map) {\n\t\n}";
			ret.snippet = "foreach (${1:" ~ keys ~ "}; ${2:map}) {\n\t$0\n}";
		}
		ret.resolved = true;
		return ret;
	}

	Snippet simpleForeach(string name = null, string type = null)
	{
		Snippet ret;
		ret.providerId = typeid(this).name;
		ret.id = "simple";
		ret.title = "foreach loop";
		if (name.length)
			ret.title ~= " (over " ~ name ~ ")";
		ret.shortcut = "foreach";
		ret.documentation = name.length
			? "Foreach over locally defined variable." : "Foreach over a variable or range.";
		string t = type.length ? type ~ " " : null;
		if (name.length)
		{
			ret.plain = "foreach (" ~ t ~ "key; " ~ name ~ ") {\n\t\n}";
			ret.snippet = "foreach (" ~ t ~ "${1:key}; ${2:" ~ name ~ "}) {\n\t$0\n}";
		}
		else
		{
			ret.plain = "foreach (" ~ t ~ "key; list) {\n\t\n}";
			ret.snippet = "foreach (" ~ t ~ "${1:key}; ${2:list}) {\n\t$0\n}";
		}
		ret.resolved = true;
		return ret;
	}

	Snippet stringIterators(string name = null)
	{
		Snippet ret;
		ret.providerId = typeid(this).name;
		ret.id = "str";
		ret.title = "foreach loop";
		if (name.length)
			ret.title ~= " (unicode over " ~ name ~ ")";
		else
			ret.title ~= " (unicode)";
		ret.shortcut = "foreach_utf";
		ret.documentation = name.length
			? "Foreach over locally defined variable." : "Foreach over a variable or range.";
		if (name.length)
		{
			ret.plain = "foreach (char key; " ~ name ~ ") {\n\t\n}";
			ret.snippet = "foreach (${1|char,wchar,dchar|} ${2:key}; ${3:" ~ name ~ "}) {\n\t$0\n}";
		}
		else
		{
			ret.plain = "foreach (char key; str) {\n\t\n}";
			ret.snippet = "foreach (${1|char,wchar,dchar|} ${2:key}; ${3:str}) {\n\t$0\n}";
		}
		ret.resolved = true;
		return ret;
	}
}
