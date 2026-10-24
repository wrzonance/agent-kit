# ak waves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An `ak:issues` root spawns a wave, stays silent, and wakes exactly once when every worker of the wave
has reached an end state. Waves come from `--serialize` staging.

**Architecture:**
- `ak plan` tags each run item with a wave.
- A new `ak wait` watches each worker's result file and transcript, settles every worker (including the CI wait
  that collect does today), writes one summary, and exits.
- `ak collect --wave` releases the next wave.
- On Claude, one `UserPromptSubmit` hook swallows sub-agent completion notices while a live `ak wait` holds the
  wave open.
- Both harnesses are benched the same way: interactive under tmux, with one transcript scorer.

**Tech Stack:** bash 5.2, jq, git, the fake `gh` and harness stubs in `tests/v2/stub`, Python 3 (`bench/live/score.py`),
tmux (bench only).

**Spec:** `docs/superpowers/specs/2026-10-23-ak-wave-wait-design.md`. Read it first. Its "Settled after the
builder check" section is binding.

## Global Constraints

- bash 5.2 with `set -euo pipefail`; `LC_ALL=C` on every `sort` and `comm`.
- Helpers print only what the caller needs next.
- Refusals are two lines through `die` (the cause, then the fixing command). `usage_die` exits 2. Evidence
  failures exit 1.
- Shipped v2 code must pass the harness, environment and org neutrality gates (`tests/run-tests.sh --gates-only`).
  Harness branches go only through `harness()` in `v2/lib/common.sh`.
- `tests/v2/lint-budget.sh`: at most 120 lines per SKILL.md, 40,960 bytes of v2 markdown, and 5,000 lines of v2
  code (3,149 today).
- Exactly one hook in all of v2: a `UserPromptSubmit` command hook on the Claude plugin. Nothing else may be
  hooked. The gate is rewritten in Task 8 to enforce exactly that.
- The hook fails open, does no network calls and no state writes, and costs one file read plus one string match
  per prompt.
- Hang threshold default 1200 s via `AK_WAIT_HANG_S`.
- Codex fallback wait: `wait_agent` with the literal `timeout_ms=3600000`.
- The worker template is unchanged, except that a worker never messages the root mid-run.
- Suites follow `tests/v2/test-*.sh`: `TEST_NAME`, `source lib.sh`, fixtures in `$WORK`, the `assert_*` helpers, and
  `finish`.
- v2 is at version `0.1.0`, untagged. Shipped bytes may change. Re-check `git tag` before the last commit; if `0.1.0`
  was tagged meanwhile, run `tests/prepare-next-version.sh` first.
- Work in `.worktrees/feat/ak-wave-wait`, on branch `feat/ak-wave-wait` from `origin/main`. Conventional Commits,
  with `Co-Authored-By` naming the agent that did the work.
- No field host, field repository or company names in any commit, PR or fixture (`docs/v2-open-findings.md`
  convention).

## Review Focus

1. **Operator types a message while a wave is open.** It must reach the root at once; the hook passes every source
   except agent task notices. Owned by Task 8.
2. **A stale or reused pid in `.ak/wave.open`** after a crash or reboot must never block. The marker stores the pid
   and that process's start time (field 22 of `/proc/<pid>/stat`, or `ps -o lstart=` where `/proc` is absent).
   The hook blocks only when both match. Owned by Tasks 6 and 8.
