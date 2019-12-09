module workspaced.com.snippets.dependencies;

import workspaced.api;
import workspaced.com.dub;
import workspaced.com.snippets;

import std.algorithm;

///
alias SnippetList = PlainSnippet[];

/// A list of dependencies usable in an associative array
struct DependencySet
{
	string[] sorted;

	void set(string[] deps)
	{
		deps.sort!"a<b";
		sorted = deps;
	}

	bool hasAll(string[] deps) const
	{
		deps.sort!"a<b";
		int a, b;
		while (a < sorted.length && b < deps.length)
		{
			const as = sorted[a];
			const bs = deps[b];
			const c = cmp(as, bs);

			if (c == 0)
			{
				a++;
				b++;
			}
			else if (c < 0)
				return false;
			else
				b++;
		}
		return a == sorted.length;
	}

	bool opEquals(const ref DependencySet other) const
	{
		return sorted == other.sorted;
	}

	size_t toHash() const @safe nothrow
	{
		size_t ret;
		foreach (v; sorted)
			ret ^= typeid(v).getHash((() @trusted => &v)());
		return ret;
	}
}

class DependencyBasedSnippetProvider : SnippetProvider
{
	SnippetList[DependencySet] snippets;

	void addSnippet(string[] requiredDependencies, PlainSnippet snippet)
	{
		DependencySet set;
		set.set(requiredDependencies);

		if (auto v = set in snippets)
			*v ~= snippet;
		else
			snippets[set] = [snippet];
	}

	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info)
	{
		if (!instance.has!DubComponent)
			return Future!(Snippet[]).fromResult(null);
		else
		{
			string id = typeid(this).name;
			auto dub = instance.get!DubComponent;
			return Future!(Snippet[]).async(delegate() {
				string[] deps;
				foreach (dep; dub.dependencies)
				{
					deps ~= dep.name;
					deps ~= dep.dependencies.keys;
				}
				Snippet[] ret;
				foreach (k, v; snippets)
				{
					if (k.hasAll(deps))
					{
						foreach (snip; v)
							if (snip.levels.canFind(info.level))
								ret ~= snip.buildSnippet(id);
					}
				}
				return ret;
			});
		}
	}

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet)
	{
		snippet.resolved = true;
		return Future!Snippet.fromResult(snippet);
	}
}

unittest
{
	DependencySet set;
	set.set(["vibe-d", "mir", "serve-d"]);
	assert(set.hasAll(["vibe-d", "serve-d", "mir"]));
	assert(set.hasAll(["vibe-d", "serve-d", "serve-d", "serve-d", "mir", "mir"]));
	assert(set.hasAll(["vibe-d", "serve-d", "mir", "workspace-d"]));
	assert(set.hasAll(["diet-ng", "vibe-d", "serve-d", "mir", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "serve-d", "mir", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "serve-d", "vibe-d", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "mir", "mir", "vibe-d", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "mir", "vibe-d", "workspace-d"]));

	set.set(null);
	assert(set.hasAll([]));
	assert(set.hasAll(["foo"]));
}
