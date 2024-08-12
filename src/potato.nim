import std/[macros, genasts, atomics, json, tables]

when not defined(useMalloc):
  {.error: "Please compile with -d:useMalloc either in config or on the CLI".}

when appType != "lib":
  import std/[
    dynlib, compilesettings,
    paths, dirs, strutils,
    osproc, locks,
    asyncfile, asyncdispatch,
  ]
  import std/inotify except INotifyEvent
  import potato/inotifyevents
else:
  import std/typetraits


type
  SaveKind* = enum
    Int
    Float
    String

  SaveBuffer* = object
    case kind: SaveKind
    of Int:
      i: int64
    of Float:
      f: float
    of String:
      s: string

when appType == "lib":
  var serialisers: seq[proc()]

  {.push importc, dynlib:"".} # We want the executable's procedures
  proc potatoContains*(name: string, kind: SaveKind): bool
  proc potatoGetInt*(name: string, data: var int): bool
  proc potatoGetFloat*(name: string, data: var float): bool
  proc potatoGetStringSize*(name: string, len: var int): bool
  proc potatoGetString*(name: string, data: cstring): bool
  proc potatoPutInt*(name: string, i: int)
  proc potatoPutFloat*(name: string, f: float)
  proc potatoPutString*(name: string, data: string)
  proc potatoCompileIt*()
  {.pop.}


  template potatoGetOr*(name: string, data: var int, orVal: int) =
    if not potatoGetInt(name, data):
      data = orVal

  template potatoGetOr*(name: string, data: var SomeOrdinal, orVal: int) =
    if not potatoGetInt(name, data):
      data = cast[typeof(data)](orVal)

  template potatoGetOr*(name: string, data: var float, orVal: float) =
    if not potatoGetFloat(name, data):
      data = orVal

  template potatoGetOr*(name: string, data: var string, orVal: string) =
    var len = 0
    if potatoGetStringSize(name, len):
      data.setLen(len)
      discard potatoGetString(name, data.cstring)
    else:
      data = orVal

  template potatoGetOr*[T: pointer or ptr](name: string, data: var T, orVal: T) =
    var theAddr = 0
    if potatoGetInt(name, theAddr):
      copyMem(data.addr, theAddr, sizeof(pointer))
    else:
      data = orVal

  proc parseHook*[T: pointer or ptr](s: string; i: var int; v: var T) =
    var theAddr = 0
    parseHook(s, i, theAddr)
    v = cast[T](theAddr)

  type DeserialiseState = object
    refs: Table[int, pointer]
    root: JsonNode

  proc deserialise*[T: SomeInteger or bool](i: var T, state: var DeserialiseState, current: JsonNode) =
    i = T(current.getInt())

  proc deserialise*[T: pointer or ptr](p: var T, state: var DeserialiseState, current: JsonNode) =
    p = cast[T](current.getInt())

  proc deserialise*[T: SomeFloat](f: var T, state: var DeserialiseState, current: JsonNode) =
    f = T(current.getFloat())

  proc deserialise*(s: var string, state: var DeserialiseState, current: JsonNode) =
    s = current.getStr()

  proc deserialise*[T: ref](r: var T, state: var DeserialiseState, current: JsonNode) =
    mixin deserialise
    var theRef = current.getInt()
    if theRef in state.refs:
      r = cast[T](state.refs[theRef])
    else:
      new r
      state.refs[theRef] = cast[pointer](r)
      r[].deserialise(state, state.root[$theRef])

  proc deserialise*[T: object or tuple](obj: var T, state: var DeserialiseState, current: JsonNode) =
    for name, field in obj.fieldPairs:
      {.cast(uncheckedAssign).}:
        field.deserialise(state, current[name])

  template potatoGetOr*[T: object | ref | tuple](name: string, data: var T, orVal: T) =
    var theString = ""
    potatoGetOr(name, theString, "")
    if theString != "":
      let theJson = theString.parseJson()
      var state = DeserialiseState(root: theJson)
      data.deserialise(state, theJson["entry"])
    else:
      data = orVal

  template potatoGetOr*[T: SomeOrdinal or float32](name: string, data: var T, orVal: T) =
    var val = 0
    data =
      if potatoGetInt(name, val):
        cast[T](val)
      else:
        orVal

  template potatoGetOr*[T: distinct](name: string, data: var T, orVal: T) =
    potatoGetOr(name, data.distinctBase(), orVal.distinctBase())


  proc potatoPut*(name: string, i: int) = potatoPutInt(name, i)
  proc potatoPut*(name: string, f: float) = potatoPutFloat(name, f)
  proc potatoPut*(name: string, f: float32) = potatoPutFloat(name, f.float)
  proc potatoPut*(name: string, i: SomeOrdinal) = potatoPutInt(name, cast[int](i))
  proc potatoPut*(name, data: string) = potatoPutString(name, data)


  proc serialise*[T: SomeInteger or pointer or ptr or bool](name: string, val: T, root, parent: JsonNode) =
    parent.add(name, newJInt(cast[int](val)))

  proc serialise*[T: SomeFloat](name: string, val: T, root, parent: JsonNode) =
    parent.add(name, newJFloat(cast[float](val)))
  proc serialise*(name, val: string, root, parent: JsonNode) =
    parent.add(name, newJString(val))

  proc serialise*[T: ref](name: string, val: T, root, parent: JsonNode) =
    let iVal = cast[int](val)
    parent.add(name, newJInt(iVal))
    if val != nil and $iVal notin root:
      ($iVal).serialise(val[], root, root)

  proc serialise*[T: object or tuple](name: string, val: T, root, parent: JsonNode) =
    parent.add(name, newJObject())
    for fieldName, field in val.fieldPairs:
      fieldName.serialise(field, root, parent[name])

  proc potatoPut*(name: string, data: object or tuple) =
    let root = newJObject()
    try:
      serialise("entry", data, root, root)
      potatoPutString(name, $root)
    except Exception as e:
      echo e.msg
      echo $root

  proc potatoPut*(name: string, data: ref) =
    let root = newJObject()
    serialise("entry", data, root, root)
    potatoPutString(name, $root)


  proc potatoExit() {.exportc, dynlib.} =
    for ser in serialisers:
      ser()

