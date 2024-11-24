## Starch... it's what stores the potato sugar
## Serialisation stuffs is here

import std/[typetraits, macros, genasts, tables, json]
import sprouts

template log(args: varargs[untyped, `$`]) =
  when defined(potatoDebug):
    echo args

when appType == "lib":
  type DeserialiseState* = object
    refs*: Table[int, pointer]
    root*: JsonNode

  var serialisers: seq[proc() {.nimcall, raises: [Exception].}]

  template potatoGetOr*[T](name: string, data: var T, orVal: T) =
    ## assigns `data` to a value from the cache or the `orVal` if incapable of fetching or deserialising
    mixin deserialise
    let node = potatoGet(name)
    if node != nil:
      var state = DeserialiseState(root: node)
      try:
        data.deserialise(state, node["entry"])
      except CatchableError as e:
        discard e
        log "Potato: Failed to deserialise ", name, ": ", e.msg
        data = orVal
    else:
      log "Potato:", name, " is not in the buffer cache."
      data = orVal

  proc deserialise*[T: SomeInteger | enum](i: var T, state: var DeserialiseState, current: JsonNode) =
    i = cast[T](current.getInt())

  proc deserialise*(b: var bool, state: var DeserialiseState, current: JsonNode) =
    b = current.getBool()

  proc deserialise*[T: pointer | ptr or proc](p: var T, state: var DeserialiseState, current: JsonNode) =
    let val = current.getInt()
    copyMem(p.addr, val.addr, sizeof(pointer))

  proc deserialise*[T: SomeFloat](f: var T, state: var DeserialiseState, current: JsonNode) =
    f = T(current.getFloat())

  proc deserialise*(s: var string, state: var DeserialiseState, current: JsonNode) =
    s = current.getStr()

  proc deserialise*[T: distinct](val: var T, state: var DeserialiseState, current: JsonNode) =
    val.distinctBase().deserialise(state, current)

  proc deserialise*[T: ref](r: var T, state: var DeserialiseState, current: JsonNode) =
    when compiles(r of RootObj): # We lost type information, no way to get back
      r = cast[T](current.getInt())
    else:
      var theRef = current.getInt()
      if theRef in state.refs:
        r = cast[T](state.refs[theRef])
      else:
        if theRef != 0:
          new r
          state.refs[theRef] = cast[pointer](r)
          r[].deserialise(state, state.root[$theRef])

  proc deserialise*[T: object or tuple](obj: var T, state: var DeserialiseState, current: JsonNode) =
    for name, field in obj.fieldPairs:
      {.cast(uncheckedAssign).}:
        field.deserialise(state, current[name])

  proc deserialise*[T](s: var seq[T], state: var DeserialiseState, current: JsonNode) =
    s.setLen current.len
    for i, x in s.mpairs:
      x.deserialise(state, current[i])

  proc deserialise*[T](s: var set[T], state: var DeserialiseState, current: JsonNode) =
    let str = current.getStr()
    copyMem(s.addr, str.cstring, min(sizeof s, str.len))

  proc deserialise*[Idx, T](s: var array[Idx, T], state: var DeserialiseState, current: JsonNode) =
    try:
      for i, x in s.mpairs:
        x.deserialise(state, current[ord i])
    except Exception as e:
      log "Potato: ", e.msg

  proc potatoPut*[T](name: string, val: var T) =
    ## adds a value to the cache, converting it into a `JObject`
    let root = newJObject()
    root.add("entry", val.serialise(root))
    potatoPutNode(name, root)

  proc serialise*[T: SomeInteger or pointer or ptr or enum or proc](val: var T, root: JsonNode): JsonNode =
    var theAddr = 0
    copyMem(theAddr.addr, val.addr, sizeof(val))
    newJInt(theAddr)

  proc serialise*(val: var bool, root: JsonNode): JsonNode =
    newJBool(val)

  proc serialise*[T: distinct](val: var T, root: JsonNode): JsonNode =
    serialise(val.distinctbase, root)

  proc serialise*[T: SomeFloat](val: var T, root: JsonNode): JsonNode =
    newJFloat(float(val))

  proc serialise*(val: var string, root: JsonNode): JsonNode =
    newJString(val)


  proc serialise*[T: ref](val: var T, root: JsonNode): JsonNode =
    var iVal: int
    copyMem(iVal.addr, val.addr, sizeof(pointer))
    if val != nil:
      let strName = $iVal
      if not root.hasKey(strName):
        root.add(strName, nil) # store a temp here
        root[strName] = val[].serialise(root)
      newJInt(iVal)
    else:
      newJInt(0)

  proc serialise*[T: object or tuple](val: var T, root: JsonNode): JsonNode =
    result = newJObject()
    for fieldName, field in val.fieldPairs:
      {.cast(uncheckedAssign).}:
        result.add(fieldName, field.serialise(root))

  proc serialise*[T](val: var openarray[T], root: JsonNode): JsonNode =
    result = newJArray()
    for x in val.mitems:
      result.add x.serialise(root)

  proc serialise*[T](val: var set[T], root: JsonNode): JsonNode =
    let buffer = newString(sizeof(val))
    copyMem(buffer.cstring, val.addr, sizeof(val))
    newJString(buffer)

  proc potatoExit() {.exportc, dynlib.} =
    for ser in serialisers:
      ser()
    reset serialisers
    GcFullCollect()

  macro persistentImpl(expr: typed, path: static string): untyped =
    var
      defaultVal = expr[0][^1]
    defaultVal =
        if defaultVal.kind == nnkEmpty:
          newCall("default", newCall("typeof", expr[0][^2]))
        else:
          defaultVal

    result = newStmtList(expr)
    let
      name = result[0][0][0]
      thePath = newLit(path & ": " & name.repr)
    result[0][0][^1] = newCall("default", newCall("typeof", defaultVal))
    result.add:
      genast(name, thePath, defaultVal):
        potatoGetOr(thePath, name, defaultVal)
        serialisers.add proc() {.raises: [Exception], nimcall.} =
          potatoPut(thePath, name)

  template persistent*(expr: typed): untyped =
    ## Annotates a variable as persistent
    persistentImpl(expr, instantiationInfo(fullpaths = true).fileName)
