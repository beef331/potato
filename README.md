# potato
It's a hot code reloading proof of concept. Hot potato get it? No. Good.

## How to use

First `nimble install https://github.com/beef331/potato` or add a `requires "https://github.com/beef331/potato >= 0.1.2"` to the `.nimble` file.

Add the following to `config.nims`
```nim
when appType == "lib":
  --nimMainPrefix="libpotato"
```

Following that `import potato` in the main project file.
Now one can annotate any global variables with `{.persistent.}` these variables will as the name implies persist across reloads.
Any global code should be non blocking as the potato library calls a specific entry procedure.
This entry procedure's signature is `proc potatoMain() {.exportc, dynlib.}` and must be declared.
`potatoMain` is called inside a while loop meaning it must not block as that will stop the hot code reloading.
Finally the program must be compiled with `-d:hotPotato -d:useMalloc`.

This library uses the environmental variable `POTATOWATCHER` to watch a program.
The first parameter is the path to the dynamic library to watch.
Following that is a command which dumps all the dependencies of the project.

This watcher must communicate to the environmental variable `PORTATO` port TCP messages.
[src/potato/commands.nim](src/potato/commands.nim) contains the commands which potato watches for.
These are sent as single byte messages.



### Custom hooks
There are two signatures which the Potato searches for for (de)serialisation:

`proc serialise*(src: T, root: JsonNode): JsonNode`
`proc deserialise*(dest: var T, state: var DeserialiseState, current: JsonNode)`

`serialise` returns the `JsonNode` of the data to write. Global state can be added to `root` this is how cyclical graphs are broken by default.

`deserialise` writes to `dest`, `current` stores the data which is extracted to assign to `dest`.



## Limitations
As there is no way to recover the type from inheritance.
Inheritance is disabled by default.
One can provide a hook for their specific type if they need it.

Pointer procedures are disabled by default as there is no way to migrate anonymous pointer procs.
It is suggested to use `enum`s into a global constant array or similar to make dispatch static as it not rely on runtime information.

As of now [`potatowatcher`](src/potato/watcher.nim) is a Linux only file watcher. In the future it makes more sense to use `fswatch` for crossplatform file watching.
