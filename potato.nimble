# Package

version       = "0.1.0"
author        = "Jason Beetham"
description   = "Hot code reloading done as a macro"
license       = "MIT"
srcDir        = "src"

installExt = @["nim"]

namedbin = {"potato/watcher": "potatowatcher"}.toTable()

# Dependencies

requires "nim >= 2.0.8"
taskRequires "test", "sdl2_nim >= 2.0.14.1"
