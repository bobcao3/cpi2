---

name: ownership-review description: Review Zig changes in this repository for
container-header aliasing, pointer invalidation, arena lifetimes, and
unnecessary copies. Use when writing or reviewing mutable JSON state,
collections, run transitions, or resource-owning structs.
---

# Review ownership without adding copies

Read [repository rules](../../../AGENTS.md). Inspect the actual diff and the
complete affected functions before reviewing.

## Trace the data

For each changed container, identify its authoritative header, backing
allocations, arena lifetime, and aliases. Distinguish a copied header, a pointer
to the stored header, and an independently owned copy. A `const` binding does
not make referenced storage deeply immutable.

Follow aliases across publication, structural mutation, callbacks, asynchronous
work, and cleanup. Check the first later use through every surviving alias.
Parent growth can invalidate pointers, slices, and iterators into its entries.
Arena allocation does not prevent container invalidation.

Read [the run owner](../../../packages/agent/src/RunState.zig) before changing
run lifecycle code. Keep root `active` and `suspended` writes there. A suspended
model run can coexist with a different active summary run. Preserve that
behavior and the persisted JSON shape.

## Prefer a single owner

Choose owner mutation, consuming transfer, stable IDs, or a batch of structural
edits before taking references. Do not repair aliasing by defaulting to
`j.copy`, reserving an assumed capacity, weakening an assertion, or moving the
failing read.

Use a deep copy when the caller needs an independently mutable version or
crosses a real lifetime boundary. State that requirement. Keep the existing
full-document transaction clone distinct from an avoidable in-document subtree
copy.

Build response projections with their own top-level header. Do not publish a
mutable header and then extend a copied alias. Shared immutable children do not
require recursive cloning.

If a broader representation change is justified, separate stable identity from
growable storage. Give one table the mutable data and let other structures carry
IDs. Do not maintain a mutable JSON mirror beside a typed store.

## Free every temporary

`std.fmt.allocPrint` returns a fresh allocation. A helper that builds a
composite value by formatting one temporary per section and returning only its
last allocation leaks every earlier one, and the leak survives any correct
caller because no caller can see the intermediates. Prefer writing every section
into one `std.Io.Writer.Allocating` and returning its `toOwnedSlice`, so the
function hands out exactly one owned slice. When a temporary is unavoidable,
free it before returning and keep the free next to the allocation.

Match the heap discipline to the lifetime: startup-lifetime strings belong to
the `gpa` that `close` frees, per-call scratch belongs to a temporary arena that
the caller deinits, and view state belongs to `view_arena`. Do not pass `gpa`
into a helper whose siblings receive an arena, and do not mix the two in one
expression.

## Prove no leaks

`std.heap.SafeAllocator` prints `leaked [addr: ...]` only at process exit, so an
unbalanced allocator is invisible in ordinary tests. Exercise the function under
`std.testing.allocator`, which fails a unit test on a leak, with each optional
input present and absent. The end-to-end checks assert that the CLI's stderr and
the terminal log contain no `leaked [addr` record, because the interactive
lifecycle is where the budget is finally released.

## Run the checks

Run these commands from the repository root with Zig 0.17.1:

```sh
anyzig 0.17.1 build check
anyzig 0.17.1 build test-ownership test-agent
```

Use the repository's local Kit fork option when required by its build setup.
Inspect [the analyzer](../../../tools/ownership/src/analysis.zig) and
[its controls](../../../tools/ownership/tests.zig) before interpreting a
finding. For focused machine-readable findings, run
`anyzig 0.17.1 build ownership-lint -- --json PATH`.

Require a failing-before, passing-after case for a reported defect. Force
entry-storage and index-header growth rather than relying on normal field
counts. For a no-copy transition contract, verify nested backing identity inside
one document. Do not compare identity across `Session.mutate`, which
intentionally clones.

The AST rules cover known local patterns and the run-owner boundary. They are
not a Zig borrow checker. Review indirect calls, casts, function pointers,
interprocedural aliases, and pointers retained across mutations even when lint
passes. ZLS can display the build's diagnostics. ZLS does not add ownership
analysis.

## Report evidence

Report only actionable findings with an owner, invalidating operation, surviving
alias, observable consequence, and source locations. Separate reproduced
corruption, a definite structural rule violation, and an unproved risk. Include
commands and results. Do not demand copies for a safe last-use transfer or
matching write-back. Report unexamined lifetimes and unavailable editor checks
as gaps.
