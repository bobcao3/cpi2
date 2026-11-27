# Check the session lifecycle

> **Scope of results.** These commands check the existing specifications. They
> do not verify the implemented
> [session frame reducer](../../packages/agent/docs/session-frames.md).
> Documentation-only changes do not establish runtime conformance or refinement.

The specifications and counterexamples are ordinary TLA+ modules and TLC
configuration files. The model Makefile invokes TLC directly. The separate proof
target uses Lean. It does not generate or rewrite specifications.

## Select the tools

Use Java 11 or later and the jar from TLA+ tools release 1.7.4. Set `TLA2TOOLS`
to its absolute path:

```sh
export TLA2TOOLS="$HOME/.cache/cpi-formal/tla2tools-1.7.4.jar"
```

That path is the Makefile default for the previously installed jar. To install
the tools elsewhere, download `tla2tools.jar` from the official TLA+ tools
release and set the variable accordingly. The Makefile verifies SHA-256
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`. It never
downloads tools.

For proofs, use the pinned Lean release documented in
[the proof contract](../lean/README.md). TLC results and Lean theorems have
separate scopes. The complete old startup proof has not been ported to Lean.

## Run TLC

From the repository root:

```sh
./formal/check.sh lifecycle
./formal/check.sh startup
```

`./formal/check.sh tla` runs both. The lifecycle suite has four passing
configurations and sixteen deliberately broken configurations, including the
historical targeted-cancellation guard. The startup suite has four passing
configurations and seven deliberately broken configurations.

Most negative configurations in `formal/tla/negative` use TLC definition
overrides from the corresponding `*Faults.tla` modules.
`NotificationBlocksCancel.cfg` instead selects the historical faulty
notification guard through an explicit protocol constant. They must produce the
named invariant violation with exit status 12. `UnjoinedHost.cfg` instead
removes a fairness assumption and must produce a liveness violation with exit
status 13. Parser errors, unrelated violations, and unexpected success fail the
Make target.

`SessionSafety.cfg` must satisfy `CancelAvailable`. A separate corrected
`SessionCurrentCancel.cfg` would repeat the identical domain/property, so it is
consolidated into `SessionSafety`. The native regression requires targeted
cancellation to remain available after notification failure.
`negative/NotificationBlocksCancel.cfg` must still violate that invariant with
the historical faulty guard. Read `session-lifecycle.md` for the source
correspondence and limits.

Logs and TLC state files go under `.zig-cache/tla`. Set `OUT` to retain a
separate run:

```sh
OUT=/tmp/cpi-tla-check ./formal/check.sh tla
```

To run a single configuration directly:

```sh
cd formal/tla
java -XX:+UseParallelGC -Xmx1g -cp "$TLA2TOOLS" tlc2.TLC \
  -workers 1 -config SessionSafety.cfg SessionLifecycle.tla
```

For a negative control, select its fault module and configuration:

```sh
java -XX:+UseParallelGC -Xmx1g -cp "$TLA2TOOLS" tlc2.TLC \
  -workers 1 -config negative/StaleContinuation.cfg RunSlotsFaults.tla
```

The direct negative command returns nonzero when it finds the expected
violation.

## Run Lean

From the repository root:

```sh
./formal/check.sh lean
```

This checks the declared Lean portfolio with warnings treated as errors and
audits every theorem's axiom dependencies. It also checks intended failures for
false claims, incomplete proofs, and an unexpected axiom. Logs go under
`.zig-cache/lean`; set `OUT` to retain a separate run. A missing or mismatched
Lean toolchain fails instead of skipping proofs. Read the
[Lean proof contract](../lean/README.md) for the precise checked kernels and
remaining startup and implementation-refinement gaps.

## Run the native regression

The real-service cancellation regression lives in
`packages/agent/src/lifecycle_tests.zig` and runs with the existing controller
tests:

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" test-controller
```

Run `./formal/check.sh formal` to check the TLC suites and Lean portfolio.

Use a fresh `--cache-dir` if Zig cache metadata refers to deleted source files.

## Review correspondence

Follow `.pi/skills/verify-session-lifecycle/SKILL.md` when covered code changes.
The source mapping is in `session-lifecycle.md`. It requires manual review.
There is no source-hash gate and no checked Zig refinement.

Read every TLC result with the pstack `/statechart` skill. Use its installed
instructions. Compare every counterexample step with the corresponding source
and replay plausible product failures in native Zig tests. Keep product findings
separate from modelling errors.
