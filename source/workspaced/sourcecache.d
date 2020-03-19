module workspaced.sourcecache;

import cachetools;
import containers.treemap;
import dparse.lexer;
import dsymbol.string_interning;

import std.algorithm;
import std.array : array;
import std.datetime.systime;
import std.experimental.allocator.mallocator;
import std.experimental.allocator.typed;

struct SourceCache
{
	/// A path -> module & tokens mapping storing the last used files.
	CacheLRU!(string, SourceCacheEntry*) fileCache;
	/// A module -> path mapping for all files currently inside the cache.
	TreeMap!(string[], string) moduleMap;

	TypedAllocator!(Mallocator, AllocFlag.immutableShared) entryAllocator;

	@disable this(this);

	private StringCache* stringCache;

	void setup(StringCache* stringCache)
	{
		fileCache = new CacheLRU!(string, SourceCacheEntry*);
		fileCache.size = 2048;
		fileCache.enableCacheEvents();
		this.stringCache = stringCache;
	}

	/**
	 * Caches a file path with the given content. If no content is given, read the file instead.
	 *
	 * A missing file will be parsed fresh, existing files will be updated with the content or reread if neccessary.
	 *
	 * First providing content and then not providing content anymore will cause the content to stay unless the file modified time has changed since the content was set.
	 */
	ref SourceCacheEntry cacheFile(string path, const(ubyte)[] content = null)
	{
		auto existing = fileCache.get(path);
		SourceCacheEntry* value;
		if (!existing.isNull)
		{
			processEvents();
			value = existing.get();
			if (content.length)
				value.fromContent(path, content);
			else
				value.fromFile(path);
			return *value;
		}

		value = entryAllocator.make!SourceCacheEntry();
		assert(value);
		value.stringCache = stringCache;

		if (content.length)
			value.fromContent(path, content);
		else
			value.fromFile(path);

		moduleMap.insert(cast(string[]) value.moduleName, path);
		fileCache.put(path, value);
		processEvents();
		return *value;
	}

	/// Removes a given path from both the module map and the file cache.
	void removeEntry(string path)
	{
		fileCache.remove(path);
		processEvents();
	}

	/// Caches all .d and .di files in a given path recursively.
	/// If there are more files than the cache limit, this will do a lot of work and throw it away immediately again.
	void cacheRecursively(string path)
	{
		import std.file : dirEntries, getcwd, SpanMode;
		import std.path : buildNormalizedPath;

		auto normalized = buildNormalizedPath(getcwd, path);

		foreach (file; dirEntries(normalized, SpanMode.breadth))
			if (file.isFile && file.name.endsWith(".d", ".di"))
				cacheFile(file);
	}

	private void processEvents()
	{
		auto events = fileCache.cacheEvents();
		foreach (event; events)
		{
			if (event.event == EventType.Evicted || event.event == EventType.Removed)
			{
				auto moduleName = cast(string[]) event.val.moduleName;

				moduleMap.remove(moduleName);

				entryAllocator.dispose(event.val);
			}
		}
	}
}

struct SourceCacheEntry
{
	static assert(string.sizeof == istring.sizeof);

	istring[] moduleName;
	const(Token)[] tokens;
	const(ubyte)[] code;

	private StringCache* stringCache;
	private SysTime fileDate;
	private bool ownCode;

	~this()
	{
		if (ownCode)
		{
			destroy(code);
			ownCode = false;
		}
		destroy(moduleName);
		destroy(tokens);
	}

	private void reparse(string path)
	{
		destroy(tokens);
		LexerConfig config;
		config.stringBehavior = StringBehavior.source;
		config.fileName = path;
		tokens = getTokensForParser(code, config, stringCache);
		extractModuleName();
	}

	private void extractModuleName()
	{
		destroy(moduleName);
		size_t start = size_t.max;
		size_t end = size_t.max;
		foreach (i, token; tokens)
		{
			if (start != size_t.max)
				end = i;
			else if (token.type == tok!"module")
				start = i + 1;

			if (token.type == tok!";")
				break;
		}

		if (start == size_t.max || end == size_t.max)
			return;
		moduleName = tokens[start .. end].filter!(a => a.type == tok!"identifier")
			.map!(a => istring(a.text))
			.array;
	}

	void fromFile(string path)
	{
		import std.file : read;

		const modified = safeModifiedTime(path);
		if (modified == fileDate)
			return;

		if (ownCode)
			destroy(code);
		ownCode = true;
		fileDate = modified;
		code = cast(const(ubyte)[]) read(path);
		reparse(path);
	}

	void fromContent(string path, const(ubyte)[] content)
	{
		if (content is code)
			return;

		if (ownCode)
			destroy(code);
		ownCode = false;
		// avoids overrides from "fromFile" until file is actually saved
		fileDate = safeModifiedTime(path);
		code = content;
		reparse(path);
	}
}

private SysTime safeModifiedTime(string path)
{
	import std.file : timeLastModified, FileException;

	// TODO: platform specific faster nothrow alternatives (stat)

	try
		return timeLastModified(path);
	catch (FileException)
		return SysTime.init;
}

unittest
{
	StringCache stringCache = StringCache(32);
	SourceCache sc;
	sc.setup(&stringCache);

	auto entry = sc.cacheFile("/tmp/a.d", "module foo.bar; void main() {}");
	assert(cast(string[]) entry.moduleName == ["foo", "bar"]);
	assert(entry.tokens.length > 10);
}
