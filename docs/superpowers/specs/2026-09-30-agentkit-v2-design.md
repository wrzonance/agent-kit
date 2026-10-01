# agentkit v2: clean-room rewrite

Status: draft for operator approval, 2026-09-30.

## Why

One cable-tool run on 0.9.18 (2026-09-30, one issue, one draft PR):

| Measure | Value |
|---|---|
| Root tool calls | 469 |
| Root tokens | 48.0M |
| Kit prose and helper source read into the root | 687 KB |
| `--help` calls | 45 |
| Distinct helpers the root called | 36 |
| Root context per call after dispatch | 130-150K tokens |
| Root calls spent on review, CI and fixes for one PR | ~185 (~21M tokens) |
| Operator steers needed | 3 |

The same field ledger (`~/scratch/agentkit-0.9.17-ledger.md`, items 1-80) traces nearly every cost to one of four causes:

1. **The root does the work.** It fences issues, writes dispatch plans, reads the review contract, runs the suite,
   polls CI, triages findings, and composes fix prompts, all on a 150K context where each call costs ~150K tokens.
2. **Prose instead of code.** 378 KB of shipped markdown; each step says "run X --help and follow its recipe", so
   the root pays a call to learn every command and then transcribes 30-line bash blocks.
3. **Gates without exits.** Activation receipts, session ledgers, consent records, sole-writer ledgers, quiescence
   lines, next-action snapshots, finding-evidence binding, and a stop gate. Each refusal costs a search of helper
   source, and several have no command that satisfies them.
4. **Verification that proves nothing.** The local suite skipped the only suite that covered the diff, so every
   fix cycle round-tripped through CI.

Growth since v0.1.0 (2026-08-15): helper code 17,060 → 46,069 lines, helper files 49 → 117, and suites 61 → 156.
Deleting piece by piece has not worked: every gate is pinned by a suite, so each deletion fights its pins.
v2 is a new tree with new, smaller tests. v1 is deleted in one PR once v2 wins a field run.

## Budgets (the acceptance test)

A cable-tool `--yolo` run on v2 must meet all of these, measured from the rollout the same way the 2026-09-30 run
was measured:

| Budget | v2 target | 2026-09-30 |
|---|---|---|
| Root calls to first spawn | ≤ 6 | 51 |
| Root calls per PR after spawn (collect + report) | ≤ 4 | ~400 |
| Root reads of kit files other than the invoked SKILL.md | 0 | 687 KB |
| `--help` calls | 0 | 45 |
| Root tokens for a 1-issue run | ≤ 3M | 48M |

Static budgets, enforced by gates in `tests/`:

- Each SKILL.md ≤ 120 lines; all shipped markdown ≤ 40 KB in total.
- One executable, `ak`, with subcommands; ≤ 5,000 lines of shipped code in total.
- Every `ak` subcommand prints ≤ 20 lines on success. A refusal prints one line naming the cause and one line with
  the exact command that fixes it.
- No lifecycle hooks.

## Shape

### One entry point

`ak <subcommand>` replaces the 117 files and the two helper directories. The skill tells the root the exact
subcommand line to run, so it never needs `--help`, source reads, or path guesses. `ak` with no arguments prints a
one-screen usage.

### Skills

| Skill | Replaces | Root does |
|---|---|---|
| `onboard` | onboard-repo | `ak onboard`, then commit the config it writes |
| `issues` | parallel-issues | plan → spawn → wait → collect → report |
| `pr` | review-remote-pr, pr-to-green | spawn one PR worker per PR → wait → collect → optional `ak merge` |

### `issues` root flow (the whole skill)

1. `ak plan [--limit N] [--yolo] [--serialize]` does everything that happens before spawning:
   - repo facts;
   - board pick with exclusion labels (such as `tier:human-only`) applied first;
   - write sets resolved against `git ls-files`;
   - collisions (chained, or dropped);
   - worktree creation;
   - issue body fetched into each worktree as fenced data;
   - worker prompt files composed.

   It prints only:

   ```text
   run=20260930-160210
   spawn issue=671 cwd=/repo/.worktrees/feat/issue-671 prompt=/repo/.worktrees/feat/issue-671/.ak/prompt.md model=gpt-5.6-luna effort=medium
   after issue=598 needs=596
   drop issue=69 reason=label:tier:human-only
   ```

2. For each `spawn` line, spawn a worker with those exact arguments, using the prompt file's content as the message.
3. Wait on the native harness collector with the longest window it allows. Do not refresh state between waits.
4. When a worker finishes, run `ak collect --issue N`. It prints `pr=URL ci=green|red review=done|skipped
   note=…` plus any newly unblocked `spawn` lines.
5. When no workers remain, print the collect lines as the report and end the turn.

### The worker owns its PR to green

The prompt file carries the playbook. It is read in the worker's own small context, never the root's:

1. Implement with TDD inside the worktree.
2. `ak verify`: runs the repo's declared checks, and **runs every declared suite whose paths the diff touches**. When
   no local runner exists for a touched suite, it says so and the worker waits for CI instead of claiming green.
3. `ak ship`: commit, push, and open or update the draft PR with the body composed from the issue.
4. `ak review`: one cross-provider adversarial review of the pushed head. The invocation's flag is the consent; there
   is no consent record.
5. Fix the findings the worker accepts, `ak verify`, `ak ship`.
6. `ak ci`: waits for CI on the head, and on failure prints the failing job's error lines (logs fetched with
   escape sequences stripped). Fix and repeat, at most 3 times.
7. `ak receipt`: posts one PR comment with the reviewed SHA, each finding and its disposition, and CI state.
8. Write `.ak/result` (`pr=… ci=… review=…`) and end with one line.

### State

- One run file per run, `.ak/runs/<run>.json`, written by `plan` and `collect`.
- One result file per worktree, `.ak/result`.
- Nothing else: no ledgers, receipts of receipts, or activation state.

### Safeguards that stay

- **Untrusted input.** Issue bodies and fetched comments go into the worker prompt as a fenced data block labelled
  untrusted. This guards against untrusted input, which the north star keeps.
- **Draft only.** Workers open draft PRs. Ready-flip and merge happen only through `ak merge`, and only when the
  operator's invocation asks for it.
- **Protected paths** from the repo config: `plan` drops an issue whose write set touches one and names the path.
  There is no grant flow.

Everything else in v1's gate set is deleted and not replaced.

## Migration

1. v2 lives in `v2/` (`v2/bin/ak`, `v2/skills/`), shipped as a second plugin, `ak`, so it installs next to v1
   without v1's hooks.
2. Tests: `tests/v2/test-*.sh` with a fake `gh` on `PATH`. The v1 gates for harness, environment and org neutrality
   also run over `v2/`.
3. Field run: cable-tool, `$ak:issues --yolo`, measured against the budget table.
4. If it wins: one PR deletes `agentkit/`, the v1 tests and the v1 plugin; `ak` becomes `agentkit` 1.0.
5. If it loses: the ledger from that run decides what changes. Nothing is ported back into v1.

## Out of scope

Board grooming, backlog promotion, merge-queue stacking beyond simple chains, and a Claude-harness waiter protocol.
Each returns only when a field run shows its absence costs a measured turn.
