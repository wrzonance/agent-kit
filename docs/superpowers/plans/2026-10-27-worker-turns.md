# Worker Turns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the six kit-made worker turns measured on 08c2516 without changing what a worker must prove.

**Architecture:** Three helper changes (`ci` lists threads on green, `receipt` takes findings as arguments, `review` prints whole finding lines), one render change (`{{SETUP}}` placeholder), and prose changes in both templates and both skills. Every change is pinned by the existing `tests/v2` suites.

**Tech Stack:** Bash 5.2, the `tests/v2` fake `gh`, Markdown templates.

**Spec:** `docs/superpowers/specs/2026-10-27-worker-turns-design.md`

## Global Constraints

- `tests/v2/lint-budget.sh`: skills ≤ 120 lines, all v2 markdown ≤ 40960 bytes, `bin`+`lib` ≤ 5000 lines.
- `tests/v2/test-plan.sh` allows only the placeholders the composers substitute; a new one is added to that list and to both composers.
- Refusals stay two lines (`ak: cause` / `fix: command`); exit 2 for bad input, 1 for evidence.
- `LC_ALL=C` on every `sort`/`comm`; ShellCheck 0.11.0 `-S style` clean.
- No change to review requirements, CI semantics, receipt refusals or acceptance criteria.

## Review Focus

- A green `ak ci` whose thread read fails must not read as "no threads": it prints `threads=?` with a fix line, and the receipt still refuses on open threads (Task 3).
- `ak receipt` with no findings arguments while the review has findings must refuse, never post "none" (Task 4).
- A merge-down worker that runs `ak receipt` alone must reuse the earlier `.ak/findings` (Task 4).
- A finding line from the reviewer that is longer than 200 characters or contains the `—` separator in its title must still print once, cut, and still count (Task 5).
- A repository with `AGENT_CMD_SETUP` set must still get the setup step in both rendered playbooks (Task 2).

---

### Task 1: Playbook prose: Tests section and skill lookups

**Files:**
- Modify: `v2/templates/issue-worker.md` (header paragraph, step 3)
- Modify: `v2/templates/pr-worker.md` (header paragraph)
- Modify: `v2/skills/issues/SKILL.md:21-22`, `v2/skills/pr/SKILL.md:25-26` (spawn message)
- Test: `tests/v2/test-plan.sh` (template content block near line 745)

- [x] **Step 1: Write the failing assertions** in `tests/v2/test-plan.sh` after the placeholder check:

```bash
assert_not_contains "$(cat "$real")" 'commands, results' 'the Tests line does not ask for the run output ak ship refuses'
assert_contains "$(cat "$real")" 'what each test file proves' 'the Tests line matches the ship gate'
for f in "$real" "$REPO/v2/templates/pr-worker.md" "$REPO/v2/skills/issues/SKILL.md" "$REPO/v2/skills/pr/SKILL.md"; do
    assert_contains "$(cat "$f")" 'skill' "$(basename "$f") tells the worker skill lookups are unnecessary"
done
```

- [x] **Step 2: Run** `bash tests/v2/test-plan.sh` — expect the four new assertions to fail.
- [x] **Step 3: Edit the prose.** Step 3 `## Tests` bullet: "per test file, what it proves; no commands or status lines." Header of both templates: "This playbook is complete: skip skill and guide lookups; the repository's own instructions still apply." Spawn message in both skills: append "The playbook is complete; skip skill lookups."
- [x] **Step 4: Run** `bash tests/v2/test-plan.sh && tests/v2/lint-budget.sh` — PASS.
- [x] **Step 5: Commit** `docs(v2): align the Tests line with the ship gate and tell workers skill lookups are unnecessary`.

### Task 2: Setup step renders only when configured

**Files:**
- Modify: `v2/lib/common.sh` (add `setup_step`)
- Modify: `v2/lib/plan.sh:327`, `v2/lib/pr-plan.sh:63` (substitute `{{SETUP}}`)
- Modify: `v2/templates/issue-worker.md:22`, `v2/templates/pr-worker.md:17`
- Test: `tests/v2/test-plan.sh`, `tests/v2/test-pr-plan.sh`

