import std/[macros, genasts, atomics, json, tables]

when not defined(useMalloc):
  {.error: "Please compile with -d:useMalloc either in config or on the CLI".}

when appType != "lib":
  import std/[
    dynlib, compilesettings,
    paths, dirs, strutils,
    osproc, locks,
    asyncfile, asyncdispatch,
    files, tempfiles
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
  type DeserialiseState = object
    refs: Table[int, pointer]
    root: JsonNode


  var serialisers: seq[proc() {.nimcall, raises: [Exception].}]

  {.push importc, dynlib:"", raises: [Exception].} # We want the executable's procedures
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

  template potatoGetOr*(name: string, data: var SomeOrdinal, orVal: SomeOrdinal) =
    var val: int
    if potatoGetInt(name, val):
      copyMem(data.addr, val.addr, sizeof(data))
    else:
      data = orVal

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

  template potatoGetOr*[T: object | ref | tuple or seq or array](name: string, data: var T, orVal: T) =
    var theString = ""
    potatoGetOr(name, theString, "")
    if theString != "":
      let theJson = theString.parseJson()
      var state = DeserialiseState(root: theJson)
      data.deserialise(state, theJson["entry"])
    else:
      data = orVal

  template potatoGetOr*[T: SomeOrdinal | float32](name: string, data: var T, orVal: T) =
    var val = 0
    if potatoGetInt(name, val):
      copyMem(data.addr, val.addr, sizeof(T))
    else:
      data = orVal

  template potatoGetOr*[T: distinct](name: string, data: var T, orVal: T) =
    potatoGetOr(name, data.distinctBase(), orVal.distinctBase())

  template potatoGetOr*[T: pointer | ptr | proc](name: string, data: var T, orVal: T) =
    var theAddr = 0
    if potatoGetInt(name, theAddr):
      copyMem(data.addr, theAddr.addr, sizeof(T))
    else:
      data = orVal

  proc deserialise*[T: SomeInteger | bool | enum](i: var T, state: var DeserialiseState, current: JsonNode) =
    var iVal = current.getInt()
    copyMem(i.addr, iVal.addr, sizeof(T))

  proc deserialise*[T: pointer | ptr | proc](p: var T, state: var DeserialiseState, current: JsonNode) =
    let val = current.getInt()
    copyMem(p.addr, val.addr, sizeof(pointer))

  proc deserialise*[T: SomeFloat](f: var T, state: var DeserialiseState, current: JsonNode) =
    f = T(current.getFloat())

  proc deserialise*(s: var string, state: var DeserialiseState, current: JsonNode) =
    s = current.getStr()

  proc deserialise*[T: distinct](val: var T, state: var DeserialiseState, current: JsonNode) =
    val.distinctBase().deserialise(state, current)

  proc deserialise*[T: ref](r: var T, state: var DeserialiseState, current: JsonNode) =
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
    copyMem(s.addr, str.cstring, min(s.len, str.len))

  proc deserialise*[Idx, T](s: var array[Idx, T], state: var DeserialiseState, current: JsonNode) =
    try:
      for i, x in s.mpairs:
        x.deserialise(state, current[ord i])
    except Exception as e:
      echo e.msg

  proc potatoPut*(name: string, i: int) = potatoPutInt(name, i)
  proc potatoPut*(name: string, f: float) = potatoPutFloat(name, f)
  proc potatoPut*(name: string, f: float32) = potatoPutFloat(name, f.float)
  proc potatoPut*(name: string, i: SomeOrdinal or ptr or proc) =
    var data = 0
    copyMem(data.addr, i.addr, sizeof(i))
    potatoPutInt(name, data)
  proc potatoPut*(name, data: string) = potatoPutString(name, data)


  proc serialise*[T: SomeInteger or pointer or ptr or bool or enum | proc](val: T, root: JsonNode): JsonNode =
    var theAddr = 0
    copyMem(theAddr.addr, val.addr, min(sizeof(val), sizeof(int)))
    newJInt(theAddr)

  proc serialise*[T: distinct](val: T, root: JsonNode): JsonNode =
    serialise(val.distinctbase, root)

  proc serialise*[T: SomeFloat](val: T, root: JsonNode): JsonNode =
    newJFloat(float(val))

  proc serialise*(val: string, root: JsonNode): JsonNode =
    newJString(val)

  proc serialise*[T: ref](val: T, root: JsonNode): JsonNode =
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

  proc serialise*[T: object or tuple](val: T, root: JsonNode): JsonNode =
    result = newJObject()
    for fieldName, field in val.fieldPairs:
      result.add(fieldName, field.serialise(root))

  proc serialise*[T](val: openarray[T], root: JsonNode): JsonNode =
    result = newJArray()
    for x in val.items:
      result.add x.serialise(root)

  proc serialise*[T](val: set[T], root: JsonNode): JsonNode =
    let buffer = newString(sizeof(val))
    copyMem(buffer.cstring, val.addr, sizeof(val))
    result = newJString(buffer)

  proc potatoPut*(name: string, data: object or tuple) =
    let root = newJObject()
    root.add("entry", data.serialise(root))
    potatoPutString(name, $root)

  proc potatoPut*(name: string, data: ref) =
    let root = newJObject()
    root.add("entry", data.serialise(root))
    potatoPutString(name, $root)

  proc potatoPut*(name: string, data: distinct) =
    potatoPut(name, data.distinctBase)

  proc potatoExit() {.exportc, dynlib.} =
    for ser in serialisers:
      ser()
else:
  var
    compileProcess : Process
    procLock: Lock
    lib: LibHandle
    potatoMain: proc() {.nimcall.}
    needReload: Atomic[bool]
    buffers: Table[string, SaveBuffer]

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
      toInsert = " --app:lib --verbosity:0 "
    result = str
    result = result.replace(" -r ", " ")
    result.insert toInsert, secondSpace


  initLock(procLock)

  proc compileIt(command: string) =
    {.cast(gcSafe).}:
      withLock procLock:
        if compileProcess != nil:
          try:
            compileProcess.terminate()
          except OsError as e:
            echo e.msg
          compileProcess.close()

        compileProcess = startProcess("nim" & command, options = {poStdErrToStdOut, poEchoCmd, poEvalCommand, poParentStreams})

  const
    command = querySetting(commandLine)
    dynLibPath = querySetting(outDir).Path / Path(DynLibFormat % querySetting(outFile))
    pathMax = 4096


  proc potatoCompileIt*() {.exportc, dynlib.} =
    compileIt command.insertFlags(false)

  var oldLibs: seq[LibHandle]

  proc reloadLib() =
    if needReload.load():
      echo "Reload"
      if lib != nil:
        cast[proc(){.nimcall, raises: [Exception].}](lib.symAddr("potatoExit"))()
        oldLibs.add lib # Keep the address alive so pointer procs persist
        echo "saved"

      try:
        let tmp = genTempPath("potato","")
        moveFile(dynLibPath, Path tmp)
        lib = loadLib(tmp, false)
        echo "loaded"
        potatoMain = cast[typeof(potatoMain)](lib.symAddr"potatoMain")
      except:
        discard
      needReload.store false

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

    assert iNotifyFd.inotify_add_watch(cstring querySetting(outDir), IN_MODIFY) >= 0

    while true:
      try:
        let len = waitfor watcherfile.readBuffer(buffer.cstring, buffer.len)
        var pos = 0
        while pos < len:
          var event = cast[ptr InotifyEvent](buffer[pos].addr)
          if event.getName() == DynLibFormat % querySetting(outFile):
            needReload.store(true)
            pos = len
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
    reloadLib()


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
        serialisers.add proc() {.raises: [Exception], nimcall.} =
          potatoPut(thePath, name)
  else:
    result = expr

template persistent*(expr: typed): untyped =
  ## Annotates a variable as persistent
  persistentImpl(expr, instantiationInfo(fullpaths = true).fileName)
