# Recipe-fold wave — design

Dated 2026-09-10. Follows the 2026-09-07 size audit. Goal, in the maintainer's words: fewer words, as long as the agents still read and listen.

## Problem

The size waves cut skill markdown 16.6 % and hooks 15 % (o200k tokens, `c77e02b` → `main`), but the fenced recipe blocks an agent must execute went 51/74 → 51/73 (`recipe_blocks`, Tier 0 after #694). Every fenced `bash` block is at least one tool turn; 21 of the 51 open with the same rehydration guard because shell state does not persist. Prose got shorter; turns did not.

## Goal

Cut resident `recipe_blocks` 51 → 41 (−20 %) across three PRs, one per skill, with zero-to-low test churn, by folding adjacent blocks into single helper calls. Every fold is a word cut too: the glue moves into a helper that enforces it.

## Non-goals

- The 8 resolver / rehydration-definition blocks (one pair per skill). `test-contract-provenance.sh` requires them one-per-skill; they stay.
- The heavily pinned blocks: parallel `:631` (prompt compose, ~15 literal asserts), parallel `:535`/`:552` (boundary mode, `root_fence_section`), review `:321` (its suite executes the block verbatim), onboard `:27` (extracted and run by `test-skill-path-resolution.sh`). Folding them is test churn for one turn each.
- Compaction re-reads (34 truncated skill-doc reads in the reference run) and wait calls (129; issue #608). Larger turn levers, separate work.

## The folds

Inventory: [`2026-09-10-recipe-fold-wave/recipe-inventory.md`](2026-09-10-recipe-fold-wave/recipe-inventory.md) (51 rows: line, section, helpers, guard, category, pinning test). Line numbers are `main @ 9eb5afd`.

### PR 1 — onboard-repo (13 → 9 blocks; zero churn)

| fold | before | after |
|---|---|---|
| F1 | `:66` state report + `:75` preflight status (two `onboard-state.sh` calls) | one `onboard-state.sh --report --next-steps --preflight` |
| F2 | `:125` `repo-config --list` + `grep '^# AGENT_'` + `:157` `detect-toolchains.sh` suggestions | one `detect-toolchains.sh --gaps --suggest` that lists the blanks itself |
| F3 | `:184` verify + `:224` list-then-verify + `:261` harness advice | one block; `:224`'s `repo-config --list` already duplicates `:125` |
| F4 | `:94` `board-setup.sh --dry-run` then `board-setup.sh` | one call; the helper is idempotent and prints what it would do |

Constraint: `SKILL.md` is 18,699 bytes against an 18,700 gate (`test-skill-path-resolution.sh:314`). Every fold nets negative bytes.

### PR 2 — review-remote-pr (14 → 12; zero churn)

| fold | before | after |
|---|---|---|
| F5 | `:391` 4×60 s CI wait loop + `:422` re-fetch (byte-identical to `:253`) | `gh-pr-state.sh --wait-ci --rounds 4 --interval 60 --full --tmpdir "$RUN_DIR/state"` |
| F6 | `:200` `gh pr view --json mergeable` + `:209` merge/resolve/commit/push | `gh-pr-state.sh` digest already prints `mergeable=`; drop `:200`, branch on the digest |
| F7 | `:309` lint-if-declared then test | `agent-run.sh --cmd lint --if-declared --cmd test` (one call) |

### PR 3 — parallel-issues (20 → 18; low churn)

| fold | before | after |
|---|---|---|
| F8 | `:472` if/else `--no-spawn` vs `--spawn-capable` + `:514` board move | `concurrency-cap.sh --multi-agent "${multi_agent:-true}"` absorbs the branch; board move chained in the same block. `test-parallel-dispatch-contract.sh:355-362` needs the guard and `agentkit_provenance` in the `### Dispatch` section — both stay. |
| F9 | `:595` snapshot + `:609` collect (both `cross-write-check.sh`) | `cross-write-check.sh dispatch-fence` runs both; rc 10 (incident) still tolerated. `:1418` pins the helper name only. |

### Optional PR 4 — run-id derivation (−2; medium churn)

`:81` (parallel) and `:46` (review) each derive `RUN_ID` inline. `session-ledger.sh --derive-run-id` replaces both; the 5 literal asserts in `test-session-ledger.sh:266-298` move to the helper's suite. Do only if PRs 1–3 land clean.

## Rules every fold obeys

1. The rehydration guard stays on every surviving block that touches `$shared/` (`test-contract-provenance.sh:53-88` fails it otherwise).
2. No "read X in full", digest legend, or step-ordering sentence is cut. Narration, history and duplicates are.
3. Helper growth is visible: each PR either trims the helper it extends by as much as it adds, or raises that file's `lint-helper-size.sh` pin in the same PR with the reason in the PR body. The tree total moves the same way.
4. `recipe_blocks` is the wave's number. Each PR states before/after from `bench/tier0.sh HEAD` in its body.

## Verification

- Static: `tests/run-tests.sh` green per PR. The pinning suites named above are the "agents still listen" oracle at rest.
- Dynamic: after PR 3 merges, one real run of `onboard-repo` on the tally fixture and one `review-remote-pr` on an open draft PR, reported with turn count and any step the agent skipped or re-ran. Not asserted from the diff.
- Tier 0 on `main` after the wave: `recipe_blocks` resident ≤ 41.

## Risks

- A folded helper hides a failure the two-block form surfaced separately (e.g. F5's wait vs re-fetch). Mitigation: the helper's digest line names which phase failed.
- onboard-repo's 1-byte gate turns a neutral fold into a red CI. Mitigation: measure bytes before pushing.
- Fold flags creep into option knots (`code.md`: "flags to cover its callers"). Mitigation: one new flag or subcommand per fold, none shared.
