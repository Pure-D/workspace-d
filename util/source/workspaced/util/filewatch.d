module workspaced.util.filewatch;

version (linux)
{
	import core.sys.linux.sys.inotify;
	enum FileWatchFlag : uint
	{
		Access = IN_ACCESS,
	    Modify = IN_MODIFY,
	    Attrib = IN_ATTRIB,
	    CloseWrite = IN_CLOSE_WRITE,
	    CloseNoWrite = IN_CLOSE_NOWRITE,
	    Open = IN_OPEN,
	    MovedFrom = IN_MOVED_FROM,
	    MovedTo = IN_MOVED_TO,
	    Create = IN_CREATE,
	    Delete = IN_DELETE,
	    DeleteSelf = IN_DELETE_SELF,
	    MoveSelf = IN_MOVE_SELF,
	    Umount = IN_UMOUNT,
	    QOverflow = IN_Q_OVERFLOW,
	    Ignored = IN_IGNORED,
	    Close = IN_CLOSE,
	    Move = IN_MOVE,
	    OnlyDir = IN_ONLYDIR,
	    DontFollow = IN_DONT_FOLLOW,
	    ExcludeUnlink = IN_EXCL_UNLINK,
	    MaskAdd = IN_MASK_ADD,
	    IsDir = IN_ISDIR,
	    OneShot = IN_ONESHOT,
	    AllEvents = IN_ALL_EVENTS,
	}
}

struct WatchedFile
{
	string file;
	bool isWatching;

	version (linux)
	{
		import core.sys.linux.sys.inotify;
		import core.sys.posix.unistd;
		import std.string;

		int fd, wd;
		char[(inotify_event.sizeof + 16) * 1024] buffer;

		this(string file, uint flags = IN_MODIFY)
		{
			import std.stdio : stderr;
			this.file = file;
			fd = inotify_init();
			stderr.writeln("inotify_init: ", fd);
			if (fd < 0)
				throw new Exception("Can't watch file!");

			wd = inotify_add_watch(fd, file.toStringz(), flags);
			stderr.writeln("inotify_add_watch: ", wd);
			isWatching = true;
		}

		~this()
		{
			stop();
		}

		void stop()
		{
			if(isWatching)
			{
				inotify_rm_watch(fd, wd);
				close(fd);
				isWatching = false;
			}
		}

		uint wait()
		{
			auto length = read(fd, buffer.ptr, buffer.length);
			inotify_event* event = cast(inotify_event*)&buffer.ptr[0];
			return event.mask;
		}
	}
	else
		static assert(0);
}

unittest
{
	import std.file;
	import core.thread;

	write("test.txt", "");
	WatchedFile fileWatch = "test.txt";
	new Thread({
		int timesChanged = 0;
		while (fileWatch.isWatching)
		{
			fileWatch.wait();
			timesChanged++;
		}
		assert(timesChanged == 3);
	});
	append("test.txt", "foo ");
	append("test.txt", "bar");
	write("test.txt", "hello world");
	fileWatch.stop();
	remove("test.txt");
}

unittest
{
	import std.file;
	import core.thread;

	write("test2.txt", "");
	auto fileWatch = WatchedFile("test2.txt");
	new Thread({
		int timesChanged = 0;
		while (fileWatch.isWatching)
		{
			auto event = fileWatch.wait();
			if (timesChanged == 0)
			{
				assert(event & FileWatchFlag.Modify);
			}
			else
			{
				assert(event & FileWatchFlag.DeleteSelf);
			}
			timesChanged++;
		}
		assert(timesChanged == 2);
	});
	append("test2.txt", "foo ");
	Thread.sleep(1.seconds);
	remove("test2.txt");
	Thread.sleep(1.seconds);
}
