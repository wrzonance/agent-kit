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

