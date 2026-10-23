# ak waves: one root wake per wave

Status: design, approved in conversation 2026-10-23, written up for planning.

## Intent

The root of an `ak:issues` run is a reviewer. It spawns a wave of workers, each in its own worktree, and then
does nothing at all until every worker in the wave has reported. It wakes once, reviews the whole wave, hands back
corrections, and starts the next wave. Silence between waves is the whole point: every root wake re-reads the
root's full context, and those re-reads are the largest cost the kit has (`docs/v2-open-findings.md`, W1).

Measured on field runs between 2026-10-09 and 2026-10-23:

- **Claude root, 4,381 turns, 2.25B cache reads.** Of 927 wakes:
  - 325 were the root's own background `sleep`/`until` polls finishing (47% of all reads).
  - 313 were teammate idle notices (25%).
  - 70 were goal-hook re-injections.
  - 33 were real worker hand-backs. Only those always led to action.
  - About a quarter of all wakes did nothing.
- **Codex roots.** 293 `wait_agent` calls, 224 of them with `timeout_ms=60000`. 54% timed out empty, each a turn
  of about 96k input tokens.
- **For scale:** the live bench delivers 3 small issues for 1.5–2.2M tokens in total.

## Goals

- **Exactly one root wake per wave on Claude**, when the last worker of the wave reaches an end state.
- **One wake per wave on Codex** if the spike (Task 0, S2) shows a shell call can block for a wave's length.
  Otherwise one cheap wake per finishing worker, with no timed-out waits.
- **A root is never left asleep.** A worker that crashes, is logged out, or hangs still ends the wave.
- **`--serialize` becomes wave staging.** Wave 1 is every chosen issue that can start now. Wave N+1 is every
  issue whose blockers are all in waves ≤ N. Each wave-N+1 issue is stacked on its blocker's branch, as today.
- **The wake hands the root everything it needs in at most one further call:** every worker's result line and
  end state.

## Non-goals

- Progress reporting while a wave runs. The operator asked for complete silence.
- Changing how workers do their job: the worker template, ship, review, CI and receipt stay as they are.
- Keeping the root alive across a dead root process. If the root's process dies, the session is gone; the wave
  state on disk only lets the next `ak` call resume instead of starting blind.
- Merging. `ak merge` and `ak:pr` are out of scope.

## Anti-goals (what makes this a failure even if it works)

- **A web of hooks.** The v1 kit's hook structure caused large tool churn. This design adds exactly one hook, on
  Claude only, and it acts only on worker completion notices while a wave is open. No tool-call guards, no
  per-tool hooks, no hook that can refuse a command.
- **A wait that can hang the root forever** (see the deadman below).
- **Turns spent on approvals the invocation already granted.**
- **Any new rule that costs a root turn without a measured saving.**

## Decided by the operator

1. **Complete silence between waves.** The root takes no turns, does no polling, sends no relays, and answers no
   progress messages.
2. **One wake per wave, even if that takes one hook.**
3. **`--serialize` semantics.** `ak:issues --serialize --yolo --limit 20` reads Ready and Backlog. It starts wave 1
   with everything independent and stages the dependents as wave 2, stacked on their wave-1 partner's branch.
4. **Wave 2 starts only when wave 1 is finished:** every wave-1 issue has a draft PR with a review receipt,
   after the root's review and any correction rounds.
5. **A durable deadman.** A separate process, started by the root, is the authority on each worker's end state.
   It covers crashed, logged-out and hung workers.
6. **The hook stays minimal.** No v1-style hook web.

## Behavior

### Waves

`ak plan` sorts the chosen issues into waves. An issue's wave is one more than the highest wave among its
`needs`, so independent issues land in wave 1. Plan already computes `needs` and `stack` for its `after` lines, so
this regroups existing data. Plan prints `spawn` lines for wave 1 only, plus one line per later wave naming its
issues. The run file records each item's wave.

Mid-wave release goes away: `ak collect` no longer spawns successors when a single worker comes back. The next
wave is released only by the wave-boundary step below.

