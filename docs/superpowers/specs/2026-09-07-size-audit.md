# agent-kit size audit — skill markdown + shipped helpers (read-only, 2026-09-07)

Repo: `wrzonance/agent-kit` @ `ed63627` (prep for 0.7.5). Raw data: `2026-09-07-size-audit/`.

**Token counter.** All token figures use the repo's own estimator, `tests/lib/token-estimate.sh` (`bytes / 4`, integer division) — the same function `tests/lint-skill-size.sh` (SKILL.md body gate) and `bench/tier0.sh` (resident/reachable accounting) use, so every number here is directly comparable with the gate ceilings. One calibration point from the run under review: `parallel-issues/SKILL.md` measured 17.5K real tokens where bytes/4 says 20,028 → real ≈ 0.874 × (bytes/4) for this prose. Where a "calibrated" figure appears it is that factor applied; the gate-comparable bytes/4 figure is always the primary one. No tokenizer library is installed on this machine (no `tiktoken`, no `transformers`), so no exact BPE counts.

## 1. Executive summary

| Surface | Now | Proposed after | Net reduction |
|---|---|---|---|
| Skill markdown (21 files) | **451,056 B = 112,753 tok** (6,767 lines) | ≈335,231 B = 83,807 tok | **−118,214 B / −29,553 tok (−26.2 %)** summed over 104 measured proposals, after discounting every passage a test pins (§10); −115,825 B when B-01/B-02 are apportioned per file (§6) |
| Per-invocation mandatory read set, `parallel-issues` | **234,012 B = 58,503 tok** (10 files "read in full") | ≈129,000 B = 32,250 tok (lean set §4 + cuts) | **−45 %** per fresh context, and again per compaction re-read (5 compactions in the run) |
| Per-invocation mandatory read set, `review-remote-pr` | 165,740 B = 41,435 tok (11 files) | ≈102,000 B = 25,500 tok | −38 % |
| Per-worker prompt (issue-lead template alone, before contract/spec paste) | 19,592 B = 4,898 tok | ≈14,500 B = 3,600 tok | −26 % × every worker dispatched |
| Shipped helper scripts (77 files) | **32,331 lines** (24,779 code / 5,320 comment / 2,232 blank; 1,439,486 B) | ≈30,900 lines | **≈ −1,420 lines low-risk (−4.4 %; 27 % of all comment lines), ≈ −1,700 with the medium-risk rows** — 14 proposals in §7, none adding a file (`test-helper-end-of-options.sh` pins exactly 66 executables) |

SKILL.md gate state (`tests/lint-skill-size.sh`, run on this tree: "4 skills checked, 0 violations"): default ceiling 500 lines / 5,000 body-tokens. `KNOWN_OVERSIZE` is declared once (line 30: `parallel-issues` 980:16011:900, line 29: `review-remote-pr` 527:8084:450) and then **re-assigned nine times further down the same file** (lines 75-241) — the effective ceilings today are `parallel-issues` **1105 lines / 19,905 tokens** (measured 1,103 / 19,899: 2 lines and 6 tokens of headroom) and `review-remote-pr` **513 / 8,337** (measured 502 / 8,314: 23 tokens of headroom). The "target ≤900 lines" the comments describe has been ratcheted *up* by 125 lines / 3,894 tokens since the entry was written. `pr-to-green` (4,992) and `onboard-repo` (4,993) sit **7–8 tokens under the 5,000 default**. So every one of the four SKILL.md files is within 25 tokens of its ceiling, which is why each one-line fix now costs a paired trim or a ceiling bump in the same PR.

### Top 10 refactors by tokens saved per unit of risk

