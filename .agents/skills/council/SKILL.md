---

name: council description: Approve or reject the leverage and placement of
repository tests, model checks, proof claims, and verification harnesses. Use
before retaining new or changed verification artifacts, or when auditing
existing verification quality.
---

# Verification leverage council

Read
[the repository verification policy](../../../AGENTS.md#verification-quality).
It owns the eligibility criteria, placement rules, and required user notice.

## Use the installed council

Load the installed `council-mode` skill and its pass contracts. Use the Pi
harness adapter and native `pi-subagents` workflow, not an invented council
command or another agent CLI. Resolve actual advisor profiles and configured
models before launch. Use the adapter's available read-only profile equivalents
when the upstream names are absent, and record the fallback and known context
mode.

This policy authorizes only the bounded read-only council needed for this
verification gate, subject to current operator restrictions. It does not
authorize implementation delegates, publication, deployment, or unrelated
investigation. If delegation is prohibited, required tools are unavailable, or
fewer than two advisors can review independently, record a blocked review. A
degraded single- advisor consultation is not council approval. The author cannot
self-approve.

Use two or three advisors, no more than four, with independent first-pass
reports and the installed workflow's bounded cross-examination. Do not
manufacture model diversity or hide a context-aware advisor. Do not silently
replace failed runs.

## Brief the reviewed contract

Supply the exact artifact reference and content, relevant implementation and
fixtures, proposed contract, chosen verification layer, expected oracle, and
qualifying leverage criterion. Include the actual result and claimed coverage.
For regressions, include the named past failure and original evidence. For
models and proofs, include bounds, assumptions, dependencies, native
correspondence, and known gaps. Do not brief only the author's conclusion.

Ask the council to inspect the artifacts and decide for each named contract:

- Does it meet a repository leverage criterion with concrete evidence?
- Is it in the correct layer? Would types, an assertion, a property-based test,
  a protocol model, or a substantive proof express the obligation better?
- What plausible incorrect implementation or false claim does it reject? What
  behavior-preserving refactor should leave it valid?
- Is its oracle independent? Can it pass without exercising the promised
  behavior?
- Are coverage, quantification, assumptions, and refinement claims honest?
- Does its benefit justify fixtures, runtime, duplication, and maintenance cost?

Review supporting cases and lemmas as part of the contract they support. Do not
approve an entire portfolio by file count, theorem count, or a green command.

## Decide and record

Use the installed council memo format. Add a per-contract verdict of `APPROVE`,
`REJECT`, or `BLOCKED`, the qualifying criterion, placement, reviewed content,
evidence, and reasons. Approval requires at least two explicit supporting
advisor judgments and no unresolved material objection. A demonstrated vacuous
oracle, false premise, wrong boundary, or missing required evidence blocks
approval. Document why any dissent was accepted or rejected; a vote count alone
is not a rationale. At the pass cap, unresolved material objections remain
blocked.

Keep advisor run IDs and a retrievable memo with the normal review artifacts. Do
not commit review transcripts unless the operator requests it. Approval applies
only to the reviewed content and contract. Material changes require another
review. Review independence is not a mathematical proof or implementation check.

Delete tests that do not obtain approval. Do not retain unapproved added model
or proof claims, and do not evade rejection by moving them. Report the required
three-part user notice from AGENTS.md before claiming retention or completion.
Existing artifacts are not retroactively approved by creating this skill.
