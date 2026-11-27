# Embedded Luau

This package translates the embedding targets from upstream
[CMakeLists.txt](https://github.com/luau-lang/luau/blob/32c28089305f488f901aaf1dbf3fd1cb65fa3d11/CMakeLists.txt)
and
[Sources.cmake](https://github.com/luau-lang/luau/blob/32c28089305f488f901aaf1dbf3fd1cb65fa3d11/Sources.cmake)
into a Zig 0.17 build. The Git dependency and content hash are pinned in
[build.zig.zon](build.zig.zon); upstream source stays in Zig's package cache.
CMake and a system Lua installation are not required.

## Build and run

From the repository root, or from this package:

```sh
anyzig 0.17.1 build -j4
anyzig 0.17.1 build test -j4
anyzig 0.17.1 build repl -j4
```

The root build also accepts `--fork "$HOME/Kit.zig"` for the existing Kit Git
dependency. This Luau package has no Kit dependency.

[repl_example.zig](repl_example.zig) is an ordinary REPL. Globals and functions
persist between chunks; locals remain local to their chunk. Expressions print
their results, and incomplete chunks continue at the `...>` prompt. `:quit` or
end of input exits. There are no predefined `ctx` or `tools` bindings.

```lua
answer = 41
answer += 1
answer
function add(a: number, b: number): number
    return a + b
end
add(19, 23)
```

Compilation and runtime errors leave the REPL usable. Standard-library tables
remain sandboxed and read-only. The writable REPL environment is shared between
chunks, with Luau's immutable-import assumption disabled for that environment.
Input is bounded; this example has no line-editing, history, or execution-time
limits. Tests require Python 3 and use only its standard library.

## Native extensions

The host command `:load NAME PATH` opens a shared library, calls its
`int luaopen_NAME(lua_State *)` entry point under a protected call, and binds
the returned module to global `NAME`. The path is the remainder of the command
and can contain spaces; do not add shell quotes. Native loading is currently
exposed on POSIX targets and tested on Linux. The sandbox does not expose a
library loader to Luau code.

Modules must use this pinned Luau's headers and C ABI, not stock Lua headers.
They resolve VM symbols from the REPL and must not statically link another VM.
C++ modules must export the initializer with C linkage. The REPL retains loaded
libraries until after VM destruction, including modules whose initializers fail,
because an initializer can leave callbacks or userdata behind.

Build the example [POSIX extension](examples/posix.c) with the default build,
then load it in the REPL. On Linux, from the repository root:

```text
:load posix ./zig-out/lib/librepl_posix.so
```

```lua
file = assert(posix.open("README.md"))
text = assert(posix.read(file, 4096))
posix.close(file)
print(text)

directory = assert(posix.opendir("."))
while true do
    local name, err = posix.readdir(directory)
    assert(err == nil, err)
    if name == nil then break end
    print(name)
end
posix.closedir(directory)
```

| Function                    | Successful result                                                     |
| --------------------------- | --------------------------------------------------------------------- |
| `open(path, flags?, mode?)` | Managed file handle; defaults to read-only.                           |
| `read(file, count)`         | Binary string; an empty result for a nonzero count means end of file. |
| `close(file)`               | `true`.                                                               |
| `opendir(path)`             | Managed directory handle.                                             |
| `readdir(directory)`        | Entry name, including `.` and `..`; `nil` means end of directory.     |
| `closedir(directory)`       | `true`.                                                               |

System-call failures return `nil, message, errno`. Invalid argument types or
out-of-range read sizes raise Luau errors. Read sizes are bounded by the
extension's `READ_LIMIT` constant. The module exports open flags and common
errno constants used by the example. File and directory handles close during
garbage collection if not explicitly closed; using a closed handle returns
`EBADF`. File descriptors have close-on-exec enabled. `close` invalidates its
handle even on an interrupted close and never blindly retries that operation.

Loading a native module grants that code full process privileges. The POSIX
example accesses the real filesystem under the process's permissions; it does
not restrict paths. Never load an untrusted native library.

## Link from Zig or C

A dependent Zig build can use the public `luau` module:

```zig
const luau = b.dependency("luau", .{ .target = target, .optimize = optimize });
executable.root_module.addImport("luau", luau.module("luau"));
```

Access the generated C declarations through `@import("luau").c`. The build uses
`addTranslateC`, not `@cImport`. The module links both VM and compiler. For
bytecode-only consumers, link `luau.artifact("Luau.VM")` instead.

C and C++ consumers can include `luau.h`. The header preserves C linkage in C++
translation units. Individual upstream headers and C++ component headers are
installed alongside the archives. Link the compiler, AST, bytecode, VM, and
common archives, with their C++ runtime; Zig consumers receive those transitive
dependencies through the build graph.

## Translation scope

The static artifacts preserve upstream target names: `Luau.Common`, `Luau.Ast`,
`Luau.Bytecode`, `Luau.Compiler`, and `Luau.VM`. Source lists are explicit in
[sources.zig](sources.zig), with the same target dependency graph as CMake. The
archives use position-independent code so a later shared agent library can link
them.

The build enables the equivalent of `LUAU_EXTERN_C`, including
`LUA_USE_LONGJMP=1` for VM error handling. C++17 applies to the compiler and
common code; the VM also inherits that requirement from Common, as in CMake. The
VM keeps upstream's `-fno-math-errno` option. Release modes define `NDEBUG`.
Vector layout retains upstream defaults. CLI programs, analysis, require,
inliner, native code generation, web builds, and upstream test executables are
not built. Shared Luau libraries and non-default vector layouts are not exposed
as options in this wrapper.

The embedding tests exercise C linkage, Luau-specific source compilation,
coroutine suspension/resumption, native errors, syntax errors, C++ header
linkage, and Zig binding consumption. Black-box REPL tests cover persistent
globals, multiline input, diagnostics, real POSIX file/directory operations,
binary reads, and native-module lifetime after initialization failures.

Installed distributions include upstream's Luau and Lua license notices under
`share/licenses/luau`. Luau is licensed under the MIT license and includes code
derived from Lua under its MIT license.
