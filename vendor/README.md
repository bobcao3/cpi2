# Vendored native libraries

Each package builds a static archive and installs its public headers and
upstream license files. Zig fetches the source dependencies using the Git
commits and content hashes pinned in each `build.zig.zon`. Build a package from
its directory with `anyzig 0.17.1 build`.

| Package     | Zig artifact | Interface                                                                                                                  |
| ----------- | ------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `libspng`   | `spng`       | PNG encode and decode through `spng.h`, with miniz compiled into the archive                                               |
| `jpegli`    | `jpegli`     | JPEG encode and decode through `lib/jpegli/encode.h` and `lib/jpegli/decode.h`, with Highway compiled into the archive     |
| `stb_image` | `stb_image`  | In-memory GIF and BMP decode through `stb_image_gif_bmp.h`. BMP supports uncompressed data and 16-bit or 32-bit bitfields. |
| `libwebp`   | `webp`       | WebP encode, decode, mux, and demux through `webp/` headers                                                                |

For a Zig consumer, declare the codec’s directory as a path dependency. Pass the
consumer’s `target` and `optimize` options to `b.dependency`, then link the
named artifact with `module.linkLibrary`. The jpegli headers require C++, and
the archive exports the `jpegli_*` API.

[`tree_sitter`](tree_sitter/build.zig) builds the parser runtime and all bundled
grammars into a single static archive. Consumers import the `tree_sitter` module
for the C API, grammar constructors, and bundled highlight queries.
