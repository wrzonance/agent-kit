# Helper-script size audit — agentkit/skills (77 `.sh` files)

Read-only audit of `/home/adam/github/agent-kit/agentkit/skills/{.shared/scripts,.shared/scripts/lib,parallel-issues/scripts,pr-to-green/scripts,review-remote-pr/scripts}/*.sh` at commit `ed63627` (main, 2026-09-07).
Goal: refactors whose result is a **net LOC reduction** while keeping every behavior `tests/*.sh` pins. Nothing here adds a file, a gate, a rule, or a tool round trip; the only lib changes proposed land in libs that **already exist** (`.shared/scripts/lib/adversarial-review.sh`, `.shared/scripts/lib/private-dir.sh`, `.shared/scripts/lib/gh-budget.sh`).

Per-file measurements: `helpers-sizes.csv` (= `sh-sizes.csv`, produced by `measure.py`; not re-measured). Structural analysis: `analyze.py` → `analysis.json`/`analysis.txt`; duplicate detection: `dupfn.py` → `dupfn.txt`; usage-vs-prose: `md-vs-usage.txt`; header/usage dumps: `headers-vs-usage.txt`. All in this directory.

## 0. Totals and the conventions every proposal must keep

| metric | value |
|---|---|
| files | 77 (64 executable helpers + 13 `lib/*.sh`, of which `contract-cache.sh` and `worktree-setup.sh` are executable → **66 executables**, pinned by `test-helper-end-of-options.sh` `assert_eq 66`) |
| total lines | 32,331 |
| code lines | 24,779 |
| full-line comment lines | 5,320 (16.5 %) |
| blank | 2,155 |
| top-of-file header comment lines | 1,048 (re-measured allowing `set -euo pipefail` inside the header region; CSV column says 1,036) |
| `usage()` function lines | 1,311 across 55 `usage()` defs |
| ≥8-line comment blocks | 173 blocks / 2,535 lines (30 inside function bodies = 297 lines) |

Conventions pinned by the five tests I was told to read first (every proposal below states which it touches):

* **C1 `test-helper-argv-contract.sh`** — every helper whose own `case` statement has a `--repo)`/`--repository)`/`--repo=*` branch must accept `--repo`, and every one with `--repo-root)`/`--dir)` must accept `--repo-root`. Enumeration is a *grep over the script text* (`skills/*/scripts/*.sh` + `.shared/scripts/*.sh`, **not** `lib/`) and must find ≥21 / ≥20 files (today: 22 / 29). Rejections must be phrased `Unknown argument:`/`Unknown option:` (case-insensitive). ⇒ **argv `case` branches for `--repo`/`--repo-root` must stay literally inside each script; they cannot move into a lib.** Also: today's `--repository`, `--dir` aliases are what put some scripts in scope — deleting an alias can drop a file from the enumerated set (22 is only 1 above the floor of 21).
* **C2 `test-helper-end-of-options.sh`** — exactly 66 executable `.sh` under `skills/`; each must accept a trailing `--` (subcommand-first helpers get `sub --`). ⇒ no new executable file, no deleted/merged executable, no chmod of a lib; the `--)` branch stays in every script.
* **C3 `test-helper-refs.sh` + `lint-helper-refs.sh`** — every `.sh`/`.md` path named in skill prose must exist; a `lib/` file may only be mentioned as *sourced* (except `contract-cache.sh`); nothing executable directly under `.shared/`. ⇒ don't rename/move scripts; moving *functions* between files is invisible to this lint.
* **C4 `test-srisk-helpers.sh`** — pins exact stdout strings of `concurrency-cap.sh`, `select-boundary-mode.sh`, `code-quality-state.sh`, `groom-backlog.sh`, `onboard-state.sh --next-steps`, and byte/inode/mtime idempotence of `agent-preflight.sh --ensure`. ⇒ message text and `--help`/usage exit codes of those helpers are fixed.
* Additionally, across `tests/*.sh` the strings `requires a value` (10 asserts), `unknown argument: …` (5), `unexpected argument after --: extra` (1) are asserted; no test asserts the `option ` prefix that 5 scripts add (`option --x requires a value`), and no test reads header comments (`grep -l 'script header' tests/*.sh` → none).

---

## 1. Header comments (top-of-file block after the shebang, before the first non-`set` code line)

27 files have a header > 15 lines (total 863 lines, recomputed 2026-09-08 by summing the §1 table's "header lines (range)" column — the original 771 undercounted it); trimming each to ≤ 8 (one-sentence purpose + "see --help"/pointer) saves **611 lines** (sum of the table's "saved (→8)" column — six scripts whose `usage()` is a one-liner or absent keep more than 8, so this is below the uniform 863 − 216 = 647); trimming *every* header to ≤ 8, including those six, saves 647. No test pins header text. `--help` never prints the header: the four header-only scripts (`triage-issues`, `pick-issues`, `repo-config`, `bootstrap-repo`) answer `-h` with `die_usage 'help requested'` (a one-line synopsis), so their `Usage:` block in the header is their only option doc — keep those 4–9 lines, trim the rationale.

Ranked by lines saved (header lines → 8). "Restates usage()" = the header repeats the option/subcommand/exit list that the script's own `usage()` already prints (quoted pairs below the table).

