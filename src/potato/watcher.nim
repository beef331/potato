import std/[
  cmdline, envvars,
  net, paths, strscans, strutils, tables,
  asyncfile, asyncdispatch, sets, osproc,
  atomics,
]
import std/inotify except INotifyEvent
import inotifyevents, commands

const pathMax = 4096

let
  port = Port(
    try:
      parseInt(getEnv("PORTATO")) # This is a silly name, I'm a registered silly billy
    except:
      0
  )
  dylibPath = paramStr(1)
  checkCommand = paramStr(2)

var reloaded: Atomic[bool]
reloaded.store true

proc send(socket: Socket, cmd: Command) =
  discard socket.send(cmd.addr, 1)

proc reloadWatcher() {.gcsafe.} =
  var
    buffer = newString(sizeof(InotifyEvent) + pathMax + 1)
    iNotifyFd = inotify_init()
    watcherFile = newAsyncFile(AsyncFd iNotifyFd)

  {.cast(gcSafe).}:
    assert iNotifyFd.inotify_add_watch(cstring dylibPath.Path.parentDir().string, InCloseWrite) >= 0

  while true:
    try:
      let len = waitfor watcherfile.readBuffer(buffer.cstring, buffer.len)
      var pos = 0
      while pos < len:
        var event = cast[ptr InotifyEvent](buffer[pos].addr)
        {.cast(gcSafe).}:
          if event.getName() == dylibPath.Path.extractFileName().string:
            let theSocket = net.dial("localhost", port)
            defer: theSocket.close()

            theSocket.send Reload
            reloaded.store true
            pos = len
        pos += sizeof(InotifyEvent) + int event.len

    except Exception as e:
      echo "Failed to read from buffer " & e.msg
      break


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


proc compileWatcher() =
  var
    buffer = newString(sizeof(InotifyEvent) + pathMax + 1)
    iNotifyFd = inotify_init()
    watcherFile = newAsyncFile(AsyncFd iNotifyFd)
    lastCount = 0
    watchFut: Future[string]
    fds: Table[string, cint]
    currentDepends: HashSet[string]
    theSocket = net.dial("localhost", port)

  theSocket.send Compile
  theSocket.close()

  while true:
    if reloaded.load():
      let newDeps = block:
        {.cast(gcSafe).}:
          getDepends(checkCommand) #TODO: Replace with `gendepends`

      for dir in currentDepends - newDeps: # Remove old ones:
        discard iNotifyFd.inotify_rm_watch(fds[dir])
        fds.del(dir)

      for dir in newDeps - currentDepends: # add new ones
        fds[dir] = iNotifyFd.inotify_add_watch(cstring dir, InCloseWrite)

      currentDepends = newDeps
      reloaded.store false

    let len = waitfor watcherfile.readBuffer(buffer.cstring, buffer.len)
    var pos = 0
    while pos < len:
      var event = cast[ptr InotifyEvent](buffer[pos].addr)
      pos += sizeof(InotifyEvent) + int event.len
    theSocket = net.dial("localhost", port)
    theSocket.send Compile
    theSocket.close()


var threads: array[2, Thread[void]]
threads[0].createThread(reloadWatcher)
threads[1].createThread(compileWatcher)
joinThreads threads
