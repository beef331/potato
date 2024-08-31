# Package

version       = "0.1.4"
author        = "Jason Beetham"
description   = "Hot code reloading done as a macro"
license       = "MIT"
srcDir        = "src"

installExt = @["nim"]

namedbin = {"potato/watcher": "potatowatcher"}.toTable()

# Dependencies

requires "nim >= 2.0.8"
requires "checksums >= 0.2.1"
taskRequires "test", "sdl2_nim >= 2.0.14.1"
