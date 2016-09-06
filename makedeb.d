import std.stdio : writeln;
import std.file;
import std.path;
import std.conv;
import std.process;

static import std.stdio;

static import source.info;

void main()
{
	if (!exists("debs"))
		mkdir("debs");
	auto pkgVersion = source.info.Version[0].to!string ~ "."
		~ source.info.Version[1].to!string ~ "-" ~ source.info.Version[2].to!string;
	string pkgPath = "workspace-d_" ~ pkgVersion;
	if (exists("debs/" ~ pkgPath))
	{
		writeln("Package already exists, returning");
		return;
	}
	mkdir("debs/" ~ pkgPath);
	mkdir("debs/" ~ pkgPath ~ "/DEBIAN");
	write("debs/" ~ pkgPath ~ "/DEBIAN/control", `Package: workspace-d
Version: ` ~ pkgVersion ~ `
Section: base
Priority: optional
Architecture: amd64
Maintainer: WebFreak001 <workspace-d@webfreak.org>
Description: Wraps dcd, dfmt and dscanner to one unified environment managed by dub
`);
	mkdir("debs/" ~ pkgPath ~ "/usr");
	mkdir("debs/" ~ pkgPath ~ "/usr/local");
	mkdir("debs/" ~ pkgPath ~ "/usr/local/bin");
	writeln("Building workspace-d");
	spawnProcess(["dub", "build", "--build=release"]).wait;
	rename("workspace-d", "debs/" ~ pkgPath ~ "/usr/local/bin/workspace-d");
	writeln("Generating package in debs/ folder");
	spawnProcess(["dpkg-deb", "--build", pkgPath], std.stdio.stdin,
			std.stdio.stdout, std.stdio.stderr, null, Config.none, buildPath(getcwd, "debs")).wait;
	writeln("Done");
}
