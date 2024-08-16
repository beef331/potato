import std/[json]

when not defined(useMalloc):
  {.error: "Please compile with -d:useMalloc either in config or on the CLI".}

when appType != "lib" and defined(hotPotato):
  import std/[
    dynlib, compilesettings,
    paths, strutils,
    osproc, asyncdispatch, asyncnet, os,
    tempfiles, envvars, tables
  ]
  import potato/commands

elif appType == "lib":
  import std/[typetraits, macros, genasts, tables]

when appType == "lib":
  type DeserialiseState = object
    refs: Table[int, pointer]
    root: JsonNode


  var serialisers: seq[proc() {.nimcall, raises: [Exception].}]

  {.push importc, dynlib:"", raises: [Exception].} # We want the executable's procedures
  proc potatoGet*(name: string): JsonNode
  proc potatoPutNode*(name: string, val: JsonNode)
  proc potatoCompileIt*()
  proc potatoQuit*()
  {.pop.}

  template potatoGetOr*[T](name: string, data: var T, orVal: T) =
    mixin deserialise
    let node = potatoGet(name)
    if node != nil:
      var state = DeserialiseState(root: node)
      try:
        data.deserialise(state, node["entry"])
      except CatchableError as e:
        echo "Failed to deserialise: ", name, " ", e.msg
        data = orVal
    else:
      echo name, " is not in the buffer cache."
      data = orVal
      potatoPut(name, data) # Always write the data to the cache

  proc deserialise*[T: SomeInteger | enum](i: var T, state: var DeserialiseState, current: JsonNode) =
    var iVal = current.getInt()
    copyMem(i.addr, iVal.addr, sizeof(T))

  proc deserialise*(b: var bool, state: var DeserialiseState, current: JsonNode) =
    echo "deserialise bool"
    b = current.getBool()

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
      echo e.msg

  proc potatoPut*[T](name: string, val: T) =
    let root = newJObject()
    root.add("entry", val.serialise(root))
    potatoPutNode(name, root)

  proc serialise*[T: SomeInteger or pointer or ptr or enum | proc](val: T, root: JsonNode): JsonNode =
    var theAddr = 0
    copyMem(theAddr.addr, val.addr, min(sizeof(val), sizeof(int)))
    newJInt(theAddr)

  proc serialise*(val: bool, root: JsonNode): JsonNode =
    newJBool(val)

  proc serialise*[T: distinct](val: T, root: JsonNode): JsonNode =
    serialise(val.distinctbase, root)

  proc serialise*[T: SomeFloat](val: T, root: JsonNode): JsonNode =
    newJFloat(float(val))

  proc serialise*(val: string, root: JsonNode): JsonNode =
    newJString(val)


  proc serialise*[T: ref](val: T, root: JsonNode): JsonNode =
    when compiles(val of RootObj):
      {.warning: """
Presently HCR does not serialise inheritance objects using the field method, it just keeps a pointer.
Reorganizing these objects is UB and will cause problems. Type causing this message:
""" & $typeof(val).}
      newJInt(cast[int](val))
    else:
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
    newJString(buffer)

  proc potatoExit() {.exportc, dynlib.} =
    for ser in serialisers:
      ser()
elif defined(hotPotato):
  var
    compileProcess : Process
    lib: LibHandle
    potatoMain: proc() {.nimcall.}
    buffers: Table[string, JsonNode]
    running = true

  {.passc: "-rdynamic", passL: "-rdynamic".}
  {.push exportc, dynlib.}
  proc potatoGet*(name: string): JsonNode =
    if name in buffers:
      buffers[name]
    else:
      nil

  proc potatoPutNode*(name: string, val: JsonNode) =
    buffers[name] = val

  {.pop.}

  proc insertFlags(str: string): string =
    let
      firstSpace = str.find(" ")
      secondSpace = str.find(" ", firstSpace + 1)
      toInsert = " --app:lib --verbosity:0 "
    result = str
    result = result.replace(" -r ", " ")
    result.insert toInsert, secondSpace

  proc insertCheckFlags(str: string): string =
    const toInsert = " check --verbosity:0 --processing:filenames --warnings:off --hint:all=off --hint:Processing:on "
    result = str.multireplace(
      {
        " --hints:off": " ",
        " c ": toInsert,
        "-r ": " ",
      }
    )

  proc compileIt(command: string) =
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

  proc potatoCompileIt*() {.exportc, dynlib.} =
    compileIt command.insertFlags()

  proc potatoQuit*() {.exportc, dynlib.} =
    running = false

  var oldLibs: seq[LibHandle]

  proc reloadLib() =
    if lib != nil:
      cast[proc(){.nimcall, raises: [Exception].}](lib.symAddr("potatoExit"))()
      oldLibs.add lib # Keep the address alive so pointer procs persist
      echo "Saved Lib state"

    try:
      let tmp = genTempPath("potato","")
      copyFile(string dynLibPath, tmp)
      lib = loadLib(tmp, false)
      echo "Loaded new Lib"
      potatoMain = cast[typeof(potatoMain)](lib.symAddr"potatoMain")
    except:
      discard

  let
    port = Port(
      try:
        parseInt(getEnv("PORTATO")) # This is a silly name, I'm a registered silly billy
      except:
        0
    )
    watcher = getEnv("POTATOWATCHER", "potatowatcher")


  var commandQueue: seq[Command]

  proc readCommand(sock: AsyncSocket) {.async.} =
    var data: uint8
    try:
      discard await(sock.recvinto(data.addr, 1))
    except CatchableError as e:
      echo "Failed to read data: ", e.msg
    if data.ord in Command.low.ord .. Command.high.ord:
      commandQueue.add Command(data)
    else:
      echo "Command out of range: ", data.ord

  var commandSocket: AsyncSocket

  proc tcpLoop() {.async.} =
    var clients: seq[AsyncSocket]
    while true:
      let client = await commandSocket.accept()
      clients.add client
      asyncCheck readCommand(client)
      for i in countDown(clients.high, 0):
        if clients[i].isClosed:
          clients.del(i)

  commandSocket = newAsyncSocket()
  commandSocket.setSockOpt(OptReuseAddr, true)
  commandSocket.bindAddr(port)
  putEnv("PORTATO", $commandSocket.getLocalAddr()[1].int)
  commandSocket.listen()


  const handlers = [
    Compile: proc() = potatoCompileIt(),
    Reload: proc() = reloadLib(),
    Quit: proc() = running = false
  ]

  let watcherProc {.used.} = startProcess(
    watcher,
    args = [string dynLibPath, command.insertCheckFlags()],
    options = {poStdErrToStdOut, poParentStreams, poUsePath}
  )
  var theTcpLoop = tcpLoop()
  while running:
    if potatoMain != nil:
      potatoMain()
    try:
      poll(0)
    except CatchableError:
      theTcpLoop = tcpLoop()

    for command in commandQueue:
      handlers[command]()
    commandQueue.setLen(0)

  try:
    watcherProc.kill()
  except:
    discard
  watcherProc.close()

when defined(hotPotato):
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
else:
  proc potatoGet*(name: string): JsonNode = discard
  proc potatoPutNode*(name: string, val: JsonNode) = discard
  proc potatoCompileIt*() = discard
  proc potatoQuit*() = discard


  template persistent*(expr: typed): untyped = expr

