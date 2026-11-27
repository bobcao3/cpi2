# Execution services

Services publish operation descriptors derived from typed arguments, results,
limits, recovery classification, and implementation. `Operation.define` binds a
typed implementation. `Operation.defineJson` validates a JSON implementation
against the same typed contract. Both generate argument and result schemas.

`agent.Controller` freezes service registration and resolves grants to
descriptor identities. Registry dispatch validates arguments before calling a
service and checks its result before returning it. Registration does not grant
model capabilities. Callbacks must honor `Context.io` cancellation and must not
retain the borrowed request allocator or context after returning.

`Files` provides `files.read` and `files.write`. Reads return text, or base64
for images and non-text bytes, plus MIME, byte range, size, and SHA-256. Files
larger than 8 MiB produce a size warning. Writes accept an optional
`expected_sha256` precondition checked under that Files instance's lock. This is
not a filesystem-wide atomic compare-and-swap against external writers. Confined
read-only instances reject traversal, symlinks, and special files. The service
has no Pi result envelope or fuzzy-edit operation. Minimal composes these
primitives in Luau and tracks successful file observations for compaction. Its
fuzzy edit path uses `text.normalize_nfkc`, which reports size warnings when
expansion or canonical-ordering work exceeds its expected bounds. Services
report these warnings through `Context.warnSize`. The Controller forwards them
to its sink, and standalone services log them. Operation names longer than 256
bytes are accepted with a registration warning.

The first service is `Process`, backed by the adjacent ghostmux package. Both
packages use Zig 0.17. The root build installs `ghostmux`, `cpi-services`, and
the agent shared library.
`anyzig 0.17.1 build test-services --fork /path/to/Kit.zig -j4` runs real
process and agent integration checks. `test-ghostmux` runs ghostmux's native
suite, and `test` runs all checks.

Process creates configured parent directories before Ghostmux creates and
validates the private runtime directory. Callers do not need a separate native
directory-creation step for nested service instances.

## Session redesign integration

The [session journal](../agent/docs/journal.md) records framework effect intents
and results. That record does not replace a service’s keyed receipt or authorize
replay of an uncertain external action.

## Process RPC

| Endpoint             | Arguments                                                                     | Result                                                                                                   |
| -------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `process.spawn`      | `argv`, optional `cwd`, `env` map, `description`, `is_pty`, `columns`, `rows` | Persistent job status                                                                                    |
| `process.repeat`     | Spawn arguments plus `interval_ms`                                            | Background job that repeats while its command exits zero; a nonzero exit or invocation deadline stops it |
| `process.status`     | `id`                                                                          | Job status, PID, exit code, description and output path                                                  |
| `process.list`       | Optional `include_completed`                                                  | `jobs` belonging to this service's runtime directory                                                     |
| `process.read`       | `id`, optional byte `offset`, `limit`                                         | Status plus replacement-decoded `output`, exact `base64`, `next_offset`, `truncated` and `eof`           |
| `process.wait`       | Read arguments plus `wait_ms`                                                 | Same result, after completion or the foreground wait deadline                                            |
| `process.write`      | `id`, `data`                                                                  | Queue text input to a PTY                                                                                |
| `process.signal`     | `id`, optional `signal`                                                       | Signal the job's process group                                                                           |
| `process.resize`     | `id`, `columns`, `rows`                                                       | Resize a PTY                                                                                             |
| `process.capture`    | `id`, optional `history`, `join`, `max_bytes`                                 | Rendered terminal `text`, `head_bytes`, `omitted_bytes`                                                  |
| `process.screenshot` | `id`, optional `font_size`                                                    | PNG artifact `path` and `mime_type`                                                                      |
| `process.detach`     | `id`                                                                          | Release a job from session cleanup and completion notifications                                          |

`spawn` and `repeat` require an idempotency key. Native callers pass it in
`Context.idempotency_key`, not in the endpoint arguments. Retained job records
deduplicate requests and reject conflicting arguments. The service never
automatically replays a launch with an uncertain outcome. It derives an opaque
job ID from the key. Raw keys, command arguments, and environment values are not
copied into the job manifest. Output and status remain available after the
process exits and after reopening the service. A missing launch status is
`unknown`, not permission to retry.

Each runtime directory owns its jobs, socket, logs, status records and
screenshots. Use a separate private directory for each agent session. Runtime
directories are checked by ghostmux; agents cannot select a different runtime
through endpoint arguments. Runtime directories scope jobs to one service. They
are not an OS sandbox. Spawned commands retain the host process's filesystem and
network privileges. The `cwd` argument selects a working directory, not an
access restriction.

Foreground waiting does not impose a process timeout. An unfinished job returns
`running` and continues. Read and wait return the retained log from the given
offset through the current end, or through the caller's explicit `limit`. A
selection above 65,536 bytes emits an advisory size event. Retained process logs
continue beyond 64 MiB and report a size advisory. PTY input is streamed to the
backend over stdin and emits an advisory above 64 KiB.

