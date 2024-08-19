## This is a hot code reloading(HCR) library
## Importing of this model with `hotPotato` defined will enable the HCR.
## Potato blocks the main process then compiles the module again as a shared object.
## Inside the code you can use `when appType == "lib"` to detect when running inside this HCR environement.
## When running the code all global scoped variables are assigned as normal, unless they're annotated `{.persistent.}`.
## The macro stores the variable to a global cache to be recovered later.
## There are two signatures which the Potato searches for for (de)serialisation
## `deserialise`:  `proc deserialise*(dest: var T, state: var DeserialiseState, current: JsonNode)`
## This this procedure writes to `dest`, the node it is operating on is `current`.
## `serialise`: `proc serialise*(src: T, root: JsonNode): JsonNode`
## Using this procedure one must return the value they want written to the present tree.
## In the base implementation references write to the `root` with their address as a field.
## Any other types that need this can do the same to allow migration between old and new libraries.
## The global scope is ran on load and must not block.
## After the global scope is ran and intialised the program then invokes the `potatoMain` procedure.
## Its signature is `proc potatoMain() {.exportc, dynlib.}`
## As this is called as fast as it's exited one does not need a `while` loop inside the body of this procedure.
## It can be blocking, but making it never exit results in recompiled libraries not loading.

## Potato listens for TCP input on the port `$PORTATO` for the filewatcher.
## Refer to `potato/commands` to see the available commands.
## `potato/watcher` is the Linux watcher based on inotify
## `potatowatcher` is spawned by default, but the variable `POTATOWATCHER` can be used to change it.
## As mentioned previously this watcher should send commands to Potato by sending TCP messages to the port `PORTATO`

## When this program is spawned its arguments are:
## [0]- shared object file path.
## [1]- nim check command, a command which outputs the list of dependencies the project has.

import std/[json]
import system/ansi_c

when not defined(useMalloc):
  {.error: "Please compile with -d:useMalloc".}

template log*(args: varargs[untyped, `$`]) =
  when defined(potatoDebug):
    log args

when appType != "lib" and defined(hotPotato):
  import std/[
    dynlib, compilesettings,
    paths, strutils,
    osproc, asyncdispatch, asyncnet, os,
    tempfiles, envvars, tables, exitProcs
  ]
  import potato/commands


elif appType == "lib":
  import std/[typetraits, macros, genasts, tables]

