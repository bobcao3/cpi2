# Vendored libyaml

The parser sources come from libyaml release 0.2.5 at commit
`2c891fc7a770e8ba2fec34fc6b545c672beb37e6`.

Upstream is
https://github.com/yaml/libyaml/tree/2c891fc7a770e8ba2fec34fc6b545c672beb37e6.

`License` contains the upstream MIT license and copyright notices.
`include/yaml.h`, `src/api.c`, `src/reader.c`, and `src/parser.c` are unchanged
copies.

`src/scanner.c` changes anchor scanning to accept npm yaml's YAML 1.2 anchor
characters. Anchor names end at a space, tab, CR, LF, comma, square bracket, or
curly bracket. Empty names still reject.

`src/yaml_private.h` restricts line-break recognition to CR and LF.
`src/scanner.c` also removes the older Unicode line-break conversions from
`READ_LINE`. NEL, U+2028, and U+2029 are literal characters in plain, quoted,
and block scalars, matching npm yaml's default YAML 1.2 behavior. Double-quoted
escapes for these characters remain supported.

`src/cpi_bridge.c` is a local adapter. It owns the C parser and exposes flat
events to Zig 0.17, which no longer supports `@cImport`. It also rejects
adjacent comments after quoted scalars and closed collections, matching npm
yaml's strict mode.

Compile `api.c`, `reader.c`, `scanner.c`, `parser.c`, and `cpi_bridge.c`. Add
`include` to the C include path and link libc. Define `YAML_VERSION_MAJOR=0`,
`YAML_VERSION_MINOR=2`, `YAML_VERSION_PATCH=5`, and
`YAML_VERSION_STRING="0.2.5"`. No configure or generated configuration header is
needed.

The Zig consumer ports npm yaml's default alias accounting from
`dist/nodes/Alias.js` and `dist/nodes/toJS.js`. See the task report for the
differential verification scope and remaining unverified cases.
