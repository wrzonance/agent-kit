# Fenced `bash` block inventory — 4 SKILL.md files (main @ 9eb5afd, 2026-09-10)

51 blocks total: parallel-issues 20, review-remote-pr 14, onboard-repo 13, pr-to-green 4.

Category key: (a) pure helper invocation, already ~1 line · (b) glue a new helper could absorb · (c) prompt-fragment / display-only · (d) other (resolver/bootstrap plumbing).

## agentkit/skills/parallel-issues/SKILL.md (20)

| start | section | n | what it does | helpers | preamble | cat | pinned by |
|---|---|---|---|---|---|---|---|
| :81 | Session decision ledger | 13 | Derive normalized RUN_ID hash from scope + invocation flags | — | none | b | test-session-ledger.sh:266–281 (4 literal asserts) |
| :155 | The resolver (once per session) | 18 | Read `skills= path=` from provenance-checked env-contract | — | none (defines it) | d | test-skill-invocations.sh:52–55; test-contract-provenance.sh:22–28, 118–140; test-skills-contract.sh:80 |
| :182 | THE CACHE REHYDRATION | 3 | Re-read cached session context, verify agentkit unchanged | contract-cache.sh | none (defines it) | d | test-contract-provenance.sh:144–150 |
| :196 | Run the preflight — ONCE | 22 | Preflight, add `.agent/*` exclude, warm contract cache | agent-preflight.sh, contract-read.sh, contract-cache.sh | `set -euo`+resolver-guard | b | test-contract-provenance.sh:104–140 (warm-up boundary awk) |
| :239 | Step 1: Establish repo facts | 18 | Export repo config, resolve repository slug and base | repo-config.sh, contract-read.sh | 3-line preamble | b | unpinned (structural only: lint-skill-invocations.sh) |
| :266 | Step 2: Triage candidate set | 15 | jq guard then one triage-issues call | triage-issues.sh | `set -euo`, guard@7 | a | test-skills-contract.sh:313 (`jq is not installed; evidence unavailable`) |
| :430 | Step 5: Create worktrees | 15 | Build chain-base args, call create-issue-worktree | contract-read.sh, create-issue-worktree.sh | `set -euo`, guard@4 | b | unpinned |
| :472 | Dispatch (one round) | 9 | if/else picks `--no-spawn` vs `--spawn-capable` | concurrency-cap.sh | guard@1 | b | test-parallel-dispatch-contract.sh:355–362 |
| :514 | Dispatch (one round) | 7 | Move selected issues to In progress on board | contract-read.sh, move-github-project-item.sh | `set -euo`, guard@4 | a | unpinned |
| :535 | Root canonical issue fetch | 14 | Probe visibility, select boundary mode, validate result | select-boundary-mode.sh | none | b | test-parallel-dispatch-contract.sh:417–426 (`root_fence_section`, literal `printf 'boundary mode: %s\n'`) |
| :552 | Root canonical issue fetch | 27 | Optional prior-art tmpfile, run prepare-issue-artifacts, rc case | prepare-issue-artifacts.sh | guard@1 | b | test-parallel-dispatch-contract.sh:417–426 |
| :595 | Root cross-write fence | 7 | Build snapshot argv from write-sets, snapshot root | cross-write-check.sh | none | b | test-parallel-dispatch-contract.sh:1418 (helper name only) |
| :609 | Root cross-write fence | 14 | Collect per-worker cross-writes, tolerate incident rc 10 | cross-write-check.sh | none | b | test-parallel-dispatch-contract.sh:1418 (name only) |
| :631 | Compose the issue-lead prompt | 33 | Compose prompt, verify plan-sha, persist verification report | compose-worker-prompt.sh | guard@1 | b | HEAVIEST: test-parallel-dispatch-contract.sh:430–470 (~15 literal asserts + `grep -Fxc` exact-line count at :435) |
| :738 | Root review and draft PR | 9 | Validate handback argv, exec it inside worktree | validate-handback.sh | guard@1 | b | test-parallel-dispatch-contract.sh:911–925 (6 literal asserts) |
| :777 | Phase 3 draft loop | 7 | Move one issue to In review on board | contract-read.sh, move-github-project-item.sh | `set -euo`, guard@4 | a | unpinned |
| :812 | Step 3b: Dispatch review agents | 11 | Compute PR-loop dispatch cap from runtime thread budget | — | none | b | (truncated in transit) |
| :841 | Adversarial-review receipt | 13 | Precheck whether receipt budget already spent | run-dir.sh, consent-record.sh, post-receipt.sh | guard@3 | b | test-adversarial-review-receipt.sh:23-68 (section-scoped, incl. full guard literal) |
| :867 | Adversarial-review receipt | 23 | Ledger findings then publish receipt, rc case | run-dir.sh, finding-ledger.sh, post-receipt.sh | guard@3 | b | test-adversarial-review-receipt.sh:23-68 |
| :933 | Do NOT Delete Worktrees | 9 | Read back per-issue dispatch verification reports | — | none | b | test-parallel-dispatch-contract.sh:510 (`for dispatch_report in "$dispatch_reports_dir"/issue-*.report`) |

