# dotenv

A std-only Zig 0.17.1 package that loads a dotenv subset into an owned
`std.process.Environ.Map`. It never mutates the process environment.

```zig
const dotenv = @import("dotenv");

var diagnostic: dotenv.Diagnostic = .{};
var env = try dotenv.load(allocator, io, process_environment, .{
    .files = &.{ .{ .path = "base.env" }, .{ .path = "local.env" } },
    .diagnostic = &diagnostic,
});
defer env.deinit();
```

Build and test it alone with
`anyzig 0.17.1 build --build-file packages/dotenv/build.zig test`.

## Precedence and failure

Files load in order. A later file overrides an earlier file. The process
environment then overrides every file value, and a present empty process value
also wins. `File.required` defaults to true. Only an optional missing file is
ignored. Any other failure returns an error and no map. Allocations made by the
failed load are freed.

`Diagnostic` reports the file index. Syntax failures also report a 1-based line
and byte column. File and encoding failures leave line and column at zero. The
diagnostic never contains source text or values. It is empty after a successful
load.

## Dialect

- A single leading UTF-8 BOM is ignored.
- Blank lines and lines whose first non-blank byte is `#` are ignored.
- A line is `NAME=value`, with optional blanks around `NAME`, `=`, and an
  optional `export ` prefix. Names match `[A-Za-z_][A-Za-z0-9_]*`.
- LF and CRLF line endings work. Physical multiline values are rejected.
- Single-quoted values are literal.
- Double-quoted values decode `\\`, `\"`, `\n`, `\r`, and `\t`. Other escapes
  are rejected. A closing quote may be followed by blanks and a comment.
- Unquoted values keep backslashes literally. `#` starts a comment at the start
  of the value or after a space or tab. Trailing blanks are removed.
- Empty values are valid. Duplicate names use the last assignment.
- Dollar expressions stay literal. There is no interpolation, substitution, or
  shell execution.

Files must be valid UTF-8 and may not contain NUL bytes. Tabs are allowed. Other
raw control bytes are preserved in values. The parser rejects trailing garbage
after a closing quote and malformed keys.

## Size thresholds

Crossing a size threshold does not stop parsing. The loader logs warnings by
default. Pass `Options.size_warnings` to receive them in the caller.

| Measurement       | Default threshold |
| ----------------- | ----------------- |
| Files             | 64                |
| Bytes per file    | 1 MiB             |
| Total input bytes | 4 MiB             |
| Assignments       | 16384             |

Size reporting uses the actual bytes read. Assignment counts include duplicates.
Each report contains the measurement, actual size, and threshold. Empty paths
and paths containing NUL return `InvalidPath`.

## Files and platforms

Paths are passed to `Options.dir`, which defaults to the process working
directory. The package never searches parent directories.

The [loader](src/root.zig) checks the opened handle and reads only regular
files. Tests cover directory and FIFO rejection on Linux. Runtime verification
covers Linux only.

## Security

Dotenv files contain plaintext secrets. Treat them as credentials, keep them
local, and ignore them in version control. A loaded value can redirect where a
caller sends a secret, so only load files you trust.
