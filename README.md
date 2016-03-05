# workspace-d [![Build Status](https://travis-ci.org/Pure-D/workspace-d.svg?branch=master)](https://travis-ci.org/Pure-D/workspace-d)

workspace-d wraps dcd, dfmt and dscanner to one unified environment managed by dub.

It uses process pipes and json for communication.

## Installation

Install the desired extra programs (dcd, dfmt, dscanner) if using them.

```sh
git clone https://github.com/Pure-D/workspace-d.git
cd workspace-d
dub build --build=release
# or with debug information:
dub build
```

## Usage

For users:

* Visual Studio Code: [code-d](https://github.com/Pure-D/code-d)

For plugin developers:

First you need to start the process. It receives commands via stdin and strictly outputs via stdout. Debug information and errors go through stderr.

To send a command you need following structure:

```
[32 bit big endian data length + 4]
[32 bit big endian request id]
[JSON data]
```

You will get something back that looks like this:

```
[32 bit big endian data length + 4]
[32 bit big endian request id]
[JSON response]
```

The request id will be the same as the one that got sent in. Every request will get a response. If an exception occurs it sets "error" to true,
msg will be the exception message and exception will be the full string value of the exception.

For synchronous requests it's recommended to increase the request id for every request. Otherwise random will also work. It's important to unregister
for waiting for a response after receiving it as every request gets exactly one response.

To use the functionalities of workspace-d you first need to load the components.

For loading dub and dcd:

```json
{
	"cmd": "load",
	"components": ["dub", "dcd"],
	"dir: "/path/to/dir"
}
```

For every component there are different arguments. They also share some arguments like "dir" for the current working directory.

Some arguments are optional and some are required. In every code file for most components there is an init struct at the top of the code, where every
variable with a default value is optional.

For running command from a component like dub:

```json
{
	"cmd": "dub",
	"subcmd": "list:import"
}
```

This will return a JSON array of all import paths. For example:

```json
[
	"/path/to/component/src",
	"/path/to/dir/source"
]
```

Before running workspace-d commands one should make sure it is the correct version using the version command.
```json
Request:
{
	"cmd": "version"
}

Response:
{
	"major": 1,
	"minor": 0,
	"patch": 0
}
```

When stopping the plugin everything should be unloaded and the process should be stopped when done.

```json
{
	"cmd": "unload",
	"components": "*"
}
```

## [Component Documentation](http://workspaced.webfreak.org)