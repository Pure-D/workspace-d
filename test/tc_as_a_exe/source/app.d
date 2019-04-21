import std.bitmanip;
import std.conv;
import std.file;
import std.process;
import std.string;
import std.stdio;
import std.json;

version (assert)
{
}
else
	static assert(false, "Compile with asserts.");

void main()
{
	string dir = getcwd;
	JSONValue response;

	//scope backend = new WorkspaceD();
	auto backend = pipeProcess(["../../workspace-d"], Redirect.stdout | Redirect.stdin);

	//auto instance = backend.addInstance(dir);
	backend.stdin.writeRequest(1, `{"cmd": "new", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	assert(backend.stdout.readResponse(1).type == JSON_TYPE.TRUE);

	//backend.register!FSWorkspaceComponent;
	backend.stdin.writeRequest(2,
			`{"cmd": "load", "component": "fsworkspace", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	assert(backend.stdout.readResponse(2).type == JSON_TYPE.TRUE);

	//auto fsworkspace = backend.get!FSWorkspaceComponent(dir);
	//assert(instance.importPaths == [getcwd]);
	backend.stdin.writeRequest(3, `{"cmd": "import-paths", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	response = backend.stdout.readResponse(3);
	assert(response.type == JSON_TYPE.ARRAY);
	assert(response.array.length == 1);
	assert(response.array[0].type == JSON_TYPE.STRING);
	assert(response.array[0].str == getcwd);

	//fsworkspace.addImports(["source"]);
	backend.stdin.writeRequest(4,
			`{"cmd": "call", "component": "fsworkspace", "method": "addImports", "params": [["source"]], "cwd": ` ~ JSONValue(
				dir).toString ~ `}`);
	backend.stdout.readResponse(4);

	//assert(instance.importPaths == [getcwd, "source"]);
	backend.stdin.writeRequest(5, `{"cmd": "import-paths", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	response = backend.stdout.readResponse(5);
	assert(response.type == JSON_TYPE.ARRAY);
	assert(response.array.length == 2);
	assert(response.array[0].type == JSON_TYPE.STRING);
	assert(response.array[0].str == getcwd);
	assert(response.array[1].type == JSON_TYPE.STRING);
	assert(response.array[1].str == "source");
}

void writeRequest(File stdin, int id, JSONValue data)
{
	stdin.writeRequest(id, data.toString);
}

void writeRequest(File stdin, int id, string data)
{
	stdin.rawWrite((cast(uint) data.length + 4).nativeToBigEndian);
	stdin.rawWrite(id.nativeToBigEndian);
	stdin.rawWrite(data);
	stdin.flush();
	writefln("%s >> %s", id, data);
}

JSONValue readResponse(File stdout, int expectedId = 0x7F000001)
{
	ubyte[4] intBuf;
	uint length;
	int reqId;
	while (true)
	{
		stdout.rawRead(intBuf[]);
		length = intBuf.bigEndianToNative!uint;
		stdout.rawRead(intBuf[]);
		reqId = intBuf.bigEndianToNative!uint;
		if (expectedId != 0x7F000001 && expectedId != reqId)
		{
			writefln("%s << <skipped>", reqId);
			if (length > 4)
				stdout.seek(length - 4);
		}
		else
			break;
	}

	if (length > 4)
	{
		ubyte[] data = new ubyte[length - 4];
		stdout.rawRead(data);
		writefln("%s << %s", reqId, cast(char[]) data);
		return parseJSON(cast(char[]) data);
	}
	else
	{
		writefln("%s << <empty>", reqId);
		return JSONValue.init;
	}
}
