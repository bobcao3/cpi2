# Formal verification

- [TLA+ models](tla/README.md) cover protocol safety and liveness within the
  checked TLC configurations. The pinned tool and individual commands are in the
  [TLC runbook](tla/check-session-lifecycle.md).
- [Lean proofs](lean/README.md) establish properties of the registry,
  publication, and resource-lifetime kernels and document their correspondence
  to the implementation.
- [Source boundary checks](boundaries/) enforce the Controller and Kit
  integration rules.

Run both suites from the repository root with `./formal/check.sh formal`. Use
`./formal/check.sh tla` or `./formal/check.sh lean` to run either suite on its
own. Running `./formal/check.sh` also runs the boundary checks.
