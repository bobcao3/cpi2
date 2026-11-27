# Streaming and socket protocols

Use this guide when feeding terminal bytes or writing a client. For managed
terminal commands, start with the [README](README.md).

## Capture during a stream

Run `ghostmux --protocol` and keep stdin open. Send one JSON request per line:

```json
{"op":"feed","data":"hello\r\n\u001b[31mred\u001b[0m"}
{"op":"capture"}
{"op":"screenshot","path":"first.png"}
{"op":"resize","cols":100,"rows":30}
{"op":"feed","base64":"5Lit5paHIPCfmIA="}
{"op":"capture","history":true,"join":true}
{"op":"quit"}
```

Each request finishes and flushes its response before the next runs. Captures
see all preceding feeds. You can keep feeding after a screenshot.

Use `data` for a JSON string or `base64` for arbitrary bytes, never both. Base64
can carry chunks that split a UTF-8 character or escape sequence. `--input PATH`
reads requests from a file instead of stdin.

Successful replies include `ok`, `cols`, and `rows`. Captures add `text`;
screenshots add `path`. A screenshot can also specify `font_size`. Invalid
requests and I/O errors end the CLI with a nonzero status and a message on
stderr. EOF before the expected reply means failure. Request lines above 1 MiB
emit a size advisory and are still parsed.

Trust the controller. Screenshot requests write to paths it chooses. Put
untrusted program output inside `data` or `base64`, never directly into the
request stream. Fonts come from bundled assets, not controller-supplied files.

[protocol.zig](src/protocol.zig) defines the requests.
[options.zig](src/options.zig) defines geometry advisories and CLI defaults.

## Talk to the daemon

The daemon uses Unix-domain sockets on POSIX and Windows. This is separate from
`--protocol`. Each socket frame contains a four-byte big-endian length and JSON.
Clients must check the version and reject incomplete frames. Command errors
normally return JSON error names; a timeout or transport failure can interrupt
the exchange.

See [wire.zig](src/wire.zig) for the schema and
[runtime_frames.zig](src/runtime_frames.zig) for framing. The
[CLI client](src/client.zig) shows startup coordination. It holds the startup
lock through the first response. Lock files remain on disk so clients lock the
same inode.

Socket requests above 1 MiB and responses above 8 MiB emit size advisories. The
four-byte length defines which payload sizes the protocol can represent. Input
above 64 KiB is queued in full, with an advisory. The CLI can read input from
stdin.

`read-output` uses the retained log for offsets older than the live buffer when
a log was requested. Without a log, those offsets report `OutputExpired`. The
caller's `--limit` selects the requested byte count and defaults to 64 KiB. Slow
subscribers can delay reads from the child and may disconnect on a write
deadline. Crossing a queue size threshold emits an advisory.

## Signals and cleanup

`signal-session` acknowledges the request without waiting for removal. On POSIX,
it signals the managed process group and any distinct foreground group.
Processes can escape those groups, so use a supervisor if you need containment.

On Windows, signal requests forcibly terminate the session's Job Object. They do
not deliver POSIX signals. Both PTY and pipe sessions use kill-on-close jobs.
Forced cleanup can report a synthetic status.

## Replay and rendering limits

Feed actual PTY bytes. A bare line feed need not return to column zero. Replay
cannot answer terminal queries; managed sessions can. Text capture removes
trailing spaces and blank rows. Raw replay adds a newline to nonempty captures;
protocol captures do not add one.

Emoji are monochrome. Screenshots draw terminal cells, not Kitty or Sixel
graphics. Font coverage is not universal. Ligatures depend on the font, and the
bundled Noto Sans Mono faces lack `ffl` ligatures. Italics are synthesized. See
[the font manifest](fonts/MANIFEST.sha256) for bundled assets.

A large screenshot can delay other commands. Unusually large screenshots,
glyphs, and font sizes emit size warnings. Oversized glyphs can render without
entering the cache. Daemon replies may include `size_warnings` with the
measurement, actual value, and expected threshold. The command-line client emits
those warnings on stderr, where cpi-services can publish them as harness events.

On POSIX, terminal rows and columns still reach the child if the calculated
pixel dimensions are too large for the kernel's window-size fields. Ghostmux
reports the overflow and leaves the affected pixel field unspecified.
