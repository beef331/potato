import std/[macros, genasts, json, tables]

when not defined(useMalloc):
  {.error: "Please compile with -d:useMalloc either in config or on the CLI".}

when appType != "lib":
  import std/[
    dynlib, compilesettings,
    paths, dirs, strutils,
    osproc, locks,
    asyncfile, asyncdispatch, asyncnet,
    files, tempfiles, envvars,
    strutils, sets, strscans, streams, atomics
  ]
  import std/inotify except INotifyEvent
  import potato/inotifyevents
else:
  import std/typetraits

when appType == "lib":
  type DeserialiseState = object
    refs: Table[int, pointer]
    root: JsonNode


  var serialisers: seq[proc() {.nimcall, raises: [Exception].}]

  {.push importc, dynlib:"", raises: [Exception].} # We want the executable's procedures
  proc potatoGet*(name: string): JsonNode
  proc potatoPutNode*(name: string, val: JsonNode)
  proc potatoCompileIt*()
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

  {.warning: """
Presently HCR does not serialise inheritance objects using the field method, it just keeps a pointer.
Reorganizing these objects is UB and will cause problems.
""".}
  proc serialise*[T: ref](val: T, root: JsonNode): JsonNode =
    when compiles(val of RootObj):
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
    procLock: Lock
    lib: LibHandle
    potatoMain: proc() {.nimcall.}
    needReload: Atomic[bool]
    reloadCount: Atomic[int]
    buffers: Table[string, JsonNode]

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

  proc getDepends(command: string): HashSet[string] =
    let depProcess = startProcess("nim" & command, options = {poEvalCommand, poEchoCmd, poStdErrToStdOut})
    defer:
      try:
        depProcess.close()
      except CatchableError as e:
        echo e.msg
    for line in depProcess.lines:
      var hintStr: string
      if line.scanf("Hint: $+ [Processing]", hintStr):
        let start = hintStr.rfind(':') + 2
        result.incl hintStr[start..^1]

  const
    command = querySetting(commandLine)
    dynLibPath = querySetting(outDir).Path / Path(DynLibFormat % querySetting(outFile))
    pathMax = 4096


  proc potatoCompileIt*() {.exportc, dynlib.} =
    compileIt command.insertFlags()

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
        reloadCount.atomicInc()
      except:
        discard
      needReload.store false

  proc reloadWatcher() =
    var
      buffer = newString(sizeof(InotifyEvent) + pathMax + 1)
      iNotifyFd = inotify_init()
      watcherFile = newAsyncFile(AsyncFd iNotifyFd)

    compileIt(command.insertFlags())

    {.cast(gcSafe).}:
      withLock procLock:
        discard compileProcess.waitForExit()

    needReload.store(true)

    assert iNotifyFd.inotify_add_watch(cstring querySetting(outDir), InCloseWrite) >= 0

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


  proc compileWatcher() =
    var
      buffer = newString(sizeof(InotifyEvent) + pathMax + 1)
      iNotifyFd = inotify_init()
      watcherFile = newAsyncFile(AsyncFd iNotifyFd)
      lastCount = 0
      watchFut: Future[string]
      fds: Table[string, cint]
      currentDepends: HashSet[string]
    while true:
      let theCount = reloadCount.load()
      if theCount != lastCount or lastCount == 0:
        let newDeps = getDepends(command.insertCheckFlags()) #TODO: Replace with `gendepends`

        for dir in currentDepends - newDeps: # Remove old ones:
          discard iNotifyFd.inotify_rm_watch(fds[dir])
          fds.del(dir)

        for dir in newDeps - currentDepends: # add new ones
          fds[dir] = iNotifyFd.inotify_add_watch(cstring dir, InCloseWrite)
        currentDepends = newDeps
        lastCount = theCount

      let watchFut = watcherfile.readBuffer(buffer.cstring, buffer.len)
      watchFut.addCallback proc() = potatoCompileIt()
      try:
        poll(500)
      except CatchableError as e:
        echo e.msg

  type Command* = enum
    Compile
    Quit


  echo "Welcome to potato, be careful it is warm"
  var reloadThread: Thread[void]
  reloadThread.createThread(reloadWatcher)

  var compileThread: Thread[void]
  compileThread.createThread(compileWatcher)

  let
    port = Port(
      try:
        parseInt(getEnv("PORTATO")) # This is a silly name, I'm a registered silly billy
      except:
        0
    )
    isListening = port.int > 0

  var
    commandFut: Future[void]
    commandQueue: seq[Command]


  const commandSize = static:
    var theSize = len $Command.low
    for x in Command:
      theSize = max(len $Command.high, theSize)
    theSize

  proc readCommand(sock: AsyncSocket) {.async.} =
    let data = await sock.recv(commandSize)
    try:
      commandQueue.add parseEnum[Command](data)
    except:
      echo "Cannot parse the Command: ", data

  var commandSocket: AsyncSocket

  proc tcpLoop() {.async.} =
    var clients: seq[AsyncSocket]
    while true:
      clients.add await commandSocket.accept()
      asyncCheck readCommand(clients[^1])
      for i in countDown(clients.high, 0):
        if clients[i].isClosed():
          clients.del(i)

  if isListening:
    commandSocket = newAsyncSocket()
    commandSocket.setSockOpt(OptReuseAddr, true)
    commandSocket.bindAddr(port)
    commandSocket.listen()

  while true:
    if potatoMain != nil:
      potatoMain()
    reloadLib()
    if isListening:
      try:
        poll(0)
      except CatchableError as e:
        asyncCheck tcpLoop()
    const handlers = [
      Compile: proc() = potatoCompileIt(),
      Quit: proc() = quit(0)
    ]
    for command in commandQueue:
      handlers[command]()

    commandQueue.setLen(0)

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


  template persistent*(expr: typed): untyped = expr