## agentkit/skills/review-remote-pr/SKILL.md (14)

| start | section | n | what it does | helpers | preamble | cat | pinned by |
|---|---|---|---|---|---|---|---|
| :46 | Session decision ledger | 9 | Derive review RUN_ID from PR, repo, flags | — | none | b | test-session-ledger.sh:317 |
| :91 | Resolver (once per session) | 17 | Read provenance-checked contract for skills path | — | none (defines it) | d | test-contract-provenance.sh:22-28, 118-140 |
| :117 | THE CACHE REHYDRATION | 3 | Re-read cached session context | contract-cache.sh | none (defines it) | d | test-contract-provenance.sh:144-150 |
| :169 | 0a — Enter the PR worktree | 20 | Run pr-worktree, parse worktree, cd, warm contract | pr-worktree.sh, agent-preflight.sh, contract-read.sh, contract-cache.sh | resolver comment + guard@4 | b | test-skills-contract.sh:278-282; test-contract-provenance.sh:116 |
| :200 | 0b — Check merge conflicts | 1 | One `gh pr view --json mergeable` | — | none | a | unpinned |
| :209 | 0b — Check merge conflicts | 20 | Merge base, resolve, commit with trailer, lint/test/push | repo-config.sh, contract-read.sh, worktree-commit.sh, agent-run.sh | guard@4 | b/c | unpinned (structural only) |
| :238 | 0c — Resolve RUN_DIR | 3 | Resolve durable per-PR artifact directory | run-dir.sh | guard@1 | a | test-review-artifacts.sh:505 |
| :253 | Step 1: Check | 4 | Fetch full PR state into RUN_DIR/state | gh-pr-state.sh | guard@1 | a | test-review-artifacts.sh:515 (RUN_DIR re-set sentinel) |
| :279 | Step 1b: Adversarial Review | 12 | Build diff payload, precheck receipt-spent, rc case | consent-record.sh, post-receipt.sh | guard@1 | b | test-adversarial-review-receipt.sh:70+ |
| :309 | Step 2: Fix CI Failures | 4 | Run declared lint then test | agent-run.sh | guard@1 | a | unpinned |
| :321 | Step 2: Fix CI Failures | 8 | mktemp, run verification-baseline, promote or discard | verification-baseline.sh | guard@1 | b | test-verification-baseline.sh:229-241 — extracts and EXECUTES this block verbatim |
| :342 | Adversarial-review receipt | 30 | Ledger findings, gather head-sha/payload/harness, publish | finding-ledger.sh, post-receipt.sh, contract-read.sh, consent-record.sh | guard@4 | b | test-adversarial-review-receipt.sh:23-68 |
| :391 | Step 4: Wait for CI | 3 | Bounded CI wait, 4 rounds x 60s | gh-pr-state.sh | guard@1 | a | unpinned (helper-side only) |
| :422 | Step 6: Evaluate and Repeat | 4 | Re-fetch full PR state into RUN_DIR/state | gh-pr-state.sh | guard@1 | a | unpinned — byte-identical to :253 |

## agentkit/skills/onboard-repo/SKILL.md (13)

WARNING: the file is 18,699 bytes and test-skill-path-resolution.sh:314 gates it at <= 18,700. One byte of headroom — every fold here must be net-shrinking.

| start | section | n | what it does | helpers | preamble | cat | pinned by |
|---|---|---|---|---|---|---|---|
| :27 | Step 0 — resolve the tree | 24 | Contract-or-plugin-cache resolver, preflight `--ensure`, verify | agent-preflight.sh, contract-read.sh | resolver comment | d | test-skill-path-resolution.sh:26-48 (extracts + runs it); test-skills-contract.sh:57-59, 76-81 (`agentkit=$(find ` exactly once tree-wide); test-contract-provenance.sh:153-200 |
| :58 | THE CACHE REHYDRATION | 3 | Re-read cached session context | contract-cache.sh | none (defines it) | d | test-contract-provenance.sh:144-150, 156 |
| :66 | (after rehydration) | 3 | Print onboarding state report + next steps | onboard-state.sh | guard@1 | a | unpinned |
| :75 | (after rehydration) | 2 | Print onboarding preflight status | onboard-state.sh | guard@1 | a | unpinned |
| :82 | Step 1 — look before writing | 2 | Dry-run bootstrap | bootstrap-repo.sh | guard@1 | a | test-skills-contract.sh:243-250 (ordering vs `^"$shared/bootstrap-repo.sh"$`) |
| :94 | If there is no board | 3 | Dry-run then real board setup | board-setup.sh | guard@1 | a | unpinned |
| :116 | Step 2 — write the files | 2 | Run bootstrap for real | bootstrap-repo.sh | guard@1 | a | test-skills-contract.sh:245 (exact line anchor) |
| :125 | Step 3 — find what it left blank | 4 | List config, grep blanks, print toolchain gaps | repo-config.sh, detect-toolchains.sh | guard@1 | a | unpinned |
| :157 | Step 4 — work out the commands | 2 | Print toolchain command suggestions | detect-toolchains.sh | guard@1 | a | unpinned |
| :184 | Step 4 — work out the commands | 2 | Run declared verify | agent-run.sh | guard@1 | a | unpinned |
| :224 | Step 6 — write and validate | 4 | List config, then hand verify to the user | repo-config.sh, agent-run.sh | guard@1 | a/c | unpinned |
| :245 | Step 7 — commit, or not | 4 | Branch, inspect ignored state, force-add config.env | — | none | c | unpinned |
| :261 | Step 8 — check the harness | 2 | Print harness advice | harness-advice.sh | guard@1 | a | unpinned |