**Interfaces:**
- Produces: `setup_step` in `common.sh`: prints "Run \`ak setup\`. " when `cfg AGENT_CMD_SETUP` is non-empty, else nothing.

- [x] **Step 1: Write the failing assertions.** In `test-plan.sh` after the first rendered prompt (`prompt=$(cat "$wt/.ak/prompt.md")`, line 43): `assert_not_contains "$prompt" 'ak setup' 'no setup command, no setup step'`; add `SETUP` to the placeholder allow-list. Add a plan run with `AGENT_CMD_SETUP='true'` on a fresh issue and assert the prompt contains "1. Run \`ak setup\`." In `test-pr-plan.sh` after line 49: `assert_not_contains "$prompt" 'ak setup'`; a second render with `AGENT_CMD_SETUP=true` contains it.
- [x] **Step 2: Run** both suites — FAIL.
- [x] **Step 3: Implement.** `setup_step()` in `common.sh`; `text=${text//"{{SETUP}}"/"$(setup_step)"}` in both composers; templates read `1. {{SETUP}}If \`.ak/resolve\` exists: …`.
- [x] **Step 4: Run** both suites — PASS.
- [x] **Step 5: Commit** `perf(plan): render the setup step only when a setup command is configured`.

### Task 3: `ak ci` lists open threads on green

**Files:**
- Modify: `v2/lib/ci.sh` (`ci_blocked` records `CI_PR`; new `ci_threads`; `cmd_main` green/none paths)
- Modify: `v2/templates/issue-worker.md` step 6, `v2/templates/pr-worker.md` step 6
- Test: `tests/v2/test-ci.sh`

**Interfaces:**
- Consumes: `threads_open SLUG N`, `threads_summary` from `threads.sh` (source it at the top of `ci.sh`; `receipt.sh` already sources both, and `cmd_main` is defined last in each file).
- Produces: after `ci=green…` or `ci=none…`, one line `threads=N` (`N` open threads) followed by `thread=ID author path:line: text` lines; `threads=? note=could not read the review threads; run ak threads` when the read fails. Nothing when the branch has no open PR.

- [x] **Step 1: Write the failing assertions.** The existing exact-match green assertions (`assert_eq 'ci=green checks=2 failing=' "$out"`) become two-line expectations only where a PR is routed; where `$prs` answers `[]` there is no PR and no threads line, so those stay. Add: with `set_pr … clean`, `assert_eq $'ci=green checks=1 failing=\nthreads=0'`; route one open thread for PR 12 and assert `threads=1 note=…` plus the `thread=T1 …` line; route the graphql call to exit 1 and assert `threads=? note=` with `fix:`-free single line and rc 0; `ci=none` with a PR also prints `threads=0`.
- [x] **Step 2: Run** `bash tests/v2/test-ci.sh` — FAIL.
- [x] **Step 3: Implement** `ci_threads PR` and call it from `cmd_main` for the green and none returns, after the summary line.
- [x] **Step 4: Playbook step 6** (both templates): "`ak ci` green lists open threads (`thread=ID …`). Fix (verify, ship) or decline each, then `ak threads --resolve ID --note …`. Open threads block the receipt." Drop "Run `ak threads`."
- [x] **Step 5: Run** `bash tests/v2/test-ci.sh tests/v2/test-receipt.sh tests/v2/test-threads.sh` — PASS.
- [x] **Step 6: Commit** `perf(ci): list open review threads with the green verdict`.

### Task 4: `ak receipt` takes findings as arguments

**Files:**
- Modify: `v2/lib/receipt.sh` (`cmd_main` argument parsing; `receipt_findings` reads a string)
- Modify: both templates, step 6
- Test: `tests/v2/test-receipt.sh`

