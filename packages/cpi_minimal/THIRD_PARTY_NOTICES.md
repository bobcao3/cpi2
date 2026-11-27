# Third-party notices

Tool descriptions, parameter documentation, system prompts, skill behavior, and
compaction behavior derive from
[Pi](https://github.com/earendil-works/pi/tree/90b42bca6ed161b8e7ee40ceda9755205c2882ec),
revision `90b42bca6ed161b8e7ee40ceda9755205c2882ec`. The native implementation
adapts those contracts. Code-mode tool descriptions, discovery globals, MCP
prompt layout, script-result formatting, startup artwork and skill presentation,
composer status borders, summary cards, session tree presentation, and footer
layout are adapted from
[Pi 1.6.1](https://github.com/earendil-works/pi/tree/v1.6.1). Minimal does not
include Pi's extension system.

The normalization tables in
[`../services/src/text_normalize.zig`](../services/src/text_normalize.zig)
derive from the
[Unicode 17.0.0 character database](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt).
They use the [Unicode data license](LICENSE-UNICODE.txt). The existing tables
moved with the reusable NFKC mechanism. They were not regenerated.

Frontmatter uses
[libyaml 0.2.5](https://github.com/yaml/libyaml/tree/2c891fc7a770e8ba2fec34fc6b545c672beb37e6),
compiled into the native executable. Its [MIT license](vendor/libyaml/License)
is included. [Vendor notes](vendor/libyaml/README.cpi.md) describe the YAML 1.2
scanner changes and local event bridge.

Syntax highlighting uses
[Tree-sitter](https://github.com/tree-sitter/tree-sitter/tree/v0.25.10) and its
language grammars. The [vendor manifest](../../vendor/tree_sitter/build.zig.zon)
pins the sources. Their licenses are installed under `share/cpi/licenses`.
Session search adapts the
[fzf V2 scorer](https://github.com/junegunn/fzf/blob/v0.60.3/src/algo/algo.go)
in Zig under [fzf's MIT license](LICENSE-FZF.txt).

Inline image processing uses [libspng](https://github.com/randy408/libspng) and
[miniz](https://github.com/richgel999/miniz) for PNG,
[jpegli](https://github.com/google/jpegli) with
[Highway](https://github.com/google/highway) and
[libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) headers for
JPEG, [libwebp](https://github.com/webmproject/libwebp) for WebP, and
[stb_image](https://github.com/nothings/stb) for GIF and BMP. Their license
files are installed under `share/cpi/licenses`.

Minimal follows Pi 1.6.1's X11 clipboard target selection and incremental
transfer behavior. It loads the system's `libxcb.so.1` for X11 clipboard reads.
[Pi's X11 implementation](https://github.com/earendil-works/pi/blob/ef4a1cfcca62b77ad3558337ff3e1c7f6beeadfe/packages/tui/native/linux/src/linux-platform-x11.c)

The system theme is a Luau adaptation of Pi 1.6.1's palette rules and OKLab and
OKHSL conversions. The bundled dark and light theme JSON files come from Pi
1.6.1. The OKHSL conversion incorporates Björn Ottosson's reference code,
copyright 2021 Björn Ottosson, under the MIT terms below.

## Pi license

MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
