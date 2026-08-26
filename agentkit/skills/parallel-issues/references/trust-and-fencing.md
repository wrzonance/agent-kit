# Verification cache and suite cadence

Command-approval fence removed 2026-08-19: `agent-run.sh` no longer gates a declared command
on an interactive approval or a trunk-comparison trust record, so this file no longer carries
the `--yolo`/`--approve`/command-trust rationale it used to. A declared command runs directly
through `agent-run.sh --cmd NAME`; there is no approval, no trust record, and no
changed-input refusal to adjudicate. What is left of this file — the verification cache below
— is a separate, still-live mechanism, unrelated to command approval.

Read this when deciding how often to re-run verification during red/green iteration.
`SKILL.md` keeps the pinned rule sentences; this file carries the rationale behind them.

## Verification cache and suite cadence

On a green completion for an eligible verification name (`test`, `lint`, `typecheck`,
`coverage`, `verify`, or `check`), `agent-run.sh` records evidence in the excluded
per-worktree `.agent/verification-cache`, keyed by the command name, execution directory,
and current tree state. Repeating the same eligible `--cmd` in the same directory on
unchanged bytes prints `agent-run: verification current: <log>` and exits 0; `--force`
bypasses that shortcut.

During red/green iteration, run focused suites for changed files, then run the full suite
once per tree state before commit. State-producing names such as `build`, `setup`, `seed`,
and `migrate` are always executed and never cached. After push, GitHub CI is authoritative
for that SHA; an unchanged local full-suite request is evidence-backed by the cache rather
than a new run.

## Worker baseline exclusions

Workers may opt into a baseline comparison for a failed check by supplying the chain-base ref,
failing test path, and stable test id to `agent-run.sh`. The helper runs the same command from an
isolated base checkout and writes `.agent/baseline-exclusion.md` only when the test blob and
normalized failure signature match. `BASELINE-EXCLUDED` means publication may continue; it is not
green evidence and must not unblock ready or merge. The file is rendered as an unchecked `Testing`
box carrying the resolved base SHA and evidence-log path.

During the root's final sweep, coalesce exclusions by test id and base SHA and propose one Backlog
candidate per distinct trunk failure. Candidates are observations only: never promote them to
Ready or otherwise mutate board status automatically.
