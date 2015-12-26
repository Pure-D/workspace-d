# workspace-d

workspace-d wraps dcd, dfmt and dscanner to one unified environment managed by dub.

It uses process pipes and json for communication.

## Installation

Install the desired extra programs (dcd, dfmt, dscanner) if using them.

```sh
git clone https://github.com/WebFreak001/workspace-d.git
cd workspace-d
dub build --build=release
# or with debug information:
dub build
```

## Usage

For users:

* Visual Studio Code: [code-d](https://github.com/WebFreak001/code-d)

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

## Components

### dub

Load arguments:

| name | type                     | description |
|------|--------------------------|-------------|
| dir  |string                    | **Required** Working directory for dub (must be a valid package) |
|watchFile|bool                   | **Default: true** Automatically check for updates on dub.json (only works on Linux) |
|registerImportProvider|bool      | **Default: true** If this should be the component managing code import paths |
|registerStringImportProvider|bool| **Default: true** If this should be the component managing string import paths |

---

`subcmd: "update"`

**Arguments:** *none*

**Description:** Manually updates import and string import paths.

**Returns:** `boolean` Returns true whenever the current configuration has any import paths 

---

`subcmd: "upgrade"`

**Arguments:** *none*

**Description:** Runs dub upgrade.

---

`subcmd: "list:dep"`

**Arguments:** *none*

**Description:** Lists all dependencies as array.

**Returns:** `[{dependencies: [string], ver: string, name: string}]`

---

`subcmd: "list:import"`

**Arguments:** *none*

**Description:** Lists all import paths as string array.

**Returns:** `[string]`

---

`subcmd: "list:string-import"`

**Arguments:** *none*

**Description:** Lists all string import paths as string array.

**Returns:** `[string]`

---

`subcmd: "list:configurations"`

**Arguments:** *none*

**Description:** Lists all available configurations.

**Returns:** `[string]`

---

`subcmd: "set:configuration"`

**Arguments:** configuration: string

**Description:** Sets the current configuration used for dub commands. Might require calling update.

---

`subcmd: "get:configuration"`

**Arguments:** *none*

**Description:** Returns the current configuration.

**Returns:** `string`

---

`subcmd: "set:build-type"`

**Arguments:** build-type: string

**Description:** Sets the current build type used for dub commands. Might require calling update.

---

`subcmd: "get:build-type"`

**Arguments:** *none*

**Description:** Returns the current build type.

**Returns:** `string`

---

`subcmd: "set:compiler"`

**Arguments:** compiler: string

**Description:** Sets the compiler. Valid values: `dmd` `gdc` `ldc`

---

`subcmd: "get:compiler"`

**Arguments:** *none*

**Description:** Returns the compiler.

**Returns:** `string`

---

`subcmd: "get:name"`

**Arguments:** *none*

**Description:** Returns the package name.

**Returns:** `string`

---

`subcmd: "get:path"`

**Arguments:** *none*

**Description:** Returns the project path of the package.

**Returns:** `string`

### dcd

Load arguments:

| name | type   | description |
|------|--------|-------------|
| dir  |string  | **Required** Working directory for dcd |
| port |bool    | **Default: 9166** Port to start server on. If autoStart is enabled it will throw an error when something is already running on that port. |
|clientPath|bool| **Default: dcd-client** Executable path of dcd-client or name if in PATH |
|serverPath|bool| **Default: dcd-server** Executable path of dcd-server or name if in PATH |
|autoStart|bool | **Default: true** If DCD should start on loading. Should be false if using `setup-server` |

---

`subcmd: "status"`

**Arguments:** *none*

**Description:** Queries the server status on selected port.

---

`subcmd: "setup-server"`

**Arguments:** *none*

**Description:** Starts the server and adds import paths from an import path provider.

---

`subcmd: "start-server"`

**Arguments:** *none*

**Description:** Starts the server on selected port.

---

`subcmd: "stop-server"`

**Arguments:** *none*

**Description:** Stops the server using `dcd-client --shutdown`.

---

`subcmd: "kill-server"`

**Arguments:** *none*

**Description:** Kills the server using a kill signal.

---

`subcmd: "restart-server"`

**Arguments:** *none*

**Description:** Stops the server and then starts it again.

---

`subcmd: "find-and-select-port"`

**Arguments:** port: int (start port)

**Description:** Automatically finds a port without a running DCD instance and selects it.

---

`subcmd: "list-completion"`

**Arguments:**

code: string (Current code in the editor)

pos: int (Byte position where code should be completed)

**Description:** Queries completion for current code.

**Returns:** `{type:string}` where type is either identifiers, calltips or raw.

When identifiers: `{type:"identifiers", identifiers:[{identifier:string, type:string}]}`

When calltips: `{type:"calltips", calltips:[string]}`

When raw: `{type:"raw", raw:[string]}`

Raw is anything else than identifiers and calltips.

---

`subcmd: "get-documentation"`

**Arguments:**

code: string (Current code in the editor)

pos: int (Byte position where code should be completed)

**Description:** Returns the documentation or empty string for the symbol at given position.

---

`subcmd: "find-declaration"`

**Arguments:**

code: string (Current code in the editor)

pos: int (Byte position where code should be completed)

**Description:** Finds the declaration of symbol at given position and returns `[string, int]` (file, byte position).

---

`subcmd: "search-symbol"`

**Arguments:** query: string

**Description:** Searches for a query through all import files. Returns `[{file: string, position: int, type: string}]`

---

`subcmd: "refresh-imports"`

**Arguments:** *none*

**Description:** Adds import paths from an import path provider.

---

`subcmd: "add-imports"`

**Arguments:** imports: [string]

**Description:** Adds the specified imports for DCD. This should be called with default phobos import paths at startup.

### dscanner

Load arguments:

| name | type         | description |
|------|--------------|-------------|
| dir  | string       | **Required** Working directory for dscanner |
|dscannerPath| string | **Default: dscanner** Executable path of dscanner or name if in PATH |

---

`subcmd: "lint"`

**Arguments:** file: string

**Description:** Statically checks *file* for errors. Returns `[{file: string, line: int, column: int, type: string, description: string}]`.

---

`subcmd: "list-definitions"`

**Arguments:** file: string

**Description:** Lists all symbol definitions from a file as `[{name: string, line: int, type: string, attributes: string[string]}]`.

### dfmt

Load arguments:

| name | type     | description |
|------|----------|-------------|
| dir  | string   | **Required** Working directory for dfmt |
|dfmtPath| string | **Default: dfmt** Executable path of dfmt or name if in PATH |

---

**Raw Arguments:** code: string

**Description:** Formats the code given in `code` and writes the output as string.

**Note:** This doesn't require a `subcmd` value and instead directly uses `code`.
