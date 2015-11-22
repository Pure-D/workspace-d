import std.bitmanip;
import std.process;
import std.string;
import std.stdio;
import std.conv;
import std.file;
import std.uni;
import core.thread;

bool isNumeric(in string s)
{
	if(s.length == 0)
		return false;
	foreach(c; s)
		if(!c.isNumber)
			return false;
	return true;
}

void main(string[] args)
{
	import etc.linux.memoryerror;
	static if (is(typeof(registerMemoryErrorHandler)))
		registerMemoryErrorHandler();

	string[] preprogrammed = [
		`{"cmd":"load","components":["dub"],"dir":"` ~ getcwd() ~ `","port":9621}`,
		`{"cmd":"dub","subcmd":"list-dep"}`,
		`{"cmd":"dub","subcmd":"list-import"}`,
		`{"cmd":"dub","subcmd":"list-string-import"}`,
		`{"cmd":"dub","subcmd":"update"}`,
	];

	auto pipes = pipeProcess(["./workspace-d"] ~ args, Redirect.stdin | Redirect.stdout | Redirect.stderr);
	int requestID = 0;
	ubyte[4] intBuffer;
	ubyte[] dataBuffer;
	new Thread({
		while(!pipes.stderr.eof)
			write("Error: ", pipes.stderr.readln());
	}).start();
	while(true)
	{
		write("Enter JSON: ");
		string instr = readln().strip();
		if(instr.isNumeric)
			instr = preprogrammed[toImpl!int(instr)];
		ubyte[] input = cast(ubyte[]) instr;
		if(input.length == 0)
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

		assert(requestID == receivedID, "Processed invalid id!");

		dataBuffer.length = length - 4;
		dataBuffer = pipes.stdout.rawRead(dataBuffer);

		writeln("Received: ", cast(string) dataBuffer);
	}
}
