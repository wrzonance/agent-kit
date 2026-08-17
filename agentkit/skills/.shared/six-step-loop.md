# The six-step ultracode loop

Read this when you are about to dispatch or perform implementation work — the loop is
required for every code-bearing change in `parallel-issues` (each issue lead) and
`review-remote-pr` (each mechanical fix-batch worker). It is the single detailed home for
the loop's steps, its reporting format, and the two gates that follow it; the dispatching
skill's own body states only that the loop is required and names this file for the detail.

Placement rule: helpers invoked by more than one skill live in `.shared/scripts/`; single-skill helpers live in `<skill>/scripts/`; nothing executable lives directly in `.shared/`.

**Worker prompts render this content verbatim, not as a pointer.** A dispatched worker
starts with `fork_context: false` — no memory of this session, no guaranteed read of any
file outside the pasted prompt. Copy the steps below into the prompt text itself; do not
replace them with "see `.shared/six-step-loop.md`" inside a worker message.

## The steps, in order

Stage 4 is the sole temporary-edit exception, fully reverted before Stage 5; production
implementation begins only at Stage 6.

1. **STRUCTS** — name or reshape the data structures the change introduces or touches
   first. Get the shapes right before behavior — behavior gets simpler once the data is
   correct.
2. **INTERFACES** — define the function/method contracts: inputs, outputs, and errors.
   Signatures only, no bodies yet.
3. **TODOS** — map every affected file, call site, import, wiring point, and verification
   command (each one written as an `agent-run.sh` invocation). This change-map sizes the
   work and exposes ripple before code is cut.
4. **SPIKE + REVERT** — for every code-bearing change, rough-implement one bounded
   vertical slice only far enough to expose what the design missed, record the learnings,
   then revert every spike change before tests or production code. Not optional for
   code-bearing work. A code-bearing change may declare the spike skipped only when its
   final diff has at most 10 changed implementation lines (tests, docs, and generated
   files excluded) and touches only an existing pattern: no new data shape, control flow,
   integration boundary, or failure mode. The handback must include the one-line form
   `SPIKE + REVERT: SKIPPED — <one-line justification>`. For a performed spike, use
   `SPIKE + REVERT: PERFORMED — transcript evidence: <spike edit reference>; <revert
   reference>`; the references must identify immutable transcript/tool evidence containing
   both the spike edit and the revert, not a prose narrative. A documentation-only or
   no-code change may report `SPIKE + REVERT: N/A — <concrete reason>`.
5. **INVARIANTS** — fold the spike's learnings back into the design, state the boundary
   pre/postconditions, and derive 5–10 ordered tasks (cap 12). These invariants become the
   tests, and little else — pin them at boundaries, not internals.
6. **IMPLEMENTATION (TDD)** — for each task: write a failing boundary test (red), verify it
   actually fails, make it pass minimally (green), refactor, and run scoped checks through
   `agent-run.sh`. Run the full suite the same way at the final task. Leave progress unstaged
   for handback.

### Changed-input trust-gate handoff

If `agent-run.sh --yolo` refuses because a named command input differs from the trust base, the
worker reports BLOCKED for that workstream and stops. The root treats the refusal as an
adjudication request: preserve the workstream, produce an input-diff digest with every changed
input, its diffstat, and each complete input diff, then choose `approve-with-record` through the
harness's interactive `agent-run.sh --approve --cmd NAME` flow or `park-and-hand-off`. The root
continues other workstreams. No trust record is forged, approval is not implied by `--yolo`, and a literal
command retry is not verification. If a changed input is a shared repo-root file, the handoff
notes the sibling PR merge conflict risk.

## Reporting format (must be explicit)

Report the checklist and its status; do not collapse the first five steps into "design" or
describe the loop only as "design → invariants → TDD." Name every step:

```text
Six-step loop: 1 Structs ✅ · 2 Interfaces ✅ · 3 Todos ✅ · 4 Spike + Revert ✅ ·
5 Invariants ✅ · 6 Implementation (TDD) in progress
```

`N/A` is valid only for Step 4, and only when the accepted scope contains no code changes.

## After Step 6 — two more gates, not folded into "implementation"

7. **REVIEW** — inspect the full scoped unstaged diff through three lenses: correctness,
   repo-rule/security, and tests. Try to refute every suspected finding before acting on
   it. Fix confirmed findings with regression tests; cap at two rounds.
8. **FINISH** — run the full repository verification through `agent-run.sh` from fresh
   output, confirm the scoped unstaged tree, and return a publication handback. The
   dispatching root — never the worker — owns board moves, metadata publication, forge
   actions, and any privileged command.

## Where each step maps for an orchestrated lead

| Loop step | Lead phase |
|---|---|
| Understand | Map code, tests, commands, conventions, ADR/prior art; use two read-only lenses when slots permit |
| 1. Structs | **Design** — name or reshape the data structures first; compare minimal-reuse and robust/failure-mode angles |
| 2. Interfaces | **Design** — define function/method contracts, inputs, outputs, and errors before implementation |
| 3. Todos | **Design** — map every affected file, call site, import, wiring point, and verification command; synthesize the design and decide `needsSpike` |
| 4. Spike + revert | **Spike** — rough-implement one bounded vertical slice only far enough to expose design mistakes, record learnings, then revert every spike change |
| 5. Invariants | **Invariants** — fold spike learnings back, state boundary pre/postconditions, and cut the ordered task list |
| 6. Implementation (TDD) | **Implement** — red → green → refactor per task; scoped checks per task and the full suite at the final task, all through `agent-run.sh`. Leave the scoped changes **unstaged**: a worker never runs `worktree-commit.sh` itself, it returns the exact invocation in its handback and the root runs it (see the `verify + ship` row) |
| review gate | **Review** — correctness, house-rules, and test lenses; adversarially verify before fixing; max 2 rounds |
| verify + ship | **Finish** — worker leaves scoped changes unstaged and returns a publication handback; the root alone verifies, commits, pushes, and publishes |
