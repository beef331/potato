import system/ansi_c
import potato/[starch, sprouts]
export starch, sprouts

when not defined(useMalloc):
  {.error: "Please compile with -d:useMalloc".}

template log(args: varargs[untyped, `$`]) {.used.} =
  when defined(potatoDebug):
    echo args


when appType != "lib" and defined(hotPotato):
  import std/[
    dynlib, compilesettings,
    paths, strutils,
    osproc, os, net, selectors, json,
    tempfiles, envvars, tables, exitProcs
  ]
  import potato/commands
  import pkg/checksums/sha1

when appType == "lib":
  import std/typetraits

  unhandledExceptionHook = proc(e: ref Exception) {.nimcall, gcsafe, raises: [], tags: [].}=
    try:
      {.cast(tags: []).}:
        for i, x in e.getStackTraceEntries:
          stdout.write x.fileName, "(", x.line, ") ", x.procName
          stdout.write "\n"
        stdout.write"Error: "
        stdout.writeLine e.msg
        stdout.flushFile()
        potatoError()
    except:
      discard


  {.push stackTrace:off.}
  proc signalHandler(sign: cint) {.noconv.} =
    if sign == SIGINT:
      potatoQuit()
      potatoError()
    elif sign == SIGSEGV:
      writeStackTrace()
      echo "SIGSEGV: Illegal storage access. (Attempt to read from nil?)"
      potatoError()
    elif sign == SIGABRT:
      writeStackTrace()
      echo "SIGABRT: Abnormal termination."
      potatoError()
    elif sign == SIGFPE:
      writeStackTrace()
      echo "SIGFPE: Arithmetic error."
      potatoError()
    elif sign == SIGILL:
      writeStackTrace()
      echo "SIGILL: Illegal operation."
      potatoError()
    elif (when declared(SIGBUS): sign == SIGBUS else: false):
      echo "SIGBUS: Illegal storage access. (Attempt to read from nil?)"
      potatoError()
  {.pop.}

  #c_signal(SIGINT, signalHandler)
  c_signal(SIGSEGV, signalHandler)
  c_signal(SIGABRT, signalHandler)
  c_signal(SIGFPE, signalHandler)
  c_signal(SIGILL, signalHandler)
  when declared(SIGBUS):
    c_signal(SIGBUS, signalHandler)