| # | file | header lines (range) | usage() LOC | restates usage()? | saved (→8) | test that pins behavior | risk |
|---|---|---|---|---|---|---|---|
| 1 | review-remote-pr/scripts/review-ledger.sh | 107 (2–108) | 19 | **yes** — header 34–63 is the 4-subcommand synopsis usage 129–140 prints; usage ends "See the script header comment for the full contract" | 99 (or 90 if the 9-line exit table 97–105 is moved into usage) | test-review-ledger (exit 10/11/12, verdict words) | low |
| 2 | review-remote-pr/scripts/gh-pr-state.sh | 73 (2–74) | 102 | **partly** — digest legend 50–63 ≈ usage "Counting rules" 233–277; 5–48 is #394/#396/#578 rationale | 65 | test-gh-pr-state (settle rules, `ci=0/0 none-configured`) | low |
| 3 | review-remote-pr/scripts/post-receipt.sh | 71 (2–72) | 61 | **yes** — header 11–58 (precheck/status/publish) ≈ usage 88–142, both list the same flags and exit words | 63 | test-post-receipt, test-adversarial-review-receipt | low |
| 4 | review-remote-pr/scripts/classify-issue-comment-findings.sh | 61 (2–62) | 9 | **yes** — header 34–57 subcommand doc; usage 93–95 + "See the script header comment" | 53 (47 if 6 lines of subcommand one-liners move into usage) | test-classify-issue-comment-findings | low |
| 5 | review-remote-pr/scripts/codex-adversarial-review.sh | 37 (2–38) | 49 | **yes** — header Modes/Output/Exit ≈ usage 95–137 (`Exit: 0 verdict obtained, 1 usage/invariant failure, 3 environment-blocked.`) | 29 | test-probe-contract, test-adversarial-review-bounds | low |
| 6 | .shared/scripts/worktree-commit.sh | 33 (2–34) | 71 | **yes** — header EXIT CODES 25–29 ≈ usage; "WHY THIS EXISTS" 6–18 is prose | 25 | test-worktree-commit | low |
| 7 | review-remote-pr/scripts/claude-adversarial-review.sh | 32 (2–33) | 63 | **yes** — header 16–31 Output/Exit status is verbatim usage 132–149 | 24 | test-probe-contract | low |
| 8 | .shared/scripts/agent-preflight.sh | 31 (2–32) | 46 | partly — OUTPUT key list 21–31 ≈ usage 159 | 23 | test-agent-preflight, test-srisk-helpers (`--ensure`) | low |
| 9 | review-remote-pr/scripts/verification-baseline.sh | 31 (2–32) | 24 | **yes** — header `Usage:` 15–17 = usage 53–54; exit list 19–24 | 23 | test-verification-baseline | low |
| 10 | .shared/scripts/lib/gh-budget.sh | 28 (2–29) | — (lib) | n/a — header is the lib's only API doc (3 functions) | 8 (keep API lines, drop #475 narrative) | none (0 tests) | low |
| 11 | .shared/scripts/triage-issues.sh | 28 (2–29) | none (`die_usage` one-liner) | n/a — header holds the only Usage: (15–18) | 16 (keep Usage+Exit) | test-triage-issues, test-work-shape | low |
| 12 | .shared/scripts/pick-issues.sh | 27 (2–28) | none | n/a — keep Usage 21–23 + Exit 25–28 | 15 | test-pick-issues, test-autonomy-flags | low |
| 13 | review-remote-pr/scripts/run-dir.sh | 27 (2–28) | 21 | partly — usage already explains primary/fallback location (55–59); header is #405/#447 history | 19 | test-run-dir | low |
| 14 | .shared/scripts/repo-config.sh | 25 (2–26) | none | n/a — keep the 9-line Usage table 12–24 | 8 | test-repo-config (11 suites) | low |
| 15 | .shared/scripts/agent-run.sh | 24 (2–25) | 59 | **yes** — header `Usage:` 21–23 is usage 37–39 | 16 | test-agent-run-* (23 suites) | low |
| 16 | .shared/scripts/board-setup.sh | 24 (2–25) | 29 | partly — exit codes 24–25 ≈ usage 65–66; 6–22 is incident narrative | 16 | test-board-setup | low |
| 17 | parallel-issues/scripts/materiality-check.sh | 23 (2–24) | 4 | no (usage is one printf) — header 17–24 output/exit doc is the only doc; keep 8 | 15 | test-materiality-check | low |
| 18 | .shared/scripts/lib/secure-mkdir.sh | 21 (2–22) | — | n/a | 13 | test-session-ledger | low |
| 19 | parallel-issues/scripts/stall-check.sh | 21 (2–22) | 4 | no — verdict table 10–14 + exits 19–22 are the only doc | 9 | test-stall-check | low |
| 20 | .shared/scripts/lib/contract-cache.sh | 20 (2–22) | — | n/a (#551 narrative 8–22) | 12 | 6 suites | low |
| 21 | review-remote-pr/scripts/gh-comment.sh | 18 (2–19) | 46 | **yes** — Exit status 15–16 ≈ usage 81–83; Requires line | 10 | test-gh-comment | low |
| 22 | .shared/scripts/bootstrap-repo.sh | 17 (2–18) | none | n/a — keep Usage 13–18 | 6 | test-bootstrap-repo | low |
| 23 | .shared/scripts/ci-gap.sh | 17 (2–18) | 15 | **yes** — usage 26–36 already says "list the CI gates no declared command covers… Exit 0…3" | 9 | test-ci-gap | low |
| 24 | .shared/scripts/detect-toolchains.sh | 17 (2–18) | 18 | **yes** — header `Usage:` 17–18 = usage 31; exit rule 13–15 = usage 38 | 9 | test-detect-toolchains | low |
| 25 | .shared/scripts/gh-auth-state.sh | 17 (2–20) | none | n/a (no options) | 9 | test-gh-auth-state | low |
| 26 | parallel-issues/scripts/prepare-issue-artifacts.sh | 17 (2–19) | 44 | partly | 9 | test-prepare-issue-artifacts (6 suites) | low |
| 27 | .shared/scripts/harness-id.sh | 16 (2–17) | none (one-line) | n/a | 8 | test-harness-id | low |

Quoted pair for #1 (review-ledger): header line 40–42 `#   status --repo OWNER/REPO --pr N --comments FILE --head SHA / [--diff-payload ID] [--kind adversarial|bot] [--provider NAME] / [--trusted-author LOGIN] [--repo-root DIR]` vs usage 131–133 `$PROGNAME status --repo OWNER/REPO --pr N --comments FILE --head SHA / [--diff-payload ID] [--kind adversarial|bot] [--provider NAME] / [--trusted-author LOGIN] [--repo-root DIR]` — byte-identical modulo the `#`.
Quoted pair for #7 (claude-adversarial-review): header 24–26 `# Exit status: 0 — review completed and every invariant held. 1 — usage error, or a real invariant/verdict failure.` vs usage 139–141 `Exit status: 0 review completed and every invariant held. 1 usage error, or a real invariant/verdict failure.`
Quoted pair for #3 (post-receipt): header 12–16 `precheck --issue-comments FILE … spent → exit 0 / not-spent → exit 10` vs usage 107–111 `precheck: … stdout 'spent' and exit 0 … stdout 'not-spent' and exit 10`.

**Proposal H1 — trim the 27 headers to ≤ 8 lines: −611 lines (−647 if every header, including the six scripts whose `usage()` is a one-liner or absent, is trimmed uniformly to 8).** Touches no convention; all 27 keep their argv loops. Risk: low (comment-only edits; the issue numbers being deleted are all already carried by the named regression suites).

---

## 2. Inline comment essays (≥ 8 consecutive full-line comments inside a function body)

30 blocks, 297 lines. Each one below is rationale/history (issue numbers, "used to") rather than a description of the code; the test column says which suite already pins the behavior the essay justifies, making the essay redundant with the test. Proposed: cut each to ≤ 3 lines (keep the issue ref) → **−207 lines**.

| file:lines | len | function | rationale | pinned by |
|---|---|---|---|---|
| .shared/scripts/agent-preflight.sh:403-416 | 14 | probe_identity | unborn-checkout `rev-parse` failure | test-agent-preflight |
| agent-preflight.sh:571-579 | 9 | probe_instructions | per-directory AGENTS.md scan, skips vendored trees | test-agent-preflight |
| agent-preflight.sh:685-695 | 11 | probe_gh | "when gh says no, say WHY" (gh-auth-state delegation) | test-gh-auth-state |
| agent-preflight.sh:747-757 | 11 | probe_sandbox | #332 "no verified escalation signal" | test-agent-preflight (`--measured-from`) |
| agent-preflight.sh:789-800 | 12 | caches_restriction_score | #332 F2 anchor-at-start | test-agent-preflight |
| agent-preflight.sh:802-810 | 9 | caches_restriction_score | unparseable reason ranks restrictive | test-agent-preflight |
| agent-preflight.sh:999-1009 | 11 | inherit_or_probe | #372 fail-closed comparator | test-agent-preflight, test-session-contract-freshness |
| agent-preflight.sh:1068-1081 | 14 | probe_caches | #332 whitespace in root= | test-agent-preflight |
| agent-preflight.sh:1173-1184 | 12 | node_roots | #338 package-manager choice | test-agent-preflight |
| agent-preflight.sh:1413-1422 | 10 | main | #453 keys-vs-values presence | test-contract-skills-content |
| .shared/scripts/agent-run.sh:277-284 | 8 | select_caches | ecosystem-allow redirect | test-agent-run-cmd |
| agent-run.sh:816-826 | 11 | resolve_named_command | AGENT_CMD_CHECK_NODE_P… declaration reading | test-agent-run-cmd |
| .shared/scripts/lib/secure-mkdir.sh:42-49 | 8 | secure_mkdir_p | idempotence like `mkdir -p` | test-session-ledger |
| .shared/scripts/worktree-commit.sh:677-684 | 8 | (trunk guard) | main/master/trunk default | test-worktree-commit |
| parallel-issues/scripts/chain-advance.sh:856-863 | 8 | cover_retarget_lineage | `--paginate` concatenation | test-chain-advance |
| chain-advance.sh:981-990 | 10 | recover_closed | #564 F3 | test-chain-advance, test-pr-to-green-merge-pr |
| parallel-issues/scripts/create-issue-worktree.sh:295-304 | 10 | (contract copy) | #332 sandbox=/caches= inheritance | test-create-issue-worktree, test-session-contract-freshness |
| parallel-issues/scripts/cross-write-check.sh:639-647 | 9 | (ref incidents) | HEAD reflog | test-cross-write-ref-fence |
| cross-write-check.sh:685-693 | 9 | (branch checked out elsewhere) | | test-cross-write-ref-fence |
| review-remote-pr/scripts/adversarial-run.sh:280-287 | 8 | select_reviewer | roster form | test-adversarial-run |
| adversarial-run.sh:339-347 | 9 | select_reviewer | AGENT_ADVERSARIAL_REVIEWER | test-adversarial-run |
| adversarial-run.sh:592-599 | 8 | (append) | failed append deliberate | test-adversarial-run |
| adversarial-run.sh:875-883 | 9 | main | #477 reaffirm | test-consent-record |
| review-remote-pr/scripts/gh-pr-state.sh:899-912 | 14 | thread_counts | line-anchored marker | test-gh-pr-state |
| gh-pr-state.sh:1258-1266 | 9 | print_digest | full head SHA | test-gh-pr-state |
| gh-pr-state.sh:1328-1338 | 11 | main | mktemp 600 staging | test-gh-pr-state |
| review-remote-pr/scripts/post-receipt.sh:805-813 | 9 | (ledger append) | #477/#484 best-effort | test-post-receipt |
| review-remote-pr/scripts/review-ledger.sh:679-686 | 8 | cmd_append | free-text defense | test-review-ledger |
| review-ledger.sh:807-814 | 8 | cmd_cover | (sha, reason) idempotence | test-review-ledger |
| review-ledger.sh:831-840 | 10 | cmd_cover | fail-closed like cmd_status | test-review-ledger |

Beyond function bodies there are 106 top-level essays (1,279 lines) that sit *between* functions — mostly doc-comments preceding a definition. The 12 longest (≥ 15 lines, 262 lines total) are the cheapest cuts and are itemised under §7 for the big five; the largest single one is `agent-preflight.sh:881-928` (48 lines of #332/#372 history above a 2-line assignment). Capping all 106 at 4 lines would save ~855 lines; I only count the ≥15-line ones (−190) in the ranked table because the rest need per-block judgment.

---

## 3. Duplicated code (verified by `diff -w` on extracted ranges — see `dupfn.txt` sections A1/A2/C)

### 3a. Small-helper family: `die` / `die_usage` / `die_blocked` / `die_evidence` / `require_value`

Exact normalized-body duplicates (dupfn.py A1):

| body | copies | LOC each | files (line range) |
|---|---|---|---|
| `die(){ printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }` | **18** | 4 | apply-ledger 13-16, board-list 55-58, board-setup 70-73, bootstrap-repo 25-28, diff-facts 20-23, pick-issues 43-46, triage-issues 37-40, concurrency-cap 25-28, write-merge-plan 13-16, authorize-queue 28-31, merge-gate 36-39, merge-pr 40-43, pr-queue 36-39, code-quality-state 91-94, compose-comment-body 30-33, compose-review-reply 29-32, groom-backlog 21-24, thread-action 32-35 |
| same with `$PROGNAME`/`"$1"` | 7 | 4 | adversarial-run 104-107, classify-author 27-30, claude-adv 153-156, codex-adv 141-144, gh-pr-state 281-284, run-dir 66-69, verification-baseline 76-79 |
| same, `exit 2` | 5 | 4 | cross-write-check 14-17, materiality-check(parallel) 39-42, named-active-state 19-22, stall-check 37-40, materiality-check(review) 21-24 |
| `$PROGNAME`/`"$*"` | 3 | 4 | gh-body 66-69, compose-pr-body 25-28, gh-comment 94-97 |
| `die_usage` (`$PROGNAME`, usage>&2, exit 2) | 8 | 5 | adversarial-run 113-117, classify-issue-comment-findings 101-105, consent-record 68-72, finding-ledger 30-34, post-receipt 148-152, review-ledger 147-151, run-dir 71-75, verification-baseline 81-85 (+ `$PROGRAM` twins board-list 59-63, board-setup 74-78, apply-ledger 18-22, bootstrap-repo 33-37, repo-config 45-49 → 13 identical modulo variable name) |
| `die_blocked`/`die_env` (exit 3) | 5 | 4 | board-list 64-67, board-setup 79-82, bootstrap-repo 29-32, pick-issues 47-50, triage-issues 41-44 |
| `die_evidence`/`evidence_unavailable` | 4 | 4 | classify-issue-comment-findings 107-110, finding-ledger 36-39, post-receipt 154-157, review-ledger 153-156 |
| `require_value` (3 wordings) | 13 (+2 `need_value`) | 3 | gh-body 71, chain-advance 86, compose-pr-body 30, adversarial-run 119, review-liveness 48, run-dir 77, claude-adv 223, codex-adv 181, consent-record 74, verification-baseline 87, finding-ledger 46, session-ledger 67, gh-pr-state 323; need_value: agent-preflight 235, worktree-commit 143 |
| `require_uint` | 2 | 4 | post-receipt 159-162, review-ledger 158-161 |

Total footprint: 33×4 (die) + 13×5 (die_usage) + 5×4 + 4×4 + 15×3 + 2×4 = 132 + 65 + 20 + 16 + 45 + 8 = **286 lines** across 46 scripts (recomputed 2026-09-08; the original 294 mis-summed this same arithmetic).

No existing lib provides these (`lib/private-dir.sh` and `lib/adversarial-review.sh` both say "the caller supplies `die`"; `lib/worktree-setup.sh` has its own `worktree_setup_fail`). Consolidating them means every one of 46 scripts gains `source "$SCRIPT_DIR/../../.shared/scripts/lib/<existing>.sh"` (1 line) plus a `SCRIPT_DIR=` line in the ~30 scripts that have none, and the shared `die` must absorb three variances (`PROGRAM` vs `PROGNAME`, `"$*"` vs `"$1"`, exit 1 vs 2) — e.g. `die(){ printf '%s: %s\n' "${PROGNAME:-${PROGRAM:-${0##*/}}}" "$*" >&2; exit "${DIE_EXIT:-1}"; }`.

Arithmetic: 286 removed − 20 shared impl (die 4 + die_usage 5 + die_blocked 4 + die_evidence 4 + require_value 3) − 46 source lines − 30 `SCRIPT_DIR` lines = **net −190**. Conventions touched: none of C1–C4 directly (argv loops stay; messages stay `prog: msg`), but the 5 `exit 2` die-scripts (`cross-write-check`, both `materiality-check`, `named-active-state`, `stall-check`) and `require_value`'s `option ` prefix are pinned by `test-materiality-check`/`test-stall-check`/`test-named-active-state` exit codes → the `DIE_EXIT` knob is mandatory. **Risk: medium** — 46 scripts acquire a runtime dependency on a sibling lib (a copied-alone script stops working; `agent-preflight.sh` deliberately guards every `source` for exactly that reason), and a `die` with an exit-code knob is the "flags to cover its callers" smell `code.md` warns about. I recommend doing it only for the **review-remote-pr family (16 scripts) that already sources a lib** (net −64 with zero new `SCRIPT_DIR` lines) and leaving the `.shared` PROGRAM family alone; both figures are in the ranked table.

### 3b. Claude/Codex adversarial-review twins → `lib/adversarial-review.sh` (already sourced by both, at claude:719 / codex:651, immediately before `main "$@"`, so every function moved is defined before any call)

`diff -w` results (claude-adversarial-review.sh ↔ codex-adversarial-review.sh):

| function | claude range | codex range | LOC | diff | net if moved to lib |
|---|---|---|---|---|---|
| verdict_schema | 384-407 | 311-334 | 24 | **identical** | −24 |
| seconds_until_deadline | 180-186 | 155-161 | 7 | identical | −7 |
| record_helper_pid | 213-218 | 148-153 | 6 | identical | −6 |
| heartbeat_failure_detail | 207-211 | 172-176 | 5 | identical | −5 |
| transcript_event_count | 458-462 | 391-395 | 5 | identical | −5 |
| record_heartbeat_failure | 202-205 | 167-170 | 4 | identical | −4 |
| die | 153-156 | 141-144 | 4 | identical | −4 |
| require_value | 223-225 | 181-183 | 3 | identical | −3 |
| die_duration | 198-200 | 163-165 | 3 | only the harness word | −2 (parametrise on the existing `$harness` arg `review_verify_verdict` already takes) |
| verify_consent | 309-325 | 269-285 | 17 | only `--provider anthropic` vs `openai` | −15 (one `CONSENT_PROVIDER` var per script) |
| validate_args | 268-307 | 228-267 | 40 | 28-line block 286-320 / 246-280 identical (the mode/diff/repo/pr/consent checks); only the budget-vs-token checks differ | −26 (`review_validate_common_args` + 1 call each) |
| parse_args | 227-266 | 185-226 | 40/42 | 20 lines 236-255 / 194-213 identical; harness-specific flags differ | 0 — keep (argv `case` must stay in-script per C1/C2) |
| emit_progress | 478-513 | 397-431 | 36/35 | 0.81 similar; JSON field lists differ (`lastEvent`, `harness`) | −28 if unified on one field set (changes stderr progress JSON — pinned by test-adversarial-review-bounds? it greps `status:"running"` only) |
| write_review_input | 419-456 | 338-389 | 38/52 | 17-line prompt heredoc 423-443 / 349-369 identical | −15 |

Sum of the identical rows: **−58** (zero risk: move, delete twin, both scripts already source the lib). With verify_consent/validate_args/die_duration: **−101**. With emit_progress/write_review_input: **−144**. Pinned by test-probe-contract, test-adversarial-review-bounds, test-adversarial-review-cleanup, test-consent-record, test-review-artifacts. Conventions: none (parse_args stays; `--)` stays). Note `emit_progress` is **not** dead — `review_poll_progress` in the lib calls it (my first pass flagged it; verified with grep).

### 3c. `file_mode` / `run_dir_mode` / `reject_writable_by_others` (stat-mode probe) → `lib/private-dir.sh`

| copy | file:lines | LOC | diff |
|---|---|---|---|
| file_mode | pr-to-green/scripts/authorize-queue.sh:36-47 | 12 | identical |
| file_mode | pr-to-green/scripts/merge-gate.sh:44-55 | 12 | identical |
| file_mode | pr-to-green/scripts/merge-pr.sh:48-59 | 12 | identical |
| run_dir_mode (same body on `$RUN_DIR`) | review-remote-pr/scripts/finding-ledger.sh:135-148 | 14 | identical to post-receipt |
| run_dir_mode | review-remote-pr/scripts/post-receipt.sh:619-632 | 14 | |
| reject_writable_by_others | authorize-queue 49-53, merge-pr 61-65 (identical), merge-gate 57-61 (adds optional `writer` arg) | 5 | |

`lib/private-dir.sh` (58 lines, "private-directory creation and validation", already sourced by 9 scripts) is the semantic home. Arithmetic: 12×3 + 14×2 + 5×3 = 79 removed − 17 lib (12 + 5 with `${3:-}` writer) − per-site (authorize-queue, merge-gate, merge-pr, finding-ledger have no `SCRIPT_DIR`: 2 lines each; post-receipt: 1) 9 = **net −53**. Pinned by test-pr-to-green-authorize-queue, test-pr-to-green-merge-gate, test-pr-to-green-merge-pr, test-finding-ledger, test-post-receipt (the "must not be group- or world-writable" refusals). Conventions: none. Risk: low-medium (`private_dir_ensure` calls `die`, and finding-ledger has no `die` — the mode function itself does not call `die`, so sourcing is safe, but shellcheck will now see an unused `private_dir_ensure`).

### 3d. Completed-result jq predicate (verdict invariants) — 3 copies

| file:lines | LOC | notes |
|---|---|---|
| review-remote-pr/scripts/adversarial-run.sh:660-675 (`valid_completed_result`) | 16 | producer |
| review-remote-pr/scripts/finding-ledger.sh:175-186 (`validate_completed_review`) | 15 identical predicate lines wrapped in `jq -s` + comment "Mirrors valid_completed_result in adversarial-run.sh" | |
| review-remote-pr/scripts/review-liveness.sh:141-157 | 15 identical lines (inside a `completed OR blocked` alternation) | |

Existing home: `lib/adversarial-review.sh` ("verdict invariants live here"). adversarial-run sources private-dir + canonical-diff (not this lib); finding-ledger sources nothing; review-liveness sources private-dir. Arithmetic: 45 − 16 (one `REVIEW_COMPLETED_RESULT_JQ` string in the lib) − 5 source/SCRIPT_DIR lines = **net −24**. Risk: medium — sourcing `adversarial-review.sh` also runs its top-level (`source private-dir.sh`, PID slot init); finding-ledger lacks `die`, which `private_dir_ensure` needs, so it must not call it. Pinned by test-adversarial-run, test-finding-ledger, test-review-liveness. Low priority.

### 3e. compose-worker-prompt.sh re-parses what prepare-issue-artifacts.sh already published

`compose-worker-prompt.sh:689-750 extract_acceptance_commands` (62 LOC) + `673-684 add_acceptance_command` (12) is a near-copy of `prepare-issue-artifacts.sh:244-300 extract_acceptance_to_file` (the `diff -w` shows the latter is the *stricter* one: trims whitespace, rejects control chars, enforces `^[A-Za-z0-9_./:=\ -]{1,120}$`, de-duplicates). prepare-issue-artifacts publishes `<worktree>/.agent/acceptance.txt` in **all** boundary modes (its usage line 56), and compose-worker-prompt does not read that file at all (`grep -n acceptance.txt` → 0 hits). Replacing the parser with a ≤5-line reader of `acceptance.txt` deletes 74 lines: **net −69**, and removes a *weaker* validator. Pinned by test-compose-worker-prompt / test-compose-worker-prompt-scope (both fixture `acceptance.txt`? — `test-compose-worker-prompt.sh` mentions the file; `-scope` does not: its fixtures must be checked for a spec-without-acceptance.txt case before doing this). Conventions: none. Risk: medium (fixture dependency).

### 3f. Families verified as NOT worth consolidating (listed so nobody re-derives them)

* `create-issue-worktree.sh:87-105` ≡ `pr-worktree.sh:49-67` (19 lines, `diff -w` IDENTICAL) — it is the `-h|--help` / `--` / `*` tail of the argv `case` plus `validate_args` head; C1/C2 require the `case` to stay in-script.
* `run-dir.sh:63-84` ≡ `verification-baseline.sh:73-94` (22 lines IDENTICAL) — covered by 3a (die/die_usage/require_value) plus the `--)` one-liner shared by 47 scripts.
* `chain-advance.sh:690-701` ≡ `gh-pr-state.sh:811-822` (11-line jq `def bucket`) — chain-advance sources no lib; net would be 22 − 12 − 2 = 8. Skip.
* `authorize-queue.sh:221-236` ~ `pr-queue.sh:161-175` (mktemp/trap/provider preamble) — differ in 4 lines; skip.
* `die_on_gh_failure` gh-pr-state 294-303 / pr-queue 47-55 — both source `gh-budget.sh`; differ in `first_error` vs `$2`, `PROGNAME` vs `PROGRAM`, `gh` vs `$GH_BIN`: net ≈ +19 − 9 − 2 − (variance) ≈ 6. Skip.
* `materiality-check.sh` (parallel-issues, 179 lines) vs `materiality-check.sh` (review-remote-pr, 124 lines): `diff -w` = 163 changed lines; only `is_skip_eligible_path` (12 LOC, 0.60 similar) overlaps. Not a duplicate.
* `resolve_repo` (gh-comment 22 / gh-pr-state 21), `cleanup` ×7, `resolve_gh_comment_script`, `validate_run_dir`, `dir_writable` (agent-run 12 vs agent-preflight 7 — different probes): all < 0.6 similarity.
* Argument-parsing loops: 47 scripts share the identical one-liner `--) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" … exit 2; }; break ;;` — 1 line each, cannot leave the script (C2).
* SCRIPT_DIR resolution: 17 different spellings of `$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)`; 1 line each; no saving.
* `gh api` retry/budget wrappers: only gh-budget.sh (3 callers) — no duplicates. Contract-read invocations: worktree-commit ×5, compose-worker-prompt ×2, agent-preflight ×1 — all different keys. mktemp+trap: 47 traps, each bespoke to its temp names.

---

## 4. `--help` / `usage()` text

55 `usage()` functions, 1,311 lines. 12 exceed 40 lines (707 lines):

| file | usage LOC | parser flags | flags in usage | prose files mentioning the script (lines) | flags documented in both | parser flags missing from usage |
|---|---|---|---|---|---|---|
| review-remote-pr/scripts/gh-pr-state.sh | **102** | 14 | 14 | 7 files / 36 lines | 12 | — |
| .shared/scripts/worktree-commit.sh | 71 | 13 | 13 | 4 / 23 | 7 | — |
| parallel-issues/scripts/move-github-project-item.sh | 64 | 7 | 7 | 3 / 6 | 4 | — |
| review-remote-pr/scripts/claude-adversarial-review.sh | 63 | 17 | 14 | 1 / 1 | 0 | `--base-ref --consent-payload --state`(alias) |
| review-remote-pr/scripts/post-receipt.sh | 61 | 18 | 17 | 3 / 21 | 17 | `--comments`(alias) |
| .shared/scripts/agent-run.sh | 59 | 12 | 12 | 6 / 53 | 4 | — |
| review-remote-pr/scripts/code-quality-state.sh | 59 | 14 | 12 | 3 / 9 | 9 | `--repository`(alias) |
| review-remote-pr/scripts/codex-adversarial-review.sh | 49 | 18 | 15 | 0 | 0 | `--base-ref --consent-payload --state` |
| .shared/scripts/agent-preflight.sh | 46 | 8 | 8 | 4 / 21 | 4 | — |
| review-remote-pr/scripts/gh-comment.sh | 46 | 8 | 8 | 2 / 8 | 4 | — |
| pr-to-green/scripts/review-transition.sh | 45 | 10 | 9 | 2 / 7 | 6 | — |
| parallel-issues/scripts/prepare-issue-artifacts.sh | 44 | 5 | 5 | 1 / 1 | 1 | — |

Duplication between `--help` and prose is real but shallow: prose mentions carry the *invocation* (`--pr N --repo …`), not the option table. Heavy overlap sits **inside the same script** (header ↔ usage, §1) — e.g. gh-pr-state's "Counting rules" (usage 233–277, 45 lines) re-explains the digest legend of header 50–63 and the `provider`/`agent-docs` paragraphs of `review-remote-pr/references/provider-rules.md`.

**Proposal U1** — cut the five usages that exceed 60 lines to ≤ 40 by dropping "Behaviour/Output/Examples" sections that repeat the option table or the header: gh-pr-state 102→45 (−57, drop Counting rules to a 10-line legend), worktree-commit 71→45 (−26: Behaviour 114–122 + Examples 127–132 duplicate Options), move-github-project-item 64→40 (−24), claude-adversarial-review 63→45 (−18: Output/Exit sections are §1's duplicate — keep them *here* and delete the header copy), post-receipt 61→45 (−16). **−141 lines**, no convention touched (`-h|--help` exit codes unchanged; tests assert only `Usage:` presence and rc). Risk: low.

Flags parsed but absent from `usage()` are **all aliases** (`--comments`≡`--issue-comments`, `--worker-id`≡`--issue`, `--tree-root`≡`--chain-base`, `--artifact`≡`--threads-artifact`, `--part`≡`--body-file`, `--dispatch-plan`≡`--merge-plan`, `--repository-visibility`≡`--visibility`, `--repository`≡`--repo`, `--repo-root`≡`--worktree`/`--dir`, `--state`≡`--consent-state`). None is dead: `review-remote-pr/references/grooming.md` still calls `--repository`, and C1 counts files by the presence of `--repo)`/`--repo-root)` branches (22 vs floor 21). Leave them.

---

## 5. Dead / single-caller / unused

* **Dead function:** `.shared/scripts/worktree-commit.sh:434-436 scope_paths()` — defined, never called (only `scope_paths_for` and `authorized_scope_paths` are used; verified `grep -rn scope_paths agentkit tests`). **−3 LOC**, no test references it.
* `emit_progress` (claude 478-513, codex 397-431) looked dead in-file but is called by `review_poll_progress` in `lib/adversarial-review.sh:143` — **not dead**.
* Every `lib/*.sh` function has ≥1 external caller (`analysis` "LIB inventory"); `worktree_setup_prepare_agent_dir` is lib-internal (called at 198/286), `worktree_setup_common_dir`/`_exclude_path` are internal + pinned by test-worktree-setup.
* **Env vars read but set nowhere** (scripts, skills/*.md, tests): `AGENT_MULTI_AGENT`, `MULTI_AGENT`, `SPAWN_CAPABILITY` (concurrency-cap.sh:49 — harness probes, keep), `REPOSITORY_VISIBILITY` (select-boundary-mode.sh:7), `MERGE_GATE_SCAN_ROUNDS` (merge-gate.sh:26), `PR_QUEUE_SETTLE_ROUNDS` (pr-queue.sh:437), `COMPOSE_REVIEW_AGENT_IDENTITY` (compose-review-reply.sh:26), `THREAD_ACTION_AGENT_IDENTITY` (thread-action.sh:29), `THREAD_ACTION_COMPOSER` (thread-action.sh:16). These are undocumented tunables; each is a `${VAR:-default}` expansion inside an assignment that stays, so deleting them saves 0–1 line each (≤ 6 total). `SSL_CERT_*`/`REQUESTS_CA_BUNDLE`/`CURL_CA_BUNDLE`/`NODE_EXTRA_CA_CERTS` are standard external env — keep.
* **Options parsed but never used:** none (the alias list in §4 is the complete set of usage-undocumented flags; every assigned variable is referenced).
* Scripts with **zero test coverage**: `.shared/scripts/harness-advice.sh` (172 lines), `lib/gh-budget.sh`, `lib/trunk-policy.sh` — noted only because their behavior is not pinned, so edits there carry more risk, not less.

---

## 6. Python heredocs

Exactly **one**: `.shared/scripts/validate-handback.sh:38-622` — `exec python3 - "$PROTECTED_LIB" "$REPO_CONFIG" "$@" <<'PY'`, 585 lines (the whole script is a Python program in a bash wrapper; lines 1–37 are the bash shim). It parses `.agent/config.env` via repo-config and validates a handback record; not expressible in jq in fewer lines. No other script embeds Python (`python3` mentions in agent-preflight/detect-toolchains/onboard-state are toolchain names). No snippet is shared between two scripts. **Nothing to cut here.**

---

## 7. The five largest scripts — LOC map and top-3 cuts

### 7.1 `.shared/scripts/agent-run.sh` — 1,627 lines (1,267 code / 257 comment), 58 functions = 1,123 lines, top-level 504

Function → LOC (largest first): try_baseline_exclusion 122 (1130-1251), resolve_named_command 89 (814-902, 29 comment lines), repo_config_resolve_keys 70 (689-758), usage 59, compose_project_hardcodes 53 (510-562), hash_untracked_files 43, format_failure_paths 36, register_suite_run 35, report_failure 33, resolve_literal_executable 28, apply_test_focus 27, compute_tree_hash 26, select_caches 25, detect_ca 25, configure_compose_project 25, remove_baseline_exclusion 23, compose_argv 22, record_verification 20, resolve_runner 20, resolve_declared_runner 18, verification_cache_hit 18, choose_log 16, python_source_roots 15, set_pythonpath 15, maybe_use_package_dir 15, compose_repo_has_compose_file 13, dir_writable 12, warn_if_root_readonly 12, absolutise_path_args 11, current_process_start 11, sanitize_baseline_path 11, repo_config_get 10, compose_static_value 10, ... 26 functions ≤ 9 LOC.

Top-3 cuts:
1. **try_baseline_exclusion 122 → ~95 (−27).** The `rm -f -- "$baseline_output"; rm -rf -- "$baseline_dir"; return 1` triple appears 5× (1162-1178, 1187-1191) and the per-path "blob unchanged at base" check (1146-1152) is repeated verbatim inside the loop (1210-1221): one `baseline_abort()` and one `path_unchanged_at_base()` local helper. Pinned by test-agent-run-baseline-exclusion / test-agent-run-cmd (`BASELINE-EXCLUDED:` line). Risk low.
2. **Comments: header 24→8 (−16), resolve_named_command 29 comment lines →8 (−21), top-level essays 134-144 (11), 564-576 (13), 1267-1276 (10), 1374-1387 (14 — #287, pinned by test-agent-run-focus), 1545-1555 (11) → 3 each (−44). Total −81.** Risk low.
3. **`die`/`dir_writable` → nothing to share** (agent-run's dir_writable is the redirect-order probe, agent-preflight's is mktemp; different). Instead: usage 59 → 45 by dropping the Examples block 87-91 and the duplicated Repository-declarations lines 74-80 that `repo-config.sh --list-keys` documents (−14). Risk low.
Total for agent-run: **≈ −120**.

### 7.2 `.shared/scripts/agent-preflight.sh` — 1,484 lines (954 code / **451 comment = 47 %**), 48 functions = 1,094 lines, top-level 390

Function → LOC: main 88 (1395-1482), probe_gh 63 (20 comment), probe_git 53 (16 comment), probe_instructions 51, probe_sandbox 49, usage 46, probe_identity 45, probe_caches 43, inherit_or_probe 42, node_roots 41, parse_args 40, apply_never_widen 35, write_block 35, probe_runtime_pin 34, caches_restriction_score 31, compute_inherit_session_state 28, probe_tls 28, resolve_repo_runner 26, probe_config 23, probe_protected 23, router_references 22, parse_repo_slug 20, py_roots 19, detect_base 16, resolve_node_pm_for_root 16, probe_runners 15, probe_peer_cli 15, ... 21 functions ≤ 12.

Top-3 cuts:
1. **Essays.** 20 blocks ≥ 8 lines = 273 lines (113 inside functions). Largest: 881-928 (**48 lines** of #332 F3/#372 narrative over `readonly INHERIT_SESSION_MAX_AGE_MINUTES=30`), 965-981 (17), 2-32 header (31), 1306-1317 (12), 1334-1343 (10), 507-515, 539-547 (9 each), plus the 10 in-function blocks of §2. Cap at 4 lines each: **−193**. All pinned by test-agent-preflight (14 suites) + test-session-contract-freshness + test-srisk-helpers (`--ensure` byte/inode/mtime). Risk low.
2. **Guarded lib sourcing 79-117 (39 lines, four copies of `X_LIB="$(cd -- … && pwd -P)/lib/x.sh"; if [[ -r … ]]; then source …; fi` each with a 5-line comment) → one 7-line `for lib in protected-paths sandbox-comparator skills-content-hash secure-mkdir; do …; done` (the per-lib variable names are used later only as `-r` guards → replace with `declare -F`). −32.** Risk low-medium (secure-mkdir uses `readlink -f` in its path; keep that spelling for all four).
3. **probe_gh 63 / probe_git 53 / main 88: 52 comment lines between them → ≤ 15 (−37).** Risk low.
Total: **≈ −260**. (Shared code: none — its `die`/`need_value` are the 5-copy variants of §3a; `dir_writable` differs from agent-run's.)

### 7.3 `review-remote-pr/scripts/gh-pr-state.sh` — 1,364 lines (981 code / 328 comment), 42 functions = 981 lines, top-level 383

Function → LOC: usage **102**, main 63, thread_counts 60, wait_for_ci 54, fetch_meta 48, fetch_threads 43, print_digest 43, parse_args 41, fetch_base_state 34, provider_state 33, fetch_ci_only 31, print_thread_lines 31, full_cache_load 30, acceptance_status 29, validate_args 27, print_ci_line 26, full_cache_save 25, save_artifacts 25, base_advance_is_automation_only 23, ci_counts 23, resolve_repo 21, alert_count 19, matches_automation_path 13, print_issue_comment_findings_line 13, fetch_all 12, print_acceptance_lines 12, die_on_gh_failure 10, print_next_lines 10, ... 14 functions ≤ 9.

Top-3 cuts:
1. **Header 73 → 8 (−65)** — 5-48 is the #396/#578/#394 rationale that test-gh-pr-state pins; 50-63 digest legend is repeated by usage's Counting rules. Risk low.
2. **Comment prose in the preamble and cache section:** 75-178 carries 50 comment lines over 50 code lines (constant definitions each with a 3–6-line justification); 704-730 (27-line cache essay); 950-974 (25-line provider_state essay); 866-876, 899-912. Cap each at 4: **−95**. Risk low.
3. **usage 102 → 45 (−57)** per U1; plus `die`/`die_usage`/`require_value`/`note` → lib (§3a review-remote-pr subset, −10 net). Risk low.
Total: **≈ −225**. Shared-code candidates that already exist: `gh_budget_*` (already used); `ci_counts`' jq `bucket` is duplicated in chain-advance (§3f, skipped).

### 7.4 `parallel-issues/scripts/compose-worker-prompt.sh` — 1,329 lines (1,023 code / 254 comment), 33 functions = 589 lines, **top-level 740**

Function → LOC: extract_acceptance_commands 62, extract_spec_steps 61, emit_acceptance_declarations 38, emit_image_invalidating_writers 37, match_spec_step 35, emit_commands 31, scope_commands 28, emit_spec_command_precedence 23, validate_setup_artifact_contract 22, assess_dispatch_plan_record 19, emit_focus 18, command_uses_compose 15, write_set_reaches_rundir 14, spec_step_covers_declaration 14, emit_trust_rule 14, emit_boundary_disclosure 13, add_acceptance_command 12, spec_step_names_other_component 12, cache_scoped_command_tokens 11, query_test_resolution 11, resolve_spec_steps 11, is_verification_key 10, glob_literal_prefix 10, emit_write_set 10, emit_boundary_rule 10, spec_significant_tokens 9, usage 8, compose_reachable 7, read_command_argv 6, shell_quote 5, spec_step_tokens 5, emit_compose_isolation 4, emit_blocker_contract 4. Top-level: 15-188 argv+setup (143 code), 227-325 boundary/contract checks (61 code / 33 comment), 1072-1329 template substitution (226 code).

Top-3 cuts:
1. **Read `.agent/acceptance.txt` instead of re-parsing the spec (§3e): −69.** Pinned by test-compose-worker-prompt (fixtures `acceptance.txt`), test-parallel-dispatch-contract. Risk medium (check `-scope` fixtures).
2. **Template substitution 1090-1329: 18 `if [[ $line == '__TOKEN__' ]]; then emit_x; continue; fi` blocks (4 lines each) → one `case $line in __DECLARED_COMMANDS__) emit_commands ;; …` table (1 line each): −54.** Pinned by test-compose-worker-prompt-scope (rendered prompt bytes unchanged). Risk low.
3. **Essays 229-239 (#334/#359), 269-276, 360-373 (#336), 459-468, 523-530, 648-661 (#337), 841-861 (#336, 21 lines), 911-919 = 95 lines → 3 each: −71.** Risk low.
Total: **≈ −194**. Existing lib already used: `sandbox-comparator.sh`. Its `shell_quote` (5) duplicates `repo-config.sh:819-821` (3) — not worth a source line.

### 7.5 `parallel-issues/scripts/chain-advance.sh` — 1,076 lines (807 code / 216 comment), 38 functions = 822 lines, top-level 254

Function → LOC: recover_closed **107** (958-1064, 19 comment), retarget 67, refresh_code_scanning 63, parse_args 56, check_ci_fresh 52, cover_retarget_lineage 34, check_ci 31, check_ancestry 28, base_advance_is_generated_only 25, resolve_check_run_slugs 24, persist_boundary 23, code_scanning_refresh_needed 21, resolve_local_repo_slug 20, usage 19, validate_args 19, describe_approval 19, resolve_review_provider_names 18, is_provider_residue_check 18, boundary_for 17, timeline_boundary 17, persisted_boundary 13, matches_generated_path 13, parse_origin_slug 11, path_has_no_symlink 11, resolve_generated_paths 10, ... 13 functions ≤ 9.

Top-3 cuts:
1. **Essays (13 blocks, 137 lines): 467-492 (26, #572/#577), 546-559 (14, #455), 836-846 (11, #564/#567), 950-957 (8, #484/#561/#564), 981-990 (10, #564 F3), 303-310, 347-355, 405-413, 439-447, 614-621, 648-656, 38-45 → 3 each: −98.** All pinned by test-chain-advance, test-pr-to-green-merge-pr, test-pr-to-green-authorize-queue. Risk low.
2. **parse_args 56 → 38 (−18):** `--pr`/`--base`/`--repo` each spend a 5-line branch + a 1-line `=*` branch; group as `--pr|--base|--repo) require_value "$1" "${2-}"; …` the way compose-worker-prompt.sh:36-56 does. Keeps the literal `--repo)` and `--base)` tokens the C1 grep needs (`--repo)` must remain a separate pattern-list member — `--pr|--base|--repo)` still matches `--repo\)`). Pinned by test-chain-advance. Risk low.
3. **recover_closed 107 → 88 (−19 comment lines to ≤ 4) and `die` (8 LOC, a `$1`-code variant) + `require_value` → §3a lib (−9 net if the review-remote-pr-style lib is adopted).** Risk low.
Total: **≈ −144** (98 essays + 18 parse_args + 19 recover_closed comments + 9 die/require_value lib — recomputed 2026-09-08, the original −125 dropped the essay figure).

---

## 8. Ranked proposals

Net figures are lines of the 32,331 total. "Conv." = which of C1–C4 the change touches (— = none).

| rank | proposal | files | LOC before | LOC after | net saved | conv. | risk |
|---|---|---|---|---|---|---|---|
| 1 | **H1** Trim the 27 headers > 15 lines to ≤ 8 (purpose + pointer); keep Usage/exit tables only where `usage()` is absent | 27 (§1 table) | 863 header lines | 252 | **−611** (−647 aggressive) | — | low (comment-only; no test reads headers) |
| 2 | **E2** Cap the 12 top-level essays ≥ 15 lines (agent-preflight 881-928, 965-981; gh-pr-state 704-730, 950-974; chain-advance 467-492; compose-worker-prompt 841-861; adversarial-run 227-246, 611-628; run-dir 136-156; sandbox-comparator 29-48; verification-baseline 181-196; review-ledger 271-287) at 4 lines | 8 | 262 | 48 | **−214** | — | low |
| 3 | **E1** Cut the 30 in-function essays (§2) to ≤ 3 lines | 12 | 297 | 90 | **−207** | — | low (every one is pinned by a named suite) |
| 4 | **D1** `die`/`die_usage`/`die_blocked`/`die_evidence`/`require_value` into one existing lib for all 46 scripts | 46 + 1 lib | 286 | 96 (20 lib + 76 source/SCRIPT_DIR lines) | **−190** | C1/C2 untouched; exit-code variants need `DIE_EXIT` | **medium** (46 new sibling-lib dependencies; knob-style abstraction) |
| 4′ | **D1-lite** same, only the 16 review-remote-pr scripts that already `source` a lib | 16 + 1 lib | 84 | 20 | **−64** | — | low |
| 5 | **U1** Cut the five usages > 60 lines to ≤ 45 (drop Behaviour/Examples/Counting-rules that repeat the option table) | 5 | 361 | 220 | **−141** | — | low |
| 6 | **A1** Claude/Codex twins: move the 8 byte-identical functions + verify_consent + common validate_args block into `lib/adversarial-review.sh` | 2 + 1 lib | 2×(24+7+6+5+5+4+4+3+17+28)=206 | 105 | **−101** (−58 for the identical-only subset, −144 with emit_progress/write_review_input) | — (parse_args stays) | low |
| 7 | **P1** agent-preflight: fold the four guarded `source` blocks 79-117 into one loop | 1 | 39 | 7 | **−32** | — | low-med |
| 8 | **A2** agent-run try_baseline_exclusion: `baseline_abort()` + `path_unchanged_at_base()` | 1 | 122 | 95 | **−27** | — | low |
| 9 | **C1** compose-worker-prompt template substitution → `case` table | 1 | 72 | 18 | **−54** | — | low |
| 10 | **C2** compose-worker-prompt reads `acceptance.txt` instead of re-parsing | 1 | 74 | 5 | **−69** | — | medium (fixture check) |
| 11 | **F1** `file_mode`/`run_dir_mode`/`reject_writable_by_others` → `lib/private-dir.sh` | 5 + 1 lib | 79 | 26 | **−53** | — | low-med |
| 12 | **G1** chain-advance parse_args grouping | 1 | 56 | 38 | **−18** | C1 (keep `--repo)` literal — grouped pattern still matches) | low |
| 13 | **V1** completed-result jq predicate → `lib/adversarial-review.sh` | 3 + 1 lib | 45 | 21 | **−24** | — | medium (lib top-level side effects) |
| 14 | **X1** delete dead `scope_paths()` worktree-commit.sh:434-436 | 1 | 3 | 0 | **−3** | — | none |
| — | Alias flags, `--)` one-liners, SCRIPT_DIR spellings, materiality-check pair, ci `bucket` jq, python heredoc | — | — | — | 0 | C1/C2 forbid or net ≤ 8 | — |

Sum of the low-risk rows (1, 2, 3, 4′, 5, 6, 7, 8, 9, 12, 14): **≈ −1,472 lines (4.6 % of 32,331; 28 % of all comment lines)** without adding a file, gate, rule, or round trip — recomputed 2026-09-08 from the corrected row 1 (H1, −611) and row 4 (D1, −190) figures above; the original ≈ −1,420/−1,700 pair carried the stale 771/294 totals. Adding the medium-risk rows (4 instead of 4′, 10, 11, 13): **≈ −1,744**.

Skepticism notes: every "identical" claim above was checked with `diff -w` on the extracted ranges (§3 tables state the outcome); `emit_progress` and the lib functions flagged as "dead" by in-file reference counting were re-verified across the tree and are **not** dead; the usage-vs-prose overlap (§4) is mostly invocation lines, not option tables, so I did not count it as savings.

---

## 9. Reproduction commands

```bash
S=/home/adam/github/agent-kit/agentkit/skills; D=<scratchpad>/size-audit
# per-file sizes (pre-existing, not re-run): python3 measure.py $D  -> sh-sizes.csv (= helpers-sizes.csv)
python3 $D/analyze.py $D/analysis.json > $D/analysis.txt      # headers, usage(), function LOC maps, essays, dead fns, sources, argv/trap/mktemp lines
python3 $D/dupfn.py 6 > $D/dupfn.txt                          # A1 exact fn-body dups, A2 same-name similarity (difflib), C sliding-window (6 normalized code lines) cross-file blocks
(cd $S && python3 - <<'EOF' ... ) > $D/md-vs-usage.txt         # usage() flags vs parser flags vs .md mentions (script embedded in md-vs-usage section of this session; see file header)
# diff-verification examples
x(){ sed -n "$2p" "$1"; }; cd $S
diff -w <(x pr-to-green/scripts/authorize-queue.sh 28,52) <(x pr-to-green/scripts/merge-pr.sh 40,64)          # file_mode/reject: identical modulo comment
diff -w <(x parallel-issues/scripts/create-issue-worktree.sh 87,105) <(x review-remote-pr/scripts/pr-worktree.sh 49,67)   # IDENTICAL
diff -w <(x review-remote-pr/scripts/run-dir.sh 63,84) <(x review-remote-pr/scripts/verification-baseline.sh 73,94)      # IDENTICAL
diff -w <(x review-remote-pr/scripts/claude-adversarial-review.sh 384,407) <(x review-remote-pr/scripts/codex-adversarial-review.sh 311,334)  # verdict_schema IDENTICAL
diff -w <(x review-remote-pr/scripts/claude-adversarial-review.sh 286,320) <(x review-remote-pr/scripts/codex-adversarial-review.sh 246,280)  # validate_args common block
diff -w parallel-issues/scripts/materiality-check.sh review-remote-pr/scripts/materiality-check.sh | grep -c '^[<>]'   # 163 -> not a duplicate
# conventions
grep -lE -- '--repo\)|--repository\)|--repo=\*|--repository=\*' $S/*/scripts/*.sh $S/.shared/scripts/*.sh | wc -l   # 22 (floor 21)
grep -lE -- '--repo-root\)|--dir\)|--repo-root=\*|--dir=\*'   $S/*/scripts/*.sh $S/.shared/scripts/*.sh | wc -l   # 29 (floor 20)
find $S -type f -name '*.sh' -perm -111 | wc -l                                                                    # 66
grep -c 'shift; (( $# == 0 )) || { printf "%s: unexpected argument after --' -r --include='*.sh' $S | grep -vc ':0$'   # 47
# dead / callers
grep -rn 'scope_paths\b' $S /home/adam/github/agent-kit/tests   # only the definition at worktree-commit.sh:434
grep -rn 'emit_progress' $S                                      # lib/adversarial-review.sh:143 calls it
grep -rnE 'python3? +-c|python3? *- *<<|python3 - ' --include='*.sh' $S   # validate-handback.sh:38 only
# tests referencing each script
for f in $S/*/scripts/*.sh $S/.shared/scripts/*.sh $S/.shared/scripts/lib/*.sh; do b=$(basename $f); echo "$(grep -l -- "$b" /home/adam/github/agent-kit/tests/*.sh | wc -l) $b"; done | sort -n
```
