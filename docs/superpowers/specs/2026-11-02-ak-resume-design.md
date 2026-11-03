# Resume unfinished ak issues

The 2026-11-02 field run returned no workable issues while 18 open issues were
In progress or In review. The planner never considered those columns. Old setup
files also meant “running”, and any saved PR URL meant “shipped” indefinitely.
This violates the north star: the operator had to investigate the planner by hand.

## Repository status reviewed

At `b7f49bd`, v2 is the separate `ak` 0.1.0 plugin under `v2/`; v1 remains
alongside it. The current root workflow is plan, spawn, wait, collect, report.
Unlike the September draft and October 23 findings, current code has a transcript
waiter, wave settlement, and recovery commands. Recent fixes cover ship notices,
receipt grace and red receipts. This change uses those existing signals instead
of adding another root investigation step. Baseline planner: 259 assertions pass.
Baseline budgets: 3,999 code lines and 16,921 markdown bytes, below 5,000/40,960.

## Approach

Use the existing planner, run records, transcript reader and worker prompts.
Adding only board columns would still strand stale work; asking the root to
investigate every worktree would recreate the expensive orchestration v2 removes.
The command handles deterministic eligibility; the worker assesses completion.

- Keep Ready first, then In progress and In review, then Backlog with `--yolo`.
- Retain exclusions, dependencies, protected paths, collision handling and limits.
- Respect matched running transcripts even if commits are old. Persist the run's
  harness/session so a later invocation can find its worker. Ended workers are
  resumable. Without a transcript, use recent worktree activity, including staged,
  modified and untracked files, with the existing 20-minute wait threshold.
- Reuse only the expected git worktree and branch; never discard dirty files.
  Old setup markers alone must not hold work forever.
- Check a saved PR's current state. Open or unreadable PRs hold their issue;
  closed PRs do not prove an open issue complete. Preserve prior evidence in the
  new prompt and retire review/receipt state belonging to the previous PR.
- The worker compares issue acceptance criteria against code, commits, PRs,
  previous receipts and local changes, then continues only what remains. A park
  note is evidence to reassess, not permission to perform a manual/operator step.
- Do not infer dependency completion from a merged PR or close/groom issues.
  Existing collect semantics still refer to completion of a wave's PR, not the
  entire issue. This fix targets a fresh planning invocation.

## Interfaces and invariants

Extract planner recovery functions into `v2/lib/recovery.sh` and share worktree
activity inspection via `v2/lib/transcript.sh`. Run JSON adds `harness` and
`session` at the top level; old records use activity fallback.
No new flags, daemon, lease store, or root investigation loop. Preserve the last
PR result and receipt under `.ak/previous-*` so another interruption does not lose
the handoff. Those are evidence, never a new dispatch gate.
Live workers are never replaced because their last commit is old. Resuming
preserves tracked, staged, untracked and committed work byte-for-byte.

Evidence sources: [Git status porcelain](https://git-scm.com/docs/git-status)
supports stable, NUL-delimited output including untracked files;
[GitHub pull requests](https://docs.github.com/en/rest/pulls/pulls) expose current
state independently of the issue's state. Existing local transcript fixtures
define harness completion signals.