when appType == "lib":
  type DeserialiseState* = object
    refs*: Table[int, pointer]
    root*: JsonNode


  var serialisers: seq[proc() {.nimcall, raises: [Exception].}]

  {.push importc, dynlib:"", raises: [Exception].} # We want the executable's procedures
  proc potatoGet*(name: string): JsonNode
  proc potatoPutNode*(name: string, val: JsonNode)
  proc potatoCompileIt*()
  proc potatoQuit*()
  proc potatoError*()
  {.pop.}

  globalRaiseHook = proc(e: ref Exception): bool =
    for i, x in e.getStackTraceEntries:
      stdout.write x.fileName, "(", x.line, ") ", x.procName
      stdout.write "\n"
    stdout.write"Error: "
    stdout.writeLine e.msg
    stdout.flushFile()
    potatoError()
    true

  {.push stackTrace:off.}
  proc signalHandler(sign: cint) {.noconv.} =
    if sign == SIGINT:
      echo("SIGINT: Interrupted by Ctrl-C.")
      potatoQuit()
      potatoError()
    elif sign == SIGSEGV:
      writeStackTrace()
      echo("SIGSEGV: Illegal storage access. (Attempt to read from nil?)")
      potatoError()
    elif sign == SIGABRT:
      writeStackTrace()
      echo("SIGABRT: Abnormal termination.")
      potatoError()
    elif sign == SIGFPE:
      writeStackTrace()
      echo("SIGFPE: Arithmetic error.")
      potatoError()
    elif sign == SIGILL:
      writeStackTrace()
      echo("SIGILL: Illegal operation.")
      potatoError()
    elif (when declared(SIGBUS): sign == SIGBUS else: false):
      echo("SIGBUS: Illegal storage access. (Attempt to read from nil?)")
      potatoError()
  {.pop.}

  c_signal(SIGINT, signalHandler)
  c_signal(SIGSEGV, signalHandler)
  c_signal(SIGABRT, signalHandler)
  c_signal(SIGFPE, signalHandler)
  c_signal(SIGILL, signalHandler)
  when declared(SIGBUS):
    c_signal(SIGBUS, signalHandler)


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
      potatoPut(name, data) # Always write the data to the cache

  proc deserialise*[T: SomeInteger | enum](i: var T, state: var DeserialiseState, current: JsonNode) =
    var iVal = current.getInt()
    copyMem(i.addr, iVal.addr, sizeof(T))

  proc deserialise*(b: var bool, state: var DeserialiseState, current: JsonNode) =
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
      log "Potato: ", e.msg

  proc potatoPut*[T](name: string, val: T) =
    ## adds a value to the cache, converting it into a `JObject`
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
Presently potato does not serialise inheritance objects using the field method, it just keeps a pointer.
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
  type sigjmp_buf {.bycopy, importc: "sigjmp_buf", header: "<setjmp.h>".} =  object

  proc sigsetjmp(jmpb: C_JmpBuf, savemask: cint): cint {.header: "<setjmp.h>", importc: "sigsetjmp".}
  proc siglongjmp(jmpb: C_JmpBuf, retVal: cint) {.header: "<setjmp.h>", importc: "siglongjmp".}

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
        log e.msg
      compileProcess.close()
    const flags =
      when defined(potatoDebug):
        {poStdErrToStdOut, poEchoCmd, poEvalCommand, poParentStreams}
      else:
        {poStdErrToStdOut, poEvalCommand, poParentStreams}
    compileProcess = startProcess("nim" & command, options = flags)

  const
    command = querySetting(commandLine)
    dynLibPath = querySetting(outDir).Path / Path(DynLibFormat % querySetting(outFile))

  var jmp: C_JmpBuf
  proc potatoError() {.exportc, dynlib.} =
    siglongjmp(jmp, 1)

  proc potatoCompileIt*() {.exportc, dynlib.} =
    compileIt command.insertFlags()

  proc potatoQuit*() {.exportc, dynlib.} =
    running = false

  var oldLibs: seq[LibHandle]

  proc reloadLib() =
    if lib != nil:
      cast[proc(){.nimcall, raises: [Exception].}](lib.symAddr("potatoExit"))()
      oldLibs.add lib # Keep the address alive so pointer procs persist
      log "Potato: Saved Lib state"

    try:
      let tmp = genTempPath("potato","")
      copyFile(string dynLibPath, tmp)
      lib = loadLib(tmp, false)
      log "Potato: Loaded new Lib"
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
      log "Potato: Failed to read data: ", e.msg
    if data.ord in Command.low.ord .. Command.high.ord:
      commandQueue.add Command(data)
    else:
      log "Potato: Command out of range: ", data.ord

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
      if sigsetjmp(jmp, int32.high.cint) == 0:
        potatoMain()
      else:
        reloadLib()
    try:
      poll(0)
    except CatchableError:
      theTcpLoop = tcpLoop()

    for command in commandQueue:
      handlers[command]()
    commandQueue.setLen(0)

  proc onExit() {.noconv.} =
    try:
      watcherProc.terminate()
    except:
      discard
    watcherProc.close()

  addExitProc onExit
  setControlChook onExit

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
        thePath = newLit(path & ": " & name.repr)
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
  proc potatoGet*(name: string): JsonNode =
    ## Retrieves a node from the global cache

  proc potatoPutNode*(name: string, val: JsonNode) =
    ## Adds a node to the global cache

  proc potatoCompileIt*() =
    ## Recompiles the project. This likely will trigger a reload if there is a file watcher

  proc potatoQuit*() =
    ## Exits the main loop gracefully

  proc potatoError*() =
    ## Reloads the library. Meant for recovery from things like nil reference errors.

  template persistent*(expr: typed): untyped =
    ## Annotates a global variable so that it stores its value across reloads
    expr