else:
  var buffers: Table[string, SaveBuffer]
  {.passc: "-rdynamic", passL: "-rdynamic".}
  {.push exportc, dynlib.}
  proc potatoContains*(name: string, kind: SaveKind): bool =
    name in buffers and buffers[name].kind == kind

  proc potatoGetInt*(name: string, data: var int): bool =
    if name in buffers and buffers[name].kind == Int:
      data = buffers[name].i
      true
    else:
      false

  proc potatoGetFloat*(name: string, data: var ): bool =
    if name in buffers and buffers[name].kind == Float:
      data = buffers[name].f
      true
    else:
      false

  proc potatoGetStringSize*(name: string, len: var int): bool =
    if name in buffers and buffers[name].kind == String:
      len = buffers[name].s.len
      true
    else:
      false

  proc potatoGetString*(name: string, data: cstring): bool =
    if name in buffers and buffers[name].kind == String:
      copyMem(data, buffers[name].s.cstring, buffers[name].s.len)
      true
    else:
      false

  proc potatoPutInt(name: string, i: int) =
    buffers[name] = SaveBuffer(kind: Int, i: i)

  proc potatoPutFloat(name: string, f: float) =
    buffers[name] = SaveBuffer(kind: Float, f: f)

  proc potatoPutString(name: string, data: string) =
    buffers[name] = SaveBuffer(kind: String, s: data)

  {.pop.}

  proc insertFlags(str: string, firstRun: bool): string =
    let
      firstSpace = str.find(" ")
      secondSpace = str.find(" ", firstSpace + 1)
      toInsert =
        if firstRun:
          " -d:firstRun --app:lib --verbosity:0 "
        else:
          " --app:lib --verbosity:0 "
    result = str
    result.insert toInsert, secondSpace
    result = result.replace " -r "

  var
    compileProcess : Process
    procLock: Lock
    lib: LibHandle
    potatoMain: proc() {.nimcall.}
    needReload: Atomic[bool]

  initLock(procLock)

  proc compileIt(command: string) =
    {.cast(gcSafe).}:
      withLock procLock:
        if compileProcess != nil:
          compileProcess.close()
        compileProcess = startProcess("nim" & command, options = {poStdErrToStdOut, poEchoCmd, poEvalCommand, poParentStreams})

  const
    command = querySetting(commandLine)
    dynLibPath = querySetting(outDir).Path / Path(DynLibFormat % querySetting(outFile))
    pathMax = 4096


  proc potatoCompileIt*() {.exportc, dynlib.} =
    compileIt command.insertFlags(false)

  proc reloadLib() =
    if lib != nil:
      cast[proc(){.nimcall.}](lib.symAddr("potatoExit"))()
      lib.unloadLib()
    lib = loadLib(string dynLibPath)
    potatoMain = cast[typeof(potatoMain)](lib.symAddr"potatoMain")

  proc watcherProc() =
    var
      buffer = newString(sizeof(InotifyEvent) + pathMax + 1)
      iNotifyFd = inotify_init()
      watcherFile = newAsyncFile(AsyncFd iNotifyFd)

    compileIt(command.insertFlags(true))

    {.cast(gcSafe).}:
      withLock procLock:
        discard compileProcess.waitForExit()

    needReload.store(true)

    assert iNotifyFd.inotify_add_watch(cstring querySetting(outDir), {CloseWrite}) >= 0

    while true:
      try:
        let len = waitfor watcherfile.readBuffer(buffer.cstring, pathMax + 1)
        var pos = 0
        while pos < len:
          var event = cast[ptr InotifyEvent](buffer[pos].addr)
          if event.getName() == DynLibFormat % querySetting(outFile):
            needReload.store(true)
            echo "Reload"

          pos += sizeof(InotifyEvent) + int event.len

      except Exception as e:
        echo "Failed to read from buffer " & e.msg
        break

  echo "Welcome to potato, be careful it is warm"
  var watcherThread: Thread[void]
  watcherThread.createThread(watcherProc)
  while true:
    if potatoMain != nil:
      potatoMain()
    if needReload.load:
      reloadLib()
      needReload.store(false)


macro persistentImpl(expr: typed, path: static string): untyped =
  when appType == "lib":
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
      thePath = newLit(path & name.repr)
    result[0][0][^1] = newCall("default", newCall("typeof", defaultVal))
    result.add:
      genast(name, thePath, defaultVal):
        potatoGetOr(thePath, name, defaultVal)
        serialisers.add proc() =
          potatoPut(thePath, name)
          reset(name)
  else:
    result = expr

template persistent*(expr: typed): untyped =
  ## Annotates a variable as persistent
  persistentImpl(expr, instantiationInfo(fullpaths = true).fileName)
