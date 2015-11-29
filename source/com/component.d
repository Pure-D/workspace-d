module workspaced.com.component;

import std.json;

class Component
{
public:
	abstract void load(JSONValue args);
	abstract void unload(JSONValue args);
	abstract JSONValue process(JSONValue args);

	@property auto initialized()
	{
		return _initialized;
	}

	void initialize(JSONValue args)
	{
		if (_initialized)
			return;
		load(args);
		_initialized = true;
	}

	void deinitialize(JSONValue args)
	{
		if (!_initialized)
			return;
		unload(args);
		_initialized = false;
	}

private:
	bool _initialized = false;
}

interface IImportPathProvider
{
	string[] importPaths();
}

interface IStringImportPathProvider
{
	string[] stringImportPaths();
}

static Component[string] components;
private static IImportPathProvider importPathProvider;
private static IStringImportPathProvider stringImportPathProvider;

void setImportPathProvider(IImportPathProvider provider)
{
	assert(importPathProvider is null, "Another import path provider is already set!");
	importPathProvider = provider;
}

void setStringImportPathProvider(IStringImportPathProvider provider)
{
	assert(stringImportPathProvider is null, "Another string import path provider is already set!");
	stringImportPathProvider = provider;
}

IImportPathProvider getImportPathProvider()
{
	return importPathProvider;
}

IStringImportPathProvider getStringImportPathProvider()
{
	return stringImportPathProvider;
}

string getString(JSONValue value, string key)
{
	auto ptr = key in value;
	assert(ptr, key ~ " not specified!");
	assert(ptr.type == JSON_TYPE.STRING, key ~ " must be a string!");
	return ptr.str;
}

auto getInt(JSONValue value, string key)
{
	auto ptr = key in value;
	assert(ptr, key ~ " not specified!");
	assert(ptr.type == JSON_TYPE.INTEGER, key ~ " must be a string!");
	return ptr.integer;
}

JSONValue get(JSONValue value, string key)
{
	auto ptr = key in value;
	assert(ptr, key ~ " not specified!");
	assert(ptr.type == JSON_TYPE.OBJECT, key ~ " must be an object!");
	return *ptr;
}