| # | ID | What | Saves | Risk / test pin |
|---|---|---|---|---|
| 1 | **B-01** | Replace the 44 × two-line `# >>> prepend THE CACHE REHYDRATION … <<<` marker + `[ -d … ] && [ … = ok ] \|\| { …exit 1; }` guard pairs (and 45 guard-only lines) with one ≤30-byte comment. The rehydration block already `exit 1`s on a bad cache read, and an unset `$agentkit` makes the very next helper path fail loudly. | 9,071 B / 2,268 tok across 8 files; every one of these lines is re-read after every compaction | `tests/test-contract-provenance.sh:106-129` requires both lines per block → edit its two awk regexes in the same PR |
| 2 | **SC-01 + SC-02** | `.shared/spawn-contract.md`: cut the 98 lines of in-block comment essays to one line each, and cut the 79-line prose restatement (sanctioned set / roster / pivot / OpenCode tier) that follows a block whose own `stderr` messages already say each of those things. Mandatory read for both dispatching skills. | 9,591 B / 2,398 tok (SC-02 discounted for 48 pinned sentences) | `test-spawn-contract-roster.sh` executes the block — comments do not change execution; keep the sentences test-skills-contract.sh greps |
| 3 | **§4 lean read set** (no text change) | `parallel-issues/SKILL.md:28` says read `triage-and-selection.md` (43 KB) and `worker-prompts.md` (51 KB) *in full* on every run, though the same SKILL.md says at 381-383 "only for the issues the digest flagged" and worker-prompts' own header says the fix-batch/PR-loop templates are read only when those workers are dispatched. Make the reads section-conditional (both files already carry a `## Contents` list) and drop `.shared/six-step-loop.md` from the mandatory set (the issue-lead template pastes the loop verbatim; the root's only need — the Stage-4 acceptance grammar — is already restated in SKILL.md 835-842). | ≈ 60,000 B / 15,000 tok per fresh context and per compaction | none (read instructions only); `bench/tier0.sh` `reachable` unchanged |
| 4 | **B-02** | Keep ONE resolver + rehydration block (in `.shared/shell-portability.md`, already a mandatory read for all four skills); the four SKILL.md copies (three of them byte-identical, `pr-to-green`'s a fourth variant) become 3-line pointers. | 4,882 B / 1,220 tok | `test-skills-contract.sh` / `test-contract-provenance.sh` extract and execute the resolver from each SKILL.md → move the extraction source in the same PR |
| 5 | **AM-01/02/03/04** | `auto-merge.md`: the merge-gate flag paragraphs (80 lines), code-scanning proof essay (40), mechanical-advance buckets (83) and dependents/delete section (50) each narrate what `merge-gate.sh` / `authorize-queue.sh` / `merge-pr.sh` enforce and print (`blocked reason=…`, `exemptions=disabled reason=…`, exit 3 with dependents named). | 11,548 B / 2,887 tok | helpers + `test-pr-to-green-*.sh` pin every behaviour |
| 6 | **PV-01/02/03** | `provider-rules.md`: Pitfalls table (32 rows, ≥20 restate rules from the same file), "Provider identity" (52 lines restating the classifier + a legend for digest lines that `gh-pr-state.sh` already prints with `next:` hints), CodeRabbit-state legend (29 lines). Mandatory read before Step 1a. | 8,140 B / 2,035 tok | `classify-author.sh`, `gh-pr-state.sh` `provider:`/`next:` lines, `test-review-author-classification.sh` |
| 7 | **CH-01/03/04/05** | `chains.md`: issue #577/#455 exemption internals (52 lines — the proof line's tokens `behind= generated-only= provider-check= approval=` are what the agent needs), "before this was fixed" inheritance history (37), publish-chain-base repetition (24), human-merge/delete section duplicating auto-merge.md (30). | 7,900 B / 1,975 tok | `chain-advance.sh`, `test-chain-advance.sh` |
| 8 | **WP-01/02/05/06** | `worker-prompts.md` shared template blocks: the `<WHEN … trust record.>` blurbs the composer *skips* (`compose-worker-prompt.sh:1120-1128`, never reaches a worker), the 15-line `--trailer` essay ×2 (helper refuses an empty trailer, derives one when omitted: `worktree-commit.sh:576-585`), file-image freshness ×2, filesystem-scope/ownership ×2. Counts twice: root read + every worker prompt. | 5,884 B / 1,471 tok in the file; ≈3,000 B per composed issue-lead prompt | composer needles (`<WHEN this parallel-issues invocation carried --yolo` … `trust record.>`, `__IMAGE_INVALIDATING_WRITERS__`) must stay |
| 9 | **PI-03 + RR-03 + WG-02** | Replace `gh repo view` / `git remote show origin` / `gh pr view --json baseRefName|mergeable` re-derivations (6 network calls in recipes) with `contract-read.sh --get repo.slug|base.branch` and the Step 1 digest's first line, which already carry the facts. | 1,934 B, and −6 network round trips per run | `contract-read.sh:188-193`; PI-03's block may be pinned by `test-parallel-dispatch-contract.sh` (see test-pins.md) |
| 10 | **PI-01/04/08/09/10/13/14/15** | `parallel-issues/SKILL.md` narration of helper output (board-move shapes, triage sample, fence exit-12 prose, handback validator description), the dot graph that restates the headings, the publish-receipt block duplicated from review-remote-pr, and two pointer-only sections. | ≈7,400 B / 1,850 tok in the most-re-read file in the tree (read twice after compactions in the run), after discounting the 50 pinned literals in PI-13/PI-14 | `test-adversarial-review-receipt.sh:86-122` and `test-parallel-dispatch-contract.sh:514-529` pin literals in PI-13/PI-14 — keep them in the pointer |

Categories of the 104 proposals (bytes saved): NARR (prose narrating what a helper already prints/enforces) 44,854 · DUP (cross-file duplication) 26,942 · SELF (repetition inside one file) 24,935 · HIST (history / rationale essays, issue numbers, "before this was fixed") 20,721 · BOILER (repeated block boilerplate) 14,492 · NET (network re-derivation) 1,934.

## 2. Measurements

### 2.1 Skill markdown (item 1) — `md-sizes.csv`

21 files, 451,056 B, 112,753 tokens (bytes/4), 6,767 lines. Body tokens (after frontmatter, what the gate measures) are in the per-file table (§6). The five largest files are 55 % of the tree: `parallel-issues/SKILL.md` 80,115 B · `worker-prompts.md` 50,903 · `triage-and-selection.md` 43,225 · `provider-rules.md` 38,631 · `auto-merge.md` 33,852.

### 2.2 Helper scripts (item 2) — `sh-sizes.csv`, `helpers-report.md`

77 scripts, 32,331 lines: 24,779 code, 5,320 comment (16.5 %), 2,232 blank; 1,439,486 B. Ranked by size: `agent-run.sh` 1,627 · `agent-preflight.sh` 1,484 · `gh-pr-state.sh` 1,364 · `compose-worker-prompt.sh` 1,329 · `chain-advance.sh` 1,076 · `repo-config.sh` 1,054 · `post-receipt.sh` 1,030 · `move-github-project-item.sh` 1,011. Highest comment-to-code ratios: `harness-id.sh` 1.71, `secure-mkdir.sh` 1.32, `gh-budget.sh` 1.27, `sandbox-comparator.sh` 1.26 (small libs whose header essays outweigh their code), then `review-ledger.sh` 0.41 (107-line header), `gh-pr-state.sh` 0.33 (73-line header), `post-receipt.sh` 0.26 (71-line header), `classify-issue-comment-findings.sh` 0.47 (61-line header). Detailed consolidation proposals: §7.

### 2.3 Reference reachability (item 3) — `xref-map.txt`

Every one of the 16 reference files is named by at least one SKILL.md and by `references.md`; **no orphans**. Two are reachable only through one skill: `environment-contract.md`, `grooming.md`, `worker-gate.md` (review-remote-pr only); `auto-merge.md` is cross-referenced from chains.md and adversarial-review.md as well. Self-mentions: only `six-step-loop.md` names itself (line 14, "do not replace with see six-step-loop.md" — fine). What *is* orphaned is at section level: `worker-prompts.md §PR-loop setup worker prompt` (216 lines) is reached only via the one word `pr-loop-setup` in `parallel-issues/SKILL.md:968`, and `triage-and-selection.md §Bulk mutation` (137 lines) is reached only from a REST-routing paragraph — yet both are inside files the SKILL.md orders read "in full".

### 2.4 Duplication (item 4) — `dups.json`

8-word shingling over 857 paragraphs finds 602 near-duplicate pairs (containment ≥ 0.5, ≥ 4 shared shingles), 482 of them cross-file. The largest families, with the copy count and bytes of the redundant copies:

| Family | Copies | Where | Redundant bytes |
|---|---|---|---|
| Rehydration/resolver marker + guard pair | 44 pairs + 45 lone guards | 8 files (parallel-issues 12, onboard-repo 11, review-remote-pr 10, t&s 4, …) | 10,391 (B-01) |
| Resolver block + rehydration block | 4 + 4 | all four SKILL.md Step 0 | 8,053 (B-02) |
| Issue-lead ↔ fix-batch template blocks (scope, ownership, chmod, trailer shell + essay, write-a-file, image freshness, history freeze) | 2 | worker-prompts.md 75-252 ↔ 661-810 | ≈9,800 (WP-02/05/06; composer extracts by section so the copies must stay but can each shrink) |
| Six-step loop + Stage-4 grammar | 4 | six-step-loop.md 21-49; worker-prompts 284-297 and 778-784; parallel-issues/SKILL.md 835-842 | ≈4,500 (read-set change §4 + WP-11) |
| Bounded inline correction + quiescence gate | 4 | spawn-contract 427-443; worker-gate 69-77; parallel-issues/SKILL.md 826-830, 852-853; wait-discipline 39-47 | ≈2,900 (PI-20, WG-01) |
| Adversarial receipt precheck/publish blocks | 2 | review-remote-pr/SKILL.md 303-329, 372-410 ↔ parallel-issues/SKILL.md 971-1036 | 2,900 (PI-13, test-pinned literals kept) |
| Runtime/provider neutrality paragraph | 3 | parallel-issues 142-156; review-remote-pr 62-83; environment-contract.md 6-24 | ≈2,400 (RR-07, EC-01) |
| "References are read once and batched" | 3 SKILL.md + references.md | | ≈1,000 (PI-17, RR-06) |
| Chain rules (graph build, deferral) | 2 | chains.md 19-61/88-103 ↔ parallel-issues/SKILL.md 476-488/590-599 | ≈2,300 (PI-06/07) |
| GitHub API budget | 2 (+ the user's global rule) | wait-discipline 49-82 ↔ pr-to-green 98-103 | ≈3,300 (WD-01, PG-02) |
| Protected-path / hook-bypass sentences | 3 | onboard-repo 160-166; review-remote-pr 214-218; worktree-commit.sh --help | ≈700 (OB-01, RR-02) |

### 2.5 Prose that narrates a helper (item 5)

44,854 B (11,213 tok) of prose tells the agent what a helper prints or refuses, where the helper's own stdout/exit code carries the same fact at the moment it matters. Largest: auto-merge.md merge-gate/authorize-queue/merge-pr internals (11.5 KB), spawn-contract.md prose after the block (5 KB), chains.md retarget-proof internals (3.5 KB), triage-and-selection.md validator/composer prose (2.4 KB), adversarial-review.md launcher internals (2.9 KB), parallel-issues/SKILL.md board-move shapes / fence prose / handback validator (1.7 KB), pr-to-green authorization JSON shape (2.4 KB). Each row in the proposal table names the helper and the test that pins the behaviour.

### 2.6 Read cost per invocation (item 7) — `mandatory-reads.csv`

Files each SKILL.md orders read unconditionally ("read … in full", "before any wait/body mutation/recipe"):

| Skill | Unconditional files | Bytes | Tokens (b/4) | Calibrated | Conditional (chain / --auto-merge / flagged verdicts) |
|---|---|---|---|---|---|
| parallel-issues | 10 (SKILL.md, shell-portability, references.md, triage-and-selection, worker-prompts, spawn-contract, six-step-loop, wait-discipline, github-body-policy, verification-isolation) | 234,012 | 58,503 | ≈51,100 | 92,118 B (chains, trust-and-fencing, adversarial-review, provider-rules) |
| review-remote-pr | 11 (SKILL.md, shell-portability, environment-contract, provider-rules, worker-gate, spawn-contract, six-step-loop, adversarial-review, wait-discipline, github-body-policy, grooming) | 165,740 | 41,435 | ≈36,200 | 0 |
| pr-to-green | 5 (SKILL.md, shell-portability, references.md, review-remote-pr/SKILL.md, wait-discipline) — plus review-remote-pr's 10 when entering Phase A | 73,896 (+165,740) | 18,474 (+41,435) | | auto-merge.md 33,852 |
| onboard-repo | 2 | 23,402 | 5,850 | | 0 |

In the run under review the root hit 5 compactions and re-read SKILL.md and references afterwards (34 cat/sed calls of skill docs, each truncated at 13–19 K tokens because the files exceed the tool's output cap — i.e. the agent paid for a full read and *still* did not get the whole file in one turn). So the effective per-run read cost for parallel-issues was on the order of 3–6 × 58 K ≈ 175–350 K tokens of pure procedure text, before any repository content.

## 3. Proposals — skill markdown (104 rows; full detail in `proposals.csv`)

Columns: **Before → after** is measured bytes of the cited line range → the auditor's estimate of the rewritten passage. **Behavior preserved by** names the helper and/or test that already enforces what the cut prose said. Categories: NARR narrates a helper · DUP cross-file duplicate · SELF in-file repetition · HIST history/rationale · BOILER repeated block boilerplate · NET network re-derivation. Every proposal is a cut, merge, or pointer — none adds a file, gate, rule, or round trip (PI-22 is flagged MIXED because it moves bookkeeping into an existing helper).

#### `parallel-issues/SKILL.md` — 23 proposals, −14825 B (−3706 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| PI-01 | 158-180 | SELF | 1512 → 0 (−1512) | Delete the `## Process` dot graph; the Step headings that follow are the same sequence | Step headings 181-1100 | 3 | no test greps `digraph`/`## Process` (checked tests/*.sh) |
| PI-02 | 226-241 | HIST | 1122 → 350 (−772) | Cut the "run the preflight ONCE" rationale + onboarded-precondition essay to 3 lines; change the resolver error text at line 205 to say "run onboard-repo first" (review-remote-pr line 107 already says "run onboarding first") | resolver block exits 1 with the message; test-skills-contract.sh pins onboard-repo as the bootstrap | 0 | low |
| PI-03 | 286-331 | NET | 1769 → 450 (−1319) | Replace Step 1 (gh repo view + git remote show origin = 2 network calls) with contract-read.sh --get repo.slug / --get base.branch (values the Step 0 contract already printed; table line 276 admits the re-derivation) | contract-read.sh keys repo.slug/base.branch (contract-read.sh:188-193); test-contract-provenance.sh | 8 | no test greps `gh repo view`/`git remote show` in the Step 1 block (checked test-parallel-dispatch-contract.sh, test-skills-contract.sh, test-autonomy-flags.sh) |
| PI-04 | 358-370 | NARR | 569 → 120 (−449) | Delete the sample triage-output listing; the verdict table (385-392) + the one-line format sentence (358) explain the helper output | triage-issues.sh prints it; test-triage-issues.sh | 0 | low |
| PI-05 | 398-409 | DUP | 989 → 250 (−739) | Replace the REST-routing / bulk-ledger paragraph with a 2-line pointer to triage-and-selection §Bulk mutation | tests/lint-rest-routing.sh enforces REST routing in recipes; triage-and-selection.md 136-152 keeps the rule | 2 | low |
| PI-06 | 476-489 | DUP | 1481 → 500 (−981) | Cut the --auto-serialize walkthrough to 4 lines (classify → chain → cap 4 → read chains.md); chains.md 19-61 is the verbatim home and is read whenever a chain exists | chains.md §Building the chain graph; test-chain-advance.sh | 9 | test-autonomy-flags.sh may pin a sentence; verify |
| PI-07 | 590-600 | DUP | 871 → 350 (−521) | Cut "Chained issues defer" to 3 lines; chains.md 88-103 is the home (the paragraph already says "See chains.md for the full rationale") | chains.md §Deferred dispatch | 4 | low |
| PI-08 | 637-651 | NARR | 1130 → 350 (−780) | Cut the six no-op output shapes; keep the one rule: only `moved #` or `no-op: … already` completes the phase, all shapes exit 0 | move-github-project-item.sh prints them; test-move-project-item.sh pins the shapes | 1 | low |
| PI-09 | 705-713 | NARR | 639 → 300 (−339) | Cut the fence-preparation prose that restates the case-block messages (exit 12, --resume archive path) | prepare-issue-artifacts.sh; test-prepare-issue-artifacts.sh | 0 | low |
| PI-10 | 858-869 | NARR | 886 → 700 (−186) | Cut the environment-refusal validator description to 4 lines; validate-handback.sh enforces every listed check | validate-handback.sh; test-handback.sh | 9 | low |
| PI-11 | 889-896 | DUP | 1542 → 650 (−892) | Cut Polling discipline to 3 lines (read wait-discipline.md; quote the printed wait-bound=; digest after completion); wait-discipline.md is a mandatory read | .shared/wait-discipline.md; test-wait-bound.sh | 13 | KEEP the literal sentence "**900 s** minimum, draft-loop/review/CI waits **600 s**" — pinned by test-wait-bound.sh:61 and test-parallel-dispatch-contract.sh:1266 |
| PI-12 | 897-910 | DUP | 1056 → 600 (−456) | Cut the Phase 3 intro worker/root split to 5 lines; worker-gate.md + spawn-contract.md carry it | worker-gate.md, spawn-contract.md | 2 | low |
| PI-13 | 995-1037 | DUP | 2900 → 1600 (−1300) | Keep the precheck block (979-994: test-adversarial-review-receipt.sh pins `post-receipt.sh precheck`, `consent-record.sh payload`, the `: "${PR:?set PR}"` boundary); replace the publish block + prose (995-1036) with a 6-line pointer that still carries the pinned literals `post-receipt.sh publish`, `finding-ledger.sh add`, `--require-pushed` | review-remote-pr/SKILL.md Step 1b + receipt; test-adversarial-review-receipt.sh, test-post-receipt.sh | 50 | 50 literal pins from test-adversarial-review-receipt.sh in 995-1004 — keep that paragraph, cut the duplicate publish block | test-adversarial-review-receipt.sh:86-122 pins literals in the parallel-issues text — keep them in the pointer |
| PI-14 | 1065-1074 | SELF | 1224 → 1400 (−0) | Final draft sweep: 1067/1068 and 1070-1071/1073 say the same thing twice; keep one statement each | post-receipt.sh status exit codes | 20 | low |
| PI-15 | 1101-1106 | SELF | 402 → 0 (−402) | Delete Common Mistakes (a pointer list to files already named as mandatory reads) | references.md | 7 | no test greps "Common Mistakes" |
| PI-16 | 73-85 | SELF | 870 → 400 (−470) | Cut lines 73-84 (--auto-review independence + consent-context paragraph); 939-942 restates the consent rule at the point of use and adversarial-review.md carries the full gate | adversarial-review.md §--auto-review; test-cross-provider-consent.sh | 5 | KEEP the heading sentence "`--auto-review` is independent" (test-autonomy-flags.sh:63) and the --auto-approve alias mention (line 51, satisfied by the Flags table row 39) |
| PI-17 | 21-29 | DUP | 858 → 1000 (−0) | Cut the read-discipline paragraph to 3 lines (same rule lives in references.md, review-remote-pr 12-17, pr-to-green 17) | references.md header | 27 | low |
| PI-18 | 107-120 | SELF | 1414 → 900 (−514) | Ledger prose: keep the append/read command lines and the RUN_ID stability sentence; cut the worked example and reflow caveat | session-ledger.sh; test-session-ledger.sh | 14 | low |
| PI-19 | 1107-1115 | SELF | 628 → 350 (−278) | Limits: 4 bullets (cap 10, chain depth 4, root-only spawn, gh/jq requirements) | concurrency-cap.sh | 3 | low |
| PI-20 | 826-831;852-854 | DUP | 536 → 300 (−236) | Quiescence gate + bounded inline correction: 1 pointer line each to spawn-contract §Bounded inline corrections (which is a mandatory read) | spawn-contract.md 427-443 | 4 | low |
| PI-21 | 64-70 | DUP | 545 → 200 (−345) | Verification-cache paragraph: 2 lines + pointer; trust-and-fencing.md 13-26 is the home | agent-run.sh cache; test-agent-run-verification-cache.sh | 4 | low |
| PI-22 | 757-793 | NARR | 3795 → 2000 (−1795) | Compose block: move the spec-verification/plan-sha/report-persistence bookkeeping (lines 767-789) into compose-worker-prompt.sh (overlaps filed #613 root bookkeeping); SKILL keeps the 8-line call | compose-worker-prompt.sh (test-compose-worker-prompt.sh) | 38 | lines 777-787 are EXECUTED verbatim by test-parallel-dispatch-contract.sh:471-497 (kind c) — moving them into the helper needs that extraction re-pointed in the same PR | MIXED: adds ~40 LOC to the helper; net md −2.4KB |
| B-03 | 247-250;291-294;529-532 | BOILER | 539 → 0 (−539) | Drop the repeated 4-line `repository_root=$(git rev-parse --show-toplevel)` guard; the rehydration block already sets contract_root (use it) | rehydration block line 221 | 0 | low |

#### `review-remote-pr/SKILL.md` — 10 proposals, −5269 B (−1317 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| RR-01 | 132-166 | SELF | 2319 → 700 (−1619) | Compress The Loop ASCII to 10 lines (phase → step numbers); Steps 0-6 below carry the detail | Step sections | 3 | no test greps "PHASE A" (checked tests/*.sh); test-skills-contract.sh pins Step headings, which stay |
| RR-02 | 212-232 | DUP | 1326 → 600 (−726) | 0b prose: 214-218 duplicates onboard-repo 160-166 + worktree-commit.sh exit-code contract; 225-231 sed/python note is shell-portability content → 6 lines | worktree-commit.sh exits 2/3; shell-portability.md | 8 | low |
| RR-03 | 221-223;233-233 | NET | 315 → 120 (−195) | Drop `gh pr view --json mergeable` and `--json baseRefName` (2 network calls): BASE_BRANCH from contract-read --get base.branch; mergeable from the Step 1 digest first line (pr= draft= mergeable=) | gh-pr-state.sh digest line 51; contract-read.sh base.branch | 1 | 0b runs before Step 1: swap 0b/0c order or read mergeable after Step 1 |
| RR-04 | 446-458 | DUP | 988 → 500 (−488) | Step 5 → 5 lines; provider-rules.md (mandatory read at Step 1a) carries the cycle order and recipes | provider-rules.md §Step 5 | 1 | low |
| RR-05 | 482-503 | SELF | 1215 → 700 (−515) | Exit report: one template with a `[draft-phase|final]` header instead of two near-identical ones | — | 0 | low |
| RR-06 | 12-18 | DUP | 533 → 450 (−83) | Read-discipline paragraph → 2 lines | references.md | 14 | low |
| RR-07 | 62-83 | DUP | 1506 → 1200 (−306) | Runtime neutrality + provider rules paragraphs → 5 lines; environment-contract.md 6-24 and provider-rules.md 37-57 are the mandatory-read homes | environment-contract.md; provider-rules.md | 18 | low |
| RR-08 | 64-65;191-191;221-221;282-285 | SELF | 529 → 60 (−469) | Drop the per-block `command -v jq` preamble (4 copies): every helper the blocks call exits non-zero itself when jq is missing; keep the one rule sentence at 64 | gh-pr-state.sh/post-receipt.sh/consent-record.sh require jq and die | 4 | gh-pr-state.sh, post-receipt.sh, pr-worktree.sh, verification-baseline.sh, triage-issues.sh self-check jq; consent-record.sh has no explicit check but fails non-zero on a missing jq |
| RR-09 | 258-274 | NARR | 1022 → 350 (−672) | 0c prose: run-dir.sh owns the path/mode/fallback; keep the block + 1 line | run-dir.sh; test-run-dir.sh | 11 | low |
| RR-10 | 412-423 | SELF | 896 → 700 (−196) | Step 3 wait: 4 lines (never gh pr ready; report; wait per wait-discipline; observe provider) | wait-discipline.md | 13 | low |

#### `pr-to-green/SKILL.md` — 5 proposals, −4017 B (−1004 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| PG-01 | 159-216 | NARR | 3311 → 1100 (−2211) | Authorization: keep the example command (171-177) + 6 lines; the JSON record shape (188-205) and the helper-behavior prose describe what authorize-queue.sh/review-transition.sh enforce | authorize-queue.sh, review-transition.sh; test-pr-to-green-authorize-queue.sh, test-review-transition.sh | 15 | low |
| PG-02 | 98-104 | DUP | 570 → 300 (−270) | API-budget bullet → 2 lines; wait-discipline.md §GitHub API budget is the home | pr-queue.sh budget: line; exit 3 | 7 | low |
| PG-03 | 273-282 | DUP | 687 → 350 (−337) | Phase C paragraph → 3 lines; provider-rules.md owns settlement | provider-rules.md; thread-action.sh | 6 | low |
| PG-04 | 217-248 | DUP | 1937 → 1100 (−837) | Step 2: baseline-red paragraph (227-238) duplicates review-remote-pr Step 2 + trust-and-fencing; → 12 lines total | verification-baseline.sh; test-verification-baseline.sh | 8 | low |
| PG-05 | 76-97 | SELF | 1362 → 1000 (−362) | Hard rules → 5 bullets (93-95 "stay in their authoritative files" is meta; 96-97 repeats 25) | — | 14 | low |

#### `onboard-repo/SKILL.md` — 4 proposals, −1805 B (−451 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| OB-01 | 160-167 | DUP | 711 → 250 (−461) | Protected-path/hook-bypass paragraph → 2 lines; same sentences live in review-remote-pr 214-218 and worktree-commit.sh --help | worktree-commit.sh exit 3/2; test-worktree-commit.sh | 1 | low |
| OB-02 | 328-337 | SELF | 616 → 200 (−416) | Delete: "runs directly, no approval" is stated at 25, 201-203 and again here; VERIFY/TEST on-demand is stated at 191-194 | — | 0 | low |
| OB-03 | 13-28 | SELF | 1271 → 500 (−771) | Intro: 7 one-line paragraphs → 4 lines (23/25 overlap Step 6/Reference) | — | 8 | low |
| OB-04 | 183-190 | SELF | 507 → 350 (−157) | "Do not test a candidate yourself" + SETUP paragraphs → 3 lines | agent-run.sh | 0 | low |

#### `parallel-issues/references/worker-prompts.md` — 11 proposals, −8748 B (−2187 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| WP-01 | 111-121;728-735 | HIST | 1412 → 240 (−1172) | `<WHEN … trust record.>` template-author blurbs: keep the first-line start marker and the `trust record.>` end marker on ONE line each; the composer skips the block (compose-worker-prompt.sh:1120-1128) so it never reaches a worker | compose-worker-prompt.sh skip_when; test-compose-worker-prompt.sh | 4 | composer matches the start substring and the end token — keep both |
| WP-02 | 217-232;709-724 | NARR | 2754 → 700 (−2054) | Trailer essay ×2 → 3 lines each: pass --trailer "$worker_attribution" in the same tool call; the helper refuses an empty trailer and derives one when omitted | worktree-commit.sh:576-585; test-worktree-commit.sh | 4 | pasted into every worker prompt: saving is per-worker too |
| WP-03 | 124-134 | DUP | 934 → 350 (−584) | Baseline-exclusion paragraph in the lead prompt → 3 lines; trust-and-fencing.md 28-41 is the root-side home; agent-run.sh prints BASELINE-EXCLUDED | agent-run.sh --baseline-*; test-agent-run-*.sh | 0 | low |
| WP-04 | 144-151 | NARR | 664 → 300 (−364) | agent-run.sh behaviour paragraph → 3 lines (PASS/FAIL line, read the named log, pass --) | agent-run.sh output | 4 | low |
| WP-05 | 162-177;751-766 | SELF | 1744 → 900 (−844) | File-image freshness ×2 → 5 lines each (keep __IMAGE_INVALIDATING_WRITERS__) | composer placeholder | 10 | low |
| WP-06 | 75-98;661-685 | SELF | 3573 → 2000 (−1573) | Filesystem scope + ownership + instructions ×2 → 8 lines each; fix-batch 661-670 repeats 672-676 inside the same template | cross-write-check.sh enforces cross-writes at Collect; test-cross-write-ref-fence.sh | 38 | low |
| WP-07 | 510-537;538-554 | NARR | 2870 → 3200 (−0) | PR-loop setup: root regeneration block → 8 lines; terminal-marker prose (538-553) restates the code above → 5 lines | composer pins artifact-contract text (compose-worker-prompt.sh:1229-1247) | 66 | 66 pins across the setup prompt — cut only unpinned prose; keep every needle | composer greps needles in this section; keep the needle strings |
| WP-08 | 556-577 | SELF | 1579 → 800 (−779) | Draft PR body prose: "never inline --body" appears twice; composer order is printed by the helper → 8 lines | compose-pr-body.sh; gh-body.sh refuses inline bodies; test-compose-pr-body.sh, test-gh-body.sh | 6 | low |
| WP-09 | 18-45 | HIST | 2167 → 1200 (−967) | Fast-mode round contract (historical baseline numbers) + misplaced pr-to-green helper argv → 8 lines | pr-to-green/SKILL.md call-site map | 20 | low |
| WP-10 | 89-94 | HIST | 411 → 0 (−411) | paths-touched.ndjson paragraph: the hook never writes it (filed #611); delete or 1 line | #611 | 2 | depends on #611 disposition |
| WP-11 | 284-298 | DUP | 2698 → 2698 (−0) | Six-step block in the lead template: keep (must be pasted) but drop .shared/six-step-loop.md from parallel-issues mandatory reads — see read-cost section | six-step-loop.md | 11 | no size change here; read-cost only |

#### `parallel-issues/references/triage-and-selection.md` — 8 proposals, −6024 B (−1506 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| TS-01 | 40-48;66-70;79-83;89-95;97-102;111-115;128-135;144-153 | HIST | 3358 → 900 (−2458) | Bulk-mutation recipe: shrink the explanatory comment stanzas to one line each and the prose to 3 lines each | apply-ledger.sh; test-apply-ledger.sh; lint-rest-routing.sh | 5 | low |
| TS-02 | 337-367 | NARR | 2280 → 800 (−1480) | write-merge-plan.sh validator behaviour prose → 8 lines (it prints every violation + a jq patch; --fix applies) | write-merge-plan.sh; test-write-merge-plan*.sh | 2 | low |
| TS-03 | 410-424;431-450 | NARR | 1562 → 1300 (−262) | Drop the merge-plan field bullets and the second (schema-2) JSON example; the helper names the first failing field | write-merge-plan.sh validation messages | 14 | field bullets 410-423 are pinned (chainBaseSha/headSha) — keep them; drop only the second JSON example |
| TS-04 | 457-470 | NARR | 927 → 400 (−527) | uncoveredVerification prose → 4 lines; composer prints spec-verification= | compose-worker-prompt.sh | 1 | low |
| TS-05 | 489-497 | DUP | 565 → 200 (−365) | AGENT_GENERATED_PATHS cross-reference → 2 lines | onboard-repo Reference table | 1 | low |
| TS-06 | 685-711 | SELF | 2386 → 2600 (−0) | Funnel examples: 8 → 4; keep the pinned "Legacy forms are compatibility-only…" sentence + 1 legacy example; drop the example explanations 706-710 | test-fast-mode-contract.sh:119 pins the legacy sentence; test-parallel-dispatch-contract.sh:289 pins one legacy line | 52 | 52 pins: test-fast-mode-contract.sh:164 checks each example line's arithmetic — keep the examples, cut only the explanations 706-710 | keep both pinned strings |
| TS-07 | 257-270 | NARR | 842 → 400 (−442) | Active-worker ledger mode/shape rules → 4 lines; named-active-state.sh enforces 0600/symlink/owner | named-active-state.sh; test-named-active-state.sh | 1 | low |
| TS-08 | 212-218;226-230 | HIST | 790 → 300 (−490) | Work-shape rationale → 3 lines | triage-issues.sh --classify-shape; test-work-shape.sh | 0 | low |

#### `parallel-issues/references/chains.md` — 5 proposals, −8485 B (−2121 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| CH-01 | 166-218 | NARR | 4267 → 800 (−3467) | Retarget-proof exemptions (issue #577/#455 internals) → 8-line token legend for behind=/generated-only=/provider-check=/approval=; chain-advance.sh computes and prints them | chain-advance.sh; test-chain-advance.sh | 0 | low |
| CH-02 | 297-313 | DUP | 1340 → 350 (−990) | Post-push rewrite essay → 3 lines; worker-prompts History freeze is the worker-side rule | worker-prompts.md 247-252 | 0 | low |
| CH-03 | 314-350 | HIST | 2575 → 700 (−1875) | Contract-inheritance history ("Before this was fixed…") → the 3-step recovery + 2 lines | agent-preflight.sh --inherit-session revalidation; test-agent-preflight.sh | 1 | low |
| CH-04 | 63-87 | SELF | 1796 → 1000 (−796) | Publishing a chain base → 10 lines (37-61 already states the join push rule) | create-issue-worktree.sh pushes once | 4 | low |
| CH-05 | 238-268 | DUP | 2557 → 1200 (−1357) | Human-merge/delete-branch + retarget-invalidation → 12 lines; auto-merge.md §Dependents check is the home for merge-pr.sh behaviour | merge-pr.sh; chain-advance.sh --recover-closed | 0 | low |

#### `.shared/spawn-contract.md` — 4 proposals, −12159 B (−3039 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| SC-01 | 34-46;56-60;90-93;102-106;111-119;125-139;149-151;156-160;169-178;181-190;211-221;224-231 | HIST | 7036 → 900 (−6136) | In-block comment essays (98 lines) → one line each (12 lines); the code is unchanged | test-spawn-contract-roster.sh extracts and executes the block; comments do not affect it | 21 | the block 25-252 is executed by test-spawn-contract-roster.sh and 12× by test-parallel-dispatch-contract.sh:1615 — comment removal does not change execution; keep any comment line a test greps (test-pins.csv lists them) |
| SC-02 | 255-334 | NARR | 6455 → 3000 (−3455) | Prose restating the block (sanctioned set, roster, pivot, OpenCode tier) → 15 lines; each stop prints its own reason on stderr | the block itself (lines 199, 238) | 48 | 48 literal pins (test-skills-contract.sh:122-179, test-parallel-dispatch-contract.sh:1590-1604) — keep those sentences; cut the rest |
| SC-03 | 335-368 | SELF | 2535 → 1200 (−1335) | Capability bullets: 352-355 repeats 337-338; 356-362 repeats 316-318 → 12 lines | — | 2 | low |
| SC-04 | 445-477 | NARR | 2433 → 1200 (−1233) | Tier mapping → 12 lines; peer-cli candidate search is harness-id.sh/agent-preflight.sh behaviour | harness-id.sh; test-harness-id.sh | 5 | low |

#### `review-remote-pr/references/adversarial-review.md` — 6 proposals, −7284 B (−1821 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| AR-01 | 103-136 | HIST | 2591 → 900 (−1691) | Provenance essay (history of the `#`-comment idiom) → the 6-line recipe + 2 lines | adversarial-run.sh --provenance; test-adversarial-run.sh | 3 | low |
| AR-02 | 136-157 | NARR | 2042 → 450 (−1592) | Launch marker + lock internals → 4 lines; adversarial-run.sh enforces and names the ambiguous prior attempt | adversarial-run.sh; test-adversarial-review-cleanup.sh | 2 | low |
| AR-03 | 174-193 | NARR | 1574 → 450 (−1124) | Payload identity prose → 4 lines; consent-record.sh payload computes it | consent-record.sh; test-consent-record.sh | 5 | low |
| AR-04 | 273-309 | NARR | 2891 → 1000 (−1891) | Roster/fallback resolution prose → 10 lines; adversarial-run.sh resolves and warns by name | adversarial-run.sh; test-review-provider-catalog.sh | 0 | low |
| AR-05 | 364-371 | SELF | 676 → 0 (−676) | Pitfalls table restates 18-33 and 343-348 → delete | — | 0 | low |
| AR-06 | 79-93 | DUP | 910 → 600 (−310) | --auto-review paragraph → 6 lines; parallel-issues Flags table + line 39 carry the flag semantics | test-cross-provider-consent.sh | 2 | consent gate is external-transfer protection: keep the disclosure/record bullets 95-169 mostly |

#### `review-remote-pr/references/provider-rules.md` — 6 proposals, −9980 B (−2495 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| PV-01 | 450-482 | SELF | 6586 → 2500 (−4086) | Pitfalls: keep ~10 rows with unique facts (NOT_FOUND thread ID, 404 reply URL, dismissal endpoint, code-quality vs scanning, TRIGGER_MISPARSED, Review limit, Dismiss finding); drop ~20 rows that restate rules above | — | 2 | low |
| PV-02 | 124-176 | DUP | 4054 → 1200 (−2854) | "Provider identity" restates the classifier (37-57) and legends the digest lines that gh-pr-state.sh already prints with `next:` hints → 12 lines | gh-pr-state.sh next: lines; classify-author.sh; test-review-author-classification.sh | 1 | low |
| PV-03 | 218-247 | NARR | 2271 → 1200 (−1071) | CodeRabbit state legend → 12 lines (4 states, one line each) | gh-pr-state.sh provider: line; test-gh-pr-state.sh | 0 | low |
| PV-04 | 59-87 | DUP | 1777 → 500 (−1277) | Code Quality probe block: the setup worker prompt (worker-prompts 407-433) runs it; root needs the 3-line artifact read → 6 lines | code-quality-state.sh; test-code-quality-state.sh | 4 | low |
| PV-05 | 332-339 | HIST | 610 → 200 (−410) | Fingerprint essay (review-finding F4 history) → 2 lines | classify-issue-comment-findings.sh; test-classify-issue-comment-findings.sh | 0 | low |
| PV-06 | 418-426 | SELF | 582 → 300 (−282) | End of cycle → 3 lines | — | 0 | low |

#### `pr-to-green/references/auto-merge.md` — 7 proposals, −13633 B (−3408 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| AM-01 | 184-265 | NARR | 5649 → 2400 (−3249) | merge-gate flag paragraphs → 24 lines (flag + one-line meaning); the helper prints `blocked reason=` and --help carries the enum | merge-gate.sh; test-pr-to-green-merge-gate.sh | 1 | low |
| AM-02 | 331-371 | NARR | 2947 → 600 (−2347) | Code-scanning proof essay → 6 lines; helper prints scheduled-only/blocked reasons | merge-gate.sh | 0 | low |
| AM-03 | 100-183 | NARR | 5603 → 2000 (−3603) | Mechanical-advance buckets → 20 lines (4 bucket names + one line each + fail-closed sentence) | authorize-queue.sh --allow-mechanical-advance; test-pr-to-green-authorize-queue.sh | 1 | low |
| AM-04 | 450-500 | NARR | 3349 → 1000 (−2349) | Dependents/delete section → 10 lines; merge-pr.sh exit 3 names dependents | merge-pr.sh; test-pr-to-green-merge-pr.sh | 1 | low |
| AM-05 | 508-536 | NARR | 1649 → 350 (−1299) | PreToolUse guard alignment → 3 lines (the hook refuses gh pr merge / REST PUT / GraphQL merge; use merge-pr.sh) | hooks/lib/guard-lib.sh; test-hooks.sh | 1 | low |
| AM-06 | 537-549 | SELF | 704 → 300 (−404) | Still forbidden → 3 lines | — | 0 | low |
| AM-07 | 23-53 | SELF | 1882 → 1500 (−382) | Concurrency admission → 12 lines | concurrency-cap.sh; authorize-queue.sh fixed path | 5 | low |

#### `.shared/wait-discipline.md` — 3 proposals, −2574 B (−643 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| WD-01 | 49-83 | DUP | 2552 → 800 (−1752) | GitHub API budget → 8 lines (exit 3 = stop, record applied/outstanding, report reset verbatim, never retry into an empty pool) | gh-pr-state.sh/pr-queue.sh exit 3 with reset=; test-pr-queue.sh | 0 | low |
| WD-02 | 8-11;86-89 | HIST | 444 → 100 (−344) | Anecdotes (27 empty cycles; 61 timed-out waits) → 1 line | — | 1 | low |
| WD-03 | 109-119 | HIST | 728 → 250 (−478) | Never replay a recorded path → 2 lines | lint-versioned-plugin-paths.sh | 1 | low |

#### `.shared/six-step-loop.md` — 2 proposals, −1704 B (−426 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| SS-01 | 94-107 | SELF | 1522 → 0 (−1522) | Lead-phase mapping table restates 21-49 + 80-92 in a second layout → delete | — | 0 | low |
| SS-02 | 9-10 | HIST | 182 → 0 (−182) | Placement rule is maintainer content → delete | lint-helper-refs.sh | 1 | low |

#### `review-remote-pr/references/environment-contract.md` — 2 proposals, −1912 B (−478 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| EC-01 | 6-25 | DUP | 1489 → 600 (−889) | Runtime neutrality → 6 lines (same content in review-remote-pr 62-68 and parallel-issues 142-156) | — | 2 | low |
| EC-02 | 37-58 | HIST | 1623 → 600 (−1023) | Harness-keyed contract note + fleet/runner operator setup → 6 lines | contract-read.sh resolves the harness file; docs/fleet-identity.md | 1 | low |

#### `parallel-issues/references/trust-and-fencing.md` — 1 proposals, −646 B (−161 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| TF-01 | 1-12 | HIST | 746 → 100 (−646) | Changelog preamble ("Command-approval fence removed 2026-08-19…") → 1 line | — | 0 | low |

#### `review-remote-pr/references/worker-gate.md` — 2 proposals, −2522 B (−630 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| WG-01 | 6-30;41-58;69-78 | DUP | 3902 → 1800 (−2102) | worker-gate: 6-29 duplicates review-remote-pr 126-130 + spawn-contract; 41-57 duplicates six-step-loop 51-64/83-92; 69-77 duplicates spawn-contract 436-443 → 6 + 4 + 1 lines | spawn-contract.md, six-step-loop.md | 23 | low |
| WG-02 | 84-93 | NET | 570 → 150 (−420) | Drop the block: REPO via `gh repo view` (network) — contract-read.sh --get repo.slug; PR is an input | contract-read.sh | 3 | low |

#### `review-remote-pr/references/grooming.md` — 1 proposals, −815 B (−203 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| GR-01 | 16-28;93-100 | SELF | 1115 → 300 (−815) | REPO_ROOT resolved three ways → 3 lines; Pitfalls restate 5-7 → delete | groom-backlog.sh exit 3 no-op | 2 | low |

#### `.shared/github-body-policy.md` — 1 proposals, −693 B (−173 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| GB-01 | 7-7 | NARR | 843 → 150 (−693) | gh-body.sh --json paragraph → 1 line; --help carries the shape | gh-body.sh --help; test-gh-body.sh | 0 | low |

#### `references.md` — 1 proposals, −1166 B (−291 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| RF-01 | 3-31 | HIST | 1866 → 700 (−1166) | Manifest preamble (hidden-dir rationale, lint description, lib note) → 8 lines | lint-reference-manifest.sh | 3 | lint-reference-manifest.sh parses entries only; preamble is free |

#### `(tree-wide)` — 1 proposals, −9071 B (−2267 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| B-01 | 44 marker lines + 45 guard lines | BOILER | 10391 → 1320 (−9071) | Replace each two-line "prepend THE CACHE REHYDRATION/RESOLVER" marker + guard with one ≤30-byte comment (`# ⟵ Step 0 rehydration`); the rehydration block itself exits 1 when the cache read fails, and an unset $agentkit makes the very next helper path fail loudly (`/.shared/scripts/x.sh: No such file`) | rehydration block (contract-cache.sh --read-session-context exits non-zero); test-contract-provenance.sh | 0 | test-contract-provenance.sh:106-129 requires BOTH the marker line and the guard message in every guarded block; edit its two regexes in the same PR to accept the one-line form |

#### `(4 SKILL.md)` — 1 proposals, −4882 B (−1220 tok)

| ID | Lines | Cat | Before → after (bytes) | Cut / merge / replace | Behavior preserved by | Hard pins in range | Risk / test note |
|---|---|---|---|---|---|---|---|
| B-02 | pi 191-210,218-222; rr 94-112,120-124; ob 35-60,66-70; pg 31-42,49-56 | BOILER | 8053 → 3171 (−4882) | Keep ONE canonical resolver + rehydration block (in .shared/shell-portability.md, already a mandatory read for all four skills, or in onboard-repo whose variant is the superset); each SKILL.md Step 0 becomes a 3-line pointer + its skill-specific preflight call | contract-cache.sh; contract-read.sh; test-contract-provenance.sh, test-skills-contract.sh | 0 | HIGH: test-skills-contract.sh/test-contract-provenance.sh extract the resolver from each SKILL.md and execute it — the extraction source must move with the block in the same PR (verify in test-pins.md) |

## 4. Leaner mandatory-read sets (item 7, continued)

These change *read instructions*, not content, so they stack with the cuts in §3. Measured with today's file sizes.

### 4.1 `parallel-issues` — single issue, no chain (the `SKILL.md:28` case)

| File | Today | Proposed | Why |
|---|---|---|---|
| `SKILL.md` | 80,115 (read twice after compactions in the run) | ≈57,000 after §3 cuts | — |
| `.shared/shell-portability.md` | 3,055 | 3,055 (+2,300 if it becomes the resolver's home, B-02) | needed before the first recipe |
| `references.md` | 6,601 | ≈5,400 (RF-01) | manifest |
| `references/triage-and-selection.md` | 43,225 **in full** | read §Work-shape + §Conflict-analysis (≈16,500 → ≈12,500 after TS-02/03/04) at Step 3; §Bulk mutation only before a 2+-object batch (never in the normal flow: PRs open one per completion); §Prior-art/§Tracker only for a flagged verdict (SKILL.md 381-383 already says so); §Step 2b only for auto/thin selection | the file's own header (line 12-14) says "read the section you were pointed at"; SKILL.md:28 overrides it with "in full" |
| `references/worker-prompts.md` | 50,903 **in full** | §Issue-lead template (19,592) at dispatch; §Draft PR body (5,226) at publication; §PR-loop setup / §PR-fix-batch (22,416) only when those workers are composed | the file's own header (10-16) already scopes each template to its step |
| `.shared/spawn-contract.md` | 29,384 | ≈17,000 after SC-01…04 | executed once; the block is the code |
| `.shared/six-step-loop.md` | 7,583 | **drop from this skill's mandatory set** | the issue-lead template pastes the loop verbatim (worker-prompts 284-297); the root's only need — Stage-4 acceptance forms — is in SKILL.md 835-842 |
| `.shared/wait-discipline.md` | 10,387 | ≈7,800 after WD-01/02/03 | needed |
| `.shared/github-body-policy.md` | 1,333 | ≈640 (GB-01) | needed before first body mutation |
| `references/verification-isolation.md` | 1,426 | 1,426 | fine |
| **Total** | **234,012 B / 58,503 tok** | **≈129,000 B / ≈32,300 tok** | **−45 % per fresh context and per compaction** |

### 4.2 `review-remote-pr`

Drop `worker-gate.md` from the mandatory set after WG-01 (what remains is a pointer to spawn-contract + six-step-loop, both already mandatory); read `adversarial-review.md` at Step 1b only (the SKILL.md already says "before running or skipping", i.e. late); read `grooming.md` after loop exit only (already so). After §3 cuts: ≈102,000 B / 25,500 tok vs 165,740 / 41,435 today (−38 %).

### 4.3 `pr-to-green`

It orders `review-remote-pr/SKILL.md` read "once when entering Phase A" — that pulls review-remote-pr's whole set (≈41 K tok) into a skill whose own body is 5 K. No text change proposed beyond §3; note that after B-02 the resolver is read once for both.

### 4.4 Compaction re-reads

Every compaction re-read costs the full mandatory set again. The run showed 5 compactions and 34 skill-doc reads truncated at 13–19 K tokens. Two zero-cost mitigations that are *not* text additions: (a) after B-01/B-02 and the §3 cuts, `parallel-issues/SKILL.md` (≈57 KB) and `worker-prompts.md` (≈40 KB) still exceed a single tool-output cap (~19 K tok ≈ 76 KB) only for SKILL.md — the split-read probe exception at SKILL.md:25-26 then applies only to that one file; (b) the lean read set in 4.1 halves what must be re-read at all.

## 5. Turn-cost items in prose (item 8)

Each of these costs a tool round trip (or a network call inside one) for a fact the environment contract or a prior helper output already holds, or a rule whose remedy is "run the identical command again".

| file:line | What it costs | Already available from | Fix |
|---|---|---|---|
| `parallel-issues/SKILL.md:308,317` (Step 1) | `gh repo view` (API) + `git remote show origin` (network) | contract `repo=` / `base=` lines; `contract-read.sh --get repo.slug|base.branch` | PI-03 |
| `parallel-issues/SKILL.md:533` (Step 5) | `git remote show origin` per issue | same | read `base.branch` once in the rehydration block |
| `parallel-issues/SKILL.md:627,915` (board moves) | `gh repo view` per move | `repo.slug` | same |
| `parallel-issues/SKILL.md:659-660` (boundary mode) | `gh repo view` ×2 (slug + isPrivate) | slug from contract; visibility is the one genuinely new fact | keep only the `isPrivate` call |
| `review-remote-pr/SKILL.md:222` (0b) | `gh pr view --json mergeable` | Step 1 digest line `pr= draft= mergeable=` (`gh-pr-state.sh:51`) | RR-03: run 0c+Step 1 first, then merge if `CONFLICTING` |
| `review-remote-pr/SKILL.md:233` (0b) | `gh pr view --json baseRefName` | contract `base=`; `contract-read.sh --get base.branch` | RR-03 |
| `review-remote-pr/SKILL.md:390` (publish) | `gh api repos/$REPO/pulls/$PR --jq .head.sha` | digest `sha=`; `$RUN_DIR/state/pr_N_*.json` | read from the Step 1/6 artifact |
| `review-remote-pr/references/worker-gate.md:89`, `.shared/wait-discipline.md:141` | `gh repo view` | `repo.slug` | WG-02, WD-04 |
| `review-remote-pr/SKILL.md:191,221,282` ×3 + `parallel-issues/SKILL.md:343` | `command -v jq` preamble in 4 blocks | every helper called afterwards dies non-zero without jq (gh-pr-state.sh, post-receipt.sh, pr-worktree.sh, verification-baseline.sh, triage-issues.sh self-check) | RR-08 |
| `parallel-issues/SKILL.md:25-26` | "one bounded size probe (`wc -l`) to plan split reads" for files > 800 lines | the manifest could carry the line count — but that adds text; the cuts in §3 bring every file except SKILL.md under one tool-output cap | after §3 only SKILL.md needs a split read |
| `parallel-issues/SKILL.md:392` | `unknown` verdict → "re-run; if it persists, fetch that one issue" | the identical-command retry rule the brief flags | replace with the single `gh api …/issues/N` fallback (drop the blind re-run) |
| `parallel-issues/SKILL.md:1069-1073` | `10:receipt=none` → "re-enter the draft loop once" | post-receipt.sh status | keep one re-entry; the text says it three times (PI-14) |
| `.shared/wait-discipline.md:105-107` | `timed_out:true` → "escalate the bound (at least double it)" | the bound printed as `wait-bound=` at dispatch | fine as written; the run's 129 `wait_agent` calls suggest the printed bound was not being used — filed separately (#608 wait/yield) |
| `worker-prompts.md:140-142` | `git branch --show-current` fenced as a standalone block inside the prompt (a tool turn for the worker) | the prompt's `Branch:` header + Branch Rules step 2 | drop the fence; keep rule 2 |
| `review-remote-pr/SKILL.md:15-17` | "re-read provider-rules.md exactly once after compaction" | — | unavoidable; smaller file after PV-01/02/03 |
| helper-path guesses (run evidence: `.shared/scripts/gh-comment.sh` tried; it lives in `review-remote-pr/scripts/`) | 2 failed calls + `--help` probes (15 in the run) | `references.md` lists only `.md` files; helper homes are stated only in prose | see §8.1 |

## 6. Per-file table

Ceilings are `tests/lint-skill-size.sh` values (body lines / body tokens); references and `.shared/*.md` are ungated. "Proposed delta" sums the §3 proposals for that file (pin-discounted) plus its share of B-01 (marker count × ~206 B) and B-02; `shell-portability.md` gains the canonical resolver copy (+2.3 KB).

| File | Lines | Bytes | Tokens (bytes/4) | Body tokens (gate) | Ceiling | Proposed delta | After |
|---|---|---|---|---|---|---|---|
| `parallel-issues/SKILL.md` | 1114 | 80115 | 20028 | 19899 | 1105 lines / 19905 tok (KNOWN_OVERSIZE, effective after 9 re-assignments; target 900) | −18297 B (−4574 tok) | 61818 B (15454 tok) |
| `parallel-issues/references/worker-prompts.md` | 820 | 50903 | 12725 | 12725 | — (ungated) | −9160 B (−2290 tok) | 41743 B (10435 tok) |
| `parallel-issues/references/triage-and-selection.md` | 720 | 43225 | 10806 | 10806 | — (ungated) | −6848 B (−1712 tok) | 36377 B (9094 tok) |
| `review-remote-pr/references/provider-rules.md` | 481 | 38631 | 9657 | 9657 | — (ungated) | −10392 B (−2598 tok) | 28239 B (7059 tok) |
| `pr-to-green/references/auto-merge.md` | 548 | 33852 | 8463 | 8463 | — (ungated) | −13633 B (−3408 tok) | 20219 B (5054 tok) |
| `review-remote-pr/SKILL.md` | 506 | 33486 | 8371 | 8314 | 513 lines / 8337 tok (KNOWN_OVERSIZE, effective; target 450) | −9329 B (−2332 tok) | 24157 B (6039 tok) |
| `.shared/spawn-contract.md` | 476 | 29384 | 7346 | 7346 | — (ungated) | −12159 B (−3039 tok) | 17225 B (4306 tok) |
| `parallel-issues/references/chains.md` | 350 | 25481 | 6370 | 6370 | — (ungated) | −8485 B (−2121 tok) | 16996 B (4249 tok) |
| `review-remote-pr/references/adversarial-review.md` | 370 | 25007 | 6251 | 6251 | — (ungated) | −7284 B (−1821 tok) | 17723 B (4430 tok) |
| `pr-to-green/SKILL.md` | 353 | 20367 | 5091 | 4992 | 500 lines / 5000 tok (default) | −5723 B (−1430 tok) | 14644 B (3661 tok) |
| `onboard-repo/SKILL.md` | 341 | 20347 | 5086 | 4993 | 500 lines / 5000 tok (default) | −4371 B (−1092 tok) | 15976 B (3994 tok) |
| `.shared/wait-discipline.md` | 144 | 10387 | 2596 | 2596 | — (ungated) | −2574 B (−643 tok) | 7813 B (1953 tok) |
| `.shared/six-step-loop.md` | 106 | 7583 | 1895 | 1895 | — (ungated) | −1704 B (−426 tok) | 5879 B (1469 tok) |
| `references.md` | 68 | 6601 | 1650 | 1650 | — (ungated) | −1166 B (−291 tok) | 5435 B (1358 tok) |
| `review-remote-pr/references/worker-gate.md` | 92 | 6462 | 1615 | 1615 | — (ungated) | −2522 B (−630 tok) | 3940 B (985 tok) |
| `review-remote-pr/references/grooming.md` | 99 | 6178 | 1544 | 1544 | — (ungated) | −1227 B (−306 tok) | 4951 B (1237 tok) |
| `review-remote-pr/references/environment-contract.md` | 57 | 4234 | 1058 | 1058 | — (ungated) | −1912 B (−478 tok) | 2322 B (580 tok) |
| `.shared/shell-portability.md` | 50 | 3055 | 763 | 763 | — (ungated) | −-2300 B (−-575 tok) | 5355 B (1338 tok) |
| `parallel-issues/references/trust-and-fencing.md` | 45 | 2999 | 749 | 749 | — (ungated) | −646 B (−161 tok) | 2353 B (588 tok) |
| `parallel-issues/references/verification-isolation.md` | 20 | 1426 | 356 | 356 | — (ungated) | −0 B (−0 tok) | 1426 B (356 tok) |
| `.shared/github-body-policy.md` | 7 | 1333 | 333 | 333 | — (ungated) | −693 B (−173 tok) | 640 B (160 tok) |
| **Total** | 6767 | **451056** | **112764** | | | **−115825 B (−28956 tok)** | **335231 B (83807 tok)** |

## 7. Helper scripts (item 6) — summary of `helpers-report.md` (full detail, per-file tables and `diff -w` evidence there)

77 scripts / 32,331 lines. Four conventions bound every proposal and are pinned by tests: **C1** `test-helper-argv-contract.sh` enumerates helpers by grepping for literal `--repo)` / `--repo-root)` `case` branches (floors 21 / 20; today 22 / 29) — argv loops cannot move into a lib; **C2** `test-helper-end-of-options.sh` pins exactly 66 executables, each accepting a trailing `--` — no file may be added, merged, or chmod-ed; **C3** `lint-helper-refs.sh` — every path named in prose must exist, `lib/` only as sourced; **C4** `test-srisk-helpers.sh` pins exact stdout of six helpers. No test reads a header comment.

| Rank | Proposal | Files | LOC before → after | Net | Risk |
|---|---|---|---|---|---|
| 1 | **H1** Trim the 27 top-of-file headers > 15 lines to ≤ 8 (purpose + "see --help"). Four headers restate their own `usage()` verbatim (review-ledger 107 lines, gh-pr-state 73, post-receipt 71, classify-issue-comment-findings 61 — quoted pairs in the report); the rest are issue-number history (#332, #372, #394, #396, #405, #447, #475, #578). Keep the `Usage:` table only in the 6 scripts whose `--help` is a one-liner. | 27 | 771 → 216 | **−560** (−647 aggressive) | low: comment-only |
| 2 | **E2** Cap the 12 top-level comment essays ≥ 15 lines at 4 (largest: `agent-preflight.sh:881-928`, 48 lines of #332/#372 narrative above a 2-line `readonly`) | 8 | 262 → 48 | **−214** | low |
| 3 | **E1** Cut the 30 in-function essays (≥ 8 consecutive comment lines; each justified by an issue a named test suite already pins) to ≤ 3 lines | 12 | 297 → 90 | **−207** | low |
| 4 | **D1-lite** `die`/`die_usage`/`die_evidence`/`require_value` into the lib the 16 review-remote-pr scripts already source (the full 46-script version nets −198 but adds 46 sibling-lib dependencies and an exit-code knob — the `code.md` "flags to cover its callers" smell; not recommended) | 16 + lib | 84 → 20 | **−64** | low |
| 5 | **U1** Cut the five `usage()` texts > 60 lines to ≤ 45 by dropping Behaviour/Examples/"Counting rules" blocks that repeat the option table or the header (gh-pr-state 102→45, worktree-commit 71→45, move-github-project-item 64→40, claude-adversarial-review 63→45, post-receipt 61→45) | 5 | 361 → 220 | **−141** | low: tests assert only `Usage:` presence + rc |
| 6 | **A1** Claude/Codex adversarial twins: 8 byte-identical functions (`verdict_schema` 24, `seconds_until_deadline`, `record_helper_pid`, `heartbeat_failure_detail`, `transcript_event_count`, `record_heartbeat_failure`, `die`, `require_value`) + `verify_consent` (differs only in provider token) + the 28-line common `validate_args` block → `lib/adversarial-review.sh`, which both already source before `main` | 2 + lib | 206 → 105 | **−101** (−58 identical-only; −144 with `emit_progress`/`write_review_input`) | low; `parse_args` stays (C1/C2) |
| 7 | **C2** `compose-worker-prompt.sh` re-parses acceptance commands from the spec (74 lines) that `prepare-issue-artifacts.sh` already publishes to `.agent/acceptance.txt` with a *stricter* parser; read the file instead | 1 | 74 → 5 | **−69** | medium: check `test-compose-worker-prompt-scope.sh` fixtures for a spec-without-acceptance.txt case |
| 8 | **C1** `compose-worker-prompt.sh:1090-1329`: 18 four-line `if [[ $line == '__TOKEN__' ]]; then emit_x; continue; fi` blocks → one `case` table | 1 | 72 → 18 | **−54** | low: rendered bytes unchanged |
| 9 | **F1** `file_mode` ×3 (authorize-queue, merge-gate, merge-pr — identical) + `run_dir_mode` ×2 (finding-ledger, post-receipt) + `reject_writable_by_others` ×3 → `lib/private-dir.sh` (already sourced by 9 scripts) | 5 + lib | 79 → 26 | **−53** | low-med |
| 10 | **P1** `agent-preflight.sh:79-117`: four guarded `source` blocks (5-line comment each) → one loop | 1 | 39 → 7 | **−32** | low-med |
| 11 | **A2** `agent-run.sh try_baseline_exclusion` (122 lines): the rm/rm/return triple ×5 and the blob-unchanged check ×2 → two local helpers | 1 | 122 → 95 | **−27** | low |
| 12 | **V1** completed-result jq predicate ×3 (adversarial-run 660-675, finding-ledger 175-186, review-liveness 141-157) → one string in `lib/adversarial-review.sh` | 3 + lib | 45 → 21 | **−24** | medium: lib top-level side effects |
| 13 | **G1** `chain-advance.sh parse_args` 56 → 38 by grouping `--pr|--base|--repo)` (literal `--repo)` token stays for C1) | 1 | 56 → 38 | **−18** | low |
| 14 | **X1** delete dead `worktree-commit.sh:434-436 scope_paths()` (only `scope_paths_for`/`authorized_scope_paths` are called) | 1 | 3 → 0 | **−3** | none |

Sum of the low-risk rows: **≈ −1,420 lines (4.4 % of the tree; 27 % of all comment lines)**; with the medium-risk rows ≈ −1,700. No proposal adds a file (C2 forbids it), a gate, a rule, or a round trip; the only lib changes land in `lib/adversarial-review.sh` and `lib/private-dir.sh`, which already exist and are already sourced by the affected scripts.

Per-script maps for the five largest (function → LOC and top-3 cuts) are in `helpers-report.md §7`: agent-run ≈ −120, agent-preflight ≈ −260 (47 % comment), gh-pr-state ≈ −225, compose-worker-prompt ≈ −194, chain-advance ≈ −125.

Verified non-findings (so nobody re-derives them): only one Python heredoc exists (`validate-handback.sh:38-622` — the whole helper is a Python program in a bash shim; nothing to cut); every parsed-but-undocumented flag is an alias still used by prose or by the C1 count; `emit_progress` is called from the lib (not dead); nine `${VAR:-default}` env knobs are set nowhere (≤ 6 lines total); the two `materiality-check.sh` files differ in 163 lines and are not duplicates; `--)` one-liners (47 copies) and `SCRIPT_DIR` spellings (17) are one line each and cannot leave their script.

**Cross-link to §3 (prose that duplicates `--help`).** `gh-pr-state.sh`'s 45-line "Counting rules" usage block, its 73-line header, and `provider-rules.md` §Provider identity / §CodeRabbit state check (PV-02/PV-03) all legend the same digest lines; keep the legend once, in `usage()`, at ≤ 10 lines.

## 8. Findings that are not size reductions but cut turns or tokens at run time

1. **Helper index in the manifest (+≈900 B once, saves the guesses).** `references.md` lists only `.md` files; the run wasted two calls guessing `.shared/scripts/gh-comment.sh`. A 20-line `helper → directory` list in `references.md` (no new file) removes the guess class; it is the one addition this audit recommends, and it is smaller than the `--help` output it replaces.
2. **Tool-output cap vs file size.** 34 skill-doc reads truncated at 13–19 K tokens: the agent paid a full turn and got a partial file. After §3, only `parallel-issues/SKILL.md` remains over one cap; consider ordering its content so the linear spine (Steps 0–5) is in the first ~70 KB and Phase 3/handoff after — no bytes change, one fewer split read per compaction.
3. **`config.env` facts in every block.** Recipes re-run `repo-config.sh --export` (parallel-issues 297-304) and `contract-read.sh` per block because shell state does not persist. That is inherent; but the *same* rehydration block also resolves `contract_root` — B-03 removes the three extra `git rev-parse` guards that re-derive it.
4. **`wait-bound=` is printed but the prose still recalls the number.** `wait-discipline.md:96-101` says never duplicate it; `parallel-issues/SKILL.md:893` then states "900 s minimum … 600 s" as literals. The literal sentence is pinned by `test-wait-bound.sh:61` and `test-parallel-dispatch-contract.sh:1266`, so PI-11 keeps it; dropping the duplicate number needs a two-line test edit and is not counted in the totals.
5. **Two SKILL.md files sit 7–8 tokens under the 5,000 gate** (`pr-to-green` 4,992, `onboard-repo` 4,993). Every future one-line fix there costs a paired trim or a ceiling bump; §3 gives each ≈1,800–4,300 B of headroom.
6. **`KNOWN_OVERSIZE` is a ratchet in name only.** `tests/lint-skill-size.sh` declares the ceilings at lines 29-30 and re-assigns them at lines 75, 146, 182, 194, 208, 217, 221, 233, 241 — nine bumps, each with its own justification paragraph (the file is 40 % comment). The effective ceiling (1105 / 19,905) is 6 tokens above today's measurement. The §3 cuts (−20.6 KB on `parallel-issues/SKILL.md`) land it at ≈14,800 tokens / ≈870 lines — under the *original* 980 / 16,011 entry and past the 900-line target — so the nine re-assignments can collapse back to the one declaration. That is also a LOC cut in the gate script itself (≈100 lines of ceiling-bump prose).

## 9. What could not be measured, and why

- **Exact BPE token counts.** No tokenizer is installed; all figures are bytes/4 (gate-comparable) with one empirical calibration point (0.874). Real savings on code-heavy passages (shell blocks) are likely *higher* than 0.874× because BPE tokenizes punctuation-dense shell at closer to bytes/3.
- **Per-worker prompt bytes after composition.** `compose-worker-prompt.sh` substitutes the contract, spec, prior art, declared commands and image-invalidating writers; the composed size depends on the repository. Template-only sizes are given (issue-lead 19,592 B; pr-loop-setup 11,144; pr-fix-batch 11,272).
- **Which references the root actually opened in the run.** The brief's counts (34 reads, 15 `--help`, 129 waits) are from the transcript; this audit could not join them to file names beyond the ones quoted.
- **Helper `--help` text vs prose duplication** is measured in §7 from the scripts; whether a given `--help` call in the run was caused by missing prose or by a truncated read is not recoverable.
- **Behavioural equivalence of the "after" text** is an estimate; every proposal names the helper/test that pins the behaviour so the implementer can verify the rewrite against them rather than against this report.

## 10. Test-pin cross-check (item 3 of the risk column) — `test-pins.md`

`test-pins.csv` maps 2,910 test assertions onto markdown lines (kinds: **a** literal phrase, **b** heading/marker used for extraction, **c** code block extracted and *executed*, **d** negative pin, **e** structural). `pin-overlap.py` intersects every §3 proposal range with the hard locks (a, c, b-markers, short e); the result is the "Hard pins in range" column and the discounted after-estimates already folded into every total above (the un-discounted sum was 131,352 B; the pin-aware sum is **118,214 B / 29,553 tok**).

**What the pins say about where the free bytes are** (hard-locked lines / total): `parallel-issues/SKILL.md` 303/1114, `worker-prompts.md` 290/820 (every placeholder and template fence is an extraction marker), `spawn-contract.md` 271/476 (its sole bash fence L25-252 is sourced 13× by tests — byte-locked *as code*, comments free), `review-remote-pr/SKILL.md` 127/506, `triage-and-selection.md` 111/720. Nearly unpinned: `auto-merge.md` 9/548, `provider-rules.md` 4/481, `chains.md` 30/350, `trust-and-fencing.md` 0/45, `environment-contract.md` 0/57 — which is exactly where §3's largest NARR/HIST cuts sit (AM-01…07, PV-01…03, CH-01…05). The pin map's own free-region list for `parallel-issues/SKILL.md` (≥15 contiguous unlocked lines) corroborates PI-01 (L170-188), PI-03 (L299-343), PI-04 (L350-373), PI-08 (L635-649), PI-12 (L904-918).

**Executed blocks (kind c) — verbatim-locked, any edit needs the test re-pointed in the same PR:** `spawn-contract.md` 25-252 (SC-01 touches only comments inside it); `onboard-repo/SKILL.md` 37-59, 47-48 (B-02 moves this block — `test-skill-path-resolution.sh:27,35` must follow it); `parallel-issues/SKILL.md` 777-787 (PI-22) and 1083-1091 (untouched); `review-remote-pr/SKILL.md` 356-366 (untouched); `worker-prompts.md` 208-209, 395-405, 700-701 (WP-02 keeps the shell lines, cuts the prose after them).

**Gotchas the implementer must know (from test-pins.md):** (1) `test-parallel-dispatch-contract.sh:355`'s `### Dispatch` extraction has no end marker and runs to EOF — needles it asserts can sit anywhere after L571; (2) several tests flatten a SKILL.md and its references into one haystack, so a sentence may be "kept" in either file; (3) `references.md` must carry exactly one entry per reference file — deleting or merging a reference means deleting its manifest line; (4) `lint-helper-refs.sh` re-triggers the `$agentkit/`-rooted first-mention rule whenever a helper's first mention is cut — the next mention becomes the first and must be path-form; (5) `test-skill-size.sh:320`'s stale-entry rule fails the gate if an allowlisted skill drops *under* the 500-line / 5,000-token default while its `KNOWN_OVERSIZE` line remains — `review-remote-pr` lands at ≈6.3 K tokens after §3 (still over), `parallel-issues` at ≈14.8 K, so no entry needs deleting, but the nine re-assignments (§8.6) can collapse to one.

**Proposals with zero hard pins in range (safe to implement first, 23 of 102):** PI-02, PI-04, PI-09, RR-05, RR-09 (marker only), OB-02, OB-04, CH-01, CH-02, CH-05, WP-03, WP-08 (b-marker only), TS-02 (path form only), TS-04, TS-05, TS-07, TS-08, AR-04, AR-05, PV-03, PV-05, PV-06, AM-02, AM-06, WD-01, SS-01, TF-01, GB-01 — plus every AM-0x/PV-0x row whose only pin is a "path must resolve" form-lock (keep naming the helper path).

## 11. Files in this directory

`REPORT.md` (this file) · `md-sizes.csv`, `sh-sizes.csv` (item 1-2 raw) · `measure.py` · `xref-map.txt` (item 3) · `dup.py`, `dups.json` (item 4) · `mandatory-reads.csv` (item 7) · `proposals.py`, `proposals.csv`, `proposals-with-pins.csv`, `proposals-table.md`, `per-file-table.md` · `pin-overlap.py` · `helpers-report.md` + `analyze.py`/`analysis.json`/`analysis.txt`/`dupfn.py`/`dupfn.txt`/`md-vs-usage.txt`/`headers-vs-usage.txt` (item 6, sub-audit) · `test-pins.md`, `test-pins.csv` (test-pin map, sub-audit) · `notes-parallel-issues-skill.md` (reading notes, all 21 files).
