# Skill-tree size reduction, wave two (markdown) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut a further ~8,600 estimated tokens (34,387 bytes, re-measured on `origin/main` plus the in-flight #621 marker removal) from the shipped skill markdown — the mandatory-read set the root re-reads on every fresh context and after every compaction — without adding a file, a rule, a gate, or a round trip; defer three ~29 KB review-remote-pr reads to the first fix-batch dispatch; remove four network re-derivations of facts the environment contract already holds; and ratchet every size ceiling down to the measured minimum in the same PRs.

**Architecture:** Fourteen independent, mechanical prose cuts, one file (or one tightly related file group) per PR, each preserving every literal a test pins and every behaviour a helper already enforces, plus one follow-up test issue (a path-neutral composed-prompt ceiling) filed but not implemented here. The independent plan review (`plan2/review-md/REVIEW.md`, 2 High / 5 Medium / 9 Low) is folded in: see "Review findings folded in" in the self-review. Every replacement text below was applied verbatim to a scratch copy of `main` + #621 and the whole suite run against it: every lint green, and the only new failures were the two `inner bash examples` counts that Task E's own test edit rewrites. Tasks C–N touch disjoint files and can run in parallel worktrees from `origin/main`; Tasks A, B, and D edit the three `SKILL.md` files that #621 (`refactor/size-w1-markers`) also edits and branch from that branch (or from `main` once it merges); Task B chains on Task A because both edit the two ratchet lines in `tests/lint-skill-size.sh` / `tests/test-skill-size.sh`.

**Tech Stack:** Bash test suite (`tests/run-tests.sh`), `tests/lint-skill-size.sh` (body-token gate, `bytes/4` estimator in `tests/lib/token-estimate.sh`), `gh` over REST, git worktrees under `.worktrees/`.