A wave-N issue whose blocker ended parked, red or unrecoverable is held, together with its own dependents. The
rest of wave N+1 still starts. The release step prints one line per held issue and why.

### The wait (`ak wait`)

A new root command, started right after the root has spawned every worker of a wave.

- It reads the current run's open wave from the run file.
- For each worker, it watches two durable signals:
  - **The result file** (`.ak/result` in the worker's worktree), written by `ak receipt` or `ak park`.
  - **The worker's transcript file.** A Claude sub-agent writes `subagents/agent-*.jsonl` under the root session's
    project directory, and a Codex child writes its own rollout file. While the worker works, the file grows;
    when it ends, its last records say so.
- Each worker reaches exactly one end state:
  - **reported:** the result file exists, and is newer than the wave (or correction round) start.
  - **ended-without-result:** the transcript shows the worker ended (finished, errored, logged out) and no result
    exists. This is detected as soon as the transcript ends, with no timeout.
  - **hung:** the transcript has not grown for the hang threshold. The default is 20 minutes, configurable,
    and it must stay above the longest single tool call a worker makes.
  - **unwatched:** no transcript could be matched to the worker. It then falls back to worktree and `.ak/` log
    activity under the same threshold. The summary says the fallback was used.
- When every worker has an end state, `ak wait` writes the wave summary to disk, prints it, and exits 0. The
  summary has one line per worker (issue, end state, the result line if any, and for non-reported states the
  command that recovers it), then one wave line.
- **Corrections:** `ak wait --issue N [--issue M]…` waits only on the named workers, for a result newer than the
  call. The root uses it after handing corrections back: Claude resumes the finished sub-agent with
  `SendMessage`, Codex uses `followup_task`.
- **Durable state:** state lives under `.ak/` in the main checkout. A second `ak wait` attaches to the first's
  state instead of starting a second watcher. An `ak wait` started after the root restarted reports the wave as
  it stands.
- The watcher never kills or restarts a worker. It reports. The root stops a hung worker (Claude `TaskStop`,
  Codex `interrupt_agent`) and re-spawns or parks it during its review.

### How the root waits on each harness

**Claude:**
- The root runs `ak wait` as a background Bash task.
- Every worker's own completion notice is swallowed by the hook below, so the only notice that reaches the root
  is `ak wait`'s exit. That is the one wake.
- Its first call after waking reads the summary: the task's output, or a command `ak wait` names.

**Codex:**
- A child's completion cannot be swallowed. `wait_agent` returns on any child's mailbox activity, and Codex hooks
  cannot suppress that or wake an idle root.
- So, pending the spike: the root blocks on `ak wait` directly through the shell.
- If the spike shows a single shell call cannot stay blocked for a wave's length, the fallback is the root
  looping `wait_agent` with the literal `timeout_ms=3600000` (the hard maximum, verified in the source),
  answering each return with nothing but the next wait, until `ak wait --check` says the wave is settled.

### The one hook (Claude only)

A `UserPromptSubmit` command hook shipped with the ak Claude plugin. It is the first hook ak v2 ships.

- **Blocks:** a prompt that is a sub-agent completion notice (source `system`, a `<task-notification>` for an
  agent task) while the current checkout has an open, unsettled wave. The hook returns `decision: "block"`.
- **Passes, always:** human input, every other source, `ak wait`'s own exit notice, and everything when no wave is
  open or the wave is settled. `ak wait` marks the wave settled before it exits.
- **Its whole cost:** one file test and one string match per prompt. No network, no `jq` over large input, no
  state writes.
- **Fails open:** if anything in the hook errors, the prompt passes. The worst case is the extra wakes we have
  today, never a lost message.
- **Nothing is lost by blocking:** every worker's outcome is on disk, and `ak wait` reads it from there.

### Removed

- **The background "still working" notice** that `run_lock` prints after 3 s. It made roots re-run `ak plan`
  (35+ times seen). If Codex's shell yield still needs a hint, it prints only under Codex. Builder's call after
  the spike.
- **Step 3 of `skills/issues/SKILL.md`** ("wait with your harness's native wait, using the longest window") is
  replaced by the literal per-harness recipe above.

## Interfaces (shape, not final)

- `ak plan`: unchanged flags. Output adds the wave of each `after` line, or a `wave=N issues=…` line per later
  wave.
- `ak wait [--issue N]… [--check]`: blocks until settled and prints the summary. `--check` prints the state once
  and exits (0 settled, 3 still open). Exit 1 means it could not read the run.
- `ak collect`: per-issue collection stays. A new wave-boundary form (for example `ak collect --wave`) refuses
  while the wave is unsettled. Once settled, it records the wave accepted and prints `spawn` lines for the next
  wave's releasable issues and `held` lines for the rest.
- **Run file:** each item gains `wave`. The run gains the open wave number and its settled state. The watcher
  state lives next to it.
- **Hook:** `v2/hooks/` plus the Claude plugin manifest entry. Codex gets no hook.

## Constraints

- **North star and AGENTS.md rules:**
  - Each helper prints only what the caller needs next.
  - Refusals name the cause and the fixing command.
  - bash 5.2, `set -euo pipefail`, and `LC_ALL=C` on every sort.
  - The harness-, environment- and org-neutrality gates.
  - The size ratchets: raise a ceiling only with an issue named.
- **Must run on both Claude and Codex**, through the existing `harness()` detection in `v2/lib/common.sh`.
- **The worker template stays as it is**, except that a worker never messages the root mid-run. It parks with a
  reason instead.
- **Tests at the module boundary**, using fixture transcripts for both harnesses (ended, still growing, stale)
  and fixture run files.
- **Bench before and after, measured the same way on both harnesses** (operator: "consistent so that both Codex
  and Claude are measured accurately and in as much the same way as possible"; the method is the designer's call).
  - **Interactive, never headless.** Both arms run the interactive CLI in a tmux session that the bench drives: it
    sends the one invocation and nothing after it. Headless `codex exec` and `claude -p` deliver background
    completions differently from an interactive session, so neither would measure the wake behavior this change
    is about.
  - **One scorer for both.** It reads a Codex rollout or a Claude session transcript, plus their sub-agent files,
    and writes one record shape to `bench/results/live.jsonl`. Per wave it records: root turns, root wakes by
    trigger, root input and cache-read tokens, worker tokens, wall-clock, and the acceptance result. It extends
    `bench/live/score.py`.
  - **Fixtures and sandbox.** Both arms use the same sandbox repository, the same fresh issues per reset, and a
    fixture that produces two waves (two independent issues, each with a dependent).
  - **Order.** Baseline current `main` on both harnesses first, then measure the change on both, ABBA as in the
    existing bench.

## Task 0: spikes (throwaway, before any design is locked)

- **S1 (Claude).** Does a `UserPromptSubmit` hook see a sub-agent completion notice? Is `decision: "block"`
  honored for it? Does the hook see enough of the notice to tell an agent task from a Bash task? Measure the
  per-prompt cost of the hook.
  - If blocking is not honored, stop and bring it back to the operator. The fallback is one cheap wake per
    worker.
- **S2 (Codex).** What is the longest a single shell call can block before the model gets a turn (code-mode
  `exec` with `yield_time_ms`, then the `wait` tool on its cell)? Does a child's completion interrupt that call?
  - This decides `ak wait` in the shell versus the `wait_agent` loop.
- **S3 (both).** How a worker's transcript file is found from what `ak` knows (worktree path, issue number, the
  prompt text), and which records mark its end:
  - a Claude sub-agent's final turn or an error;
  - a Codex rollout's completion event or error.
- **S4 (Claude).** Is a background Bash task in an interactive session time-limited? The docs state a 30-minute
  default and a 2-hour maximum only for unattended runs. If it is limited, `ak wait` must hand off before the
  limit (re-launch itself and keep its state) without waking the root.

## Settled after the builder check

The first five settle the state machine.

1. **The wake carries the post-CI state.** `ak wait` does the per-worker result refresh itself, including the CI
   wait that `ak collect --issue N` does today (`result_refresh`). It is already waiting, so the CI wait costs no
   turn. The one wake therefore carries every worker's final state.
2. **`ak collect --wave` is quick.** It checks that every item is settled, records the wave accepted, and releases
   the next wave. It makes no CI wait.
3. **Per-issue collect stays only for correction rounds** and is not needed on the happy path.
4. **Release happens only at the wave boundary.** `spawn_successors` becomes the wave-boundary release.
   `release_other_runs`, called from a park today, releases nothing mid-wave either.
5. **The open-wave marker.**
   - **Location:** one file in the main checkout, `.ak/wave.open`, holding the watching `ak wait`'s pid. The hook
     finds the main checkout from its cwd through the git common directory, so it works from a worktree.
   - **The hook's test:** block only if the marker exists and `kill -0` on its pid succeeds.
   - **Stale markers:** a marker left by a crashed watcher or an abandoned run has a dead pid, so the hook passes.
     A stale marker never blocks, which keeps "no run started, no blocker". No expiry clock is needed.
   - **Settling:** `ak wait` removes the marker before it exits.

The remaining calls:

6. **Correction rounds.** `ak wait --issue N…` writes the same marker with its own pid while it waits, so
   correction-round notices are swallowed too.
   - Only one watcher per checkout exists at a time. A second `ak wait` attaches to the live one and adds its
     items. It never starts a second watcher.
   - The marker is cleared when the union of all waited-on items is settled.
7. **Locking.** `ak wait` does not take `run_lock`. It writes only its own state file next to the run file. Run-file
   state changes (`collected`, `held`, `accepted`) are written by `ak collect --wave` under the existing lock. A
   worker's `ak park` writes only its own result file, as today.
8. **Other spawns during a wave.** Any worker the kit prints a `spawn` line for while a wave is open joins that
   wave as a correction item, and the root waits on it with `ak wait --issue`/`--pr`. That covers corrections,
   `pr-plan` red-CI or conflict workers, and merge-downs.
   - Red or conflicting items appear in the wake summary with the exact command that hands them on, as
     `collect_next` prints today.
   - During a wave the root spawns nothing else. Its own reviewers and helpers belong to the review pass after the
     wake, when the hook passes everything, so the hook does not need to tell ak workers from other agents.
9. **Plan output.** `after` lines stay, each gaining a `wave=N` field. No new line type is added, so the empty-plan
   check and the existing consumers keep working; tests that pin `after` lines gain the field.
10. **Stacking and held issues.**
    - An issue stacked on a shipped blocker outside the run (`stack_parent`) has no in-run `needs` and lands in
      wave 1.
    - A dependent whose blocker ended parked or red gets the new run state `held`, and so do its dependents.
      `held` is not active, so a later `ak plan --issue N` can pick it up again, like a parked issue today.
11. **Hook shipping.** The ak Claude plugin's source is `v2/` (`.claude-plugin/marketplace.json`). The hook goes in
    `v2/hooks/hooks.json` with its script beside it, referenced through the plugin-root variable. Plugin hooks are
    active whenever the plugin is enabled; S1 confirms this on the installed version. `plugin/` and
    `tests/build-plugin.sh` belong to the v1 `agentkit/` tree and are not involved.

## Left to the builder

- Exact command names and output wording, within the shapes above.
- The watcher's internals: polling interval, file layout under `.ak/`, and how it attaches to an existing
  watcher.
- How `ak plan` prints later waves, as long as the root still has no reason to read anything until wave 1 is done.
- Whether the Codex-only yield hint survives (see Removed).

## Calls made by the designer (check these)

- Hang threshold 20 minutes by default, configurable.
- Corrections use `ak wait --issue …`, not a new command.
- The wave boundary is a form of `ak collect`, not a new verb.
- A blocker that ends parked or red holds only its own dependents.
- The hook fails open.