3. **A second Claude session in the same checkout** (the operator's ad-hoc session) must not lose its own agent
   notices. The marker records the root's session id, and the hook blocks only on a match. S1 finds where `ak
   wait` reads the session id. If none is readable, the hook blocks only when the marker's recorded cwd equals
   the hook input's `cwd`, and the PR states that limit. Owned by Tasks 6 and 8.
4. **A worker that finished before `ak wait` started** must count as reported at once. It must not wait for the hang
   threshold. Owned by Task 6.
5. **A correction round reuses a worktree whose old `.ak/result` exists.** Only a result newer than the `ak wait
   --issue` call counts. Owned by Task 7.

---

### Task 0: Spikes (throwaway; record results, then revert)

**Files:**
- Create: `docs/superpowers/specs/2026-10-23-ak-wave-wait-spikes.md` (kept; the spike code is not).

Each spike is run by hand in a scratch directory under `.worktrees/spike`, with a throwaway hook or script, and
removed afterwards. Record each result as: question, what was run, observed output, and verdict.

- [ ] **S1 (Claude):** install a throwaway `UserPromptSubmit` hook that logs its stdin JSON to a file and returns
  `{"decision":"block"}` when the prompt contains `<task-notification>` and `Agent`. Spawn two background
  sub-agents that each sleep 30 s and end. Record:
  - the JSON the hook received (field names: `source`, `prompt`, `session_id`, `cwd`);
  - whether the notice reached the model;
  - whether a human message still passes;
  - how a Bash-task notice differs from an agent-task notice;
  - which env var or file gives a Bash command the session id;
  - whether a hook in the installed plugin (`v2/hooks/hooks.json`) is active without user config.

  **Gate:** if the block is not honored, stop and report to the operator. Do not continue to Task 8.
- [ ] **S2 (Codex):** in an interactive Codex session, have the root run `sleep 900; echo done` through the shell
  and wait on it. Record the longest stretch with no model turn, and the `yield_time_ms` values involved. Repeat
  with a spawned child finishing during the sleep, and record whether the child's completion interrupted the
  shell wait.

  **Gate:** if the shell can stay blocked ≥ 30 min without a model turn, the Codex root uses blocking
  `ak wait` (path A). Otherwise it loops `wait_agent timeout_ms=3600000` with `ak wait --check` (path B).
- [ ] **S3 (both):** from a real two-worker run on each harness, record:
  - the transcript path of each worker and how it can be found from the worktree path or the prompt's first line;
  - the exact final records of a worker that ended normally, one killed (`TaskStop` / `interrupt_agent`), and one
    whose session errored.

  Copy minimal, scrubbed examples into `tests/v2/fixtures/transcripts/{claude,codex}/` (Task 6 uses them).
- [ ] **S4 (Claude):** run `sleep 4000` as a background Bash task in an interactive session. Record whether it is
  killed, and when.

  **Gate:** if it is killed before the end, Task 6 adds the hand-off (re-exec keeping state) and S4's limit
  becomes `AK_WAIT_HANDOFF_S`.
- [ ] Commit the spikes file only:

```bash
git add docs/superpowers/specs/2026-10-23-ak-wave-wait-spikes.md
git commit -m "docs(spec): ak waves spike results"
```

### Task 1: One scorer for both harnesses

**Files:**
- Modify: `bench/live/score.py`, adding a Claude reader beside `score_thread`.
- Create: `tests/test-bench-live-score.sh`, `tests/fixtures/bench-live/{claude,codex}/` (tiny transcripts).

**Interfaces:**
- Produces:
  - `score.py ROOT [--sessions DIR] [--harness codex|claude]`: the existing record shape. The harness is
    auto-detected from the first line when not given.
  - Two new `root` fields, on both harnesses:
    - `wakes`: `{"total": int, "by_trigger": {"agent_done": int, "bash_done": int, "teammate": int, "human": int, "hook": int, "other": int}}`.
    - `cache_read_tokens`: int.
  - Claude workers are read from `<session>/subagents/agent-*.jsonl`. Tokens are deduplicated by `message.id`.

- [ ] **Step 1: Write the failing test** `tests/test-bench-live-score.sh`, scoring a fixture of each harness:
  - Claude fixture: 1 human prompt, 2 agent task notices, 1 Bash notice, and 2 assistant lines sharing one
    `message.id`. Assert `root.wakes.by_trigger.agent_done == 2`, `bash_done == 1`, `human == 1`, and that tokens
    are counted once for the duplicated id.
  - Codex fixture: assert the existing fields are unchanged, and that `wakes.total` equals the number of
    `wait_agent` returns plus user turns.
- [ ] **Step 2:** run `bash tests/test-bench-live-score.sh`. Expected: FAIL (`wakes` missing).
- [ ] **Step 3:** implement:
  - `score_claude(path: Path) -> dict` returning the same counter keys as `score_thread`;
  - `wakes(...)`;
  - harness detection.

  `build()` picks the reader by harness and keeps its output keys.
- [ ] **Step 4:** run the test. Expected: PASS. Then run `tests/run-tests.sh --gates-only`. Expected: ALL GREEN.
- [ ] **Step 5:** commit: `test(bench): score Claude and Codex roots into one record, with wakes by trigger`.

### Task 2: Interactive tmux arm for both harnesses, and the two-wave fixture

**Files:**
- Create: `bench/live/trial-tui.sh` (it sources the shared setup from `trial.sh` where possible; split out
  `bench/live/trial-lib.sh` if that needs more than a few lines of moving).
- Create: `bench/issues/11-…md` … `14-…md`: two independent tally issues, each with a dependent whose acceptance
  needs its partner's change.
- Modify: `bench/live/batch.sh` to accept `--harness codex|claude`.
- Create: `tests/test-bench-trial-tui.sh` (dry-run only, with stub `tmux`, `codex` and `claude` on PATH).

**Interfaces:**
- Consumes: `score.py` from Task 1.
- Produces: `trial-tui.sh --harness codex|claude --ref GITREF --issues "11 12 13 14" [--model M] [--effort E] [--timeout S] [--dry-run]`.
  - It starts the interactive CLI in a detached tmux session with the kit at GITREF installed in a private
    `CODEX_HOME` or Claude config dir.
  - It sends exactly one line: `$ak:issues --serialize --yolo --limit 4` (Codex) or `/ak:issues --serialize --yolo --limit 4` (Claude).
  - Done means every fixture issue has an open PR with a receipt comment, or the timeout passes.
  - Each run appends one ledger row with `"mode": "tui"` and `"harness": …`.

- [ ] **Step 1: Write the failing test.** In `--dry-run` with stubs, assert:
  - the tmux command sequence (new-session, then exactly one send-keys of the invocation, then nothing else
    typed);
  - the private config dir;
  - that the stubs' environment has no `CLAUDE*` or `CODEX_THREAD_ID` leak.
- [ ] **Step 2:** run it. Expected: FAIL (no script).
- [ ] **Step 3:** implement `trial-tui.sh` and the four fixture issues. Reuse `sandbox.sh reset`, `outcome.sh` and the
  `scrub` env list from `trial.sh`.
- [ ] **Step 4:** run the test. Expected: PASS. Then run `tests/run-tests.sh --gates-only`. Expected: ALL GREEN.
- [ ] **Step 5:** commit: `test(bench): interactive tmux trials for Codex and Claude, and a two-wave fixture`.

### Task 3: Baseline on current main (operational, no code)

- [ ] Check the GraphQL pool with `gh api graphql -f query='query{rateLimit{remaining resetAt}}'`. Continue only
  above 1,000.
- [ ] From `.worktrees/bench/baseline`, run 3 trials per harness against `origin/main` at the plan's start SHA,
  ABBA ordered: `bench/live/batch.sh --harness codex …` and `--harness claude …`.
- [ ] Commit the ledger rows: `chore(bench): baseline two-wave fixture on main, both harnesses, interactive`.
  Record per arm: median root wakes, root cache-read tokens, worker tokens, wall-clock, and acceptance passes.

### Task 4: Plan tags waves

**Files:**
- Modify: `v2/lib/plan.sh`: `write_run` (items gain `wave`) and `choose` (`after` lines gain `wave=N`).
- Test: `tests/v2/test-plan.sh`.

**Interfaces:**
- Produces:
  - Run item `wave: int`. It is 1 when `needs` is empty, otherwise 1 + the maximum `wave` over `needs`, computed
    in `CHOSEN` order.
  - Run field `open_wave: 1`.
  - `after` lines read `after issue=N needs=M,… wave=W`.
  - `stack_parent` blockers outside the run add no wave.

- [ ] **Step 1: Write the failing tests** in `test-plan.sh`, using `plan --serialize` on a board with A, B, C, where
  B needs A and C needs B:
  - `after issue=B needs=A wave=2`;
  - `after issue=C needs=B wave=3`;
  - the run file has waves `1 2 3` and `open_wave` 1.

  Also assert that an issue stacked on an out-of-run shipped blocker has `wave` 1.
- [ ] **Step 2:** run `bash tests/v2/test-plan.sh`. Expected: FAIL on the new assertions.
- [ ] **Step 3:** implement as specified in Interfaces.
- [ ] **Step 4:** run `bash tests/v2/run.sh`. Expected: all v2 suites pass. Update the existing `after` assertions
  for the new field; no other output change is allowed.
- [ ] **Step 5:** commit: `feat(plan): tag each run item with its wave`.

### Task 5: Release at the wave boundary only

**Files:**
- Modify: `v2/lib/collect.sh`:
  - extract `collect_one KIND N`, the body of `cmd_main` from `collect_item` through `run_update`, with no release;
  - `cmd_main` calls `collect_one`;
  - the `spawn_successors` and `release_other_runs` calls move to the new wave form.
- Test: `tests/v2/test-collect.sh`.

**Interfaces:**
- Produces:
  - `collect_one KIND N`: sets `LINES`, `RESULT_*` and the item state exactly as today. Task 7 consumes it.
  - `ak collect --wave`:
    - Refuses while any item of `open_wave` is `spawned`. The refusal is `die "wave W is still open: N,…" "ak wait"`.
    - Otherwise it marks the wave's dependents of `parked`, `red` or `blocked` items, transitively, as state
      `held`, and prints `held issue=N reason=waits-on-<state>-#M` for each.
    - It spawns the releasable items of wave W+1 through `spawn_successors` (stack base unchanged) and sets
      `open_wave` to W+1.
    - When no later wave remains, it prints `wave=done`.
  - `held` is not active in `issue_active`, so `ak plan --issue N` re-plans it.

- [ ] **Step 1: Write the failing tests.**
  - `collect --issue` of a green wave-1 item prints no `spawn` line, and the wave-2 item stays `queued`.
  - `collect --wave` with one item still `spawned` exits 1 with `wave 1 is still open`.
  - With all of wave 1 collected, it prints the wave-2 `spawn` line, stacked on its partner's branch.
  - With one wave-1 item parked, its dependent and that dependent's own dependent print `held …`, and the other
    wave-2 item spawns.
  - `plan --issue <held>` plans it again.
- [ ] **Step 2:** run `bash tests/v2/test-collect.sh`. Expected: FAIL on the new tests. Existing chain tests that
  expected a mid-wave spawn now fail; rewrite them to the wave rule, and list each rewritten assertion in the
  commit body.
- [ ] **Step 3:** implement as specified in Interfaces.
- [ ] **Step 4:** run `bash tests/v2/run.sh`. Expected: PASS.
- [ ] **Step 5:** commit: `feat(collect): release the next wave only when the whole wave is in`.

### Task 6: `ak wait`, end states and the open-wave marker

**Files:**
- Create:
  - `v2/lib/wait.sh`: `cmd_main`, the watch loop, and the marker;
  - `v2/lib/transcript.sh`: per-harness transcript discovery and end detection, from S3;
  - `tests/v2/test-wait.sh`;
  - `tests/v2/fixtures/transcripts/…` (from S3).
- Modify: `v2/bin/ak` usage (root: `wait [--issue N]… [--check]`).

**Interfaces:**
- Consumes: the run file (`open_wave`, `items[].wave`, `.worktree`, `.state`) from Task 4.
- Produces:
  - `transcript_find WORKTREE`: prints the worker's transcript path or nothing.
  - `transcript_state PATH`: prints `running`, `ended` or `errored`.
  - `transcript_age PATH`: prints seconds since its last growth.
  - `wave_state`: one line per watched item, `issue=N state=reported|ended-without-result|hung|unwatched|running`.
  - The marker `$MAIN/.ak/wave.open`, one `key=value` per line: `pid=<pid>`, `start=<proc start time>` and
    `session=<id or empty>`, plus `cwd=<root cwd>` when no session id is readable (S1).
  - Exit codes: `ak wait --check` exits 0 when every item is settled and 3 when any is still running. `ak wait` exits
    0 when settled and 1 when the run is unreadable.
  - A second `ak wait` while a live marker exists attaches: it waits for the marker to clear, then prints the same
    summary. It never starts a second watcher.

- [ ] **Step 1: Write the failing tests** (`AK_WAIT_POLL_S=1`, `AK_WAIT_HANG_S=3`), one per case:
  - The result exists before the call: `reported` at once (Review Focus 4).
  - An ended transcript and no result: `ended-without-result` without waiting for the threshold.
  - A transcript not grown for 3 s: `hung`.
  - No transcript match and an idle worktree: `unwatched` after 3 s, with the fallback named in the line.
  - A marker carrying a live pid but the wrong start time is treated as stale and replaced (Review Focus 2).
  - `--check` returns 3, then 0 after a result appears.
  - The marker is gone after `ak wait` exits.
  - A second concurrent `ak wait` attaches and does not create a second marker.
- [ ] **Step 2:** run `bash tests/v2/test-wait.sh`. Expected: FAIL (no command).
- [ ] **Step 3:** implement.
  - Sleep in `AK_WAIT_POLL_S` steps (default 15). Print nothing until settled.
  - If S4 found a limit, re-exec before `AK_WAIT_HANDOFF_S`, keeping the marker's pid line updated to the new
    process.
- [ ] **Step 4:** run `bash tests/v2/run.sh` and `tests/v2/lint-budget.sh`. Expected: PASS.
- [ ] **Step 5:** commit: `feat(wait): ak wait settles every worker of a wave from result files and transcripts`.

### Task 7: `ak wait` settles with CI, prints the summary, and runs correction rounds

**Files:**
- Modify: `v2/lib/wait.sh`, which sources `collect.sh` for `collect_one`.
- Test: `tests/v2/test-wait.sh`.

**Interfaces:**
- Consumes: `collect_one` (Task 5) and `wave_state` (Task 6).
- Produces:
  - **The summary**, printed and also written to `$MAIN/.ak/runs/<run>.wave<W>.summary`:
    - for a `reported` worker, the `collect_one` lines;
    - for any other state, `issue=N state=<state> next=<recovering command>`;
    - last, one line `wave=W settled=K/N summary=<path>`.
  - **Correction rounds:** `ak wait --issue N…` (and `--pr N`) watches only the named items. It counts a result only
    when its mtime is newer than the call (Review Focus 5). Correction items are added to the open wave in the run
    file.

- [ ] **Step 1: Write the failing tests.**
  - A reported item with a stub PR whose checks are pending, then green: the summary shows `ci=green`, no root
    call is needed, and the wait covered the CI time.
  - A `hung` item: `next=` names stopping the worker and `ak plan --issue N`.
  - `--issue 12` with an old result in place keeps waiting until a newer result is written.
  - The summary file exists and its last line is `wave=1 settled=2/2`.
- [ ] **Step 2:** run the suite. Expected: FAIL on the new tests.
- [ ] **Step 3:** implement as specified in Interfaces.
- [ ] **Step 4:** run `bash tests/v2/run.sh`. Expected: PASS.
- [ ] **Step 5:** commit: `feat(wait): the wake carries every worker's final CI state; corrections wait on named workers`.

### Task 8: The one Claude hook, and a gate that allows only it

**Files:**
- Create: `v2/hooks/hooks.json` and `v2/hooks/wave-barrier.sh`.
- Modify:
  - `v2/.claude-plugin/plugin.json`, only if S1 showed a manifest entry is needed;
  - `tests/v2/lint-budget.sh`.
- Test: `tests/v2/test-hook.sh`.

**Interfaces:**
- Consumes: the marker format (Task 6) and the hook input field names (S1).
- Produces: `wave-barrier.sh`. It reads the hook JSON on stdin with bash parameter matching, never `jq`.
  - **It prints `{"decision":"block"}` and exits 0 only when all of these hold:**
    - the prompt is an agent task notice (S1's distinguishing string);
    - the marker exists in the main checkout found from the hook's `cwd` through `git rev-parse --git-common-dir`;
    - the marker's pid is alive and its start time matches;
    - the marker's session (or cwd fallback) matches the input.
  - **In every other case**, including any internal error, it prints nothing and exits 0.

- [ ] **Step 1: Write the failing tests** in `tests/v2/test-hook.sh`. Each case pipes a JSON input built from S1's
  recorded shape:
  - An agent notice, live marker, same session: blocked.
  - A human prompt with a live marker: passes (Review Focus 1).
  - A Bash-task notice: passes.
  - A dead-pid marker, and a live pid with the wrong start time: both pass (Review Focus 2).
  - A different session id: passes (Review Focus 3).
  - Malformed stdin: passes, exit 0.
  - Elapsed time for 100 runs stays under 2 s on the CI runner.
- [ ] **Step 2:** rewrite `lint-budget.sh`'s hook check so it fails unless `v2/hooks/hooks.json` declares exactly one
  event, `UserPromptSubmit`, with exactly one command, `wave-barrier.sh`, and no other file in `v2/hooks/`
  besides those two. Assert the gate in the test by adding a second event to a copy and expecting failure.
- [ ] **Step 3:** run `bash tests/v2/test-hook.sh`. Expected: FAIL (no hook).
- [ ] **Step 4:** implement `hooks.json`, with the command through `${CLAUDE_PLUGIN_ROOT}/hooks/wave-barrier.sh`, and
  the script.
- [ ] **Step 5:** run `bash tests/v2/run.sh`, `tests/v2/lint-budget.sh` and `tests/run-tests.sh --gates-only`.
  Expected: PASS and ALL GREEN.
- [ ] **Step 6:** commit: `feat(hooks): one Claude hook that holds worker notices while a wave is open`.

### Task 9: The skill and plan text

**Files:**
- Modify:
  - `v2/skills/issues/SKILL.md`, steps 3–5;
  - `v2/lib/plan.sh` `run_lock`, for the slow notice;
  - `v2/templates/issue-worker.md`, one line.
- Test: `tests/v2/test-plan.sh` and `tests/v2/test-common.sh` where the notice is pinned.

**Interfaces:**
- Consumes: `ak wait`, `ak collect --wave`, and the S2 verdict.
- Produces:
  - **SKILL.md steps 3–5 (wording is the builder's; the content is fixed):**
    - After spawning every `spawn` line, start `ak wait`. On Claude, start it as a background shell task and end
      the turn. On Codex, use path A (run `ak wait` and wait on it) or path B (`wait_agent timeout_ms=3600000`;
      on each return run `ak wait --check`; exit 3 means wait again with no words).
    - Spawn nothing else and send nothing while a wave is open.
    - On the wake, read the summary, review every worker, and hand corrections back (Claude `SendMessage`, Codex
      `followup_task`). Then run `ak wait --issue N…` the same way.
    - When satisfied, run `ak collect --wave` and spawn its `spawn` lines.
    - Repeat until `wave=done`, then print the summaries as the report.
  - **`run_lock`:** the backgrounded `still working` notice prints only when `harness` is `codex`. It prints
    nothing at all if S2 chose path B. Builder's call per the spec, recorded in the commit.
  - **Worker template:** a worker does not message the root. When it cannot proceed, it runs `ak park --reason`.

- [ ] **Step 1: Write the failing tests.**
  - Under `CLAUDECODE=1`, `ak plan` stderr carries no `still working` line even past `AK_SLOW_NOTICE`.
  - Under `CODEX_THREAD_ID`, it follows the S2 verdict.
- [ ] **Step 2:** run them. Expected: FAIL.
- [ ] **Step 3:** implement the three edits. Keep SKILL.md ≤ 120 lines and v2 markdown ≤ 40,960 bytes.
- [ ] **Step 4:** run `bash tests/v2/run.sh`, `tests/v2/lint-budget.sh` and `tests/run-tests.sh`. Expected: PASS
  and ALL GREEN.
- [ ] **Step 5:** commit: `feat(issues): the root waits once per wave and stays silent between waves`.

### Task 10: Measure the change on both harnesses (operational)

- [ ] Reinstall the kit from the branch head into each trial's private config (`trial-tui.sh` does this per run).
- [ ] Run 3 trials per harness, ABBA against the Task 3 baseline SHA, on the same fixture.
- [ ] Commit the ledger rows: `chore(bench): two-wave fixture on feat/ak-wave-wait, both harnesses`.
- [ ] Open one draft PR for the branch (`gh pr create --draft`).
  - The body's Why carries the W1 numbers.
  - The What carries the before/after table per harness: wakes per wave, root cache-read tokens, worker tokens,
    wall-clock, and acceptance passes.
  - Link `Closes` to the W1 issue if the operator filed one; otherwise name `docs/v2-open-findings.md` W1.
  - **Acceptance:** Claude root wakes per wave = 1. Codex = 1 on path A, ≤ workers per wave on path B. Acceptance
    passes equal to baseline.