**Spec:** `docs/superpowers/specs/2026-09-07-size-audit.md` (the read-only audit; §3 proposals, §4 read sets, §5 turn-cost items). Raw data — `proposals-with-pins.csv`, `test-pins.csv` — lives in `docs/superpowers/specs/2026-09-07-size-audit/`. Wave one: `docs/superpowers/plans/2026-09-07-size-wave-one.md` (PRs #622–#628 merged 2026-09-08; #621 in flight). This plan's edit spec and the scratch-tree evidence: `plan2/evidence/{edits.py,apply.py,apply-report.json,baseline-full.log,red-full.log,green-full.log,render/}` beside this plan (`python3 apply.py SIM_ROOT all md,test` re-applies the spec to any checkout of main+#621).

## Global Constraints

- **Repository:** `wrzonance/agent-kit`, trunk `main` at `0d47511` when this plan was written (wave one merged). Skills live under `agentkit/skills/`; tests under `tests/`. Line numbers below are from that commit for Tasks C–N, and from `main` + #621 (`refactor/size-w1-markers`, which only deletes 30 marker-comment lines and edits four test files) for Tasks A, B, and D — **re-anchor with the quoted first/last line before every edit**; lines drift after earlier edits in the same file, so apply each task's edits bottom-up or re-grep after each one.
- **Never edit the root checkout** (`/home/adam/github/agent-kit`); every task works in `.worktrees/<branch>` created from `origin/main` (or from its predecessor branch where the task says so).
- **Never commit to `main`.** Branches are `refactor/size-w2-<slug>`.
- **One PR per task, always `gh pr create --draft`.** PR body = Why + What + Testing checkboxes, opens with `This was written agentically; verify its assertions:` and closes with `🤖 Co-authored by Claude Fable 5.1. Closes #N.`
- **Commits:** Conventional Commits, `refactor(<scope>): …`, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **No new files under `agentkit/`** (`tests/test-helper-end-of-options.sh` pins exactly 66 executables; `tests/lint-reference-manifest.sh` requires one manifest entry per reference). No task deletes a reference file, so `references.md` and the manifest test keep their 16 entries.
- **Every pinned literal listed in a task stays verbatim and on a single line** unless the task says the pinning test flattens whitespace. When a test fails on a literal the task did not list, restore that sentence verbatim rather than deleting the assertion.
- **Ceilings ratchet down, never up.** `tests/lint-skill-size.sh` `KNOWN_OVERSIZE[<skill>]="LINES:TOKENS:TARGET"` is set to the exact measured body size in the same PR, and `tests/test-skill-size.sh` pins those numbers in its ratchet-message assertions (lines 185, 195, 224, 226) — change both together. Only `parallel-issues` and `review-remote-pr` have entries; every other file gets a per-file byte assertion in the suite that already reads it (the wave-one pattern), set 0.3–2.5 % above the measured size (the composed-prompt ceiling is the one exception: it is checkout-path-dependent, see Task E).
- **Verification before push:** `tests/run-tests.sh` (canonical local verification) exits 0. `--only NAME` accepts only `tests/test-*.sh` suite names (the file name without `test-`/`.sh`); the `lint-*.sh` gates are not suites — run them directly as `tests/lint-<name>.sh agentkit/skills` (`lint-versioned-plugin-paths.sh agentkit`). Use `--only` plus the relevant lints for the fast loop; the full run is the pre-push gate.
- **GitHub API:** REST via `gh api` for issues/PRs; the board helper for status moves.
- **North star:** nothing in this plan may add a turn, a read, or a confirmation to any run. A cut that would remove the *only* home of an executed recipe or a pinned rule is out of scope (see "Not taken" at the end).

---

## Shared step: commit, push, and open the draft PR

Every task's final step runs this exact recipe from inside its worktree with its own values. `ISSUE` comes from the Task 0 ledger (`grep '^T<letter> ' /tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan2/issues/ledger.txt | cut -d' ' -f2`).

```bash
# Set these six before running (`$agentkit` = the installed skills tree, e.g. /home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills); every other line is fixed.
SCOPE=triage-and-selection                 # commit/PR scope
TITLE='trim bulk-ledger commentary, validator narration, and the schema-2 duplicate'
WHY='A 43 KB reference read by section on every dispatch carried comment essays inside an executed fence and prose that restates what write-merge-plan.sh prints.'
WHAT='In-fence comment stanzas become one line each (executed code unchanged); validator, uncoveredVerification, ledger, and work-shape prose keep every pinned sentence. 43,225 -> <measured> bytes.'
ISSUE=<number from the ledger>

# Stage ONLY the files the task names (never a blanket add: .agent/ carries local state).
git status --short                                   # confirm every listed path is a task file
FILES=(agentkit/skills/parallel-issues/references/triage-and-selection.md tests/test-fast-mode-contract.sh)   # this task's files
"$agentkit/.shared/scripts/worktree-commit.sh" --exact --message "refactor($SCOPE): $TITLE" --body "$WHY" \
    --trailer 'Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>' -- "${FILES[@]}"
git push -u origin "$(git branch --show-current)"
body=$(mktemp); printf '%s\n' 'This was written agentically; verify its assertions:' '' '## Why' "$WHY" '' '## What' "$WHAT" '' '## Testing' '- [ ] Byte ceiling / ratchet lowered in this PR fails before the cut and passes after' '- [ ] Every pinned literal named in the plan task survives (`tests/run-tests.sh` green)' '- [ ] Executed fences unchanged where the task requires (md5 in the task)' '- [ ] CI green' '' "🤖 Co-authored by Claude Fable 5.1. Closes #$ISSUE." > "$body"
gh pr create --draft --title "refactor($SCOPE): $TITLE" --body-file "$body"
```

Then the orchestrator (not the worker) moves the issue to In review: `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number "$ISSUE" --status "In review" --repo wrzonance/agent-kit`.

## Sequencing

| Group | Tasks | Base | Notes |
|---|---|---|---|
| Chained on #621 | A → B, and D | `refactor/size-w1-markers` (or `origin/main` after #621 merges) | A and B both edit `tests/lint-skill-size.sh` + `tests/test-skill-size.sh` (adjacent lines): branch B from A's branch or merge A first. D only shares the marker-edited `onboard-repo/SKILL.md` with #621. |
| Parallel worktrees | C, E, F, G, H, I, J, K, L, M, N | `origin/main` | File-disjoint (markdown *and* test files). Merge in any order. |

Cross-task facts the texts rely on (all hold whether or not the other task has merged): Task A's PI-05 points at the REST-routing rule that Task F keeps intact in `triage-and-selection.md` lines 136–152; Task C's PG-02 links the `#github-api-budget…` heading Task L keeps; Task A's PI-20 names `.shared/spawn-contract.md`'s "Bounded inline corrections" heading, which Task H keeps.

---

### Task 0: Tracking issues and board state

**Files:**
- Create (scratch, not committed): `/tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan2/issues/ledger.txt`

**Interfaces:**
- Produces: issue numbers `ISSUE_TA … ISSUE_TN` used by every later task's branch PR body (`Closes #N`), plus `ISSUE_TO` (the follow-up test issue, not implemented in this wave).

- [ ] **Step 1: Create one issue per task over REST, ledgered so a re-run never duplicates**

```bash
S=/tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad/plan2/issues; mkdir -p "$S"; L="$S/ledger.txt"; touch "$L"
mk() { id=$1; title=$2; body=$3; grep -q "^$id " "$L" && { echo "skip $id"; return; }
  printf '%s\n' "$body" > "$S/$id.md"
  n=$(gh api repos/wrzonance/agent-kit/issues -f "title=$title" -F "body=@$S/$id.md" -f 'labels[]=enhancement' -f 'labels[]=area/skills' -f 'labels[]=p2' --jq .number) && echo "$id $n" >> "$L"; sleep 2; }
F='🤖 Co-authored by Claude Fable 5.1.'
H='This was written agentically; verify its assertions:

## North star

Every token in a mandatory-read skill file is paid on every fresh root context and again after every compaction (5 in the 2026-09-05 HonkHonk run). This is wave two of the 2026-09-07 size audit (wave one: #622–#628, #621): cut prose that a helper already prints or enforces, or that another mandatory read already carries, drop network re-derivations of contract facts, and ratchet the size ceiling down to the measured minimum in the same PR. No new file, rule, gate, or round trip.'
mk TA 'refactor(parallel-issues): cut ledger/preflight/chain narration; board moves read repo.slug from the contract' "$H

## What
\`parallel-issues/SKILL.md\` (after #621): the preflight-ONCE/onboarded essay, the ledger reflow caveat, the --auto-serialize and chained-dispatch walkthroughs, the REST-routing paragraph (triage-and-selection.md is the home), the Phase 3 intro, the quiescence gate, and Limits each keep their pinned sentences in fewer lines; the resolver message names \`onboard-repo\`; the two board-move blocks read \`repo.slug\` from \`contract-read.sh\` after the guard instead of \`gh repo view\`; the \`unknown\` verdict fetches once instead of re-running. KNOWN_OVERSIZE[parallel-issues] 1002:18581 -> 946:17853. -2,914 bytes on the most re-read file in the tree.

$F"
mk TB 'refactor(review-remote-pr): compress The Loop, drop three jq preambles, defer the worker-gate reads to the first fix batch' "$H

## What
\`review-remote-pr/SKILL.md\` (after #621): The Loop ASCII keeps every step in 14 lines; the three \`command -v jq\` preambles go (pr-worktree.sh and gh-pr-state.sh self-check; \`gh --jq\` needs no jq binary) while the rule sentence at the top stays; 0b, 0c, Step 5, Step 3, and the two exit-report templates keep every pinned sentence in fewer lines; the Repo input reads the contract's \`repo=\` instead of \`git remote get-url\`; worker-gate.md, spawn-contract.md, and six-step-loop.md are read immediately before the first fix-batch dispatch instead of as a pre-read (~29 KB not read on a PR that needs no fix batch). KNOWN_OVERSIZE[review-remote-pr] 493:8167 -> 450:7708. -1,836 bytes.

$F"
mk TC 'refactor(pr-to-green): stop restating the authorization record and the baseline-red rule' "$H

## What
\`pr-to-green/SKILL.md\`: the authorization JSON shape and helper-behaviour prose (auto-merge.md and review-transition.sh own them) become one paragraph around the kept example command; the baseline-red paragraph, Phase C settlement paragraph, API-budget bullet, and Hard rules keep every pinned sentence in fewer lines. Adds a byte ceiling to tests/test-pr-to-green.sh. 20,367 -> 18,222 bytes on a skill that sat 8 tokens under the default gate.

$F"
mk TD 'refactor(onboard-repo): fold the intro and drop the restated command-run rules' "$H

## What
\`onboard-repo/SKILL.md\` (after #621): the seven one-line intro paragraphs become one; the protected-path/hook-bypass paragraph and the candidate/SETUP paragraphs tighten; the Reference-section restatements of \"runs directly, no approval step\" and the VERIFY/TEST on-demand rule go, with the --if-declared / declaring-neither / TEST-only facts folded into Step 4's kept paragraph. Adds a byte ceiling to tests/test-skill-path-resolution.sh. 19,697 -> 18,583 bytes on a skill that sat 7 tokens under the default gate.

$F"
mk TE 'refactor(worker-prompts): trim baseline/agent-run prose and the standalone branch-check fence' "$H

## What
\`parallel-issues/references/worker-prompts.md\`: the baseline-exclusion and agent-run.sh paragraphs pasted into every issue-lead prompt shrink; the standalone \`git branch --show-current\` fence goes (Branch Rules step 2 already states the check; the fence-count assertion in test-parallel-dispatch-contract.sh becomes a no-inner-fence invariant); the base-trusted config paragraph points at adversarial-review.md; the draft-PR body prose says \"never inline --body\" once. 47,320 -> 45,826 bytes; the composed issue-lead prompt drops ~775 bytes (its absolute size is checkout-path-dependent; ceiling 20,000).

$F"
mk TF 'refactor(triage-and-selection): trim bulk-ledger commentary, validator narration, and the schema-2 duplicate' "$H

## What
\`parallel-issues/references/triage-and-selection.md\`: the five comment stanzas inside the executed bulk-mutation fence become one line each (code unchanged); the ledger, record-shape, exhaustion, work-shape rationale, active-worker ledger, write-merge-plan validator, schema-2 example, uncoveredVerification, and AGENT_GENERATED_PATHS prose keep every pinned sentence in fewer lines. Adds a byte ceiling to tests/test-fast-mode-contract.sh. 43,225 -> 37,574 bytes on a reference read by section at every dispatch.

$F"
mk TG 'refactor(chains): compress the post-push rewrite essay and the trust-and-fencing changelog' "$H

## What
\`parallel-issues/references/chains.md\`: the post-push \"reads as a rewrite\" section keeps the rule in 4 lines. \`references/trust-and-fencing.md\`: the 2026-08-19 changelog preamble becomes one parenthetical. Ratchets chains.md to 17,000 and adds a trust-and-fencing ceiling in tests/test-chain-advance.sh. -1,257 bytes.

$F"
mk TH 'refactor(spawn-contract): dedupe the capability bullets and the tier-mapping essay' "$H

## What
\`.shared/spawn-contract.md\`: the two capability bullets that repeat the preceding two (selection and completion-table evidence) merge into one; Tier mapping and the peer-cli mapping keep every pinned phrase in 12 lines. Ratchets the spawn-contract ceiling in tests/test-skills-contract.sh to 18,100. 19,709 -> 17,943 bytes on a file both dispatching skills read in full.

$F"
mk TI 'refactor(adversarial-review): replace provenance/marker/lock/roster essays with the enforced rule' "$H

## What
\`review-remote-pr/references/adversarial-review.md\`: the \`#\`-comment history, the launch-marker and lock internals, the payload-identity derivation, the roster-resolution essay, and the --auto-review preamble each become the rule adversarial-run.sh / consent-record.sh enforce; the Pitfalls table (restates lines 18-33 and 343-348) goes. Adds a byte ceiling to tests/test-review-artifacts.sh. 25,007 -> 19,405 bytes on the Step 1b read.

$F"
mk TJ 'refactor(provider-rules): trim the Code Quality probe prose, the fingerprint essay, and end-of-cycle' "$H

## What
\`review-remote-pr/references/provider-rules.md\`: the issue-#403 probe history and in-fence comments shrink around the pinned probe block; the fingerprint (F4) essay and End-of-cycle keep their rules in 3 lines each. Ratchets the ceiling in tests/test-review-author-classification.sh to 30,600. 31,610 -> 30,488 bytes.

$F"
mk TK 'refactor(auto-merge): compress concurrency admission, guard alignment, and still-forbidden' "$H

## What
\`pr-to-green/references/auto-merge.md\`: Concurrency admission keeps its four pinned sentences in 12 lines; PreToolUse guard alignment becomes the three refused forms plus the merge-pr.sh exemption; Still forbidden becomes one paragraph. Ratchets the ceiling in tests/test-pr-to-green-authorize-queue.sh to 19,300. 21,344 -> 19,100 bytes.

$F"
mk TL 'refactor(shared): compress wait-discipline budget/replay prose, drop the six-step mapping table, trim gh-body --json' "$H

## What
\`.shared/wait-discipline.md\`: the GitHub API budget section becomes 8 lines, the two anecdotes one line each, never-replay-a-path 4 lines, and the durable-state recipe reads \`repo.slug\` from the contract instead of \`gh repo view\`. \`.shared/six-step-loop.md\`: the lead-phase mapping table (restates the steps in a second layout) goes. \`.shared/github-body-policy.md\`: the --json paragraph becomes one sentence. Byte ceilings in tests/test-wait-bound.sh, test-helper-refs.sh, test-gh-body.sh. -3,732 bytes across three files every run reads.

$F"
mk TM 'refactor(review-remote-pr): trim environment-contract, worker-gate, and grooming duplicates' "$H

## What
\`references/environment-contract.md\`: runtime neutrality and the harness-keyed/fleet-identity notes keep every rule in 11 and 10 lines. \`references/worker-gate.md\`: the gate restatement (SKILL.md 126-130 + spawn-contract carry it) and the six-step duplicate keep every pinned phrase. \`references/grooming.md\`: the Pitfalls table (restates lines 5-7) goes. Byte ceilings in tests/test-cross-provider-consent.sh. -2,771 bytes.

$F"
mk TO 'test(compose-worker-prompt): make the composed issue-lead prompt byte ceiling path-neutral' "$H

## What
\`tests/test-compose-worker-prompt.sh:102-105\` measures the composed issue-lead prompt with the live \`$agentkit\` and worktree paths embedded, so the same template measures 20,423 bytes at one checkout and 20,603 at a 118-character root — the ceiling is a property of the path, not the file (the wave-one review flagged this at 6.3; the wave-two review at H2). Substitute fixed placeholders for the two absolute paths before measuring (or subtract occurrences × path length), then ratchet the ceiling to the path-neutral minimum. Test-only change; no skill markdown moves.

$F"
mk TN 'refactor(references): trim the manifest preamble' "$H

## What
\`references.md\` (read by all four skills on every run): the hidden-directory rationale, the lint description, and the lib note become 15 lines; every manifest entry, the grammar fence, and the contract-cache CLI sentence are unchanged. Adds a byte ceiling to tests/test-reference-manifest.sh. 6,725 -> 5,986 bytes.

$F"
cat "$L"
```

- [ ] **Step 2: Confirm each issue landed on project 10 in Backlog** (GitHub auto-add did this for #606–#628):

```bash
agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills
for n in $(cut -d' ' -f2 "$L"); do "$agentkit/.shared/scripts/board-list.sh" --issue "$n" | tail -1; done
```

Expected: fifteen `#N  Backlog  …` lines (fourteen `refactor(...)`, one `test(...)`). If a row is missing: `gh project item-add 10 --owner wrzonance --url https://github.com/wrzonance/agent-kit/issues/N` (GraphQL; one call each).

- [ ] **Step 3: Move each issue to In progress when its task is dispatched, In review when its PR opens** — via `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number N --status "In progress" --repo wrzonance/agent-kit`. The orchestrator does this, never the worker.

---

### Task A: `parallel-issues/SKILL.md` — PI-02, PI-05, PI-06, PI-07, PI-12, PI-16, PI-18, PI-19, PI-20, PI-21, §5 board moves and `unknown` verdict

**Files:**
- Modify: `agentkit/skills/parallel-issues/SKILL.md` (line numbers below are on `main` + #621: 64–69, 73–84, 107–115, 182, 205–217, 311, 330, 336–346, 414–426, 520–529, 557–563, 743–745, 815–825, 831–837, 1007–1012)
- Modify: `tests/lint-skill-size.sh` (`[parallel-issues]=` entry), `tests/test-skill-size.sh:224,226`
- Test: `tests/test-parallel-dispatch-contract.sh`, `tests/test-autonomy-flags.sh`, `tests/test-session-ledger.sh`, `tests/test-skills-contract.sh`, `tests/test-contract-provenance.sh`, `tests/test-wait-bound.sh`, `tests/test-issue-body-boundary.sh`, `tests/lint-helper-refs.sh`, `tests/lint-skill-invocations.sh`, `tests/lint-rest-routing.sh`

**Interfaces:**
- Consumes: #621's marker-free `SKILL.md` and its `[parallel-issues]="1002:18581:900"` entry.
- Produces: `[parallel-issues]="946:17853:900"`, which Task B leaves alone (B edits the `review-remote-pr` line only).

**Pinned literals (raw unless marked flat; every one is inside or adjacent to an edited range — the rest of the file is untouched):** `full suite` (any file in the fast-mode union); `See [references/trust-and-fencing.md](references/trust-and-fencing.md#…) for ` on the first line naming `references/trust-and-fencing.md`; `` `--auto-review` is independent ``; `dispatched review agents do not launch the reviewer`; `dispatched loop agents never stall waiting for consent` (flat); `at the launch site`; `never via a workaround` (flat); `scope=57,54`; `scope=57,62`; `compaction/resume`; `auto-review=false`; `auto-review=true`; `verbatim quote`; `session-ledger.sh" append`; `--skills-path "$agentkit"`; `--procedure-set parallel-issues`; `one canonical issue-body fetch during preparation` and `` Do not fetch issue timelines, `projectItems` `` (line 312, untouched); `` Read [references/triage-and-selection.md](references/triage-and-selection.md#…) in full `` on the bulk-batch line; `` Read `references/chains.md` in full only when the selected set contains a chain `` (flat); `test files or prose does not serialize` (flat); `cycle`; `deeper tails enter the same refill queue as slot-cap overflow` (flat); `refill the next queued successor from that exact pushed SHA` (flat); `queued=`; `as soon as the predecessor's worker has committed and pushed its branch` (flat); `for a join, this means every predecessor pushed AND the merged join base itself pushed` (flat); `chain_base_sha`; `--issue-numbers "$issue_numbers_csv"`; `exit 0`; `Step 3b workers receive only root-approved fix batches`; `root handles CI state/verification, forge conflicts, adversarial review, consent` (flat); `4-link depth window`; `gh-pr-state.sh` (still named in Polling discipline, Step 3d, and the Final draft sweep after the Limits cut); `inline correction`, `zero dispatches`, `` resume the same worker with `followup_task` first `` (774–775, untouched); every `[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ]` guard (the two board-move blocks keep theirs verbatim; the new `contract-read.sh` line sits *after* it — a helper above the guard fails `lint-skill-invocations.sh` — and carries the same `repo=none in the environment contract; …` remedy Step 1's block prints, because `contract-read.sh` returns the literal `none` with exit 0).

- [ ] **Step 1: Worktree, branch, baseline**

```bash
cd /home/adam/github/agent-kit && git fetch origin main refactor/size-w1-markers
base=refactor/size-w1-markers; git rev-parse --verify -q origin/main:tests/lint-skill-size.sh >/dev/null && grep -q '1002:18581' <(git show origin/main:tests/lint-skill-size.sh) && base=main   # #621 merged → main carries it
git worktree add .worktrees/refactor/size-w2-parallel-issues -b refactor/size-w2-parallel-issues "origin/$base"
cd .worktrees/refactor/size-w2-parallel-issues && git branch --show-current
grep -c 'prepend THE CACHE REHYDRATION (defined once' agentkit/skills/parallel-issues/SKILL.md   # 0: #621's marker removal is in the base
wc -c agentkit/skills/parallel-issues/SKILL.md                                                   # 74846
tests/lint-skill-size.sh agentkit/skills | tail -1                                               # 4 skills checked, 0 violations
```

- [ ] **Step 2 (red): lower the ratchet first**

- [ ] **ratchet parallel-issues** — replace line 31 (from `    [parallel-issues]="1002:18581:900"`) with:

`````text
    [parallel-issues]="946:17853:900"
`````

- [ ] **ratchet pin (lines)** — replace line 224 (from `assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 1002 lines' \`) with:

`````text
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 946 lines' \
`````

- [ ] **ratchet pin (tokens)** — replace line 226 (from `assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 18581 tokens' \`) with:

`````text
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 17853 tokens' \
`````

Run: `tests/lint-skill-size.sh agentkit/skills; tests/run-tests.sh --only skill-size`
Expected: the lint reports `allowlisted skill 'parallel-issues' grew to 1002 lines, past its ratcheted ceiling of 946 lines` and `… ~18581 estimated tokens, past its ratcheted ceiling of 17853 tokens`; the `skill-size` suite stays green (its fixtures exceed both new numbers).

- [ ] **Step 3: The edits** (apply bottom-up, or re-grep each anchor after the previous edit; anchors are whole lines)

- [ ] **PI-21** — replace lines 64–69 (from `**Verification cache and suite cadence.** `agent-run.sh` caches a green eligible` through `that SHA. See [references/trust-and-fencing.md](references/trust-and-fencing.md#verification-cache-and-suite-cadence) for the detail.`) with:

`````text
**Verification cache.** `agent-run.sh` caches a green eligible verification per command/directory/tree-state (`--force` bypasses it); run focused suites while iterating and the full suite once per tree state before commit. See [references/trust-and-fencing.md](references/trust-and-fencing.md#verification-cache-and-suite-cadence) for the eligible names and cadence.
`````

- [ ] **PI-16** — replace lines 73–84 (from `**`--auto-review` is independent.** It is valid with or without the other two, and it` through `workaround.`) with:

`````text
**`--auto-review` is independent.** Valid with or without the other flags; it grants only the
cross-provider send `review-remote-pr` describes — never brainstorm/approval skips, never a
repository the user does not own. Typed approval is context-local: root is the default holder,
dispatched review agents do not launch the reviewer, and dispatched loop agents never stall waiting for consent they
cannot hold — they run CI, precheck, and triage around the root-owned send. Keep `RUN_ID`, the consent
record, and the verbatim `--auto-review` quote at the launch site so harness denials surface directly,
never via a workaround.
`````

- [ ] **PI-18** — replace lines 107–115 (from `The normalized issue scope, canonical authorization flags, repository, and base are available` through `carriage return normalized to LF:`) with:

`````text
The scope, flags, repository, and base are fixed before the first receipt and survive HEAD or contract
changes after compaction/resume: `scope=57,54` and `scope=57,62` cannot share an ID, nor can
`auto-review=false` and `auto-review=true`; the same exact tuple may intentionally resume. Reuse this
invocation-level `RUN_ID` for every issue, never a worker-local value. Append every human grant, steer, or board adjudication
immediately on receipt, passing the verbatim quote through a private temp file so a multi-line grant is
stored with no reflow (CR normalized to LF):
`````

- [ ] **PI-02 (resolver message names the real remedy)** — replace line 182 (from `    printf '%s\n' 'agentkit: skills path is absent from .agent/env-contract.txt; run agent-preflight.sh first' >&2`) with:

`````text
    printf '%s\n' 'agentkit: skills path is absent from .agent/env-contract.txt; run onboard-repo first' >&2
`````

- [ ] **PI-02** — replace lines 205–217 (from `This block is **not** part of the resolver above and must never be folded back into it. It writes` through `contract; it is not a bootstrap.`) with:

`````text
Run this block once, never per shell call: it rewrites `.agent/env-contract.txt` (a transient `gh`/network
failure would silently overwrite a good contract) and prints the whole contract. It refreshes an existing
contract only — a repository with none must run `onboard-repo` first, the sole contract-absent bootstrap.
`````

- [ ] **section 5 (`unknown` verdict: one fetch, never a blind re-run)** — replace line 311 (from ``merged-ref`, `in-flight`, or `attempted` verdict; `gh issue view` for an `unknown` verdict; and`) with:

`````text
`merged-ref`, `in-flight`, or `attempted` verdict; the `gh api` issue fetch for an `unknown` verdict; and
`````

- [ ] **section 5 (`unknown` verdict row)** — replace line 330 (from `| `unknown` | the query returned nothing usable | re-run; if it persists, fetch that one issue through `gh api repos/<owner>/<repo>/issues/<N>` |`) with:

`````text
| `unknown` | the query returned nothing usable | fetch that one issue through `gh api repos/<owner>/<repo>/issues/<N>` — never a blind re-run of the digest |
`````

- [ ] **PI-05** — replace lines 336–346 (from `Any batch that creates or edits more than one forge object carries a resumable apply ledger —` through `budget-artifact check, and a correct filtered-read example live there.`) with:

`````text
Any batch that creates or edits more than one forge object carries a resumable apply ledger, never a
bare loop of mutations, and routes over REST (`gh api repos/<owner>/<repo>/...`, `-X GET` on filtered
reads) with GraphQL reserved for Projects v2 and review-thread resolution. Read
[references/triage-and-selection.md](references/triage-and-selection.md#bulk-mutation-discipline-ledger-chunks-and-resource-budget)
in full before running any bulk batch — the ledger recipe, the budget check, and the routing rule live there.
`````

- [ ] **PI-06** — replace lines 414–426 (from `**With `--auto-serialize`,** ordered pairs become chain edges instead of drops. Read `references/chains.md` in full only when the selected set contains a chain; the flag alone is insufficient. Classify each` through `it is torn down first. Chains cap 4 successor links; deeper tails enter the same refill queue as slot-cap overflow (`queued=N[#...]`). When a predecessor publishes, refill the next queued successor from that exact pushed SHA. See [references/chains.md](references/chains.md).`) with:

`````text
**With `--auto-serialize`,** ordered pairs become chain edges instead of drops. Read `references/chains.md` in full only when the selected set contains a chain; the flag alone is insufficient. Only an
**interface dependency** (one issue consumes code or contracts the other produces, or both mutate the
same executable logic) becomes a chain edge; overlap confined to test files or prose does not serialize — run
those in parallel and merge down once at the end. Build the graph from those pairs plus native blocked-by
edges, decompose it into linear chains, and print the chain plan beside the conflict table (attended:
get approval; `--fast-mode`: proceed). A cycle cannot be chained — report its members and fall back to
drop/ask for exactly those. A multi-predecessor join is scheduled, not dropped: its merged, pushed start
point is built per `references/chains.md` before dispatch. Chains cap 4 successor links; deeper tails enter the same refill queue as slot-cap overflow (`queued=N[#...]`). When a predecessor publishes, refill the next queued successor from that exact pushed SHA.
`````

- [ ] **PI-07** — replace lines 520–529 (from `**Chained issues defer — but only on the commit, not the publication.** A chain successor's` through `[references/chains.md](references/chains.md#deferred-dispatch) for the full rationale.`) with:

`````text
**Chained issues defer on the commit, not the publication.** A successor's worktree is created and its lead
dispatched as soon as the predecessor's worker has committed and pushed its branch — for a join, this means every predecessor pushed AND the merged join base itself pushed — using the full 40-character
`chain_base_sha` from the completion report; root review, PR, board, and ledger writes are off that
critical path. Deferred issues hold no slot; a failed or BLOCKED predecessor parks its chain by name. See
[references/chains.md](references/chains.md#deferred-dispatch) for the rationale.
`````

- [ ] **section 5 (board move reads repo.slug from the contract, after the guard)** — replace lines 557–563 (from `if ! repository="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || [[ -z $repository ]]; then` through `    --issue-numbers "$issue_numbers_csv" --status 'In progress' --repo "$repository"`) with:

`````text
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
repository=$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$contract_root" --get repo.slug) && [[ $repository == */* ]] || { printf '%s\n' 'repo=none in the environment contract; re-run the Step 0 preflight from a checkout with a GitHub origin' >&2; exit 1; }
"$agentkit/parallel-issues/scripts/move-github-project-item.sh" \
    --issue-numbers "$issue_numbers_csv" --status 'In progress' --repo "$repository"
`````

- [ ] **section 5 (In review board move, same substitution)** — replace lines 831–837 (from `if ! repository="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || [[ -z $repository ]]; then` through `    --issue-number "$issue_number" --status 'In review' --repo "$repository"`) with:

`````text
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf "%s\n" "agentkit unresolved: prepend THE CACHE REHYDRATION block" >&2; exit 1; }
repository=$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$contract_root" --get repo.slug) && [[ $repository == */* ]] || { printf '%s\n' 'repo=none in the environment contract; re-run the Step 0 preflight from a checkout with a GitHub origin' >&2; exit 1; }
"$agentkit/parallel-issues/scripts/move-github-project-item.sh" \
    --issue-number "$issue_number" --status 'In review' --repo "$repository"
`````

- [ ] **PI-20** — replace lines 743–745 (from `Before root writes in a worker worktree, prove no unacknowledged `SendMessage`, clean status except` through `Prefer `followup_task`; inline requires `--exact`.`) with:

`````text
Before any root write in a worker worktree, satisfy `.shared/spawn-contract.md`'s quiescence gate ("Bounded
inline corrections"); prefer `followup_task`; inline requires `--exact`.
`````

- [ ] **PI-12** — replace lines 815–825 (from `Phase A orchestration remains with the root. As the root opens each draft PR from a Phase 2` through `on any PR**.`) with:

`````text
As the root opens each draft PR from a lead's pushed completion report, it runs `/review-remote-pr`'s
**draft-first** flow on it in parallel with the other leads. Step 3b workers receive only root-approved fix batches for
mechanical implementation; they commit and push the assigned branch and stop. The root handles CI state/verification, forge conflicts, adversarial
review, consent, replies, and publication — and never initiates a provider review: **never post
`@coderabbitai review` or `full review` on any PR**.
`````

- [ ] **PI-19** — replace lines 1007–1012 (from `- Maximum 10 per wave; include root in cap; fast-mode queues overflow; attended asks.` through `- Step 3d polls observe provider-configured review timing; silence is observed state, not a trigger.`) with:

`````text
- Maximum 10 per wave (root counted); fast-mode queues overflow, attended asks. Chains use a 4-link depth window under `--auto-serialize`; deeper tails queue/refill, never drop, and count toward the limit.
- Invocation opts into issue leads; only root spawns. Requires `gh` with Projects v2 access (`read:project`/`project`, or App `Projects: write`), `jq`, the shipped helpers, and a `main` or `master` branch.
`````

- [ ] **Step 4 (green): verify sizes, pins, suite**

```bash
wc -c agentkit/skills/parallel-issues/SKILL.md                                # 71932
tests/lint-skill-size.sh agentkit/skills | tail -1                            # 4 skills checked, 0 violations (body exactly 946 lines / ~17853 tokens; if it prints other numbers, set the entry and the two test pins to what it prints)
tests/run-tests.sh --only skill-size,parallel-dispatch-contract,autonomy-flags,session-ledger,skills-contract,contract-provenance,wait-bound,issue-body-boundary,adversarial-review-receipt
for l in helper-refs skill-invocations markdown-blocks reference-manifest; do tests/lint-$l.sh agentkit/skills || echo "LINT FAIL $l"; done   # lint-rest-routing.sh is red on untouched main (10 helper-script violations) and scans .sh only; no task here touches a .sh
tests/run-tests.sh
```

Expected: all green (measured on the scratch tree: `parallel-dispatch-contract` 626/0, `autonomy-flags`, `session-ledger`, `skills-contract` 175/0, `contract-provenance` 116/0). Any pinned-literal failure → restore that sentence verbatim on one line.

- [ ] **Step 5: Shared step** with `SCOPE=parallel-issues`, `TITLE='cut ledger/preflight/chain narration; board moves read repo.slug from the contract'`, `WHY='The most re-read file in the tree still carried the preflight-ONCE essay, walkthroughs whose home is chains.md/triage-and-selection.md, and two board-move blocks that asked the network for a slug the environment contract already holds.'`, `WHAT='Ten prose ranges keep every pinned sentence in fewer lines; the resolver names onboard-repo; both board moves read repo.slug via contract-read.sh after the guard; unknown-verdict fetches once. KNOWN_OVERSIZE[parallel-issues] 1002:18581 -> 946:17853; 74,846 -> 71,932 bytes.'`, `ISSUE=<TA>`, `FILES=(agentkit/skills/parallel-issues/SKILL.md tests/lint-skill-size.sh tests/test-skill-size.sh)`.

---

### Task B: `review-remote-pr/SKILL.md` — RR-01, RR-02, RR-04, RR-05, RR-07, RR-08, RR-09, RR-10, §4.2 deferred reads, §5 repo input

**Files:**
- Modify: `agentkit/skills/review-remote-pr/SKILL.md` (on `main` + #621: 67–68, 72–78, 80–82, 87, 130, 137–164, 191, 214–218, 221, 225–230, 259–260, 268–271, 280–283, 409–415, 441–449, 475–493)
- Modify: `tests/lint-skill-size.sh` (`[review-remote-pr]=` entry), `tests/test-skill-size.sh:185,195`
- Test: `tests/test-skills-contract.sh:263-300, 398-415`, `tests/test-parallel-dispatch-contract.sh:1021-1032` (root_sections), `tests/test-review-artifacts.sh:505-520`, `tests/test-adversarial-review-receipt.sh`, `tests/test-recipe-safety.sh`, `tests/test-autonomy-flags.sh`, `tests/test-contract-provenance.sh`, `tests/test-verification-baseline.sh`, `tests/lint-helper-refs.sh` (first mentions: `contract-read.sh` on line 87 must be `$agentkit`-rooted because it now precedes line 203)

**Interfaces:**
- Consumes: Task A's branch (or `main` after A merges) for the `KNOWN_OVERSIZE` declare block.
- Produces: `[review-remote-pr]="450:7708:450"` — 450 lines is exactly the TARGET; the entry is still required because ~7708 tokens is over the 5000 default (the stale-entry rule fires only when both dimensions are within budget).

**Pinned literals:** `jq is not installed; evidence unavailable` (line 65 stays — it becomes the sole occurrence in this file); `../.shared/github-body-policy.md`; `author.__typename == "Bot"`; `generic automated finding is an automated B-item`; `H labels are human-only`; `$agentkit/review-remote-pr/scripts/gh-comment.sh` (first mention, rooted); `Reuse that loaded content in Step 5; do not re-read it` (flat) and not `in full before Step 1a and`; the first line naming `references/worker-gate.md` carries `read … in full` (the trigger names all three decision outcomes — dispatch, bounded inline correction, `worker=self` — because the inline and degraded criteria live only in the deferred files); `review the worker's pushed diff and re-check CI and review state` (flat, inside The Loop); `if ! setup_output=` before `PR_WORKTREE=`; `merge-inherited paths parked/handed off`; `core.hooksPath`; `never rebase`; `git add -A` (Step 0 range, line 207 comment stays); `peer-cli= <name> absent`; `blind same-harness fallback`; `$agentkit/.shared/scripts/worktree-commit.sh` and `$agentkit/.shared/scripts/agent-run.sh` first mentions (rooted, in the rewritten 0b paragraph); `scripts/run-dir.sh" --pr "$PR"`; `.agent/evidence/pr-<N>`; `` falls back to `${TMPDIR:-/tmp}` only when ``; `re-set RUN_DIR to the Step 0c output; shell state does not persist`; `blocked check and must never be summarized as “no findings.”`; the Step 3 section (`/^## Step 3 (Phase B)/,/^## Step 4:/`) keeps `` Never run `gh pr ready` ``, `bounded blocking re-check rounds`, `~10 minutes each`, `~90 minutes total`, `one blocking helper/harness wait`, `Never trigger a review`; `### Adversarial-review receipt:` before `## Step 3 (Phase B):`; every guard line; `"$agentkit/review-remote-pr/scripts/pr-worktree.sh" --pr` before `contract-read.sh` in the initial block.

- [ ] **Step 1: Worktree, branch, baseline**

```bash
cd /home/adam/github/agent-kit && git fetch origin
git worktree add .worktrees/refactor/size-w2-review-remote-pr -b refactor/size-w2-review-remote-pr refactor/size-w2-parallel-issues   # Task A's branch; or origin/main once A has merged
cd .worktrees/refactor/size-w2-review-remote-pr && git branch --show-current
wc -c agentkit/skills/review-remote-pr/SKILL.md          # 32901
grep -n 'command -v jq' agentkit/skills/review-remote-pr/SKILL.md   # 65, 191, 221, 280 (65 stays)
```

- [ ] **Step 2 (red): lower the ratchet first**

- [ ] **ratchet review-remote-pr** — replace line 30 (from `    [review-remote-pr]="493:8167:450"`) with:

`````text
    [review-remote-pr]="450:7708:450"
`````

- [ ] **ratchet pin (tokens)** — replace line 185 (from `assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 8167 tokens' 'the token ratchet names its ceiling'`) with:

`````text
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 7708 tokens' 'the token ratchet names its ceiling'
`````

- [ ] **ratchet pin (lines)** — replace line 195 (from `assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 493 lines' 'the line ratchet names its ceiling'`) with:

`````text
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 450 lines' 'the line ratchet names its ceiling'
`````

Run: `tests/lint-skill-size.sh agentkit/skills`
Expected: `allowlisted skill 'review-remote-pr' grew to 493 lines, past its ratcheted ceiling of 450 lines` and `… ~8167 estimated tokens, past its ratcheted ceiling of 7708 tokens`.

- [ ] **Step 3: The edits** (the three RR-08 deletions share one anchor line — the `occurrence` counts below are against the *pristine* file; apply them bottom-up)

- [ ] **section 5 (repo slug from the contract, not `git remote get-url`)** — replace line 87 (from `- **Repo** — infer from `git remote get-url origin`; override with `owner/repo` arg`) with:

`````text
- **Repo** — the contract's `repo=` line (`$agentkit/.shared/scripts/contract-read.sh --repo-root DIR --get repo.slug`; `none` means no GitHub origin — re-run the Step 0 preflight); override with `owner/repo` arg
`````

- [ ] **RR-07** — replace lines 67–68 (from `Read ["$agentkit/review-remote-pr/references/environment-contract.md"](references/environment-contract.md) in full before Step 0a: the runtime-neutrality and` through `environment-contract mechanics (preflight, decision lines, repo-runner opt-in).`) with:

`````text
Read ["$agentkit/review-remote-pr/references/environment-contract.md"](references/environment-contract.md) in full before Step 0a for the environment-contract mechanics.
`````

- [ ] **RR-07** — replace lines 72–78 (from `CodeRabbit and `github-code-quality[bot]` each have provider-specific fixed/inaccurate handling;` through `human-touched thread.**`) with:

`````text
CodeRabbit and `github-code-quality[bot]` get provider-specific handling; other bots and humans have their
own lanes. Authoritative signals: GraphQL `author.__typename == "Bot"`, REST `author.type == "Bot"`, or an
exact `[bot]` login suffix — a login merely containing `bot` is human. A generic automated finding is an automated B-item, never
H; H labels are human-only. Every automated reply passes the reply-body integrity gate
(`$agentkit/review-remote-pr/scripts/gh-comment.sh`: resolve/dismiss only on its printed stdout line + exit `0`). **Never resolve a
human-touched thread.**
`````

- [ ] **RR-07** — replace lines 80–82 (from `Read ["$agentkit/review-remote-pr/references/provider-rules.md"](references/provider-rules.md) in full before Step 1a — the` through `there. Reuse that loaded content in Step 5; do not re-read it.`) with:

`````text
Read ["$agentkit/review-remote-pr/references/provider-rules.md"](references/provider-rules.md) in full before Step 1a — the
provider table, classifier, human gate, and settlement recipes. Reuse that loaded content in Step 5; do not re-read it.
`````

- [ ] **REPORT §4.2 (worker-gate/spawn-contract/six-step-loop read at the first fix-batch dispatch, not preloaded)** — replace line 130 (from `then read ["$agentkit/review-remote-pr/references/worker-gate.md"](references/worker-gate.md), ["$agentkit/.shared/spawn-contract.md"](../.shared/spawn-contract.md), and ["$agentkit/.shared/six-step-loop.md"](../.shared/six-step-loop.md) in full first; workers validate/commit/push, root owns PR metadata/posts.`) with:

`````text
then — at the first fix batch, before choosing between a dispatch, a bounded inline correction, or a `worker=self` path, never as a pre-read — read ["$agentkit/review-remote-pr/references/worker-gate.md"](references/worker-gate.md), ["$agentkit/.shared/spawn-contract.md"](../.shared/spawn-contract.md), and ["$agentkit/.shared/six-step-loop.md"](../.shared/six-step-loop.md) in full; workers validate/commit/push, root owns PR metadata/posts.
`````

- [ ] **RR-01** — replace lines 137–164 (from `PHASE A — DRAFT (all mechanical work; never initiate a provider review)` through `  7. GROOM   — (after exit) fan across the Backlog, propose Ready candidates for the next pickup`) with:

`````text
PHASE A — DRAFT (mechanical work; never initiate a provider review)
  0. SETUP    — enter/create the PR worktree, run agent-preflight ONCE, merge if conflicts
  1. CHECK    — one $agentkit/review-remote-pr/scripts/gh-pr-state.sh --full call: digest + durable artifacts
  1a. HUMAN   — surface human-authored content; gate every action/reply on per-item confirmation
  2. FIX CI   — diagnose, dispatch the implementation worker, review the worker's pushed diff and re-check CI and review state after its push; repeat 1–2 until green
  2a. FRESHEN — digest `base:` stale=yes? run 0b's merge recipe before the review
  2b. ADVERSARIAL — LAST draft step (CI green, base current): materiality gate, then one cross-harness review with confirmed findings fixed, or a documented verified skip
PHASE B — HANDOFF: 3. WAIT-READY — report draft-phase complete; the USER flips ready and triggers any provider review, never this skill
PHASE C — REVIEW (when provider findings land)
  3a. FRESHEN — stale `base:`? rerun 0b's merge recipe once before Step 4
  4. WAIT     — gh-pr-state.sh --wait-ci in bounded rounds; escalate, don't wait
  5. FIX      — approved human actions first (threads stay unresolved); body nitpicks + github-code-quality[bot]; each CodeRabbit thread fix/decline → reply → settle; ONE push per batch
  6. REPEAT   — while CI failures, unresolved automated threads, or unhandled findings remain (cap 3 cycles); a later provider pass may need repo config or a user trigger — report and let the user decide
  7. GROOM    — (after exit) propose Ready candidates from the Backlog
`````

- [ ] **RR-08 (0a: pr-worktree.sh self-checks jq)** — delete line 191 (from `if ! command -v jq >/dev/null 2>&1; then printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; fi`).

- [ ] **RR-08 (0b: `gh --jq` needs no jq binary)** — delete line 221 (from `if ! command -v jq >/dev/null 2>&1; then printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; fi`).

- [ ] **RR-08 (Step 1: gh-pr-state.sh self-checks jq)** — delete lines 280–283 (from `if ! command -v jq >/dev/null 2>&1; then` through `fi`).

- [ ] **RR-02** — replace lines 214–218 (from `A protected path caught in a base merge uses the shared commit handoff's named-base affordance,` through ``core.hooksPath` (via `git -c`/`git config`), a `git config alias.…` override, or equivalent.`) with:

`````text
A protected path caught in a base merge uses the commit helper's named-base affordance and reports
`merge-inherited paths parked/handed off` (exit `3`, an attended park; exit `2` is the git-metadata elevation
handback). A hook refusal is one bounded named park: **never** bypass with `--no-verify`, `core.hooksPath`, an alias, or any equivalent.
`````

- [ ] **RR-02** — replace lines 225–230 (from `If `CONFLICTING`, root merges the base into the PR branch — **never rebase** a published branch,` through `and verify via `$agentkit/.shared/scripts/agent-run.sh`:`) with:

`````text
If `CONFLICTING`, root merges the base into the PR branch — **never rebase** a published branch, never
force-push it. Resolve (`git checkout --ours|--theirs <path>` or edit; strip markers with `sed`, never
`python3 -c`), grep-verify no `<<<<<<<`/`=======`/`>>>>>>>` remain, then commit via
`$agentkit/.shared/scripts/worktree-commit.sh` and verify via `$agentkit/.shared/scripts/agent-run.sh`:
`````

- [ ] **RR-09** — replace lines 259–260 (from `Review payloads carry private source and review text. Resolve one `0700` run directory for this` through `PR, carried forward as `RUN_DIR` in every later block — never hand-roll a `mktemp` path:`) with:

`````text
Resolve one private run directory for this PR, carried as `RUN_DIR` in every later block — never hand-roll a `mktemp` path:
`````

- [ ] **RR-09** — replace lines 268–271 (from `Same path every session for this PR (`<repo>/.agent/evidence/pr-<N>`, mode `0700`, a hostile` through `top of every later block: `: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"``) with:

`````text
Same path every session (`<repo>/.agent/evidence/pr-<N>`, mode `0700`); falls back to `${TMPDIR:-/tmp}` only when
`.agent/` is unwritable. Keep it for audit. Re-set it at the top of every later block: `: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"`
`````

- [ ] **RR-04** — replace lines 441–449 (from `Use the provider-rules.md content loaded in Step 1a for the full cycle order (approved human` through `handback files or uses `git add -A` (`.agent/` is untracked working state).`) with:

`````text
Use the provider-rules.md content loaded in Step 1a: the cycle order (approved human actions first →
nitpicks + Code Quality → one implementation-worker batch → post/verify replies → CodeRabbit settlement
LAST), the VALID/INVALID/NITPICK recipes, and the reply/settlement command shapes. Adversarial findings from
`$RUN_DIR/adversarial.result.json` take the same assess → fix → document path, documented in a **PR comment**.
Post declines before the cycle's single push (Step 1c). Root reviews the pushed diff; never `git add -A`.
`````

- [ ] **RR-05** — replace lines 475–493 (from `**Draft-phase report (end of Phase A, before the Step 3 wait):**` through ``worker=self` reason; every human-review item's decision, verified-reply state, open-thread state.)`) with:

`````text
**One template for both the draft-phase report (end of Phase A, before the Step 3 wait) and the final report (loop exit):**
```text
PR #N: [draft phase complete | all CI green] — CI green, conflicts none, N/N CodeRabbit threads handled, all body nitpicks handled,
GitHub Code Quality: [no findings | auto-cleared | dismissed with reasons | blocked],
CodeRabbit approval: [approved | not observable | no provider review observed],
Adversarial review [Claude Opus 5 | blind Codex-agent fallback (reason: <blockedReason>|absent)]: M findings, M handled.
Implementation worker: [<model> <effort> | worker=self — reason: <why>], six-step gate complete.
Human review: [none | H1 approved/replied/open | H2 awaiting confirmation].
[Waiting for you to mark it ready — this skill will not trigger a review. | Ready to merge | Awaiting user confirmation; not claiming readiness]
```
(Draft phase: threads 0/0 and approval "no provider review observed" — no provider review exists before the user triggers one. Identify which reviewer ran and any fallback reason; who wrote the code and its model/effort or
`worker=self` reason; every human-review item's decision, verified-reply state, open-thread state.)
`````

- [ ] **RR-10** — replace lines 409–415 (from `When Phase A is done — CI green, conflicts resolved, every adversarial finding fixed or` through `one blocking helper/harness wait to own the rounds, then escalate to the user. **Never trigger a review.**`) with:

`````text
When Phase A is done, report the draft-phase summary (Exit Report) and wait per
["$agentkit/.shared/wait-discipline.md"](../.shared/wait-discipline.md) — no `gh pr view` + sleep loop. Then
observe a real CodeRabbit review landing (walkthrough body, not an ack); if none arrives, report it. If
rate-limited, perform **bounded blocking re-check rounds** (~10 minutes each, up to ~90 minutes total): use
one blocking helper/harness wait to own the rounds, then escalate to the user. **Never trigger a review.**
`````

- [ ] **Step 4 (green)**

```bash
wc -c agentkit/skills/review-remote-pr/SKILL.md            # 31065
tests/lint-skill-size.sh agentkit/skills | tail -1         # 0 violations (body exactly 450 lines / ~7708 tokens)
tests/run-tests.sh --only skill-size,skills-contract,parallel-dispatch-contract,review-artifacts,adversarial-review-receipt,recipe-safety,autonomy-flags,contract-provenance,verification-baseline,session-ledger
for l in helper-refs skill-invocations markdown-blocks reference-manifest; do tests/lint-$l.sh agentkit/skills || echo "LINT FAIL $l"; done
tests/run-tests.sh
```

- [ ] **Step 5: Shared step** with `SCOPE=review-remote-pr`, `TITLE='compress The Loop, drop three jq preambles, defer the worker-gate reads to the first fix batch'`, `WHY='A mandatory read carried a 30-line ASCII loop, three copies of a jq preamble whose helpers self-check, two exit-report templates that differ by one line, and a pre-read of three files (~29 KB) that only a fix batch needs.'`, `WHAT='The Loop in 14 lines; one jq rule sentence; 0b/0c/Step 3/Step 5/exit report keep every pinned sentence; Repo comes from the contract; worker-gate/spawn-contract/six-step-loop read at the first fix batch, before choosing dispatch / inline / worker=self. KNOWN_OVERSIZE[review-remote-pr] 493:8167 -> 450:7708; 32,901 -> 31,065 bytes.'`, `ISSUE=<TB>`, `FILES=(agentkit/skills/review-remote-pr/SKILL.md tests/lint-skill-size.sh tests/test-skill-size.sh)`.

---

### Task C: `pr-to-green/SKILL.md` — PG-01…PG-05

**Files:**
- Modify: `agentkit/skills/pr-to-green/SKILL.md:82-83, 93-97, 98-103, 159-167, 179-215, 227-238, 273-280`
- Modify: `tests/test-pr-to-green.sh` (byte ceiling before `finish`)
- Test: `tests/test-pr-to-green.sh:20-79`, `tests/test-contract-provenance.sh`, `tests/lint-helper-refs.sh` (rooted first mentions of `concurrency-cap.sh` (80), `gh-pr-state.sh` (101 — kept in the rewritten bullet because line 114's `../review-remote-pr/…` form would otherwise become an unrooted first mention), `verification-baseline.sh` (229), `compose-pr-body.sh` (235), `review-ledger.sh` (280); `scripts/authorize-queue.sh` resolves)

**Pinned literals:** `Steps 2–4) may run in parallel across independent` (flat); `Step 5's`; `strict serial merge ordering` (flat, now folded into the first Hard-rules bullet); `provider plan, verified dependency graph, and exact serial queue` (flat); `remediation pushes, ready transitions, and trigger-capable requests` (flat); `Never merge, force-push, or clean worktrees` (flat); `adversarial review`; `per-item confirmation`; `critical section`; `only one root inside it at a time`; `review-transition.sh`, `pr-queue.sh`, `thread-action.sh`, `chain-advance.sh`, `merge-gate.sh`, `merge-pr.sh`, `move-github-project-item.sh`, `auto-merge.md`, `review-remote-pr/SKILL.md`, `review-provider-config.sh`, `--auto-merge`, `evidence-green`, `WAITING_FOR_MERGE`, `RETARGET_REQUIRED`, `Automatic discovery selects drafts`, `explicitly named ready PR`, `branch-protection refusal is`; the bash fence at 171–177 unchanged; the `source` vocabulary `capability-default` / `operator-instruction` (not test-pinned, but its only prose home — a root that displayed an operator-chosen `observe` must be able to spell `--provider coderabbit:observe:operator-instruction` without a reconfirm round trip); no `| Provider |`, no `@coderabbitai full review`, no `gh pr ready`.

- [ ] **Step 1: Worktree/branch `refactor/size-w2-pr-to-green` from `origin/main`; record `wc -c` (20,367).**

- [ ] **Step 2 (red):**

- [ ] **byte ceiling: pr-to-green SKILL.md** — replace line 111 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/pr-to-green/SKILL.md") -le 18400 ]] && printf yes || printf no)" \
    'pr-to-green SKILL.md stays at or under 18400 bytes'

finish
`````

Run `tests/run-tests.sh --only pr-to-green`; expect `FAIL pr-to-green SKILL.md stays at or under 18400 bytes`.

- [ ] **Step 3: The edits**

- [ ] **PG-05** — replace lines 82–83 (from `  Step 5's` through `  merges are serial.`) with:

`````text
  Step 5's
  merges are serial; `--auto-merge` implies strict serial merge ordering.
`````

- [ ] **PG-05 (meta bullet and the folded serial-ordering bullet)** — delete lines 93–97 (from `- Provider rules, author classification, fix batches, reply settlement,` through `  ["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md).`).

- [ ] **PG-02** — replace lines 98–103 (from `- **GitHub API budget.** Read `$agentkit/pr-to-green/scripts/pr-queue.sh --write-confirmed-queue`'s` through `  ["$agentkit/.shared/wait-discipline.md"](../.shared/wait-discipline.md#github-api-budget--a-rate-limit-exit-is-not-a-wait-to-retry).`) with:

`````text
- **GitHub API budget.** Read `$agentkit/pr-to-green/scripts/pr-queue.sh --write-confirmed-queue`'s
  `budget:` preflight line first; `$agentkit/review-remote-pr/scripts/gh-pr-state.sh`/`pr-queue.sh` exit `3` is a rate-limit stop —
  ["$agentkit/.shared/wait-discipline.md"](../.shared/wait-discipline.md#github-api-budget--a-rate-limit-exit-is-not-a-wait-to-retry) owns the rule.
`````

- [ ] **PG-01** — replace lines 159–167 (from `After confirmation, derive the owner-only authorization JSON with` through `redisplay/reconfirmation.`) with:

`````text
After confirmation, derive the owner-only authorization JSON with
`scripts/authorize-queue.sh`, passing the same repository, merge plan or PR selectors, and provider
decisions the displayed queue used; it re-reads the live queue, requires it to equal the displayed
snapshot (any drift fails closed → redisplay/reconfirm), and copies the queue fields from that live result.
`````

- [ ] **PG-01** — replace lines 179–215 (from `Pass every displayed trigger-capable provider as` through `which this same confirmation durably covers.`) with:

`````text
Pass every displayed trigger-capable provider as `--provider NAME:ACTION:SOURCE` (`--no-providers` when
the plan has none); they must match the persisted provider records exactly. The ready-transition and
auto-merge choices are mandatory arguments, so the helper never infers consent — a merging queue passes
`--auto-merge --merge-method METHOD` plus `--delete-branch` or `--keep-branch`. The record holds
`repository`, `readyTransition: true`, one `{"name","action":"trigger|observe|disabled","source"}` per
provider (`source` is `capability-default` for an unmodified `trigger`, `operator-instruction` for an
operator-chosen `observe`/`disabled`), `queue` entries `{"pr","state","headSha","base"}`, and — under `--auto-merge` — `autoMerge`,
`mergeMethod`, `deleteBranch` (["$agentkit/pr-to-green/references/auto-merge.md"](references/auto-merge.md));
`review-transition.sh` checks the live head SHA and base ref against it before any ready-flip or provider
spend, posting nothing for a `disabled`/`observe` action (`result=DISABLED`/`OBSERVE_ONLY source=<source>`).
It is narrow evidence, not reusable consent: re-display and reconfirm changed inputs, except a verified
mechanical advance of an already-confirmed PR (Step 5), which this same confirmation durably covers.
`````

- [ ] **PG-04** — replace lines 227–238 (from `A declared-verification failure whose failing paths are all provably unchanged` through `the PR fully green.`) with:

`````text
A declared-verification failure whose failing paths are all provably unchanged from base and outside
this PR's diff is `baseline-red` — classified by review-remote-pr Step 2's
`$agentkit/review-remote-pr/scripts/verification-baseline.sh`, never re-derived here. It is published
evidence (`$agentkit/parallel-issues/scripts/compose-pr-body.sh --baseline-file`, every skipped check marked SKIPPED), never a passing
check: proceed through commit, push, adversarial review, and receipt — never park on it, and never reformat
unrelated paths just to force a clean run — but ready-flip and merge stay blocked as on any other red (Step 4).
Any other declared-verification failure is `change-caused-red`: fix it.
`````

- [ ] **PG-03** — replace lines 273–280 (from `Phase C uses one consolidated fix/push batch per bounded round. Canonical` through `commit with `$agentkit/review-remote-pr/scripts/review-ledger.sh cover`; never re-review — see`) with:

`````text
Phase C uses one consolidated fix/push batch per bounded round; provider-rules.md owns settlement
(replies enter `AWAITING_BOT_RESPONSE`; refresh evidence before `thread-action.sh --settle`). Human items retain
per-item confirmation; human threads stay unresolved. Record a verified fix commit with
`$agentkit/review-remote-pr/scripts/review-ledger.sh cover`; never re-review — see
`````

- [ ] **Step 4 (green):** `wc -c` = 18,222 (≤ 18,400); `tests/run-tests.sh --only pr-to-green,contract-provenance,skills-contract,recipe-safety,reference-manifest`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-skill-size.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full `tests/run-tests.sh`.

- [ ] **Step 5: Shared step** with `SCOPE=pr-to-green`, `TITLE='stop restating the authorization record and the baseline-red rule'`, `WHY='The coordinator sat 8 tokens under the default size gate while narrating the authorization JSON shape and helper behaviour that auto-merge.md, authorize-queue.sh, and review-transition.sh already own.'`, `WHAT='Authorization, baseline-red, Phase C settlement, API budget, and Hard rules keep every pinned sentence in fewer lines; the example command is unchanged and the --provider SOURCE vocabulary (capability-default / operator-instruction) keeps its prose home. 20,367 -> 18,222 bytes; byte ceiling 18,400 in test-pr-to-green.sh.'`, `ISSUE=<TC>`, `FILES=(agentkit/skills/pr-to-green/SKILL.md tests/test-pr-to-green.sh)`.

---

### Task D: `onboard-repo/SKILL.md` — OB-01…OB-04

**Files:**
- Modify: `agentkit/skills/onboard-repo/SKILL.md` (on `main` + #621: 17–25, 154–160, 176–182, 184–187, 318–320, 323–327)
- Modify: `tests/test-skill-path-resolution.sh` (byte ceiling before `finish`)
- Test: `tests/test-skills-contract.sh:186-260` (ORDER anchors 108–125 and the instruction-audit literals — all outside the edited ranges), `tests/test-recipe-safety.sh:51-66`, `tests/test-onboard-variable-drift.sh` (Reference table, untouched), `tests/test-skill-path-resolution.sh` (executes the Step 0 fence, untouched), `tests/lint-helper-refs.sh` (rooted first mentions of `bootstrap-repo.sh` (13) and `agent-run.sh` (now inside the merged stage-contract paragraph))

**Pinned literals:** `named-base affordance`; line 27 byte-identical (`$agentkit/.shared/shell-portability.md`, `` bootstrap fence through explicit `bash -c` ``, `` Once it resolves `$agentkit`, read ``); `$agentkit/.shared/scripts/bootstrap-repo.sh` (13); a `$agentkit/.shared/scripts/agent-run.sh` mention before any bare `agent-run.sh`; `Shared helpers need Bash 4+` stays (line 321 → 320 after the deletions); the whole Reference table; `--if-declared`, `Declaring neither is legitimate`, and the TEST-only substitution now live in Step 4's kept paragraph (their only prose home after the Reference cut).

- [ ] **Step 1: Worktree/branch `refactor/size-w2-onboard-repo` from `refactor/size-w1-markers` (or `origin/main` once #621 merged); `grep -c 'prepend THE CACHE REHYDRATION (defined once' agentkit/skills/onboard-repo/SKILL.md` prints 0; record `wc -c` (19,697).**

- [ ] **Step 2 (red):**

- [ ] **byte ceiling: onboard-repo SKILL.md** — replace line 314 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/onboard-repo/SKILL.md") -le 18700 ]] && printf yes || printf no)" \
    'onboard-repo SKILL.md stays at or under 18700 bytes'

finish
`````

Run `tests/run-tests.sh --only skill-path-resolution`; expect `FAIL onboard-repo SKILL.md stays at or under 18700 bytes`.

- [ ] **Step 3: The edits**

- [ ] **OB-03** — replace lines 17–25 (from `Onboarding advances only the next incomplete stage: `not onboarded`, `discovered`, `declared`, `verified`, `committed`, then `armed`. Report it before acting; re-runs are refresh/no-op and `--reset` is explicit and reported.` through `Report whether declarations are per-machine `.agent/` state in `.git/info/exclude` or trunk-carried (Step 7), then run `$agentkit/.shared/scripts/agent-run.sh --cmd <declared name>`. Undeclared commands cannot run.`) with:

`````text
Onboarding advances only the next incomplete stage: `not onboarded`, `discovered`, `declared`, `verified`, `committed`, then `armed`. Report it before acting; re-runs are refresh/no-op and `--reset` is explicit and reported. Carry any `agentkit drift advisory` into the handoff. Before `verified`, preflight and report its runtime/setup/toolchain findings; read CI before proposing commands and make CI's proven entry point canonical `TEST`. Recipes use resolved absolute helper paths; a declared command runs as `$agentkit/.shared/scripts/agent-run.sh --cmd <name>`, and undeclared commands cannot run.
`````

- [ ] **OB-01** — replace lines 154–160 (from `Protected paths are a handoff boundary, not a suggestion to disable a guard. When a base merge carries one,` through `exit `2` is unwritable git metadata and its elevation handback.`) with:

`````text
Protected paths are a handoff boundary, not a suggestion to disable a guard: a base merge carrying one uses the
commit helper's named-base affordance and reports `merge-inherited paths parked/handed off` (exit `3`; exit `2` is
unwritable git metadata). Never bypass hooks with `--no-verify`, `core.hooksPath`, aliases, or any equivalent — a refusal is one bounded named park.
`````

- [ ] **OB-04** — replace lines 176–182 (from `**Do not test a candidate by running it yourself first.** Declare it, then run it once through` through `first verification in every parallel worktree fails for an unrelated reason.`) with:

`````text
**Do not test a candidate by running it bare first** — declare it, then run it once through `agent-run.sh`
in Step 6 and fix or remove the declaration on failure. **Declare `SETUP` if a fresh checkout needs one**
(`AGENT_CMD_SETUP=<the locked, offline-capable install command>`); without it every parallel worktree's first verification fails.
`````

- [ ] **OB-02** — delete lines 318–320 (from `A named repository command runs directly, no approval step: `agent-run.sh --cmd <name>` runs the` through `exact declared value every time.`) and the blank line that follows.

- [ ] **OB-02** — delete lines 323–327 (from `**`VERIFY` and `TEST` are the only names anything relies on** — `lint`/`build`/`coverage` are reached with` through `legitimate. In a TEST-only repo, substitute the declared name in every `--cmd` example here.`) and the blank line that follows.

- [ ] **OB-02 (the three facts the Reference restatement carried, folded into Step 4)** — replace lines 184–187 (from `**`VERIFY` and `TEST` are on-demand, not turn-gated.** Declaring one makes it runnable by name` through `declares `AGENT_CMD_VERIFY=tools/verify` and moves on):`) with:

`````text
**`VERIFY` and `TEST` are on-demand, not turn-gated.** Declaring one makes it runnable by name
(`agent-run.sh --cmd verify`/`--cmd test`) — nothing blocks a turn on it. Declaring neither is legitimate —
`lint`/`build`/`coverage` are reached with `--if-declared` — and a TEST-only repo substitutes its declared
name in every `--cmd` example here. Keep `VERIFY` fast so a one-line comment doesn't pay a refactor's cost;
let `TEST` be the slow one (a single entry point just declares `AGENT_CMD_VERIFY=tools/verify` and moves on):
`````

- [ ] **Step 4 (green):** `wc -c` = 18,583; `tests/run-tests.sh --only skill-path-resolution,skills-contract,recipe-safety,onboard-variable-drift,contract-provenance`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-skill-size.sh agentkit/skills && tests/lint-skill-invocations.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=onboard-repo`, `TITLE='fold the intro and drop the restated command-run rules'`, `WHY='The onboarding skill sat 7 tokens under the default size gate with a seven-paragraph intro and a Reference section that restates the runs-directly and VERIFY/TEST rules Steps 4 and 6 already carry.'`, `WHAT='One stage-contract paragraph; protected-path, candidate, and SETUP paragraphs tightened; two Reference restatements dropped with their --if-declared / declaring-neither / TEST-only facts folded into Step 4. 19,697 -> 18,583 bytes; byte ceiling 18,700 in test-skill-path-resolution.sh.'`, `ISSUE=<TD>`, `FILES=(agentkit/skills/onboard-repo/SKILL.md tests/test-skill-path-resolution.sh)`.

---

### Task E: `parallel-issues/references/worker-prompts.md` — WP-03, WP-04, WP-08, WP-09, §5 branch-check fence

**Files:**
- Modify: `agentkit/skills/parallel-issues/references/worker-prompts.md:29-36, 112-121, 128-131, 132-138, 533-546`
- Modify: `tests/test-compose-worker-prompt.sh:105` (composed ceiling 20500 → 20000; path-dependent, see Step 1 and Task 0's `TO` follow-up) and a file byte ceiling before `finish`; `tests/test-parallel-dispatch-contract.sh:1119-1127` (the inner-fence counts become a no-inner-fence invariant)
- Test: `tests/test-compose-worker-prompt.sh`, `tests/test-compose-worker-prompt-scope.sh:297-320` (`NAMED LOG` must reach the composed prompt), `tests/test-fast-mode-contract.sh:29-63`, `tests/test-parallel-dispatch-contract.sh:590-594, 909-945, 1095-1127`, `tests/test-issue-body-boundary.sh`, `tests/test-verification-baseline.sh:299-303`

**Composer contract:** `compose-worker-prompt.sh` never references `git branch`; the fence at 128–130 is inert template text a worker might run. `__DECLARED_COMMANDS__`, `__DECLARED_FOCUS__`, `__BLOCKER_CONTRACT__`, `__COMPOSE_ISOLATION__`, `__IMAGE_INVALIDATING_WRITERS__` and the `<WHEN … trust record.>` marker lines are untouched.

**Pinned literals:** `same first pushed diff`, `one combined fix batch`, `focused verification`, `full suite`, `code-bearing fixes step effort down`, `Initial work retains the declared worker tier`, `tiny docs-only fixes`, `mechanical fix batch`, `28 full runs, 18 commits, 13 rounds, 2h42m` (lines 20–25, untouched); `gh-pr-state.sh --full`, `review-transition.sh`, `merge-pr.sh` (38–41, untouched); `trigger/command comments`, `compose-comment-body.sh`, `forbid hand-rolled shell heredocs` (43–44, untouched); `AGENT_CMD_TEST_FOCUS`, `--only NAME[,NAME...]`, `once against the final tree state` (the focus comment line, untouched); `NAMED LOG` (kept as `READ THE NAMED LOG`); `compose-pr-body.sh`; `This was written agentically; verify its assertions:`; `` Never pass a multiline PR body through inline `--body` ``; `Stacked on #`; `chain-advance.sh --retarget`; `### Diff-size disclosure`, `still gets the same draft PR a small one gets`, `is never an unattended default` (untouched); exactly one ` ````text ` and one ` ```` ` line in the file.

- [ ] **Step 1: Worktree/branch `refactor/size-w2-worker-prompts` from `origin/main`; record `wc -c` (47,320) and the composed size:**

```bash
sed -i 's/\[\[ ${#prompt} -le 20500 \]\]/[[ ${#prompt} -le 1 ]]/' tests/test-compose-worker-prompt.sh && tests/run-tests.sh --only compose-worker-prompt 2>&1 | grep -o 'measured [0-9]*' | head -1; git checkout -- tests/test-compose-worker-prompt.sh
```

Expected: `measured <N>` — **N is checkout-path-dependent** (the composed prompt embeds the absolute `$agentkit` and worktree paths several times: 20,423 at `/home/adam/github/agent-kit/.worktrees/…`, 20,603 at a 118-character root). Record the value printed at *this* worktree; the ceiling below is set at 20,000 so it clears at any path up to ~130 characters after the cut.

- [ ] **Step 2 (red):**

- [ ] **composed issue-lead prompt ceiling** — replace line 105 (from `assert_eq yes "$([[ ${#prompt} -le 20500 ]] && printf yes || printf no)" "issue-lead prompt stays at or under 20500 bytes (measured ${#prompt})"`) with:

`````text
assert_eq yes "$([[ ${#prompt} -le 20000 ]] && printf yes || printf no)" "issue-lead prompt stays at or under 20000 bytes (measured ${#prompt})"
`````

- [ ] **byte ceiling: worker-prompts reference** — replace line 1187 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/worker-prompts.md") -le 46000 ]] && printf yes || printf no)" \
    'worker-prompts reference stays at or under 46000 bytes'

finish
`````

- [ ] **inner-fence invariant** — replace lines 1119–1127 (from `# One inner bash example remains (`git branch --show-current`); the` through `    'inner bash examples retain their triple-backtick closers'`) with:

`````text
# The raw template carries no inner ```bash fence: compose-worker-prompt.sh embeds
# every recipe itself (issue #334 removed the hand-copied `cat` recipe; the size
# wave removed the standalone `git branch --show-current` example, which Branch
# Rules step 2 already states), so a worker prompt never documents a command for
# the worker to run by hand.
assert_eq '0' "$inner_open_count" \
    'the issue-lead template carries no inner triple-backtick bash fence'
assert_eq '0' "$inner_close_count" \
    'the issue-lead template carries no inner triple-backtick closer'
`````

Run `tests/run-tests.sh --only compose-worker-prompt,parallel-dispatch-contract`; expect four FAILs: `issue-lead prompt stays at or under 20000 bytes (measured <N>)`, `worker-prompts reference stays at or under 46000 bytes`, and the two `carries no inner triple-backtick` assertions.

- [ ] **Step 3: The edits**

- [ ] **WP-09** — replace lines 29–36 (from `The `AGENT_ADVERSARIAL_REVIEWER`, `AGENT_ADVERSARIAL_REVIEWER_FALLBACK`,` through `commit helper enforces this boundary, including for `--include-staged`.`) with:

`````text
The `AGENT_ADVERSARIAL_*` keys in `.agent/config.env` are base-trusted (read from `origin/<base>`; see
adversarial-review.md "Base-trusted configuration"); a worker never stages `.agent/config.env` unless the
issue's declared write set names it — the commit helper enforces this, including for `--include-staged`.
`````

- [ ] **WP-03** — replace lines 112–121 (from `When a declared verification command fails, the worker may retry that same command with` through `green verification result or cache entry. Missing or changed evidence stays an ordinary failure.`) with:

`````text
When a declared verification command fails, the worker may retry it with
`--baseline-ref <chain-base> --baseline-path <failing-test-file> --baseline-id <test-id>`: `agent-run.sh`
re-runs it from the chain base in an isolated checkout and, only when command identity and failure evidence
match, exits 0 as `BASELINE-EXCLUDED` and writes `.agent/baseline-exclusion.md` — unchecked publication
evidence, never a green result or cache entry.
`````

- [ ] **section 5 (the standalone `git branch --show-current` fence; Branch Rules step 2 already carries the check)** — delete lines 128–131 (from ````bash` through `````) and the blank line that follows.

- [ ] **WP-04** — replace lines 132–138 (from `agent-run.sh sets the run's caches and CA bundle, prepends the detected source roots to` through `A usage error prints "agent-run: error: …" on stderr and no PASS/FAIL line at all.`) with:

`````text
agent-run.sh supplies the run's caches, CA bundle, source roots, and repo runner and suppresses output:
success is one PASS line; failure prints the matched error lines plus the log path under
<worktree>/.agent/logs/ — on failure READ THE NAMED LOG; never re-run for verbosity or repair the
environment. Its exit status IS the wrapped command's. Pass `--` before the command (always is simplest).
`````

- [ ] **WP-08** — replace lines 533–546 (from `After a worker's completion report lands and the root's post-push review of `base...HEAD`` through `the byte-verifying transport.`) with:

`````text
After a worker's completion report lands and the root's post-push review of `base...HEAD` clears it
(SKILL.md's "Root review and draft PR after a worker push"), the root opens the DRAFT PR with this recipe.
`compose-pr-body.sh` composes the body from four root-approved section files in the fixed order — agentic
disclosure, `Why`, `What`, `Decisions`, checkbox-formatted `Testing`, a signature line, and a separate
closing-keyword line — normalizing plain `- item` Testing bullets to `- [ ] item`.
Every composed body starts with the literal line `This was written agentically; verify its assertions:`.
Never pass a multiline PR body through inline `--body`; the composer writes a private file for
the byte-verifying transport.
`````

- [ ] **Step 4 (green):** `wc -c` = 45,826; the composed prompt is ~775 bytes smaller than Step 1's value (19,648 at the reference path; the ceiling assertion prints it); `tests/run-tests.sh --only compose-worker-prompt,compose-worker-prompt-scope,parallel-dispatch-contract,fast-mode-contract,issue-body-boundary,verification-baseline,spec-command-precedence`; `tests/lint-markdown-blocks.sh agentkit/skills && tests/lint-helper-refs.sh agentkit/skills && tests/lint-skill-invocations.sh agentkit/skills` (73 fences checked: one fewer than before); full suite.

- [ ] **Step 5: Shared step** with `SCOPE=worker-prompts`, `TITLE='trim baseline/agent-run prose and the standalone branch-check fence'`, `WHY='Two paragraphs pasted into every issue-lead prompt narrated agent-run.sh output the helper prints itself, and a bare git branch fence invited a worker tool turn for a check Branch Rules step 2 already states.'`, `WHAT='Baseline-exclusion and agent-run paragraphs tightened (NAMED LOG kept); branch-check fence removed and the fence-count test made a no-inner-fence invariant; base-trusted config points at adversarial-review.md; draft-PR body prose says never-inline once. 47,320 -> 45,826 bytes; composed issue-lead prompt -775 bytes (path-dependent absolute size; ceiling 20,000, path-neutral follow-up filed).'`, `ISSUE=<TE>`, `FILES=(agentkit/skills/parallel-issues/references/worker-prompts.md tests/test-compose-worker-prompt.sh tests/test-parallel-dispatch-contract.sh)`.

---

### Task F: `parallel-issues/references/triage-and-selection.md` — TS-01, TS-02, TS-03, TS-04, TS-05, TS-07, TS-08

**Files:**
- Modify: `agentkit/skills/parallel-issues/references/triage-and-selection.md:18-28, 40-47, 66-69, 79-82, 89-94, 97-101, 111-114, 128-134, 182-187, 212-217, 226-229, 264-269, 337-366, 425-451, 458-469, 489-496`
- Modify: `tests/test-fast-mode-contract.sh` (byte ceiling before `finish`)
- Test: `tests/test-parallel-dispatch-contract.sh:191-222, 288-309, 392-415, 1290-1293, 1360-1364`, `tests/test-fast-mode-contract.sh:96-164`, `tests/test-autonomy-flags.sh:113-168`, `tests/test-spec-command-precedence.sh:352-354`, `tests/lint-markdown-blocks.sh` (the bulk fence 53–126 still shellchecks)

**Executed-code invariant:** the bulk-mutation fence keeps every non-comment line byte-identical — `awk '/^```bash$/{f=1;next} /^```$/{f=0} f && !/^[[:space:]]*#/' agentkit/skills/parallel-issues/references/triage-and-selection.md | md5sum` prints the same digest before and after (record it in Step 1). Only comment stanzas inside it change.

**Pinned literals:** `if grep -Eq`; `mutation_json=$(perform_rest_mutation "$planning_id") || mutation_rc=$?`; `if [[ -z $mutation_json ]]; then`; `report_batch_failure "mutation failed for $planning_id"`; `if ! "$apply_ledger" record --ledger "$ledger"`; `--number "$created_number" --url "$created_url"` before `closing-issue verification did not pass`; `--json`; `applied/remaining`; the section `## Bulk mutation discipline: …` … `## Prior-art adjudication`; lines 136–152 (REST routing rule, the home Task A points at) untouched; `classified `tracker``; `chain-depth overflow enters this same queue` (flat); `.agent/runs/active-workers.ndjson`; `state=terminal`; `named-active-state.sh`; `held-active:#`, `reason=pr`, `reason=worktree`, `reason=heartbeat`, `stale-active=1[#`; `predictedWriteSet`; `workerEffort`; `effortReason`; `"uncoveredVerification"`; `same owner-only file`; `"independent"`; `chainBaseSha`; `headSha`; `"chains"`; `"schemaVersion": 2`; `spec-verification= issue=N steps=K covered=C uncovered=U`; `shared root files`; `conflictMap.revisions`; `chain-conversion`; `merge-down`; `inherited #137`; every Selection-funnel line 657–704 and the Step 2b prose (untouched).

- [ ] **Step 1: Worktree/branch `refactor/size-w2-triage-and-selection` from `origin/main`; record `wc -c` (43,225) and the non-comment fence md5.**

- [ ] **Step 2 (red):**

- [ ] **byte ceiling: triage-and-selection reference** — replace line 167 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/triage-and-selection.md") -le 37700 ]] && printf yes || printf no)" \
    'triage-and-selection reference stays at or under 37700 bytes'

finish
`````

Run `tests/run-tests.sh --only fast-mode-contract`; expect `FAIL triage-and-selection reference stays at or under 37700 bytes`.

- [ ] **Step 3: The edits**

- [ ] **TS-01** — replace lines 18–28 (from `Any batch that creates or edits more than one forge object carries a resumable` through `shared ledger helper itself is deliberately a ledger, not an orchestrator:`) with:

`````text
Any batch that creates or edits more than one forge object carries a resumable apply ledger: the
planning ID is the stable key, and every successful mutation is followed immediately by one `record` call
with the returned number and URL. The ledger and plan live in the private run directory `run-dir.sh
--run-id "$RUN_ID"` addresses (never a bare repository-relative path):
`````

- [ ] **TS-01** — replace lines 40–47 (from ``record`'s `--number` is always the mutation's subject issue/PR number, not` through `fragment GitHub's response actually returns.`) with:

`````text
`record`'s `--number` is the mutation's subject issue/PR number (the created number, or the existing
number a comment/close/reopen/board move acted on); `--url` embeds that same number — `.../issues/N` or
`.../pull/N`, plus the `#issuecomment-<id>` fragment for a created comment.
`````

- [ ] **TS-01 (in-fence comment)** — replace lines 66–69 (from `    # Budget FIRST, before any mutation: checking after the chunk lets an` through `    # "absent, carry on" is how an exhausted budget reads as unlimited.`) with:

`````text
    # Budget FIRST: an unreadable or exhausted artifact fails closed before any mutation.
`````

- [ ] **TS-01 (in-fence comment)** — replace lines 79–82 (from `    # Status-checked, NOT a process substitution: `mapfile < <(cmd)` discards` through `    # with unapplied IDs and no ledger report.`) with:

`````text
    # Status-checked, not a process substitution: a failed pending lookup must never read as "batch complete".
`````

- [ ] **TS-01 (in-fence comment)** — replace lines 89–94 (from `        # perform_rest_mutation is a `gh-body pr|issue create --body-file ...` through `        # parsing of its human-readable text lines.`) with:

`````text
        # perform_rest_mutation is a `gh-body pr|issue create --body-file ... --json` call; read its one JSON object verbatim.
`````

- [ ] **TS-01 (in-fence comment)** — replace lines 97–101 (from `        # A non-empty JSON object is meaningful even when the call above` through `        # result means the mutation never produced a usable object at all.`) with:

`````text
        # A non-empty object is meaningful even on nonzero exit (only the closing-issue verification failed).
`````

- [ ] **TS-01 (in-fence comment)** — replace lines 111–114 (from `        # Record-before-verify: the object already exists on the forge, so it` through `        # was an unconfirmed closing-issue reference.`) with:

`````text
        # Record-before-verify: the object already exists on the forge.
`````

- [ ] **TS-01** — replace lines 128–134 (from `Between chunks, explicitly inspect the current `.resources.graphql` budget` through `dependent batch.`) with:

`````text
On exhaustion, retain the ledger and report its `applied`/`remaining` split; never retry an empty pending
pool or claim unrecorded mutations succeeded. A rerun starts from the same ledger (zero duplicates); its
`idMap` feeds a dependent batch.
`````

- [ ] **TS-08** — replace lines 182–187 (from `Step 3's body read for conflict analysis is also the cheapest place to catch a mismatch` through `worktree is the expensive way to find out (see #444).`) with:

`````text
Step 3's body read is also where a mismatch between the ask and this skill's one shape (worktree → branch →
commit → draft PR) is cheapest to catch: a body that forbids branches, worktrees, commits, or pull requests, or
states a research-only ask, is a different shape of work (#444).
`````

- [ ] **TS-08** — replace lines 212–217 (from `The `no-code` disposition is HOLD, not an alternate dispatch path: this skill defines` through `conflict above.`) with:

`````text
The `no-code` disposition is HOLD, not an alternate dispatch path: this skill defines exactly one end-to-end
shape (worktree → branch → commit → draft PR), and improvising a no-PR variant per run is the failure this
axis exists to stop.
`````

- [ ] **TS-08** — replace lines 226–229 (from `The classifier is deliberately crude, the same posture as the ADR token-matching above:` through `Genuine ambiguity is a Step 3 conflict-analysis judgment call like any other.`) with:

`````text
The classifier is deliberately crude: a miss (`implementation`) is never proof the issue is safe, and a hit
is a signal to read and confirm; genuine ambiguity is a Step 3 judgment call.
`````

- [ ] **TS-07** — replace lines 264–269 (from `The latest valid row for an issue wins. Root appends `state=active` immediately after the worker is` through `group/world-writable ledger is blocked evidence, never permission to dispatch.`) with:

`````text
The latest valid row wins. Only root writes it (parent `0700`, ledger `0600`): `state=active` at spawn, another active row with a fresh
`heartbeatEpoch` on reported progress, and `state=terminal` on completion, interruption, or park.
`named-active-state.sh` enforces the `0600`/owner/non-symlink requirements; a malformed ledger is blocked
evidence, never permission to dispatch.
`````

- [ ] **TS-02** — replace lines 337–366 (from `The dispatch-time artifact stays at schema version 1 while PR numbers and` through `queue consumer, in one round trip instead of one violation per retry.`) with:

`````text
The dispatch-time artifact stays at schema version 1 while PR numbers and pushed heads do not exist.
Immediately after atomically persisting it, run
`"$agentkit/parallel-issues/scripts/write-merge-plan.sh" --dispatch-plan "$dispatch_plan" --chain-base "${chain_base_sha:-$repository_root}" --validate-only`;
the dispatch must not begin unless the helper prints `schemaVersion=1 valid`. The validator resolves
every glob against the chain-base tree (a glob matching nothing fails closed and names the nearest
sibling) and derives each project test root from that tree's declared `AGENT_RUNDIR_*_TEST*`/
`AGENT_CMD_*_TEST*` commands — declaration-driven only, never from a directory merely named `test`. Each
proposed root must be inside `predictedWriteSet` or listed in `testRootExclusions` (per entry, or once at
the top level for the whole plan). One invocation reports every violation with a copy-pasteable `jq`
patch; `--fix` applies them.
`````

- [ ] **TS-03** — replace lines 425–451 (from `The helper validates that every selected issue appears exactly once, upgrades` through ``independent` uses the same record shape, with null `chainBaseSha`. Each`) with:

`````text
The helper validates that every selected issue appears exactly once, upgrades the dispatch plan atomically,
preserves `entries` and `conflictMap`, and on a rejected input names the first failing field. The resulting
schema-2 shape adds `generatedAt`, `independent`, and `chains` (same record shape) beside the preserved fields:

```json
{"schemaVersion": 2, "generatedAt": "...", "entries": [...], "conflictMap": {...}, "independent": [], "chains": [[...]]}
```

Each
`````

- [ ] **TS-04** — replace lines 458–469 (from ``uncoveredVerification` records the verification steps this issue's spec` through `accept the gap in writing, not a reason to hold the dispatch.`) with:

`````text
`uncoveredVerification` records the spec's verification steps no declared command covers, as
`compose-worker-prompt.sh` reports them before spawn
(`spec-verification= issue=N steps=K covered=C uncovered=U uncovered-steps=…`, 1-based indices inside the composed
`## Spec` block); omit the key at `uncovered=0`. It is a disclosure, never a gate — the matching is approximate.
`````

- [ ] **TS-05** — replace lines 489–496 (from `The same declared list (`AGENT_GENERATED_PATHS` in `.agent/config.env`) also` through ``AGENT_GENERATED_PATHS` reference entry.`) with:

`````text
`AGENT_GENERATED_PATHS` (declared once in `.agent/config.env`) feeds both this write-set check and
`gh-pr-state.sh`'s staleness exemption (a base advance confined to those paths reports `stale=no`).
`````

- [ ] **Step 4 (green):** `wc -c` = 37,574; the non-comment fence md5 unchanged; `tests/run-tests.sh --only fast-mode-contract,parallel-dispatch-contract,autonomy-flags,spec-command-precedence,work-shape`; `tests/lint-markdown-blocks.sh agentkit/skills && tests/lint-helper-refs.sh agentkit/skills && tests/lint-skill-invocations.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=triage-and-selection`, `TITLE='trim bulk-ledger commentary, validator narration, and the schema-2 duplicate'`, `WHY='A 43 KB reference read by section on every dispatch carried comment essays inside an executed fence and prose that restates what write-merge-plan.sh, compose-worker-prompt.sh, and named-active-state.sh print or enforce.'`, `WHAT='In-fence comment stanzas become one line each (executed code byte-identical, md5 in the PR); ledger, record-shape, exhaustion, work-shape, active-worker, validator, schema-2, uncoveredVerification, and generated-paths prose keep every pinned sentence (the active-worker ledger keeps its 0700/0600 creation modes). 43,225 -> 37,574 bytes; byte ceiling 37,700.'`, `ISSUE=<TF>`, `FILES=(agentkit/skills/parallel-issues/references/triage-and-selection.md tests/test-fast-mode-contract.sh)`.

---

### Task G: `parallel-issues/references/chains.md` (CH-02) and `references/trust-and-fencing.md` (TF-01)

**Files:**
- Modify: `agentkit/skills/parallel-issues/references/chains.md:228-241`, `agentkit/skills/parallel-issues/references/trust-and-fencing.md:3-11`
- Modify: `tests/test-chain-advance.sh:1360` (chains ceiling 18000 → 17000) plus a trust-and-fencing ceiling before `finish`
- Test: `tests/test-parallel-dispatch-contract.sh:161-188`, `tests/test-reference-manifest.sh:222-237` (chains `## Contents`, `## Post-squash-merge conflicts` and its literals — untouched), `tests/test-chain-advance.sh`

**Pinned literals:** `pushed commit` (still at 40/71/103/247 after the cut); `Publishing a locally-built chain base`; every join-recipe literal in 19–61 and the merge-order/post-squash sections (untouched); the heading `## Verification cache and suite cadence` in trust-and-fencing.md (SKILL.md links its anchor); `## Never send a post-push instruction that reads as a rewrite` heading stays.

- [ ] **Step 1: Worktree/branch `refactor/size-w2-chains` from `origin/main`; record `wc -c` (17,699 and 2,999).**

- [ ] **Step 2 (red):**

- [ ] **chains ceiling lowered** — replace line 1360 (from `assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/chains.md") -le 18000 ]] && printf yes || printf no)" 'chains reference stays at or under 18000 bytes'`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/chains.md") -le 17000 ]] && printf yes || printf no)" 'chains reference stays at or under 17000 bytes'
`````

- [ ] **byte ceiling: trust-and-fencing reference** — replace line 1362 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/trust-and-fencing.md") -le 2600 ]] && printf yes || printf no)" \
    'trust-and-fencing reference stays at or under 2600 bytes'

finish
`````

Run `tests/run-tests.sh --only chain-advance`; expect `FAIL chains reference stays at or under 17000 bytes` and `FAIL trust-and-fencing reference stays at or under 2600 bytes`.

- [ ] **Step 3: The edits**

- [ ] **CH-02** — replace lines 228–241 (from `A dispatched worker's history is frozen the moment its first push lands — `worker-prompts.md`'s` through `description of what the existing one should have said.`) with:

`````text
A dispatched worker's history is frozen at its first push (`worker-prompts.md`'s "History freeze" states it in
the worker's voice). The root's reciprocal half: once a worker has pushed, never send it — or leave in its inbox
— anything readable as "amend," "reset," "rebase," or "force-push", however small the defect; a rewrite strands
any successor already started from that SHA. Word every post-push correction as a request for a new commit.
`````

- [ ] **TF-01** — replace lines 3–11 (from `Command-approval fence removed 2026-08-19: `agent-run.sh` no longer gates a declared command` through ``SKILL.md` keeps the pinned rule sentences; this file carries the rationale behind them.`) with:

`````text
Read this when deciding how often to re-run verification during red/green iteration; `SKILL.md` keeps
the pinned rule sentences. (The command-approval fence was removed 2026-08-19: `agent-run.sh --cmd NAME`
runs a declared command directly, with no approval or trust record.)
`````

- [ ] **Step 4 (green):** `wc -c` = 16,871 and 2,570; `tests/run-tests.sh --only chain-advance,parallel-dispatch-contract,reference-manifest,skills-contract`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=chains`, `TITLE='compress the post-push rewrite essay and the trust-and-fencing changelog'`, `WHY='chains.md spent 14 lines restating the worker-side history-freeze rule with a 2026-08-21 incident narrative, and trust-and-fencing.md opened with a changelog about a fence that no longer exists.'`, `WHAT='The root-side rule in 4 lines; the changelog becomes one parenthetical under the read-when sentence. 17,699 -> 16,871 and 2,999 -> 2,570 bytes; ceilings 17,000 / 2,600 in test-chain-advance.sh.'`, `ISSUE=<TG>`, `FILES=(agentkit/skills/parallel-issues/references/chains.md agentkit/skills/parallel-issues/references/trust-and-fencing.md tests/test-chain-advance.sh)`.

---

### Task H: `.shared/spawn-contract.md` — SC-03, SC-04

**Files:**
- Modify: `agentkit/skills/.shared/spawn-contract.md:215-225, 310-339`
- Modify: `tests/test-skills-contract.sh:133-134` (spawn-contract ceiling 20000 → 18100)
- Test: `tests/test-skills-contract.sh:101-182`, `tests/test-parallel-dispatch-contract.sh:1586-1606`, `tests/test-spawn-contract-roster.sh` (executes the fence at 25–177, untouched)

**Pinned literals (all outside or preserved inside the two ranges):** `set `selected_worker_model` to `worker_model`` (202); `model: "$selected_worker_model"`, `reasoning_effort: "$worker_effort"` (242–243); `spawn unavailable` (kept on one line in SC-03's bullet and in Tier mapping); `two allowed implementation exceptions` (one line); `qualifying bounded inline correction`; `claude-sonnet-5`; `gpt-5.6-terra` (26/81/91/170); `recorded reason` (269); `## Bounded inline corrections` and its seven literals (290–306, untouched); `### Harness-aware pivot` and its flat pins (187–196, untouched); `multi_agent_v1__spawn_agent(` (the canonical-rationale phrase must stay unique to this file — it does).

- [ ] **Step 1: Worktree/branch `refactor/size-w2-spawn-contract` from `origin/main`; record `wc -c` (19,709) and `awk '/^```bash$/{f=1;next} /^```$/{f=0} f' agentkit/skills/.shared/spawn-contract.md | md5sum` (the executed fence, must not change).**

- [ ] **Step 2 (red):**

- [ ] **spawn-contract ceiling lowered** — replace lines 133–134 (from `assert_eq yes "$([[ $spawn_contract_bytes -le 20000 ]] && printf yes || printf no)" \` through `    "spawn contract stays at or under 20000 bytes (measured $spawn_contract_bytes)"`) with:

`````text
assert_eq yes "$([[ $spawn_contract_bytes -le 18100 ]] && printf yes || printf no)" \
    "spawn contract stays at or under 18100 bytes (measured $spawn_contract_bytes)"
`````

Run `tests/run-tests.sh --only skills-contract`; expect `FAIL spawn contract stays at or under 18100 bytes (measured 19709)`.

- [ ] **Step 3: The edits**

- [ ] **SC-03** — replace lines 215–225 (from `- Select the resolved preferred model when advertised; otherwise select the resolved fallback` through `  actually selected.`) with:

`````text
- If neither resolved model is advertised, **STOP before creating worktrees, moving Project items, or
  editing code** and report the capability block. The spawn request is the model-and-effort evidence:
  the completion table carries the actual `worker model` and `worker effort` (or `worker=self (spawn unavailable)`)
  plus `selected_worker_pivot_note` when non-empty, so a tier claim is never inferred from prompt text.
`````

- [ ] **SC-04** — replace lines 310–339 (from `Root = trust/judgment and every privileged or forge-facing action. Luna = mechanical` through `multi-candidate, never the emitted fact.`) with:

`````text
Root = trust/judgment and every privileged or forge-facing action. Luna = mechanical execution, the
default worker tier; Terra `high` is its automatic fallback — a Luna-unavailable worker is still a dispatched
worker. Terra `xhigh` is reserved for the blind same-harness adversarial-review fallback. A single clean unit
of work may skip the dispatched **lead** (the orchestration tier), never the **implementation worker**: any
code change goes through one dispatched sole writer, except the two allowed implementation exceptions: a genuinely spawn unavailable path
(labelled `worker=self` with the reason) or a qualifying bounded inline correction.

On Claude the same split maps to `claude-opus-5` (root judgment and the cross-harness reviewer) and
`claude-sonnet-5` (the dispatched worker) — see "Harness-aware pivot" for how a declaration resolves on
the running harness. OpenCode has no fixed pair: the worker tier is the repository-declared
`provider/model-id`, and its adversarial review always runs cross-harness against the peer CLI
`peer-cli=` names (`harness-id.sh` probes `codex,claude` in order and emits one `peer-cli= <name> present|absent` line).
`````

- [ ] **Step 4 (green):** `wc -c` = 17,943; fence md5 unchanged; `tests/run-tests.sh --only skills-contract,parallel-dispatch-contract,spawn-contract-roster`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=spawn-contract`, `TITLE='dedupe the capability bullets and the tier-mapping essay'`, `WHY='Both dispatching skills read this file in full; two capability bullets restated the two above them, and Tier mapping narrated harness-id.sh behaviour over 30 lines.'`, `WHAT='One bullet for the STOP/evidence rule; Tier mapping and peer-cli mapping in 12 lines with every pinned phrase; executed fence byte-identical. 19,709 -> 17,943 bytes; ceiling 18,100.'`, `ISSUE=<TH>`, `FILES=(agentkit/skills/.shared/spawn-contract.md tests/test-skills-contract.sh)`.

---

### Task I: `review-remote-pr/references/adversarial-review.md` — AR-01…AR-06

**Files:**
- Modify: `agentkit/skills/review-remote-pr/references/adversarial-review.md:13, 81-91, 119-135, 136-156, 174-192, 275-308, 364-370`
- Modify: `tests/test-review-artifacts.sh` (byte ceiling before `finish`)
- Test: `tests/test-review-artifacts.sh:533-586`, `tests/test-cross-provider-consent.sh:24-54`, `tests/test-autonomy-flags.sh:88-97, 175-183`, `tests/test-adversarial-review-bounds.sh:286-288`, `tests/test-probe-contract.sh:123-129`, `tests/lint-helper-refs.sh` (`../../pr-to-green/references/auto-merge.md#…` at 362 resolves)

**Pinned literals:** `Make the grant legible to harness approval layers`; `answerable from the command itself`; `Consent is context-local`; `root-owned reviewer launch`; `consent given in advance`; `do not stop to ask`; `Still disclose`; `source=auto-review-flag`; `It cannot consent on behalf of whoever owns`; `Still fails closed`; `only the current invocation line`; `cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted` (one line; also at 161); `provider, PR, or diff changes` (one line); `Do not send the diff`; `consent-record.sh`; `| `codex` | `openai` |`, `| `claude` | `anthropic` |`, `A refused check names both the expected provider token` (224–239, untouched); `Materiality — run vs. document a skip`; `External-service authorization`; `Cross-provider consent — first send per session`; `The maintainer must verify each finding against the current tree`; `does not authorize an edit`; `Repository ownership`; `is not consent to disclose`; `first cross-provider send in a session`; `destination provider`; `adversarial-run.sh --pr N --repo OWNER/REPO --run-dir DIR`; `It owns consent enforcement, diff capture, provider selection, schema validation`; `A provider failure, missing provider, or unparseable verdict is blocked`; `scripts/review-liveness.sh --run-dir "$RUN_DIR" --transcript "$transcript" --verdict "$verdict_path"`; `reports exactly Completed, Still running, or Blocked`; `exits 0, 1, or 2 for those states`; `--max-duration-seconds`; `--max-tokens 400000`; `--mode probe --no-payload`; `only a synthetic snippet`; `no PR diff`; `never count against the one-review-per-PR budget`; `A missing or unparseable verdict is blocked, never clean`; `` .verdict.verdict` is the verdict string and `.verdict.findings` is the findings array ``; `Evaluate — then route into Step 5`; `post-receipt.sh publish`; and never `git --no-pager diff`, `probe_rc=`, `review_rc=`, `No parseable verdict is blocked`, `Both the root and dispatched agents hold the grant`.

- [ ] **Step 1: Worktree/branch `refactor/size-w2-adversarial-review` from `origin/main`; record `wc -c` (25,007).**

- [ ] **Step 2 (red):**

- [ ] **byte ceiling: adversarial-review reference** — replace line 588 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/review-remote-pr/references/adversarial-review.md") -le 19600 ]] && printf yes || printf no)" \
    'adversarial-review reference stays at or under 19600 bytes'

finish
`````

Run `tests/run-tests.sh --only review-artifacts`; expect `FAIL adversarial-review reference stays at or under 19600 bytes`.

- [ ] **Step 3: The edits**

- [ ] **AR-05 (Contents entry)** — delete line 13 (from `- Pitfalls`).

- [ ] **AR-06** — replace lines 81–91 (from `Recommended disclosure wording is explicit about payload, destination, and count: "sending each` through `answer has not been careful, it has just stalled.`) with:

`````text
`--auto-review` (alias `--auto-approve`) on the invocation line answers the question above for this
invocation before it is asked — consent given in advance, in the user's own words, so **do not stop to ask** (an unattended
run that halts on a question nobody is present to answer has just stalled). Record the exact
payload/destination/count ("each PR diff (filenames and code) to <resolved reviewer CLI/provider>, one
review for this PR") before using the flag; it is not consent for other data or a second attempt.
`````

- [ ] **AR-01** — replace lines 119–135 (from `  `adversarial-run.sh` takes the value as one argv element — never eval'd, never re-parsed — so` through `  still occurs is surfaced to the user as a direct question, never routed around.`) with:

`````text
  `adversarial-run.sh` takes the value as one argv element — never eval'd, never re-parsed — so
  "is this send authorized?" is answerable from the command itself; it also echoes it to stderr as
  `provenance:` and writes `$RUN_DIR/state/provenance` (mode 600) before any external call. Never write
  the provenance as a `#` comment (in a single-line cell it swallows the launcher into a silent exit-0
  no-op) or splice the verbatim quote into shell source. A denial that still occurs is surfaced to the
  user as a direct question, never routed around.
`````

- [ ] **AR-02** — replace lines 136–156 (from `- **A pre-send marker makes a no-op provably distinguishable from a lost receipt, and the` through `  touches neither the marker nor the result file — the concurrent holder owns both.`) with:

`````text
- **A pre-send marker and a per-RUN_DIR lock are enforced by the launcher itself.**
  `adversarial-run.sh` writes `$RUN_DIR/state/launch-attempted` immediately before the external call:
  absent marker → nothing was sent and an automatic retry is safe; marker present without a
  `completed`/`blocked` result → the send may have happened, and the launcher refuses to relaunch into that
  RUN_DIR (publishing a `blocked` result naming the ambiguous prior attempt) until a fresh `--run-dir` or
  explicit operator review. It also holds an exclusive lock on `$RUN_DIR/state/.launch.lock` for its whole
  run, so a concurrent second invocation refuses instead of racing a second disclosure.
`````

- [ ] **AR-03** — replace lines 174–192 (from `Before sending, derive a payload identity from the repository slug, the PR number, and the` through `it ever calls this helper.`) with:

`````text
Before sending, `consent-record.sh payload` derives a payload identity from the repository slug, the PR
number, and the SHA-256 of the exact diff bytes (an empty diff is refused). After confirmation, record
`cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted` in the active session
task state; reuse it only for a retry of the exact same payload to the same provider and scope. If the destination provider, PR, or diff changes, obtain confirmation again. If confirmation is missing,
declined, or cannot be recorded, **Do not send the diff**; report the gate as blocked and wait for user
direction. Every launcher re-derives the payload from its own arguments and refuses to start without a
successful `check` against that record; a missing, malformed, mismatched, or symlinked record fails closed.
`````

- [ ] **AR-04** — replace lines 275–308 (from ``AGENT_ADVERSARIAL_REVIEWER` and `AGENT_ADVERSARIAL_REVIEWER_FALLBACK` also accept a` through `been declared.`) with:

`````text
`AGENT_ADVERSARIAL_REVIEWER` and `AGENT_ADVERSARIAL_REVIEWER_FALLBACK` also accept a
`<model-id>-<effort>` compound (e.g. `gpt-5.6-sol-xhigh`), forming a pool of at most two candidates, one
per harness family. Resolution self-detects the running harness from the contract's `harness= name=` line
and prefers the candidate that is **not** the running harness; a well-formed roster entry is sanctioned by
declaration. When both candidates are the running harness's family, or the cross-harness candidate's CLI is
the absent peer, resolution falls back to the running harness's own candidate (or that CLI's built-in
default) — the same blind same-harness fallback. `AGENT_ADVERSARIAL_REVIEW_MODEL`/`_FALLBACK` apply only
with a declared bare-CLI reviewer; `AGENT_ADVERSARIAL_REVIEW_EFFORT` (`low`, `medium`, `high`, `xhigh`, `max`; no `ultra`) applies in
every case. Declaring the absent peer does not silently revert to the default: the runner warns naming the
substitution and falls back to the running harness's CLI. An invalid declaration is dropped by
`repo-config.sh` with a warning and the peer-CLI default applies; declaring a reviewer never bypasses the
consent record or the provider-token mapping above.
`````

- [ ] **AR-05** — delete lines 364–370 (from `## Pitfalls` through `| Auto-applying adversarial findings | Evaluate first — verify each finding against the actual code, downgrade overstated severities, and drop false positives. Confirmed findings go through Step 5; document outcomes. |`).

- [ ] **Step 4 (green):** `wc -c` = 19,405; `tests/run-tests.sh --only review-artifacts,cross-provider-consent,autonomy-flags,adversarial-review-bounds,probe-contract,skills-contract,parallel-dispatch-contract`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills && tests/lint-skill-size.sh agentkit/skills` (the file keeps `## Contents` within the first 30 lines); full suite.

- [ ] **Step 5: Shared step** with `SCOPE=adversarial-review`, `TITLE='replace provenance/marker/lock/roster essays with the enforced rule'`, `WHY='The Step 1b read carried the history of the #-comment idiom, the launch-marker and lock internals, the payload derivation, and a 34-line roster essay — all behaviour adversarial-run.sh, consent-record.sh, and repo-config.sh enforce and name in their own output — plus a Pitfalls table that restates lines 18-33.'`, `WHAT='Each becomes the rule and the helper that enforces it; Pitfalls dropped from the body and the Contents list; every pinned sentence kept. 25,007 -> 19,405 bytes; byte ceiling 19,600 in test-review-artifacts.sh.'`, `ISSUE=<TI>`, `FILES=(agentkit/skills/review-remote-pr/references/adversarial-review.md tests/test-review-artifacts.sh)`.

---

### Task J: `review-remote-pr/references/provider-rules.md` — PV-04, PV-05, PV-06

**Files:**
- Modify: `agentkit/skills/review-remote-pr/references/provider-rules.md:59-61, 64-66, 279-285, 367-372`
- Modify: `tests/test-review-author-classification.sh:58` (ceiling 32000 → 30600)
- Test: `tests/test-parallel-dispatch-contract.sh:596-598` (`if ! "$agentkit/review-remote-pr/scripts/code-quality-state.sh"` and `Code Quality findings unavailable` inside the probe block — the block's executable lines are untouched), `tests/test-recipe-safety.sh:77`, `tests/lint-helper-refs.sh` (`scripts/classify-issue-comment-findings.sh`, `$agentkit/.shared/shell-portability.md` on the Pitfalls intro line)

- [ ] **Step 1: Worktree/branch `refactor/size-w2-provider-rules` from `origin/main`; record `wc -c` (31,610).**

- [ ] **Step 2 (red):**

- [ ] **provider-rules ceiling lowered** — replace line 58 (from `assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/review-remote-pr/references/provider-rules.md") -le 32000 ]] && printf yes || printf no)" 'provider-rules reference stays at or under 32000 bytes'`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/review-remote-pr/references/provider-rules.md") -le 30600 ]] && printf yes || printf no)" 'provider-rules reference stays at or under 30600 bytes'
`````

Run `tests/run-tests.sh --only review-author-classification`; expect `FAIL provider-rules reference stays at or under 30600 bytes`.

- [ ] **Step 3: The edits**

- [ ] **PV-04** — replace lines 59–61 (from `GitHub's public Code Quality REST API currently exposes finding retrieval, not a supported per-finding dismissal mutation. Use `gh` to inspect and reply, but do not invent an endpoint.` through `A repository with GitHub Code Quality disabled 403s the findings endpoint every single time (issue #403: `AGENT_REVIEW_PROVIDERS=github-code-quality` used to be accepted at plan time regardless, and this step then died mid-gate). Probe reachability ONCE before fetching findings: a confirmed `state=not-enabled` is a stable repository fact, so skip with no findings to work rather than blocking. Any other probe outcome (a network failure, an auth/scope 403, a 5xx) is NOT proof of disablement and stays blocked, same as before:`) with:

`````text
GitHub's public Code Quality REST API exposes finding retrieval only; do not invent a dismissal endpoint. A
repository with Code Quality disabled 403s the findings endpoint every time (issue #403), so probe reachability
ONCE: a confirmed `state=not-enabled` skips with no findings to work; any other outcome (network failure, auth/scope 403, 5xx) stays blocked:
`````

- [ ] **PV-04 (in-fence comment)** — delete lines 64–66 (from `# Probe ONCE, then inspect Code Quality findings available through the` through `# reachable.`).

- [ ] **PV-05** — replace lines 279–285 (from ``fingerprint` (review finding F4) is a sha256 digest of the finding's own kind/priority/header,` through `answered state.`) with:

`````text
`fingerprint` (a sha256 of the finding's kind/priority/header) is carried straight from `list`'s output into
`mark-answered`; a finding reads `answered` only when both `id` and `fingerprint` match, so an edited
comment reads open again rather than inheriting stale answered state.
`````

- [ ] **PV-06** — replace lines 367–372 (from `The cycle ends with its **single batched push**. Post **no** review command in any phase —` through `post them before the cycle's push.`) with:

`````text
The cycle ends with its **single batched push**; post **no** review command in any phase. Post decline
replies before that push — a later `full review` re-evaluates from scratch, and stored Learnings (Decline
Rationale Templates) survive it.
`````

- [ ] **Step 4 (green):** `wc -c` = 30,488; `tests/run-tests.sh --only review-author-classification,parallel-dispatch-contract,recipe-safety,gh-pr-state,cross-provider-consent`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=provider-rules`, `TITLE='trim the Code Quality probe prose, the fingerprint essay, and end-of-cycle'`, `WHY='A mandatory Step 1a read still carried the issue-#403 history around a probe block that names its own outcomes, a seven-line fingerprint essay, and an end-of-cycle paragraph that says its rule twice.'`, `WHAT='Probe prose and in-fence comments to three lines (executable probe lines unchanged); fingerprint and end-of-cycle to three lines each. 31,610 -> 30,488 bytes; ceiling 30,600.'`, `ISSUE=<TJ>`, `FILES=(agentkit/skills/review-remote-pr/references/provider-rules.md tests/test-review-author-classification.sh)`.

---

### Task K: `pr-to-green/references/auto-merge.md` — AM-05, AM-06, AM-07

**Files:**
- Modify: `agentkit/skills/pr-to-green/references/auto-merge.md:25-52, 323-348, 352-361`
- Modify: `tests/test-pr-to-green-authorize-queue.sh:758` (ceiling 21500 → 19300)
- Test: `tests/test-pr-to-green.sh:85-96`, `tests/test-reference-manifest.sh:237` (`../../parallel-issues/references/chains.md#post-squash-merge-conflicts` at 277, untouched), `tests/lint-helper-refs.sh` (`agentkit/hooks/lib/guard-lib.sh` is prose-quoted, not a link)

**Pinned literals:** `concurrency-cap.sh`; `releases its slot immediately` (flat); `re-derive the authorization for its own PR at its own current head` (one line); `every other in-flight root revalidates its own head and base` (flat); `## Contents`; `code-scanning n/a`; `never carries forward` (both outside the ranges); the `## Board move` section between AM-04 and AM-05 untouched.

- [ ] **Step 1: Worktree/branch `refactor/size-w2-auto-merge` from `origin/main`; record `wc -c` (21,344).**

- [ ] **Step 2 (red):**

- [ ] **auto-merge ceiling lowered** — replace line 758 (from `assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/pr-to-green/references/auto-merge.md") -le 21500 ]] && printf yes || printf no)" 'auto-merge reference stays at or under 21500 bytes'`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/pr-to-green/references/auto-merge.md") -le 19300 ]] && printf yes || printf no)" 'auto-merge reference stays at or under 19300 bytes'
`````

Run `tests/run-tests.sh --only pr-to-green-authorize-queue`; expect `FAIL auto-merge reference stays at or under 19300 bytes`.

- [ ] **Step 3: The edits**

- [ ] **AM-07** — replace lines 25–52 (from `**Cap source and admission.** The runtime concurrency cap comes from` through `must do this revalidation itself before calling them again.`) with:

`````text
**Cap source and admission.** The runtime concurrency cap comes from
`parallel-issues/scripts/concurrency-cap.sh` (never inferred or invented), with the root as one
occupant; a root over the cap queues until an occupant reaches evidence-green or blocks, and a root that
fails or blocks releases its slot immediately.

**The confirmed-queue snapshot is single-slot.** `authorize-queue.sh` and `pr-queue.sh
--write-confirmed-queue` share one fixed path, so authorizing PR B overwrites PR A's record even in
sequence; a root entering the Step 2 critical section must re-derive the authorization for its own PR at its own current head every time.

**Revalidate after every merge.** A Step 5 merge stales every other in-flight root's base: before its
next mutation, every other in-flight root revalidates its own head and base with a fresh
`pr-queue.sh`/`gh-pr-state.sh` read — evidence captured before that merge may not authorize a mutation,
and the transition/settlement steps do not re-check it for you.
`````

- [ ] **AM-05** — replace lines 323–348 (from `The repository's PreToolUse hook (`agentkit/hooks/lib/guard-lib.sh`) enforces` through `internally.`) with:

`````text
The repository's PreToolUse hook (`agentkit/hooks/lib/guard-lib.sh`) refuses every directly-typed agent
merge — `gh pr merge`, `gh api -X PUT repos/OWNER/REPO/pulls/N/merge`, and a `gh api graphql`
`mergePullRequest` mutation — unconditionally, even after operator authorization, and even when the
words appear only inside a quoted data string. `merge-pr.sh` is the sole sanctioned entry point: the hook
inspects only the agent's own command line, never a helper's internals, so its identical REST call passes.
`````

- [ ] **AM-06** — replace lines 352–361 (from `Identical to the non-`--auto-merge` prohibitions, restated because a merge` through `a named stop.`) with:

`````text
Also forbidden: force-push, history rewrite, merging a `BLOCKED` item, bypassing branch protection, any
directly-typed merge form, merging outside the confirmed queue, and dispatching a workflow to manufacture
gate evidence. `merge-pr.sh` never retries around a forge refusal (required-approval, stale-sha 409,
not-mergeable 405): each is reported verbatim as a named stop.
`````

- [ ] **Step 4 (green):** `wc -c` = 19,100; `tests/run-tests.sh --only pr-to-green,pr-to-green-authorize-queue,pr-to-green-merge-gate,pr-to-green-merge-pr,reference-manifest`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills && tests/lint-skill-size.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=auto-merge`, `TITLE='compress concurrency admission, guard alignment, and still-forbidden'`, `WHY='Three sections of the --auto-merge reference restated the hook's three refused forms, the merge-pr.sh exemption, and the forbidden list in essay form.'`, `WHAT='Concurrency admission keeps its four pinned sentences in 12 lines; guard alignment and Still forbidden become one paragraph each. 21,344 -> 19,100 bytes; ceiling 19,300.'`, `ISSUE=<TK>`, `FILES=(agentkit/skills/pr-to-green/references/auto-merge.md tests/test-pr-to-green-authorize-queue.sh)`.

---

### Task L: `.shared/wait-discipline.md` (WD-01…WD-04), `.shared/six-step-loop.md` (SS-01), `.shared/github-body-policy.md` (GB-01)

**Files:**
- Modify: `agentkit/skills/.shared/wait-discipline.md:8-10, 51-82, 86-88, 111-118, 141` (the `REPO=` read gains a `repo=none` stop line); `agentkit/skills/.shared/six-step-loop.md:94-106`; `agentkit/skills/.shared/github-body-policy.md:7`
- Modify: byte ceilings before `finish` in `tests/test-wait-bound.sh`, `tests/test-helper-refs.sh`, `tests/test-gh-body.sh`
- Test: `tests/test-wait-bound.sh:25-38`, `tests/test-parallel-dispatch-contract.sh:232-268, 315-344, 976-986, 1254-1267`, `tests/test-skills-contract.sh:494-508` (`empty wait cycles` must stay in wait-discipline.md and nowhere else), `tests/test-helper-refs.sh:151-154` (the placement rule at six-step-loop.md line 9 stays — SS-02 is not taken), `tests/test-compose-worker-prompt.sh`, `tests/lint-skill-invocations.sh` (the recipe fence keeps its guard above the new `contract-read.sh` call)

**Pinned literals:** `empty wait cycles`; `A wait must never spend model turns.`; `gh-pr-state.sh --wait-ci --rounds N --interval S`; `claude-adversarial-review.sh … > verdict.json`; `agent-run.sh --cmd test`; `adversarial max-duration-seconds`; `CI round cap`; `worker completion marker`; `runner completion marker`; `test-runner logs`; `A bounded wait must be silent until its terminal condition.`; `every line of background output wakes the orchestrator for a turn`; `progress heartbeat`; `log file, not stdout`; the epoch recipe 22–29; `Between waits, wait again; read durable state only when a wait reports an actual completion.`; `Default numeric bounds per wait class`; `Worker implementation wait` row with `**900 s**`, `**600 s**` (every `**N s**` ≥ 600); `single source for the worker-wait bound`; `compose-worker-prompt.sh`; `never be re-issued at the same duration`; six-step-loop: `## How to write a file` and its seven literals, `Worker prompts render this content verbatim, not as a pointer`, `helpers invoked by more than one skill live in `.shared/scripts/``; github-body-policy lines 3 and 5 byte-identical.

- [ ] **Step 1: Worktree/branch `refactor/size-w2-shared` from `origin/main`; record `wc -c` (10,387 / 7,583 / 1,333).**

- [ ] **Step 2 (red):**

- [ ] **byte ceiling: wait-discipline policy** — replace line 67 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/.shared/wait-discipline.md") -le 8700 ]] && printf yes || printf no)" \
    'wait-discipline policy stays at or under 8700 bytes'

finish
`````

- [ ] **byte ceiling: six-step-loop policy** — replace line 185 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/.shared/six-step-loop.md") -le 6100 ]] && printf yes || printf no)" \
    'six-step-loop policy stays at or under 6100 bytes'

finish
`````

- [ ] **byte ceiling: github-body-policy** — replace line 597 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/.shared/github-body-policy.md") -le 920 ]] && printf yes || printf no)" \
    'github-body-policy stays at or under 920 bytes'

finish
`````

Run `tests/run-tests.sh --only wait-bound,helper-refs,gh-body`; expect the three ceiling FAILs.

- [ ] **Step 3: The edits**

- [ ] **WD-02** — replace lines 8–10 (from `Waiting is not work, and narrating a wait is not a status report. One observed run spent` through `progress.`) with:

`````text
Waiting is not work, and narrating a wait is not a status report — one observed run spent ~27 empty wait cycles on it.
`````

- [ ] **WD-01** — replace lines 51–82 (from `Every `gh`-authenticated tool run by this account shares two hourly pools (REST, GraphQL) across` through `GitHub App installation token or machine account — agent-kit#179), not spacing out polls by hand.`) with:

`````text
Every `gh`-authenticated run by this account shares two hourly pools (REST, GraphQL) across every session
on every machine. `pr-queue.sh --write-confirmed-queue` prints a `budget: rest=R/L reset=ISO graphql=R/L
reset=ISO` preflight line and warns (never blocks) when the queue's estimated cost exceeds the remaining
REST budget. A `gh-pr-state.sh` or `pr-queue.sh` call that dies on exhaustion exits `3` (not `1`) and names
the reset time on the same line. On that exit: stop mutating immediately (no retry, no further write-side
`gh` call); record applied-vs-outstanding from durable state, never from memory of intent; report the reset
time verbatim; and never retry into an empty pool — if the reset is inside this session's remaining time,
wait for it with the silent epoch recipe above. Concurrent runs on one account exhaust the pool inside an
hour; the durable fix is a separate machine identity (agent-kit#179), not spacing polls by hand.
`````

- [ ] **WD-02** — replace lines 86–88 (from `"An explicit bound" is a number, not an adjective. A wait issued without one falls back to` through `processing 61 timed-out waits that each carried zero information. The defaults:`) with:

`````text
"An explicit bound" is a number, not an adjective; a wait without one falls back to the harness default (~110 s). The defaults:
`````

- [ ] **WD-03** — replace lines 111–118 (from `Any path that crosses the boundary to a human, or that is recorded for a future resumed run` through ``skills_path` as an executable path on resume without re-resolving it first.`) with:

`````text
Any path that crosses to a human or is recorded for a resumed run uses the contract/resolver form (`$agentkit`,
or `"$agentkit/.shared/scripts/contract-read.sh" --get skills.path`) — never a literal `agentkit/<version>/` path,
which stops resolving at the next plugin update. The session ledger's `skills_path` field is historical
provenance and must stay; the hazard is only replaying it as executable on resume.
`````

- [ ] **WD-04 / REPORT §5 (repo slug from the contract)** — replace line 141 (from `  REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}`) with:

`````text
  REPO=${REPO:-$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$(git rev-parse --show-toplevel)" --get repo.slug)}
  [[ $REPO == */* ]] || { printf '%s\n' 'repo=none in the environment contract; re-run the Step 0 preflight from a checkout with a GitHub origin' >&2; exit 1; }
`````

- [ ] **SS-01** — delete lines 94–106 (from `## Where each step maps for an orchestrated lead` through `| verify + ship | **Finish** — worker verifies fresh, commits with `worktree-commit.sh`, and pushes its own branch, then reports the SHA; the root reviews the pushed diff and owns the PR, board, and every forge follow-up. The unstaged publication handback survives only as the environment-refusal fallback |`).

- [ ] **GB-01** — replace line 7 (from `A caller that needs the created/edited object's number and URL back as data -- a bulk apply ledger, for example -- passes `gh-body.sh`'s `--json` flag instead of parsing its default human-readable lines. `--json` emits exactly one JSON object on stdout, `{"number":N,"html_url":"...","closing_issue":{...}|null}`, consumable with `jq -er '.number'`/`.html_url` with no caller-authored parsing; the human-readable lines move to stderr in that mode. That one-object guarantee holds for a successful mutation, including one whose closing-issue verification later failed; when the gh mutation itself fails outright, `--json` emits nothing on stdout (gh's raw output moves to stderr with the failure diagnosis) -- a caller reading an empty result treats the mutation as never having produced a usable object. Default text-mode output is unchanged.`) with:

`````text
A caller that needs the created/edited object's number and URL back as data passes `gh-body.sh`'s `--json` flag: exactly one JSON object on stdout (`{"number":N,"html_url":"...","closing_issue":{...}|null}`) for any successful mutation — including one whose closing-issue verification later failed — and nothing on stdout when the mutation itself fails; human-readable lines move to stderr in that mode.
`````

- [ ] **Step 4 (green):** `wc -c` = 8,611 / 6,062 / 898; **WD-04 check (review L9):** before merging, run the rewritten durable-state fence once inside a real issue worktree created by `create-issue-worktree.sh` — `contract-read.sh --repo-root "$(git rev-parse --show-toplevel)" --get repo.slug` relies on the inherited contract that `agent-preflight.sh --inherit-session` writes there; `tests/run-tests.sh --only wait-bound,helper-refs,gh-body,parallel-dispatch-contract,skills-contract,compose-worker-prompt`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-skill-invocations.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=shared`, `TITLE='compress wait-discipline budget/replay prose, drop the six-step mapping table, trim gh-body --json'`, `WHY='Three files every run reads carried a 34-line API-budget essay, two incident anecdotes, a table that restates the six steps in a second layout, and a --json paragraph that says its guarantee three ways; the durable-state recipe also asked the network for a slug the contract holds.'`, `WHAT='API budget in 8 lines, anecdotes one line each, never-replay in 4 lines, repo.slug from contract-read.sh; mapping table dropped; --json in one sentence. 10,387 -> 8,611, 7,583 -> 6,062, 1,333 -> 898 bytes; ceilings 8,700 / 6,100 / 920.'`, `ISSUE=<TL>`, `FILES=(agentkit/skills/.shared/wait-discipline.md agentkit/skills/.shared/six-step-loop.md agentkit/skills/.shared/github-body-policy.md tests/test-wait-bound.sh tests/test-helper-refs.sh tests/test-gh-body.sh)`.

---

### Task M: `review-remote-pr/references/environment-contract.md` (EC-01, EC-02), `worker-gate.md` (WG-01), `grooming.md` (GR-01)

**Files:**
- Modify: `agentkit/skills/review-remote-pr/references/environment-contract.md:8-24, 37-57`; `agentkit/skills/review-remote-pr/references/worker-gate.md:8-29, 43-57`; `agentkit/skills/review-remote-pr/references/grooming.md:93-99`
- Modify: `tests/test-cross-provider-consent.sh` (three byte ceilings before `finish`)
- Test: `tests/test-parallel-dispatch-contract.sh:600-603, 1021-1087` (root_sections and the worker-gate flat pins), `tests/test-skills-contract.sh:181-185`, `tests/test-helper-refs.sh:155-157`, `tests/test-review-artifacts.sh`, `tests/lint-helper-refs.sh` (`../../.shared/spawn-contract.md`, `../../.shared/six-step-loop.md`, `../../.shared/github-body-policy.md`, `../../../../docs/fleet-identity.md` resolve), `tests/lint-skill-size.sh` (all three stay under 100 lines, no TOC needed)

**Pinned literals:** environment-contract: `jq is not installed; evidence unavailable` (line 10 kept); worker-gate (flat): `two allowed implementation exceptions` (one line), `harness-aware`, `Workers commit and push their own branch`, `completion report`, `Environment-refusal fallback` (heading), `refused harness patch *tool* is not a refused *shell*`, `probes the shell with a trivial write`, `How to write a file`, `fully applied or fully reverted`, `` worktree-commit.sh` exits 2 ``, `push was refused after the commit succeeded`, `continues the existing PR`, `CI, reply, review, and metadata cycle`, `## Bounded inline corrections` and its seven literals (69–82, untouched), `` resume the same worker with `collaboration.followup_task` first ``; never `Workers are turn-and-burn`, `leave progress unstaged`, `root-owned publication handback`, `opens a DRAFT PR`; grooming: `no helper script — this step is judgment`, `REPO_ROOT=$(git rev-parse --show-toplevel`, `git -C "$REPO_ROOT" rev-parse --show-toplevel` (16–27 untouched — the three-way root resolution is pinned, so GR-01 takes only the Pitfalls table).

- [ ] **Step 1: Worktree/branch `refactor/size-w2-review-references` from `origin/main`; record `wc -c` (4,234 / 6,518 / 6,178).**

- [ ] **Step 2 (red):**

- [ ] **byte ceilings: review-remote-pr references** — replace line 239 (from `finish`) with:

`````text
for ref_ceiling in environment-contract.md:3300 worker-gate.md:5300 grooming.md:5700; do
    assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/review-remote-pr/references/${ref_ceiling%%:*}") -le ${ref_ceiling##*:} ]] && printf yes || printf no)" \
        "${ref_ceiling%%:*} stays at or under ${ref_ceiling##*:} bytes"
done

finish
`````

Run `tests/run-tests.sh --only cross-provider-consent`; expect the three ceiling FAILs.

- [ ] **Step 3: The edits**

- [ ] **EC-01** — replace lines 8–24 (from `Evidence parsing is a blocking check: empty output is acceptable only when the parser proved it` through `cache and reports the substitution as a `note:` line.`) with:

`````text
Evidence parsing is a blocking check: empty output is acceptable only when the parser proved it ran;
missing parser ≠ "no findings." Guard every `jq`/`python3` recipe:
`command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is not installed; evidence unavailable' >&2; exit 1; }`
Before any GitHub body mutation, follow ["$agentkit/.shared/github-body-policy.md"](../../.shared/github-body-policy.md).
Runtime facts come from the session contract's `sandbox=`/`git=`/`measured-by=` records, never inferred
(absent = "unknown"); a denial or approval in one session never generalizes to another — report the
contract state and the exact operation that needs approval. **Shell state does NOT persist between tool
calls** (re-derive `REPO`/`PR` per block); run project commands through `.shared/scripts/agent-run.sh`,
never hand-export cache/CA/`PYTHONPATH`, never disable TLS verification. **A spawned agent cannot spawn
another.** Review-provider behavior is repo/org configuration: never claim automatic/incremental/manual-only
without current state, and never post a trigger command.
`````

- [ ] **EC-02** — replace lines 37–57 (from `The contract file is keyed by harness (issue #551): `.agent/env-contract.<harness>.txt`, never the` through `[fleet identity runbook](../../../../docs/fleet-identity.md).`) with:

`````text
The contract file is keyed by harness (issue #551): `.agent/env-contract.<harness>.txt`, so a second harness
observing a checkout never overwrites the file the first harness's run relies on; `contract-read.sh` and
every guard resolve the running harness's file automatically (the bare name is a read-only legacy fallback).
A contract carrying `mode=observer` means another harness's run was active: treat the checkout root as
read-only and work from a linked worktree. A repo opts into its own command runner via `AGENT_REPO_RUNNER`,
then a committed `.agent/runner`. `.agent/` is untracked (Step 0a excludes it) and `worktree-commit.sh`
stages only its FILE arguments, so `git add -A` is never safe. Unattended orchestration authenticates `gh`
with the fleet App installation token (`GH_TOKEN`/`GITHUB_TOKEN`); never repair a missing fleet credential by
logging the human account into the worker shell — ready flips, approvals, and merges stay human-gated (see the
[fleet identity runbook](../../../../docs/fleet-identity.md)).
`````

- [ ] **WG-01** — replace lines 8–29 (from `The PR-loop agent orchestrates — inspects state, evaluates findings, owns human-confirmation` through `other way to see them.`) with:

`````text
The PR-loop agent orchestrates — inspects state, evaluates findings, owns human-confirmation gates — and
never generates a fix batch on its own model; the two allowed implementation exceptions are a genuinely
spawn-unavailable path and a qualifying bounded inline correction. Every other code change dispatches one
real worker as the sole writer for that batch, with model/effort resolved from `AGENT_WORKER_MODEL`,
`AGENT_WORKER_MODEL_FALLBACK`, and `AGENT_WORKER_EFFORT` (harness-aware: see
[../../.shared/spawn-contract.md](../../.shared/spawn-contract.md)'s "Harness-aware pivot"). The Step 1b
reviewer (read-only) **never** satisfies this gate. Read ["$agentkit/.shared/spawn-contract.md"](../../.shared/spawn-contract.md)
for the spawn call shape and the degraded no-spawn path, and ["$agentkit/.shared/six-step-loop.md"](../../.shared/six-step-loop.md)
for the loop — **paste the six-step contract verbatim into the worker's prompt, never as a pointer** (`fork_context: false`).
`````

- [ ] **WG-01** — replace lines 43–57 (from `A refused harness patch *tool* is not a refused *shell*: before a worker reports an environment` through `normal worker result.`) with:

`````text
A refused harness patch *tool* is not a refused *shell*: before reporting an environment refusal a worker
probes the shell with a trivial write and names what it tried. See [../../.shared/six-step-loop.md](../../.shared/six-step-loop.md)'s
"How to write a file" for the write-mechanism order and the hand-authored-diff prohibition; an interrupted
change leaves the tree fully applied or fully reverted, never partial.

The unstaged publication handback survives only as an environment-refusal fallback. If
`worktree-commit.sh` exits 2, nothing is committed: return the scoped dirty files, diffstat, green log,
branch, and one exact ready-to-run commit invocation with the expanded trailer; the root runs it once and
pushes. If the push was refused after the commit succeeded, report the full commit SHA and the exact
`git push -u origin BRANCH` command; the root runs that push once. Never use an unstaged handback for a
normal worker result.
`````

- [ ] **GR-01 (Pitfalls restate lines 5–7)** — delete lines 93–99 (from `## Pitfalls` through `| Grooming blocks the PR handoff | It's best-effort. If the board/scope/`gh project` access isn't there, no-op silently and still report the PR as merge-ready. |`).

- [ ] **Step 4 (green):** `wc -c` = 3,277 / 5,275 / 5,607; `tests/run-tests.sh --only cross-provider-consent,parallel-dispatch-contract,skills-contract,helper-refs,review-artifacts`; `tests/lint-helper-refs.sh agentkit/skills && tests/lint-skill-size.sh agentkit/skills && tests/lint-markdown-blocks.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=review-remote-pr`, `TITLE='trim environment-contract, worker-gate, and grooming duplicates'`, `WHY='Three review-remote-pr references restated the gate SKILL.md and spawn-contract.md carry, duplicated six-step-loop.md, and carried a Pitfalls table that repeats the file's own first paragraph.'`, `WHAT='Runtime neutrality and the harness-keyed/fleet notes in 11 and 10 lines; the worker gate in 9 lines pointing at its two shared homes; the six-step duplicate in 4 lines; grooming Pitfalls dropped; every flat pin kept. 4,234 -> 3,277, 6,518 -> 5,275, 6,178 -> 5,607 bytes; ceilings 3,300 / 5,300 / 5,700.'`, `ISSUE=<TM>`, `FILES=(agentkit/skills/review-remote-pr/references/environment-contract.md agentkit/skills/review-remote-pr/references/worker-gate.md agentkit/skills/review-remote-pr/references/grooming.md tests/test-cross-provider-consent.sh)`.

---

### Task N: `references.md` — RF-01

**Files:**
- Modify: `agentkit/skills/references.md:3-36`
- Modify: `tests/test-reference-manifest.sh` (byte ceiling before `finish`)
- Test: `tests/test-reference-manifest.sh:51-74, 211-213`, `tests/test-parallel-dispatch-contract.sh:1376-1381`, `tests/test-skills-contract.sh:507`, `tests/lint-reference-manifest.sh` (parses entries only), `tests/lint-helper-refs.sh` (`$agentkit/.shared/scripts/contract-read.sh` and `$agentkit/.shared/scripts/lib/contract-cache.sh` resolve; the lib line is exempt from the sourced-only rule by basename)

**Pinned literals:** the grammar fence `` ```text `` + `` - `$agentkit/<path relative to the skills tree>` ``; `` contract-cache.sh` has an explicit CLI ``; every manifest entry line 44–68 byte-identical (Task 7 of wave one set the three read-when cues).

- [ ] **Step 1: Worktree/branch `refactor/size-w2-references` from `origin/main`; record `wc -c` (6,725).**

- [ ] **Step 2 (red):**

- [ ] **byte ceiling: reference manifest** — replace line 240 (from `finish`) with:

`````text
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/references.md") -le 6100 ]] && printf yes || printf no)" \
    'reference manifest stays at or under 6100 bytes'

finish
`````

Run `tests/run-tests.sh --only reference-manifest`; expect `FAIL reference manifest stays at or under 6100 bytes`.

- [ ] **Step 3: The edit**

- [ ] **RF-01** — replace lines 3–36 (from `Every companion reference this plugin ships, with the path to open it and what` through `one per line, checked by that gate:`) with:

`````text
Every companion reference this plugin ships, with the path to open it and what it is for. Read this file
instead of searching the tree; it sits undotted under the skills tree because `.shared/` is invisible to
`rg --files`, plain globs, and naive `find`.

`$agentkit` is the resolved skills tree from the session contract's `skills= path=` line
(`$agentkit/.shared/scripts/contract-read.sh --repo-root DIR --get skills.path` if you need it again), so every
entry below is an openable path — never reconstruct the prefix or fall back to a filesystem search; a path
that does not resolve is a manifest mismatch, and `tests/lint-reference-manifest.sh` is the gate that says so.

Shared executable helpers live in `$agentkit/.shared/scripts/`; skill-specific helpers in
`$agentkit/<skill>/scripts/`; name each helper by its complete `$agentkit`-relative path at first mention
in a SKILL.md. `$agentkit/.shared/scripts/lib/` holds sourced libraries, not helpers — except that
`$agentkit/.shared/scripts/lib/contract-cache.sh` has an explicit CLI:
`--read-session-context --repo-root DIR [--get KEY]`; there is no sibling with that basename under `.shared/scripts/`.

The manifest is an index, not an instruction to preload every file: read an entry only when its
`Read when:` condition matches the path the run has reached (when uncertain, read it). Entry grammar, one
per line, checked by that gate:
`````

- [ ] **Step 4 (green):** `wc -c` = 5,986; `tests/run-tests.sh --only reference-manifest,parallel-dispatch-contract,skills-contract,recipe-safety`; `tests/lint-reference-manifest.sh agentkit/skills && tests/lint-helper-refs.sh agentkit/skills`; full suite.

- [ ] **Step 5: Shared step** with `SCOPE=references`, `TITLE='trim the manifest preamble'`, `WHY='All four skills read the manifest on every run; its 34-line preamble explained the hidden-directory rationale and the lint at essay length before the first entry.'`, `WHAT='Preamble in 15 lines; every entry, the grammar fence, and the contract-cache CLI sentence unchanged. 6,725 -> 5,986 bytes; ceiling 6,100 in test-reference-manifest.sh.'`, `ISSUE=<TN>`, `FILES=(agentkit/skills/references.md tests/test-reference-manifest.sh)`.

---

## Deferred (with the reason)

- **B-02 single resolver block** — beyond the four tests wave one named (`test-contract-provenance.sh:22-27,96-102` asserts the provenance literals inside *each* SKILL.md; `test-skill-path-resolution.sh` and `test-skills-contract.sh:57-82` extract the bootstrap resolver from onboard-repo), `tests/lint-skill-invocations.sh` enforces two invariants the pointer form inverts: exactly one full resolver definition (`skills= path=` read) per SKILL.md body (:163) and zero in any reference/`.shared` file (:168). A replacement invariant would have to say where the single executed `$contract` read lives and how each SKILL.md proves it prepended it — that is a redesign of the provenance chain, not a cut, for ~1.2K tokens per context (shell-portability.md is already read). Deferred.
- **Full B-01 (guard-line removal)** — the guard executes `[ "${agentkit_provenance:-}" = ok ]`: a resolved-but-unverified tree is refused, which no later `/.shared/scripts/x.sh: No such file` failure reproduces. The audit's proposed invariant ("an unset `$agentkit` fails loudly") covers only half the guard; the other half is what `test-contract-provenance.sh` FULL_GUARD, `lint-skill-invocations.sh` GUARD_EXPR_*, `test-adversarial-review-receipt.sh:62-63`, and `test-parallel-dispatch-contract.sh:356-358,1195` pin. Deferred until a provenance-preserving one-line form exists.
- **PI-22** — moves lines `test-parallel-dispatch-contract.sh:471-497` executes (kind c) into `compose-worker-prompt.sh`; overlaps #613 (root bookkeeping). Not a markdown cut.
- **REPORT §8.1 helper index in `references.md`** — an addition (+≈900 B). File it as its own issue if wanted; out of a cut wave.

## Not taken (row id → reason)

- **PI-17** — 27 pins across 8 lines (`test-parallel-dispatch-contract.sh:1309-1330`); the audit's own after-estimate is larger than before (858 → 1000).
- **PI-13 remainder (publish block)** — 50 literals from `test-adversarial-review-receipt.sh:33-121` pin the parallel-issues copy of the receipt block; wave one took the prose, the block stays.
- **RR-03** — factually wrong for a stacked PR (`baseRefName` ≠ default branch; `mergeable` is read in 0b before the Step 1 digest exists).
- **RR-06** — 14 pins in 7 lines (`test-skills-contract.sh:267-297` extracts and asserts the paragraph); audit −83 B.
- **RR-08 (parallel-issues copy)** — `parallel-issues/SKILL.md:294-297` is the only home of the pinned `jq is not installed; evidence unavailable` in that file (`test-skills-contract.sh:304`); the three review-remote-pr copies are taken (Task B).
- **§5 `gh api …/pulls/$PR --jq .head.sha` at receipt publish** — the receipt's `--head-sha` must bind the head *after* the finding-fix push; the last Step 1/6 digest predates that push, so the live read is the correct one. Same class as RR-03.
- **§5 boundary-mode `gh repo view` ×2 (SKILL.md 584–585)** — line 584 is pinned verbatim by `test-issue-body-boundary.sh:92` and the block carries no rehydration guard, so a contract read there needs a guard line that costs more bytes than the one call it removes; `isPrivate` is genuinely new information anyway.
- **§5 `review-remote-pr/SKILL.md:15-17` re-read exception** — the audit itself calls it unavoidable.
- **§5 `wait-discipline.md:105-107`** — "fine as written" per the audit; the printed `wait-bound=` is what #608 tracks.
- **WP-07** — 66 composer needles (`compose-worker-prompt.sh:1229-1247` validate the setup template) and the audit's after-estimate exceeds before (2870 → 3200).
- **WP-10 / WP-11** — already taken by wave one (Task 6's paths-touched rewrite; Task 7's read-set change).
- **TS-06** — 52 pins (`test-fast-mode-contract.sh:142-164` checks every example line's arithmetic); audit −0.
- **SS-02** — the placement rule at `six-step-loop.md:9` is pinned by `test-helper-refs.sh:151-154` (it must live in that file).
- **GR-01 (REPO_ROOT half)** — `REPO_ROOT=$(git rev-parse --show-toplevel` and `git -C "$REPO_ROOT" rev-parse --show-toplevel` are pinned (`test-parallel-dispatch-contract.sh:600-603`); only the Pitfalls table is taken (Task M).
- **WG-01 (lines 69–82 half)** — nine pins (`test-skills-contract.sh:181-185`, `test-parallel-dispatch-contract.sh:1058-1071`) exceed the one-line pointer's saving; the two other WG-01 ranges are taken (Task M).
- **PV-04 (executable probe lines)** — `if ! "$agentkit/review-remote-pr/scripts/code-quality-state.sh"` and `Code Quality findings unavailable` are pinned (`test-parallel-dispatch-contract.sh:596-598`); the prose and comments around them are taken (Task J).
- **PI-01, PI-03, PI-04, PI-08…PI-11, PI-14, PI-15, B-03, WG-02, SC-01/02, AM-01…04, PV-01…03, CH-01/03/04/05, WP-01/02/05/06, RF-01's read-when cues, B-01-lite** — taken by wave one.

## Self-review

**Placeholder scan:** every edit below quotes its first and last anchor line verbatim and gives the complete replacement text (or "delete"); no "trim this section" instructions remain. `grep -n 'TODO\|TBD\|<trim\|trim this' <this plan>` → only this sentence.

**Method:** `edits.py` (the same texts rendered above) was applied to a scratch copy of `origin/main` + #621 by `apply.py`; every anchor located exactly once (or at the stated occurrence), no ranges overlapped; the six lints `run-tests.sh` runs plus `lint-versioned-plugin-paths.sh` green (`lint-rest-routing.sh` is red on untouched `main` with 10 helper-script violations and scans `.sh` only — unchanged by this wave); the full `tests/run-tests.sh` on the edited tree (`green-full.log`) shows only the 8 failures the untouched scratch tree also shows (6 `bench tier0` assertions that need the real git history, 2 `hooks` `/tmp`-location controls). With the test/ceiling edits applied to the *untouched* tree first, every task's red step failed exactly as written (`red-full.log`).

**Projected tokens saved (re-measured, bytes/4):**

| Task | File(s) | Before → after (bytes) | Δ tokens |
|---|---|---|---|
| A | parallel-issues/SKILL.md (after #621) | 74,846 → 71,932 | −728 |
| B | review-remote-pr/SKILL.md (after #621) | 32,901 → 31,065 | −459 (+ ~29 KB deferred off the no-fix-batch path) |
| C | pr-to-green/SKILL.md | 20,367 → 18,222 | −536 |
| D | onboard-repo/SKILL.md (after #621) | 19,697 → 18,583 | −278 |
| E | worker-prompts.md | 47,320 → 45,826 (composed lead prompt −775 B, path-dependent absolute) | −374 (−194 per composed prompt) |
| F | triage-and-selection.md | 43,225 → 37,574 | −1,413 |
| G | chains.md, trust-and-fencing.md | 17,699 → 16,871; 2,999 → 2,570 | −315 |
| H | spawn-contract.md | 19,709 → 17,943 | −442 |
| I | adversarial-review.md | 25,007 → 19,405 | −1,401 |
| J | provider-rules.md | 31,610 → 30,488 | −281 |
| K | auto-merge.md | 21,344 → 19,100 | −561 |
| L | wait-discipline.md, six-step-loop.md, github-body-policy.md | 10,387 → 8,611; 7,583 → 6,062; 1,333 → 898 | −933 |
| M | environment-contract.md, worker-gate.md, grooming.md | 4,234 → 3,277; 6,518 → 5,275; 6,178 → 5,607 | −693 |
| N | references.md | 6,725 → 5,986 | −185 |
| **Total** | 19 files | **−34,387 bytes** | **≈ −8,597 tokens** |

Per fresh context: the `parallel-issues` single-issue mandatory set (SKILL.md, references.md, spawn-contract, wait-discipline, github-body-policy, the flagged triage sections) loses ≈ 2,300 tokens; the `review-remote-pr` set loses ≈ 3,100 tokens plus ≈ 7,300 tokens (worker-gate + spawn-contract + six-step-loop) that a PR with no fix batch no longer reads. Network calls removed from recipes: 4 (`gh repo view` ×3, `git remote get-url` ×1); blind re-runs removed: 1 (`unknown` verdict).

**Spec coverage (audit row → task):**

| Row | Disposition |
|---|---|
| PI-02, PI-05, PI-06, PI-07, PI-12, PI-16, PI-18, PI-19, PI-20, PI-21 | Task A |
| PI-17, PI-22, PI-13 remainder | not taken (see above) |
| §5 board moves (627/915), `unknown` re-run (392) | Task A |
| §5 boundary `gh repo view` (659–660) | not taken |
| RR-01, RR-02, RR-04, RR-05, RR-07, RR-08 (3 of 4 copies), RR-09, RR-10, §4.2 deferred reads, §5 Repo input (87) | Task B |
| RR-03, RR-06, §5 head.sha (390), §5 :15-17 | not taken |
| PG-01…PG-05 | Task C |
| OB-01…OB-04 | Task D |
| WP-03, WP-04, WP-08, WP-09, §5 branch fence (140–142) | Task E |
| WP-07 | not taken; WP-10/WP-11 | wave one |
| TS-01, TS-02, TS-03, TS-04, TS-05, TS-07, TS-08 | Task F |
| TS-06 | not taken |
| CH-02, TF-01 | Task G |
| SC-03, SC-04 | Task H |
| AR-01…AR-06 | Task I |
| PV-04 (prose/comments), PV-05, PV-06 | Task J |
| AM-05, AM-06, AM-07 | Task K |
| WD-01, WD-02, WD-03, WD-04 (§5), SS-01, GB-01 | Task L |
| SS-02 | not taken |
| EC-01, EC-02, WG-01 (two of three ranges), GR-01 (Pitfalls) | Task M |
| RF-01 | Task N |
| B-01 (full), B-02, §8.1 | deferred |
| everything else in §3 | wave one (#621–#628) |

**Review findings folded in** (`plan2/review-md/REVIEW.md`, all applied, none disagreed): H1 — PG-01 keeps the `capability-default` / `operator-instruction` vocabulary in one parenthetical (Task C ceiling 18,400). H2 — composed-prompt ceiling 20,000 with path-dependent wording in Task E Steps 1/2/4; path-neutral assertion filed as Task 0's `TO`. M1 — Task B's trigger reads "at the first fix batch, before choosing between a dispatch, a bounded inline correction, or a `worker=self` path". M2 — both Task A board-move reads carry Step 1's `repo=none …` remedy (ratchet re-measured 946:17853); Task B's Repo input and Task L's `REPO=` line say what `none` means. M3 — TS-07 keeps "(parent `0700`, ledger `0600`)". M4 — OB-02's three facts folded into Step 4 (Task D ceiling 18,700). M5 — `rest-routing` dropped from the Step 4 loops and named as red-on-base. L1 — PG-04 keeps "never park on it, and never reformat unrelated paths just to force a clean run". L2 — PI-18 keeps ", never a worker-local value". L3 — PV-04 names the blocked outcomes. L4 — RR-05 template carries the draft-phase note. L5 — RR-02/OB-01 end ", or any equivalent". L6 — ceilings 2,600 / 920 / 3,300 / 5,300 / 6,100. L7 — `apply-report.json` regenerated from the final `all md,test` run. L8 — ledger and plan share the `c8271f1d…/plan2` root. L9 — Task L Step 4 requires one real-worktree run of the WD-04 fence before merge.

**North-star check:** no task adds a read, a turn, a gate, or a confirmation. Task B moves three reads later on the timeline (and off it entirely for a PR with no fix batch); Tasks A and L replace network reads with contract reads inside already-guarded fences; Task A's `unknown`-verdict row drops the identical-command retry; Task E removes a fence a worker would have spent a tool turn on. Every executed fence outside the two comment-only edits (Task F's bulk fence, Task J's probe block) is byte-identical; `lint-markdown-blocks.sh` reports 73 fences (74 minus Task E's inert one).
