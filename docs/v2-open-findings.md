# ak v2: open findings

This is the single list of what is still wrong with `ak` (v2) after the field runs from 2026-10-01 to 2026-10-23.
It replaces the per-run ledgers. It leaves out everything already fixed on `main` (fix waves #956–#979,
#989–#996, #998 and #1004–#1009) and every finding that was decided against on purpose. The v1 skill ledgers
are superseded by v2 and are not carried over.

Field runs are named by letter. Token figures are model-reported: cache reads make up 97–99% of them, so read
them as context re-reads, not as uncached spend.

| Run | Harness and root | Shape | Root | Workers |
|---|---|---|---|---|
| A | Claude, Fable then Opus | 4 days, about 20 issues through `ak plan`, 30 `ak merge` | 2.25B over 4,381 turns | 184 Sonnet, about 830M |
| B | Claude, Fable | 2 days, 57 workers | 649M over 1,172 turns | 286M |
| C | Codex, Sol medium | 4 days, about 48 PRs merged | 1.72B | 139 Luna, 5.18B (median 18M, p90 79M) |
| D | Codex, Sol medium | `ak:pr` merge wave | 235M | 11 workers, 416M |
| E | Codex, astra xhigh | 15 draft PRs; 12 PRs merged | 39M and 21M | 246M and 110M |

For scale, the live bench delivers 3 small issues for 1.5–2.2M tokens in total.

## Priority 0: the orchestrator wakes for nothing

### W1. No wait that returns on completion

The root has no command that blocks until a worker finishes. `skills/issues/SKILL.md` step 3 says to use the
harness's native wait. In practice the roots do something else, and every wake re-reads the whole root context
(170k–600k tokens per turn):
- Run A: 322 sleep loops and about 750 wake turns from task notifications and teammate heartbeat or idle
  messages. That is about 620M cache reads, which is more than all 184 workers in the run spent.
- Run C: about 970 `wait_agent` calls on the main root.
- Run E: 140 of 404 root calls (35%) were waits.
- `lib/plan.sh` `run_lock` puts "ak plan: still working … run the same ak plan again" in the background after 3 s.
  It was written for a shell that yields before the call ends. Roots whose shell does not yield read it as a
  prompt to poll, and it showed up 35 times or more.
- Workers wait too. `ak ci` exit 3 means "run it again", and a single in-worker block lasted 1,089 s.

Measure it by root calls and root input tokens per delivered PR, at equal acceptance.

## Priority 1

### S1. A worker's first ship and receipt fail too often

- `ak ship` pushes a head that never passed `ak verify`. Lint-only CI failures each cost a push and a CI round
  of about 25 minutes. This happened three times in run C, and another worker needed three `fix: lint`
  commits.
- The ship description checks (run output under a test heading, sentences over 45 words, "Phase N" wording)
  refused about 26 of roughly 130 ships in run A. `templates/issue-worker.md` states none of these rules.
- `ak receipt` refused six times because the findings file decided fewer findings than the review reported.
  The worker re-counts the findings by hand.

Candidate fix: ship refuses a head whose tree has not passed verify. The template states the description
rules, or the style-only ones are dropped. `ak review` writes a `.ak/findings` skeleton with one line per
finding, so the counts cannot drift.

### S2. Workers do not run at the model ak names

- `lib/common.sh` `worker_model` falls back to `gpt-5.6-luna` on Codex, which is no longer available. A root
  then asked the operator what to use, or ignored the printed `model=`.
- Roots that spawn their own sub-agents choose the model themselves. One root spawned 23 of 112 workers at Sol
  high.

Candidate fix: a current default. Tie the spawn instruction to the printed `model=` and `effort=`, pinned by
a test.

### S3. `ak merge` costs CI rounds and history

- `merge_update` calls `update-branch` before every merge, even when the base has no strict up-to-date rule.
  Each queued PR gets a new head and another CI wait of about 30 minutes, and each merge makes the rest of the
  queue stale again.
- The squash merge sends only `merge_method` and `sha`, so GitHub picks the subject line. One landed as a
  non-Conventional subject.
- A merge right after a job re-run passed while the re-run was still queued. The failed run had retired and the
  new one was not yet registered, so the gate saw no missing check.

Candidate fix: update only when GitHub reports the PR behind under strict checks, or in conflict. Pass
`commit_title="<PR title> (#N)"`. Refuse while any workflow run for the head SHA is queued or in progress.

### S4. Plan reads paths an issue only mentions

- The protected-path check unions the listed write set with every path the body names. An issue whose
  Modify/Create list holds only documents was dropped as `protected:` because a "keep the existing work"
  sentence named a migration file.
- With no listed write set, overlap falls back to named paths. Issues that only run the repository's verify script
  were serialized, and a later run refused them as `queued-after-#N`. This recurred on two named issues whose
  owned paths were disjoint.
- `ak plan --issue N` drops a named issue on `protected:`, and its `next=` offers no way through.
- In run A, a named plan printed `next=none of the named issues can start; each line above says why` with no
  line above it. The cause has not been found yet.

Roots that hit these leave ak. Run A made 148 hand-run `git worktree` calls and copied prompts between
worktrees with a home-made script. Those runs are the most expensive ones in the table.

## Priority 2

- **P1. No path to start a dependent early.** `--serialize` releases a dependent only when its blocker is
  collected green, and a queued issue cannot be planned in another run. Roots build worktrees by hand, so the
  run files keep saying `queued`.
- **P2. A stack has a single parent.** An issue that needs two open chains merges both. Its PR diff then
  inherits thousands of lines that `ak review` reviews as its own.
- **P3. Review reuse depends on the commit type.** A `test(...)` commit after the review blocked reuse, where a
  `fix:` commit would not have. Reuse should depend on what changed.
- **P4. Issues stay open after a stacked chain lands.** Stacked PRs say "Part of #N", so nothing closes the issue
  when the stack finally reaches the default branch.
- **P5. A green PR outside any run needs a worker to merge it.** `ak merge` refuses a PR that is in no run, and
  `ak pr-plan` spawns a full worker only to post the receipt and merge.
- **P6. Files outside the listed write set are not flagged.** Workers added files the issue did not list five
  times in one day. `ak ship` or `ak receipt` could print `outside-write-set=<paths>`.
- **P7. A dispatch hold in an issue body outlives the operator's decision.** A "do not auto-dispatch" line kept
  holding after the operator's later invocation asked for the work.
- **P8. Collect waits silently.** `ak collect` can block for up to 30 minutes (`AK_COLLECT_CI_TIMEOUT`) on a new
  head without printing "waiting for CI on <sha>" first.
- **P9. Onboard reports success with nothing configured.** `ak onboard` printed `keys=0 … board=none`, and the
  root reported onboarding as done. `ak plan` then refused for want of a ready label or board.
- **P10. Receipt cannot find the issue on a PR branch.** On a `pr-plan` worktree whose branch has no
  `issue-N`, `ak receipt` refuses with "cannot tell the issue from branch" and the worker writes `.ak/issue` by
  hand.

## To investigate

- **I1. Test edits that weaken the oracle pass review.** A worker kept a test green by removing a merge from a
  real template fixture, and the root's check passed it. A review flag on hunks that change an existing
  assertion or fixture is a candidate fix.
- **I2. Worker runaway.** There is no per-worker turn or token signal. Run C's worker p90 is 79M and its maximum
  363M. Find out how much of that is in-worker CI waiting (part of W1), lint rounds (S1) and genuinely large
  issues.
- **I3. `ak review` killed with exit 143 and no output** when the model was overridden through the environment.
  One case so far.
- **I4. `ak merge` exit status.** One merge printed `merged pr=N` and exited 1. The root had chained another
  command after it, so confirm whether ak itself returned non-zero.
- **I5. Harness instructions inherited per turn.** Global rules and repository instruction files add 8k–20k
  tokens to every worker turn. That is outside the kit, but it is worth measuring next to W1.

## Measurement gaps

- The last live bench batch ran on 2026-10-02, so the fix waves after it were never benched. A baseline batch
  on current `main` comes first.
- The tally fixture is three small independent issues. Add fixture issues for: W1 (a run long enough for the
  root to wait more than once), S3 (a three-PR queue on a repository without strict checks), and S4 (two issues
  that mention the same path with disjoint Modify lists, plus prose that names a protected path).
- `bench/live/score.py` reads Codex rollouts only, so Claude-root runs, the most expensive ones above, are
  unscored.
