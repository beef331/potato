type
  InotifyFlag* = enum
    Access = 1
    Modify
    Attrib
    CloseWrite
    CloseNoWrite
    Open
    MovedFrom
    MovedTo
    Create
    Delete
    DeleteSelf
    MoveSelf

    Unmount = 14
    QueueOverflow
    Ignored

    OnlyDir = 25
    DontFollow
    ExclUnlink

    OnlyCreateWatch = 29
    AddToWatch

    IsDir
    OneShot

  InotifyFlags* = set[InotifyFlag]

  InotifyEvent* {.pure, final, importc: "struct inotify_event",
                 header: "<sys/inotify.h>".} = object
    wd* {.importc: "wd".}: FileHandle ## Watch descriptor.
    mask* {.importc: "mask".}: InotifyFlags ## Watch mask.
    cookie* {.importc: "cookie".}: uint32 ## Cookie to synchronize two events.
    len* {.importc: "len".}: uint32 ## Length (including NULs) of name.
    name* {.importc: "name".}: UncheckedArray[char] ## Name.

converter toCint*(i: InotifyFlags): uint32 = copyMem(result.addr, i.addr, sizeof cint)

when sizeof(InotifyFlags) != sizeof(uint32):
  {.error: fmt"Mismatch between flags({sizeof InotifyFlags}) and uint32({sizeof(uint32)})".}

proc getName*(evt: ptr InotifyEvent): string = $cast[cstring](evt.name.addr)

const
  Close* = {CloseWrite, CloseNoWrite}
  Moved* = {MovedFrom, MovedTo}