## agentkit/skills/pr-to-green/SKILL.md (4)

| start | section | n | what it does | helpers | preamble | cat | pinned by |
|---|---|---|---|---|---|---|---|
| :31 | Environment warm-up | 10 | Read provenance-checked contract for skills path | — | none (defines it) | d | test-contract-provenance.sh:22-28 (loops every SKILL.md) |
| :49 | THE CACHE REHYDRATION | 6 | Re-read cached session context (6-line reflow of the 3-line canon) | contract-cache.sh | none (defines it) | d | test-contract-provenance.sh:144-150 |
| :60 | THE CACHE REHYDRATION | 13 | Preflight, verify skills path, warm cache | agent-preflight.sh, contract-read.sh, contract-cache.sh | `set -euo` + resolver-guard | b | test-contract-provenance.sh:104-140 |
| :158 | 1. Resolve and display | 5 | One authorize-queue call with ready / no-auto-merge flags | authorize-queue.sh | none | a | helper names only |

## Preamble

33 of 51 blocks (65%) carry the rehydration guard within their first 3 lines; 21 open with it as line 1, byte-identical:

    [ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }

Guard-in-first-3-lines per file: parallel-issues 12/20, review-remote-pr 10/14, onboard-repo 10/13, pr-to-green 1/4.

NOT foldable (8 blocks): the THE CACHE REHYDRATION definition blocks (parallel :182, review :117, onboard :58, pr-to-green :49) and the resolver blocks (parallel :155, review :91, pr-to-green :31, onboard :27). test-contract-provenance.sh:104-150 requires exactly one initial warm-up plus one rehydration definition PER SKILL; test-skills-contract.sh:57-81 requires the `find` fallback exactly once tree-wide. The guard is load-bearing: test-contract-provenance.sh:53-88 fails any fenced block touching `$shared/` without it — folding must never strip the guard from a surviving block.

## Ranked top-10 folds

| # | fold | blocks removed | test churn |
|---|---|---|---|
| 1 | onboard :66 + :75 -> one `onboard-state.sh --report --next-steps --preflight` | -1 | zero |
| 2 | onboard :125 + :157 -> one `detect-toolchains.sh --format gaps,suggestions`; absorb `repo-config --list` + grep glue | -1, -4 lines | zero |
| 3 | onboard :184 + :224 + :261 -> one block (:226 already duplicates :127) | -2 | zero |
| 4 | onboard :94 -> drop the --dry-run line, keep one board-setup.sh call | -0, -1 line | zero (helps the 1-byte size gate) |
| 5 | review :391 + :422 -> one `gh-pr-state.sh --wait-ci --rounds 4 --interval 60 --full --tmpdir "$RUN_DIR/state"` | -1 | zero |
| 6 | review :200 + :209 -> fold the `gh pr view --json mergeable` line into gh-pr-state.sh | -1 | zero |
| 7 | review :309 -> `agent-run.sh --cmd lint --if-declared --cmd test` | -0, -3 lines | zero |
| 8 | parallel :472 + :514 -> `concurrency-cap.sh --multi-agent "${multi_agent:-true}"` absorbs the if/else, then chain the board move | -1 | low (test-parallel-dispatch-contract.sh:355-362 needs guard + `agentkit_provenance` in the Dispatch section) |
| 9 | parallel :595 + :609 -> one `cross-write-check.sh dispatch-fence` | -1 | low (:1418 pins the helper name only) |
| 10 | parallel :81 / review :46 -> `session-ledger.sh --derive-run-id` | -2 | medium (5 literal asserts in test-session-ledger.sh:266-298 move to the helper suite) |

AVOID: parallel :631 (~15 literal asserts + exact-line grep -Fxc), parallel :535 + :552 (root_fence_section pins literals), review :321 (suite executes the block verbatim), onboard :27 (extracted and run by test-skill-path-resolution.sh), all 8 resolver/rehydration blocks.

Net: folds 1-9 remove 8 blocks at zero-to-low churn; with fold 10, 10 of 51 (51 -> 41).
