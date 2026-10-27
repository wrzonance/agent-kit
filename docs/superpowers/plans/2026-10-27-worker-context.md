# Worker Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce duplicated root instructions and worker context while preserving delivered work.
**Architecture:** Reference existing worker prompts; compact their playbooks and default tool output.
**Tech Stack:** Markdown, Bash 5.2, existing shell fixtures and fresh-context application tests.
**Spec:** `docs/superpowers/specs/2026-10-27-worker-context-design.md`

## Global Constraints

- Existing feature branch/worktree; user authorized commit and push before and after.
- Keep baseline checkout's local harness edits and result ledger intact.
- No model, scorer, acceptance, review requirement or CI scope changes.
- No second adversarial review of PR #1013; already completed in this branch.

## Review Focus

- Spaces in absolute prompt paths: dispatch preserves the whole path.
- A queued/merge-down redispatch: the worker reads the current prompt.
- Missing prompt: report the path; no guessed task or implementation.
- Shortened issue text boundary: tracker data never overrides playbook instructions.
- Pending shell handle / failing tests: preserve collection and failure evidence.

### Task 1: Reference dispatch and compact playbooks

**Files:** `v2/skills/{issues,pr}/SKILL.md`, `v2/templates/{issue,pr}-worker.md`,
`tests/v2/scenarios/worker-context.md`.
**Interfaces:** Existing spawn fields and rendered placeholders unchanged. Task message
carries cwd and prompt reference. Worker loads instructions itself, in a fresh context.

- [x] Save five control application responses, including full root dispatch messages.
- [x] Update root recipes and worker playbooks; keep all lifecycle requirements.
- [x] Run five fresh updated applications; inspect every response and actual prompt reads.
- [x] Run plan/pr-plan/collect/merge shell suites to verify rendering and redispatch.

### Task 2: Concise command output

**Files:** `v2/lib/{common,review}.sh`, `tests/v2/test-{common,review}.sh`.
**Interfaces:** `run_logged` keeps command start, PASS/FAIL, log path and heartbeat;
review reuse still returns original findings and never calls the provider.

- [x] Write assertions for concise success/log retention and actionable reuse; run red.
- [x] Remove repeated wait prose, retain diagnostics; replace reuse upsell with findings path.
- [x] Run common/setup/verify/review tests green and ShellCheck.
- [x] Run `AGENT_TEST_JOBS=4 tests/run-tests.sh`; inspect any failure and resolve within scope.
- [x] Record byte sizes, application outcomes and validation; commit and push with this completed change.

## State

Benchmark archive committed and pushed at 29a0709 before implementation.

## Evidence

- Control applications: 3/5 explicitly loaded full prompts in the root; another
  reloaded full contents for merge-down. One mistook the findings examples for
  severity-specific dispositions.
- First candidate: 5/5 used references; 1/5 truncated a path with a space. The
  final recipe names the field delimiters. Five fresh final samples all retained
  exact paths/name/model/effort and fresh context, kept review dispositions, and
  proceeded to CI after fixes. These are application samples, not live benchmarks.
- Actual transport test: a worker read a prompt in a path with spaces, returned
  its requested payload, reread a rewritten prompt on redispatch, then stopped
  and reported the exact path when assigned a missing file.
- `tests/v2/test-common.sh`: RED 1/38 -> GREEN 38/38; concise success, complete
  retained logs, heartbeat and failure diagnostics.
- `tests/v2/test-review.sh`: RED 1/69 -> GREEN 69/69; existing findings pointer,
  provider reuse and explicit `--again` behavior retained.
- `bash tests/v2/run.sh`: 19 suites / 1,221 assertions, zero failures.
- PR-plan's absolute-path assertion now checks the command definition because
  the template intentionally defines the path once. Required workflow is unchanged.
- `AGENT_TEST_JOBS=4 tests/run-tests.sh`: ALL GREEN, all static gates, 19 v2 suites /
  1,221 assertions and all 160 general suites. The prior preflight flake did not
  recur (251/251); its separate local fixture fix remains separate.
- Actual setup execution from the compact rendered playbook called the assigned
  absolute binary in the correct worktree, with spaces in both paths.
- Rendered issue brief with the same benchmark paths and requirements: 8,188 ->
  5,974 bytes (27.0% smaller). Live token effect remains to be measured.
