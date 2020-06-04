module workspaced.com.cache;

import workspaced.api;
import workspaced.sourcecache;

@component("cache")
class CacheComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Resizes the source cache to hold at most this many files. Cache might
	/// only be cleared next time there is a write.
	void resize(size_t numFiles)
	{
		workspaced.sourceCache.fileCache.size = numFiles;
	}

	/// See $(REF cacheFile,workspaced,sourcecache,SourceCache)
	const(SourceCacheEntry) cacheFile(string path,
			const(ubyte)[] content = null)
	{
		return workspaced.sourceCache.cacheFile(path,
				content);
	}

	/// See $(REF removeEntry,workspaced,sourcecache,SourceCache)
	bool removeEntry(string path)
	{
		return workspaced.sourceCache.removeEntry(path);
	}

	/// See $(REF cacheRecursively,workspaced,sourcecache,SourceCache)
	int cacheRecursively(string path)
	{
		return cast(int) workspaced.sourceCache.cacheRecursively(
				path);
	}

}