The standalone JSON RPC reports size advisories in the optional `size_warnings`
envelope field. Python's `ProcessService` logs advisories and publishes them
through `poll_events()` as `size_warning` events. Oversized RPC requests and
responses still use the usual result and error envelopes.
[Job listing](src/jobs.zig) warns when the job count exceeds the expected range.
Pipe jobs receive stdin EOF and merge stdout and stderr, matching CPI's ghostmux
backend. Interactive input, resize, capture, and screenshots require a PTY.

For capture, `max_bytes` requests a head/tail projection of rendered text. The
result stays within that budget without splitting UTF-8 characters. `head_bytes`
locates the split in `text`, and `omitted_bytes` counts the missing interior.
Omit the budget for a full capture. Zero requests empty text with the omitted
count. The caller chooses how to display an omission notice.

## Synchronous execution

Native embedders can register `services.Exec` beside `services.Process`. Its
`process.exec` endpoint accepts `argv`, `cwd`, optional `environment` overrides,
and optional `timeout_ms`. It returns `output_path`, `exit_code`, `timed_out`,
and `output` with decoded text captured through completion. Output above 51,200
bytes or 2,000 lines emits an advisory size event and remains available in full.
The product chooses the shell and output formatting. Exec merges stdout and
stderr into a retained artifact and imposes no default timeout.

Pass a nonempty `Context.idempotency_key`. Exec syncs keyed intent before spawn.
Matching completed requests return the receipt. Conflicting arguments fail. An
intent without a receipt reports `IndeterminateExecution` and never spawns
again. New receipts store the length of the synced log prefix captured at
completion, so replay returns the same output even if descendants append to the
log. Older receipts with embedded output replay that recorded output.

Normal leader completion preserves intentional descendants and their output
artifact. Exec concurrently reaps adopted descendants in that process group
after returning the leader result. Cancellation through `Context.io` and
timeouts kill the owned process group. Cleanup blocks cancellation and reaps the
leader and adopted group descendants before returning. Signal termination
reports `exit_code = 128 + signal`, including a timeout's killed leader. Linux
execution enables child subreaping in the embedding process. Exec waits only for
its own leaders and process groups, never unrelated children.

Keep Exec at a stable address and use the same concurrent-capable I/O backend
for all calls and `Exec.deinit(io, policy)`. Before deinit, stop new dispatch
and cancel or join admitted calls. Both `Shutdown` policies cancel and join
descendant reapers before Exec or its I/O backend can be destroyed. `.terminate`
kills and reaps their remaining process groups. `.detach` leaves intentional
descendants alive and transfers their lifetime and reaping responsibility to the
host. It leaves no task using Exec, request storage, or the I/O backend. A
reusable host must reap transferred children itself. A product preserving
background jobs at process exit must select `.detach` immediately before exiting
so the OS can reparent them. Constructor failure can select `.terminate`.
Neither policy changes cancellation or timeout cleanup, which always kills and
reaps the owned group. Neither policy waits for live descendants to finish
naturally. Retained artifacts need an external retention policy and must not be
pruned while descendants can still write.

The standalone `cpi-services` executable still registers persistent Process
endpoints. Exec is an explicit native registration and does not alter the
Ghostmux Process lifecycle.

## Native embedding

The native `cpi-services` executable accepts a bounded JSON request on stdin and
returns one result or error envelope on stdout. It contains no shell parser or
process-execution implementation. Native callers use the registry directly with
their own `std.Io` and request allocator.

Native products register service instances with `agent.Controller` and use
declared Luau capabilities. The
[native controller guide](../agent/docs/native-controller.md#services-and-provider-routes)
shows supported wiring. Frozen registration cannot change while Workers run.
Services remain caller-owned. Close Controller and join admitted calls before
releasing them. Cancellation does not undo completed effects.

`Service.release` is an optional hook, null by default. Controller calls each
registered context/hook pair once after joining all admitted calls and before
returning from external-owner `close`. The hook receives borrowed allocator/I/O
and Controller scope. It must finish its own cleanup before returning and must
not retain that context. `Registry.releaseAll` attempts all hooks and returns
the first error. Controller's existing void `close` logs release errors; it does
not provide a typed cleanup acknowledgement.

`Process.service()` keeps borrowed ownership unchanged. A native owner can call
`Process.cleanup(context)` after joining callers. `Process.ownedService()` opts
one exclusive runtime directory into Controller-close cleanup. Do not share that
owned directory with another live Controller or independent owner. Cleanup kills
non-detached jobs and waits for their completed status. It preserves manifests,
logs, and explicit `process.detach` jobs. It does not assign retained jobs to
individual Workers; `stop(worker)` joins that Worker's calls but does not
release the service directory. Exec remains borrowed and keeps its explicit
`deinit(io, .terminate/.detach)` policy.

The service observes background completion and queues `process.completed` events
for the caller. Event collection does not start model requests. The session
controller decides how to deliver those notifications.

The shell tools cover `sh`, `sh_signal`, `sh_background_ps`, `sh_detach`,
`sh_repeat_until`, `sh_screenshot`, and a `process` tool for reading and
controlling jobs. They use `/bin/sh`, and their `env` argument is an environment
map. They provide CPI's execution behaviors without its TUI, shell linting,
dotenv integration, LSP hooks, or inline model image handling. Screenshots
return files.
