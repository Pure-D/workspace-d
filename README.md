# workspace-d [![Build Status](https://travis-ci.org/Pure-D/workspace-d.svg?branch=master)](https://travis-ci.org/Pure-D/workspace-d)

workspace-d wraps dcd, dfmt and dscanner to one unified environment managed by dub.

It uses process pipes and json for communication.

## Installation

**Automatic Installation**

Just run install.sh or install.bat (Windows/WIP)

```sh
sh install.sh
```

**Manual Installation**

First, install the dependencies:
 
* [dcd](https://github.com/Hackerpilot/DCD) - Used for auto completion
* [dfmt](https://github.com/Hackerpilot/dfmt) - Used for code formatting
* [dscanner](https://github.com/Hackerpilot/Dscanner) - Used for static code linting

Then, run:

```sh
git clone https://github.com/Pure-D/workspace-d.git
cd workspace-d
# Linux:
dub build --build=release
# Windows:
dub build --build=release --compiler=ldc
```

Either move all the executable binaries to one path and add that path to the Windows PATH
variable or $PATH on Posix, or change the binary path configuration in your editor.

## Usage

**For users**

* Visual Studio Code: [code-d](https://github.com/Pure-D/code-d)

**For plugin developers**

[Wiki/Message Format](https://github.com/Pure-D/workspace-d/wiki/Message-Format)