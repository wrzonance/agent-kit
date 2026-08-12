# `--auto-serialize` — stacked worktree chains for conflicting issue batches

**Status:** approved design, pre-implementation
**Date:** 2026-08-12
**Owner decisions:** trust anchor = origin-reachable pinned SHA; ordering sources = file conflicts + intra-batch blockedBy

## Problem

`parallel-issues` Step 3 detects file-level conflicts between selected issues. Today the
responses are: attended — ask the user; `--fast-mode` — **drop the later issue of every
colliding pair**. Native `blocked-by` edges are stricter still: `pick-issues.sh` refuses to
offer an issue whose blocker is open, even when that blocker is being fixed in the same batch.
Conflicting or dependent work therefore costs one full run (and one merge round-trip) per link.

`--auto-serialize` converts both signals into **chains**: the later issue's worktree is created
from the exact commit the root produced for the earlier issue, its draft PR stacks on the
earlier branch, and nothing ever gates on a PR merge.

## Semantics

- Ordering evidence, exactly two sources (both mechanical, no prose parsing — issue bodies are
  untrusted and must not influence execution order):
  1. Step 3 file-conflict pairs ("#56 after #54");
  2. a selected issue's native `blocked-by` edge pointing at another issue **in the same
     selected set**.
- Build a DAG over the approved set; decompose into linear chains; independent components still
  run in parallel. A cycle is a planning error: report it and fall back to today's behavior
  (drop/ask) for the cyclic members.
- Attended: the chain plan is presented with the Step 3 table for approval. `--fast-mode`:
  proceed, printing the same plan.
- Chain depth cap: 4. Chains count against the existing 10-issue limit.
- Orthogonal to `--yolo` / `--trust-trunk` (#97): unattended chains thread the pinned-base
  trust below; attended chains use the batched per-worktree approval handoff.

## Chain scheduling (Phase 2)

For a chain edge A→B:

1. A dispatches normally (worktree from `origin/$base`, exactly today).
2. B's worktree creation and dispatch **defer** until the root has validated, committed, and
   pushed A's handback. The gate is the root's publication of A's commit — never A's PR state.
3. Root records `chain_base_sha` = the commit `worktree-commit.sh` just printed for A.
4. B's worktree: `git worktree add "$worktree" -b "$branch" "$chain_base_sha"` (the only
   change to the Step 5 recipe is the parameterized start point; push -u, per-worktree
   preflight, and `AGENT_CMD_SETUP` run unchanged).
5. B's dispatch prompt threads `--yolo --yolo-base $chain_base_sha` in the WHEN-yolo block, and
   states the base ("your branch is based on completed work for issue A at <sha>").
6. A's draft PR opens immediately on A's completion. B's opens on B's completion.

Slot accounting is unchanged: a deferred chain member occupies no slot until dispatched.

## Trust: `agent-run.sh --yolo-base <sha>`

New option. Requirements, all fail-closed:

- requires `--yolo` (usage error otherwise);
- value must be a full 40-hex commit SHA (no refs, no abbreviations — symbolic self-references
  are the trivial self-trust bypass);
- the SHA must be **reachable from some `refs/remotes/origin/*` ref** (`git branch -r
  --contains` non-empty). Workers cannot push; only root-published states can anchor trust.
  This preserves the gate's real property at its existing defense-in-depth level;
- the SHA must be an ancestor of the worktree's HEAD;
- when valid, `yolo_base_ref()` yields the SHA and the entire existing gate runs against it:
  `yolo_base_declarations` (base blob via `repo-config.sh --config-file`), `yolo_changed_input`
  diffs, canonical relevant-key comparison. No other gate logic changes; in particular,
  in-run `.agent/config.env` edits still refuse exactly as today.
- refusal and skip messages name the pinned base (`inputs match pinned base <sha7>`), so every
  log line records which anchor authorized the run.

## Publication

- A's PR: unchanged.
- B's PR: `gh pr create --draft --base feat/issue-A …` (the recipe already parameterizes
  `--base`), plus one generated body line:
  > Stacked on #<A-PR> — merge that PR first; GitHub retargets this one to `main`
  > automatically when its base branch is deleted on merge.
- Step 3c's ready-flip handoff lists the chain's merge order explicitly.
- Adversarial review and provider reviews already diff each PR against its own base; stacked
  PRs therefore review only their own delta. No review-loop changes.

## Failure modes (all fail-closed, no hidden state)

| Event | Behavior |
|---|---|
| Chain predecessor worker fails / BLOCKED | Successors never dispatch; chain parked with a named report |
| Predecessor gets review fixes after successor branched | Root merges predecessor's new head into successor's branch (existing Step 0b machinery) and **re-pins** `--yolo-base` to the new merge base — a root-only action, recorded in the run report |
| Operator drops a mid-chain issue | Downstream parks; never silently re-parented |
| Human merges a stacked PR before its base PR | Merges into the base *branch*, not `main` — mitigated by the body warning + ordered handoff; accepted residual risk |
| Cycle in ordering evidence | Report; cyclic members fall back to today's drop/ask |

## Touch map

| Surface | Change |
|---|---|
| `agentkit/skills/parallel-issues/SKILL.md` | Step 3 chain planning; Step 5 parameterized base; dispatch deferral rule; WHEN-yolo threading of `--yolo-base`; publication stacked-base + body line; Step 3c merge order; Limits (depth cap) |
| `agentkit/skills/.shared/scripts/agent-run.sh` | `--yolo-base` option (~30 lines: parsing, validation, `yolo_base_ref` override, message text) |
| `tests/test-agent-run-cmd.sh` | Red-first: valid pin passes and executes; non-origin-reachable SHA refused; non-ancestor refused; abbreviated/ref value refused; `--yolo-base` without `--yolo` usage error; refusal/skip messages name the pin |
| `tests/test-parallel-dispatch-contract.sh` | Recipe pins: parameterized worktree base, `--yolo-base` threading, stacked `--base` in `gh pr create`, stacked body line, merge-order handoff phrase, depth-cap prose |

Deliberately untouched (v1 / YAGNI):

- `pick-issues.sh` — chains form only over the explicitly selected / fast-mode-chosen set;
  batch-aware Ready-picking (offering a blocked issue because its blocker is in the batch) is
  deferred until a real run wants it.
- `worktree-commit.sh` — already legal on stacked branches.
- `review-remote-pr` — base-relative diffs already correct.

## Invariants

- Trust is anchored only at states the root published: trunk, or an origin-reachable ancestor
  SHA pinned by the root. A worker cannot widen its own anchor.
- A chain never gates on PR state — only on root-published commits.
- Every stacked PR reviews and merges exactly one issue's delta; merge order is stated
  wherever a human acts.
- Chain failures park downstream work loudly; nothing is silently dropped or re-parented.

## Test plan

Fixture-repo chains of length 2 in `test-agent-run-cmd.sh` (real commits, real origin refs via
`update-ref`), recipe-text assertions in the dispatch contract, and one full suite green via
`agent-run.sh --cmd test --yolo`. The `--yolo-base` validation tests are the security surface
and land red-first before any implementation.
