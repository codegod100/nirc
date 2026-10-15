version       = "0.1.0"
author        = "codegod100"
description   = "The portable core of nirc, a generic IRC client"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off tests/tircparse.nim"
