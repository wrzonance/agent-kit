# Interactive benchmark lifecycle implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan with TDD.

**Goal:** Submit interactive trials once and preserve scoring through CLI shutdown.
**Architecture:** CLI initial prompts plus transcript-confirmed startup, followed by guarded
cleanup and scoring. Retain the root transcript selected during startup.
**Tech stack:** Bash 5.2, jq, tmux, existing Python scorer and shell test framework.
**Spec:** `docs/superpowers/specs/2026-10-26-bench-tui-lifecycle-design.md`

## Global constraints

- One invocation, no synthetic resubmission, no model/permission/fixture changes.
- Own `.worktrees/fix/issue-1017`; draft PR base `feat/ak-wave-wait`; no merge.
- Use existing startup timeout and transcript schemas; no new dependency.

## Review focus

- Composer visible without a turn: bounded failure, no false startup success.
- Child transcript newer than root: select and score the root.
- CLI exits between interrupts: score and persist the completed work.
- Cleanup fails while session still exists: visible failure and retained outcome.
- CLI exits before receipts: failed trial, never a success based on absent process alone.

## Structures, interfaces, and spike

Use the existing `root` filepath and `rc` result; add startup/cleanup functions only where
needed. `wait_for_start` returns success with `root` set, `stop_session` returns cleanup
status. Existing `score.py` consumes the pinned root. The observed failed real smoke is
the diagnostic spike: its data is retained and excluded from comparison; no spike code remains.

### Task 1: Reliable trial lifecycle

**Files:** `bench/live/trial-tui.sh`, `tests/test-bench-trial-tui.sh`,
`tests/test-bench-tui-lifecycle.sh`, supporting test fixtures if necessary.

- [ ] Add regression tests for initial prompt delivery and durable startup evidence.
- [ ] Add regression tests for absent panes, cleanup errors, premature exit, and saved scores.
- [ ] Run the tests against the original runner; record expected failures.
- [ ] Implement initial prompt delivery and transcript-confirmed startup.
- [ ] Implement guarded shutdown and retain scoring on failure.
- [ ] Run focused suites and static checks; refactor only if needed to keep functions clear.
- [ ] Run the canonical gate with `AGENT_TEST_JOBS=4`, capture its complete log.
- [ ] Commit, run one unattended real Codex smoke, and record results without claiming A/B savings.
- [ ] Review the focused diff once, fix confirmed findings with regression tests, push,
      open the stacked draft PR with `Closes #1017`, and drive current-head CI green.