elif defined(hotPotato):
  const
    ErrorJump = 1
    QuitJump = 2

  var
    compileProcess : Process
    lib: LibHandle
    potatoMain: proc() {.nimcall.}
    potatoGetError: proc(): ref Exception {.nimcall.}
    buffers: Table[string, JsonNode]
    running = true
    crashed = false
    lastChecksum: SecureHash

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
      toInsert = " --app:lib --verbosity:0 --nimcache='$nimcache/potato_$projectname' "
    result = str
    result = result.replace(" -r ", " ")
    result.insert toInsert, secondSpace

  proc insertCheckFlags(str: string): string =
    const toInsert = " check --verbosity:0 --processing:filenames --warnings:off --hint:all=off --hint:Processing:on --nimcache='$nimcache/potato_check_$projectname' "
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
        compileProcess.kill()
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

  proc potatoSave() =
    cast[proc(){.nimcall, raises: [Exception].}](lib.symAddr("potatoExit"))()
    cast[proc(){.nimcall.}](lib.symAddr("NimDestroyGlobals"))()
    log "Potato: Saved library state"
    lib.unloadLib()
    log "Potato: Unload last library"

  proc potatoError*() {.exportc, dynlib.} =
    siglongjmp(jmp, ErrorJump)

  proc potatoCompileIt*() {.exportc, dynlib.} =
    compileIt command.insertFlags()

  proc potatoQuit*() {.exportc, dynlib.} =
    running = false
    siglongjmp(jmp, QuitJump)

  proc reloadLib() =
    let checksum = secureHashFile(string dynLibPath)
    if checksum != lastChecksum:
      if lib != nil and not crashed:
        potatoSave()

      try:
        let tmp = genTempPath("potato","")
        copyFile(string dynLibPath, tmp)
        lib = loadLib(tmp, false)
        log "Potato: Loaded new library"
        potatoMain = cast[typeof(potatoMain)](lib.symAddr"potatoMain")
        potatoGetError = cast[typeof(potatoGetError)](lib.symAddr"potatoGetError")
        crashed = false
      except:
        discard
      lastChecksum = checksum

  let
    port = Port(
      try:
        parseInt(getEnv("PORTATO")) # This is a silly name, I'm a registered silly billy
      except:
        0
    )
    watcher = getEnv("POTATOWATCHER", "potatowatcher")


  var commandQueue: seq[Command]

  proc readCommand(sock: Socket) =
    var data: uint8
    var read = 0
    try:
      read = sock.recv(data.addr, 1)
    except CatchableError as e:
      log "Potato: Failed to read data: ", e.msg
    if read != 0:
      if data.ord in Command.low.ord .. Command.high.ord:
        commandQueue.add Command(data)
        log "Potato: got new command ", commandQueue[^1]
      else:
        log "Potato: Command out of range: ", data.ord

  var
    commandSocket: Socket
    clients: seq[Socket]
    selector = newSelector[uint8]()

  proc tcpLoop() =
    for evt in selector.select(0): # Any events ready
      if evt.fd == commandSocket.getFd().int:
        var sock: Socket
        commandSocket.accept(sock)
        selector.registerHandle(sock.getFd(), {Read}, 0)
        clients.add sock
      else:
        for x in clients:
          if x.getFd().int == evt.fd:
            x.readCommand()

  try:
    commandSocket = newSocket()
    commandSocket.setSockOpt(OptReuseAddr, true)
    commandSocket.bindAddr(port)
    commandSocket.listen()
    selector.registerHandle(commandSocket.getFd(), {Read}, 0)
    putEnv("PORTATO", $commandSocket.getLocalAddr()[1].int)
  except:
    echo "Failed to setup listening port on: ", port.int
    quit 1


  const handlers = [
    Compile: proc() = potatoCompileIt(),
    Reload: proc() = reloadLib(),
    Quit: proc() = potatoQuit()
  ]

  let watcherProc {.used.} = startProcess(
    watcher,
    args = [string dynLibPath, command.insertCheckFlags()],
    options = {poStdErrToStdOut, poParentStreams, poUsePath}
  )


  template tryIt(expr: untyped) =
    try:
      expr
    except:
      discard

  proc freeResources() {.noConv.} =
    tryIt watcherProc.kill()
    tryIt watcherProc.close()
    tryIt selector.close()
    tryIt commandSocket.close()

  addExitProc freeResources
  setControlChook proc() {.noConv.} =
    freeResources()
    potatoQuit()


  proc handleExceptionIfRaised() =
    let err = potatoGetError()
    if err != nil:
      for i, x in err.getStackTraceEntries:
        stdout.write x.fileName, "(", x.line, ") ", x.procName
        stdout.write "\n"
      stdout.write"Error: "
      stdout.writeLine err.msg
      stdout.flushFile()
      potatoError()

  while running:
    if potatoMain != nil and not crashed:
      let jmp = sigsetjmp(jmp, int32.high.cint)
      if jmp == 0:
        potatoMain()
        handleExceptionIfRaised()
      elif jmp == ErrorJump:
        potatoSave()
        crashed = true
      elif jmp == QuitJump:
        break
      else:
        echo "Incorrect jump to: ", jmp

    tcpLoop()

    for command in commandQueue:
      handlers[command]()
    commandQueue.setLen(0)



when not defined(hotPotato):
  import std/json
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

when not defined(hotPotato) or appType != "lib":
  template persistent*(expr: typed): untyped =
    ## Annotates a global variable so that it stores its value across reloads
    expr

