## Potatos grow from sprouts, this is where shared stuff comes from
## Yes I've joined the badly named module party

{.used.}

when appType == "lib":
  import std/json
  {.push importc, dynlib:"", raises: [Exception].} # We want the executable's procedures
  proc potatoGet*(name: string): JsonNode
  proc potatoPutNode*(name: string, val: JsonNode)
  proc potatoCompileIt*()
  proc potatoQuit*()
  proc potatoError*()
  {.pop.}