**Interfaces:**
- Produces: `ak receipt [--finding LINE]... [--findings FILE] [--remaining TEXT]`. Lines from `--finding` and the file are concatenated. With neither: an existing regular `.ak/findings` is used; else when `.ak/review.md` has no `P1:`/`P2:` line or `.ak/review.unavailable` exists, findings are `none`; else `die "the review has N findings and no dispositions were given" "ak receipt --finding 'P1|title|fixed <sha>' --finding 'P2|title|declined: reason'"`. The decided lines (or `none`) are written to `.ak/findings` before posting.

- [x] **Step 1: Write the failing assertions.** Replace `assert_eq 2 "$rc" 'receipt without --findings is a usage error'` with: a review holding two findings and no arguments → rc 1, output contains `no dispositions were given` and `fix: ak receipt --finding`; `--finding 'P1|null deref in parser|fixed abc1234' --finding 'P2|rename helper|declined: churn outside the issue'` → rc 0 and `.ak/findings` holds both lines; then `ak receipt` with no arguments reuses `.ak/findings` (result note still `findings=2`); with `review.md` saying `NO FINDINGS`, bare `ak receipt` → rc 0, receipt says `Findings: none`.
- [x] **Step 2: Run** `bash tests/v2/test-receipt.sh` — FAIL.
- [x] **Step 3: Implement** in `receipt.sh`: collect `lines` from `--finding`, append the file's content, `receipt_findings` reads from a here-string, the fallbacks above, write `.ak/findings` (`rm -f` first so a link is never written through).
- [x] **Step 4: Playbook step 6** (both templates): "Run `ak receipt`, with `--finding "P1|<title>|fixed <sha>"` or `--finding "P2|<title>|declined: <reason>"` per review finding (either severity, either disposition); none needed when the review had no findings. On merge-down, `ak receipt` alone reuses the earlier findings." Keep `--remaining`.
- [x] **Step 5: Run** `bash tests/v2/test-receipt.sh` — PASS.
- [x] **Step 6: Commit** `perf(receipt): take findings as arguments and need none for a clean review`.

### Task 5: `ak review` prints whole finding lines

**Files:**
- Modify: `v2/lib/review.sh` (`review_titles` → whole line, cut at 200 chars)
- Modify: `v2/templates/pr-worker.md` step 2
- Test: `tests/v2/test-review.sh`

- [x] **Step 1: Write the failing assertions.** Flip `assert_not_contains "$out" 'loops past end' 'only titles are printed'` to `assert_contains … 'the whole finding line is printed'`; the reuse exact-match line gains the location and reason; add a 300-character finding and assert its printed line is 200 characters or fewer and `findings=1`.
- [x] **Step 2: Run** `bash tests/v2/test-review.sh tests/v2/test-receipt.sh` — FAIL.
- [x] **Step 3: Implement**: `review_titles` prints `"${BASH_REMATCH[1]}: ${BASH_REMATCH[2]:0:200}"`. `receipt_all_decided` counts `^P[12]:` lines in `review.md`, which is unchanged.
- [x] **Step 4: pr-worker.md step 2**: "It prints the findings; for `findings=unparsed`, read `.ak/review.md`."
- [x] **Step 5: Run** both suites — PASS.
- [x] **Step 6: Commit** `perf(review): print each finding whole so workers skip reading review.md`.

### Task 6: Gate, docs, PR

- [x] **Step 1:** `bash tests/v2/run.sh` — all suites PASS, budget ok.
- [x] **Step 2:** `AGENT_TEST_JOBS=4 tests/run-tests.sh` — all suites green except one pre-existing preflight DNS-probe flake, fixed as #1020 (rerun alone: 251/251).
- [x] **Step 3:** Render one issue prompt with the bench fixture paths and record its byte size against 08c2516's 5,974.
- [ ] **Step 4:** Push, open the draft PR (`Closes #1019`), move the issue to In review, and write the adapted benchmark commands (08c2516 versus the candidate SHA) into the PR body.
