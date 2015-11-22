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
		if(_initialized)
			return;
		load(args);
		_initialized = true;
	}

	void deinitialize(JSONValue args)
	{
		if(!_initialized)
			return;
		unload(args);
		_initialized = false;
	}

private:
	bool _initialized = false;
}

static Component[string] components;
