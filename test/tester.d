import std.exception;
import std.bitmanip;
import std.process;
import std.string;
import std.stdio;
import std.conv;
import std.json;
import std.uni;
import core.thread;
static import std.file;

bool isNumeric(in string s)
{
	if (s.length == 0)
		return false;
	foreach (c; s)
		if (!c.isNumber)
			return false;
	return true;
}

string readAll(File file)
{
	ubyte[1024] buf;
	string data;
	while (!file.eof)
		data ~= cast(string) file.rawRead(buf);
	return data;
}

void main(string[] args)
{
	import etc.linux.memoryerror;

	static if (is(typeof(registerMemoryErrorHandler)))
		registerMemoryErrorHandler();

	//dfmt off
	string[] preprogrammed = [
		/* 0  */`{"cmd":"load","components":["dub","dcd"],"dir":"` ~ std.file.getcwd() ~ `","port":9621}`,
		/* 1  */`{"cmd":"dub","subcmd":"list:dep"}`,
		/* 2  */`{"cmd":"dub","subcmd":"list:import"}`,
		/* 3  */`{"cmd":"dub","subcmd":"list:string-import"}`,
		/* 4  */`{"cmd":"dub","subcmd":"update"}`,
		/* 5  */`{"cmd":"dcd","subcmd":"setup-server"}`,
		/* 6  */`{"cmd":"dcd","subcmd":"add-imports","imports":["/usr/include/dmd/druntime/import","/usr/include/dmd/phobos"]}`,
		/* 7  */`{"cmd":"dcd","subcmd":"search-symbol","query":"toImpl"}`,
		/* 8  */`{"cmd":"dcd","subcmd":"find-declaration","pos":14,"code":"void main() {foo();} void foo() {}"}`,
		/* 9  */`{"cmd":"dcd","subcmd":"list-completion","pos":21,"code":"int integer; integer."}`,
		/* 10 */`{"cmd":"dcd","subcmd":"get-socketfile"}`,
		/* 11 */`{"cmd":"dcd","subcmd":"get-port"}`,
	];
	//dfmt on

	auto pipes = pipeProcess(["./workspace-d"] ~ args,
			Redirect.stdin | Redirect.stdout | Redirect.stderr);
	int requestID = 0;
	ubyte[4] intBuffer;
	ubyte[] dataBuffer;
	new Thread({
		while (!pipes.stderr.eof)
			write("Error: ", pipes.stderr.readln());
	}).start();
	while (true)
	{
		write("Enter JSON: ");
		string instr = readln().strip();
		if (instr.isNumeric)
			instr = preprogrammed[instr.to!int];
		ubyte[] input = cast(ubyte[]) instr;
		if (input.length == 0)
			continue;
		requestID++;
		input = nativeToBigEndian(requestID) ~ input;
		pipes.stdin.rawWrite(nativeToBigEndian(cast(int) input.length) ~ input);
		pipes.stdin.flush();
		dataBuffer = pipes.stdout.rawRead(intBuffer);
		assert(dataBuffer.length == 4, "Invalid buffer data");
		int length = bigEndianToNative!int(dataBuffer[0 .. 4]);

		assert(length >= 4, "Invalid request");

		dataBuffer = pipes.stdout.rawRead(intBuffer);
		assert(dataBuffer.length == 4, "Invalid buffer data");
		int receivedID = bigEndianToNative!int(dataBuffer[0 .. 4]);

		enforce(requestID == receivedID,
				"Processed invalid id! Got those bytes instead: " ~ cast(
					string) dataBuffer ~ pipes.stdout.readAll);

		dataBuffer.length = length - 4;
		dataBuffer = pipes.stdout.rawRead(dataBuffer);

		try
		{
			writeln(parseJSON(cast(string) dataBuffer).toPrettyString());
		}
		catch (Exception e)
		{
			writeln("[INVALID]: ", cast(string) dataBuffer);
		}
	}
}
