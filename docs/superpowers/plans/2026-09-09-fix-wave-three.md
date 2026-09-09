# Fix wave three — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Five open defects, one draft PR each, failing test first. (1) **#680** the gh heredoc lexer drops the owner line of a command that *ends* with a heredoc terminator, so `cat > <foreign>/notes.md <<'EOF' … EOF` passes the scope and write guards unseen. (2) **#643** the composed issue-lead prompt's byte ceiling measures two absolute paths, so the same template passes at one checkout and fails at a longer one. (3) **#607** `chain-advance.sh --retarget` proves the boundary only from a `base_ref_changed` timeline event, but a delete-branch-on-merge repository emits `automatic_base_change_succeeded`; the proof then has to be hand-registered per PR, and `--keep-branch` cannot keep a branch the repository setting deletes. (4) **#606** three hand-authored `.agent/config.env` values pass the validators and surface only mid-run: a `codex-`/`claude-`-prefixed roster entry, a dotted Claude id, and an asymmetric `AGENT_ADVERSARIAL_REVIEWER_FALLBACK`; the `gpt-5.6-*` family glob rejects `gpt-6-*` outright; a valid roster with no entry for the running harness ends a `--yolo` turn. (5) **#609** the adversarial review launches on any diff size, never excludes vendored trees, and re-asks consent for a reduced payload of an already-consented PR.

**Architecture:** Five branches `fix/issue-<N>` from `09af63c`. Four are file-disjoint. **#606 and #609 both touch `review-remote-pr/scripts/adversarial-run.sh` and `tests/test-adversarial-run.sh`** — the hunks are disjoint (see *Overlap ruling*), and #609 is **chained on #606** (`fix/issue-609` branches from `fix/issue-606`, retargets to `main` when #606 merges) so the `adversarial-run.sh` line ceiling is accounted once, sequentially. Every other pair runs in parallel worktrees.

**Tech Stack:** Bash test suite (`tests/run-tests.sh`; `--only NAME[,NAME]` takes `tests/test-*.sh` suite names only), `shellcheck -x -P SCRIPTDIR -S style` on every shipped script, `tests/lint-*.sh agentkit/skills`, `tests/lint-versioned-plugin-paths.sh agentkit`, `gh` over REST, git worktrees under `.worktrees/`.

**Spec:** the five issue bodies in `<scratchpad>/wave3/issue-{680,607,609,606,643}.md`; `#661` (blocked on #680, not in this wave) and `#608` (next wave) read for foreclosure only. Evidence for #680: `.superpowers/sdd/2026-09-08-size-wave-two-helpers-hooks/task-3-report.md` (the K3 report; its `plan2/k3-corpus/` scratch directory **no longer exists on disk** — the scratchpad was cleared — so Task 1 rebuilds the corpus from the report's own recipe). Where an issue body's premise is stale on `09af63c` (wave two rewrote several files), the task says so and plans from the code.

## Global Constraints

- **Repository:** `wrzonance/agent-kit`, trunk `main` at `09af63c` (every wave-two PR merged). Line numbers below are from `09af63c`; **re-anchor with the quoted text before every edit.**
- **Never edit the root checkout** (`~/github/agent-kit`); every task works in `.worktrees/fix/issue-<N>` created from `origin/main` (`git fetch origin && git worktree add .worktrees/fix/issue-N -b fix/issue-N origin/main`), except #609 which branches from `fix/issue-606`.
- **Never commit to `main`.** Branches are `fix/issue-<N>` (#643 is a test-only change and still uses `fix/issue-643`).
- **One PR per task, always `gh pr create --draft`.** PR body opens with `This was written agentically; verify its assertions:`, carries Why / What / Testing checkboxes, and closes with `Closes #N` followed by `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- **Commits:** Conventional Commits `fix(<scope>): …` (#643 is `test(compose-worker-prompt): …`), trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, made with `"$agentkit/.shared/scripts/worktree-commit.sh" --exact -- FILES` where `agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills` — never `git add -A` (`.agent/` carries local state).
- **No new files under `agentkit/`.** `tests/test-helper-end-of-options.sh:30` pins `assert_eq 66 "${#helpers[@]}"` executables. New shell functions go into scripts that exist or into `lib/*.sh` files the callers already `source` (`.shared/scripts/lib/canonical-diff.sh` is sourced by `adversarial-run.sh:19` and `consent-record.sh`; nothing else). No new test files: every red step lives in an existing suite.
- **Ceilings ratchet down, never up.** Every helper line ceiling and reference byte ceiling named below is quoted from the test that pins it. Lines a fix adds are paid for in the same file, or the ceiling moves by the **measured** delta with the reason stated in the test comment and the PR body. After every task the ceiling is set to the measured after-count (no slack) — never above it. The ceiling table in *Self-review* lists every one.
- **`bash -n` + `shellcheck -x -P SCRIPTDIR -S style`** on every touched script before commit; `shellcheck -S style -e SC1091,SC2034` on every touched test (every `tests/test-*.sh` on `main` already reports `SC2034 TEST_NAME appears unused`; the bar is **no new findings versus `main`**). Never delete or move a `# shellcheck disable=` directive.
- **Verification before push:** the owning suites via `--only`, then the full `tests/run-tests.sh`, `tests/lint-skill-size.sh agentkit/skills`, `tests/lint-helper-refs.sh agentkit/skills`, `tests/lint-versioned-plugin-paths.sh agentkit`. **Control set** (measured on an untouched `09af63c` copy under `/tmp`, full `tests/run-tests.sh`, `AGENT_TEST_TIMEOUT_SCALE=3`): 30 failing assertions in 4 suites, all environmental — `bench tier0` 37/6 (needs real git history), `chain-advance` 147/11 (workflow-rerun/CodeQL cases needing a real `.git`), `hooks` 660/12 (the two `command-derived target cannot self-authorize` + ten protected-path classification), `session ledger` 95/1. A worktree under `~/github/agent-kit/.worktrees/` does not show the `hooks` ones. Every red/green count below is stated against this set; a green run is one whose failures are exactly the control set's.
- **GitHub API:** REST via `gh api` for issues/PRs; `"$agentkit/parallel-issues/scripts/move-github-project-item.sh"` for board moves. No other `gh` mutation.
- **North star guard:** every task names the turn, read, or confirmation it removes from a run. Nothing here adds a human round trip; the one new gate (#609 size check) replaces a spent launch with a one-line refusal that names its remedy.
- **Hooks bite the implementer:** the installed 0.7.4 plugin predates K1 only partially; a pasted heredoc that starts a line with a helper basename, or `grep -r "$HOME"`, may trip a deny-once. Retry the same command once.
- **Shell values in the shared step contain no apostrophes** (they are single-quoted). Write "does not", never "doesn't".

---

## Shared step: commit, push, and open the draft PR

Every task's final step runs this exact recipe from inside its worktree with its own values.

```bash
agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills
TYPE=fix                                   # test for #643
SCOPE=<scope>                              # from the task
TITLE='<title>'                            # from the task
WHY='<why>'                                # from the task
WHAT='<what>'                              # from the task, measured numbers filled in
ISSUE=<N>
FILES=(<this task's files>)

git status --short                                   # every listed path is a task file; nothing else
"$agentkit/.shared/scripts/worktree-commit.sh" --exact --message "$TYPE($SCOPE): $TITLE" --body "$WHY" \
    --trailer 'Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>' -- "${FILES[@]}"
git push -u origin "$(git branch --show-current)"
body=$(mktemp); printf '%s\n' 'This was written agentically; verify its assertions:' '' '## Why' "$WHY" '' '## What' "$WHAT" '' '## Testing' '- [ ] Red step fails before the change and passes after (assertion text named in the plan task)' '- [ ] `bash -n` + `shellcheck -x -P SCRIPTDIR -S style` clean on every touched script' '- [ ] Owning suites green via `tests/run-tests.sh --only …`; full `tests/run-tests.sh` green' '- [ ] Ceiling accounting in the PR matches the measured counts' '- [ ] CI green' '' "Closes #$ISSUE" '' '🤖 Generated with [Claude Code](https://claude.com/claude-code)' > "$body"
gh pr create --draft --title "$TYPE($SCOPE): $TITLE" --body-file "$body"
```

Then the orchestrator (not the worker) moves the issue: `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number "$ISSUE" --status "In review" --repo wrzonance/agent-kit`. For #609, `gh pr create` adds `--base fix/issue-606` while #606 is open; after #606 merges, `gh api -X PATCH repos/wrzonance/agent-kit/pulls/<609-PR> -f base=main` and rebase.

---

### Task 0: Board state

**Files:** none (board only).

- [ ] **Step 1:** confirm the five issues are open and on the board: `"$agentkit/.shared/scripts/board-list.sh" --issue 680`, then 607, 609, 606, 643.
- [ ] **Step 2:** move each to In progress as its worker is dispatched (not before): `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number N --status "In progress" --repo wrzonance/agent-kit` for N in 680 643 607 606 (609 when its worker starts on the #606 branch).
- [ ] **Step 3:** each task's shared step moves its issue to In review when the draft PR opens. Done is GitHub's own close-on-merge (`Closes #N`); a redundant hand move is harmless.

---

### Task 1 (#680): guard-lib — flush the heredoc owner line at the terminator in the gh lexer

**Files:**
- Modify: `agentkit/hooks/lib/guard-lib.sh` — `guard_gh_command_segments()` `:1977-2086`; the terminator branch is the one-liner at `:1993` `[[ $terminator_line == "$heredoc" ]] && { heredoc=''; heredoc_tabstrip=0; }`; the `<<\EOF` comment `:2057-2062` (six lines beginning `# An unquoted delimiter such as`) is a verbatim copy of `:1509-1514` in the destructive lexer.
- Test: `tests/test-hooks.sh` — heredoc fixtures `:841-869` (`heredoc_scope_cmd`, `quoted_string_cmd`, `inline_script_cmd`), the destructive-lexer flush test `:1616-1634` (`segment_flush_payload`, `segment_flush_hook_payload`), the hook line-ceiling loop `:2909` (`'lib/guard-lib.sh:2410'`), helpers `pre_input` `:437`, `decision` `:443`, `pre_context` `:444`, `scope_repo` `:559`, `fresh_sid` `:430`.
- Scratch (not committed): `<scratchpad>/wave3/k3-corpus/` — the rebuilt corpus and driver.

**Premise check against `09af63c`:** true as stated. `guard_destructive_command_segments` flushes the owner line inside its terminator branch (`:1437-1443`, comment `Flush the owner line (through the heredoc opener) as its own segment now`); the gh lexer's terminator branch only clears state and `continue`s (`:1993-1994`), and its end-of-line flush at `:2079-2084` runs only for non-heredoc lines. Five live consumers (`:221` `guard_command_target_dir`, `:475` `guard_out_of_scope_target`, `:795` `guard_unresolved_instruction_read`, `:2164` `guard_gh_inline_body_reason`, `:2297` `guard_shell_write_targets`) re-split the output with `while IFS= read -r`, so a flush at the terminator changes no consumer's line sequence when a command follows the terminator (the bytes are identical, K3 report §"Step 3"); it adds exactly one line — the owner line — when the heredoc ends the input.

**Behaviour change, stated plainly:** after this fix a command such as `cat > <foreign>/notes.md <<'EOF' … EOF` gets the foreign-scope advisory (`This command reads outside the workspace (…; classification: foreign)`) and its `>` target is judged by the write guards like any other redirect. That is the intended fix: the old lexer failed open on the single commonest agent shape. An inert body (data only) still produces no write-guard denial **for a non-protected target**, because the body is still dropped and the owner line alone is judged. **One new denial, intended:** a quoted heredoc redirected into a protected path inside the worktree (`cat > <worktree>/.github/workflows/ci.yml <<'EOF' … EOF`) was `allow` before and is `deny` after — the protected-path write guard finally sees the owner line, exactly as it already did when a command followed the terminator. Step 2 pins it and the PR body says it. No hook gains a new trigger class; the existing scope/write guards now see a segment they were always meant to see.

**North star:** removes a silent hole, not a turn — but it also unblocks #661's −106-line refactor, which is a pure delegation once the two lexers agree on every corpus record.

- [ ] **Step 1 (red — direct lexer):** in `tests/test-hooks.sh`, immediately after the destructive-lexer flush assertions (`:1625-1626`, message `'and the emitted segment is exactly the owner line, not merged with or missing the heredoc opener'`), add:

```bash
# issue #680: the gh lexer must flush the owner line at the terminator too --
# it used to emit ZERO segments for a command whose heredoc ends the input,
# so the scope and write guards never saw `cat > <foreign> <<'EOF' ... EOF`.
gh_flush_payload=$'cat > /tmp/x <<\'EOF\'\nfoo\nEOF'
mapfile -t gh_flush_segs < <(
    source "$hooks/lib/guard-lib.sh" 2>/dev/null
    guard_gh_command_segments "$gh_flush_payload"
)
assert_eq '1' "${#gh_flush_segs[@]}" \
    'the gh lexer emits the heredoc-owner segment when the heredoc is the last construct in the payload'
assert_eq "cat > /tmp/x <<'EOF'" "${gh_flush_segs[0]-}" \
    'and the gh lexer emits exactly the owner line for a trailing heredoc'
mapfile -t destructive_flush_segs < <(
    source "$hooks/lib/guard-lib.sh" 2>/dev/null
    guard_destructive_command_segments "$gh_flush_payload"
)
assert_eq "${destructive_flush_segs[*]-}" "${gh_flush_segs[*]-}" \
    'both lexers agree on a trailing inert heredoc: one owner-line segment each'
```

Run `tests/run-tests.sh --only hooks` → the first two new assertions FAIL (0 segments), the third FAILS (destructive emits one line, gh none).

- [ ] **Step 2 (red — hook level):** directly after Step 1's block add the scope-advisory and no-denial assertions. The fixture root is `${RUNNER_TEMP:-/dev/shm}` because everything under `$tmp` is a configured fixture root (the suite's own comment at `:815-818`), and `scope_repo` carries no worktree contract and no observer mode, so `guard_worktree_boundary_reason` (`:855`, needs `guard_worktree_contract`) and `guard_observer_write_reason` (`:951`, needs `mode == observer`) cannot fire:

```bash
trailing_heredoc_foreign=$(mktemp -d "${RUNNER_TEMP:-/dev/shm}/hooks-trailing-heredoc.XXXXXX")
trailing_heredoc_cmd=$(printf "cat > %s/notes.md <<'EOF'\nfoo\nEOF" "$trailing_heredoc_foreign")
out=$(pre_input "$scope_repo" "$trailing_heredoc_cmd" "$(fresh_sid)" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_contains "$(pre_context "$out")" 'classification: foreign' \
    'a foreign redirect target on a trailing-heredoc owner line draws the scope advisory'
assert_eq 'allow' "$(decision "$out")" \
    'an inert trailing heredoc body written to a foreign path is advised, never denied'
rm -rf -- "$trailing_heredoc_foreign"
# The one new denial: the protected-path write guard now sees the owner line
# of a trailing heredoc, so a redirect into .github/workflows/ is refused
# exactly as it is with a command after the terminator (issue #680).
trailing_heredoc_protected_cmd=$(printf "cat > %s/.github/workflows/ci.yml <<'EOF'\nname: ci\nEOF" "$scope_repo")
out=$(pre_input "$scope_repo" "$trailing_heredoc_protected_cmd" "$(fresh_sid)" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" \
    'a trailing heredoc redirected into a protected path is denied once the write guard sees its owner line'
```

`--only hooks` → the advisory assertion FAILS (empty context) and the protected-path deny FAILS (`allow` on the old lexer); the allow assertion passes already (it is the regression fence for the second half of the acceptance). **Red total for Steps 1-2: `hooks` 666 assertions / 17 failed = control 12 + 5 new** (measured).

- [ ] **Step 3 (rebuild the K3 corpus and record the OLD lexer's output):** the K3 scratch directory is gone; rebuild it from the report's recipe in `<scratchpad>/wave3/k3-corpus/`:
  1. `agentkit-orig/`: `mkdir -p agentkit-orig/hooks/lib && git -C <worktree> show 09af63c:agentkit/hooks/lib/guard-lib.sh > agentkit-orig/hooks/lib/guard-lib.sh && ln -s <worktree>/agentkit/skills agentkit-orig/skills` (the lib aborts at load unless `../../skills/.shared/scripts/lib` resolves relative to `BASH_SOURCE[0]`).
  2. Driver `run-lexer.sh LIB CORPUS.nul`: sources `LIB`, reads NUL-separated records, prints for each `--- record N ---`, `guard_gh_command_segments "$rec"`, then `guard_destructive_command_segments "$rec"` — one file per lexer per lib.
  3. Corpus A (`extract-a.sh`): `grep -oE "(pre|post)_input \"[^\"]+\" ('[^']*'|\"[^\"]*\")" tests/test-hooks.sh` → the quoted command of each match, NUL-joined (**184 records** on `09af63c`; 177 at the K2 commit).
  4. Corpus A2: the suite's multi-line command variables — every `NAME=$'…'`, `NAME="…` multi-line, and `NAME=$(printf '…')` whose value contains `<<` (`heredoc_scope_cmd`, `quoted_string_cmd`, `inline_script_cmd`, `tabstrip_heredoc_cmd`, `quoted_delim_heredoc_cmd`, `escaped_heredoc_cmd`, `segment_flush_payload`, `segment_flush_hook_payload`, and any other); evaluate them in a `bash -c` that sources nothing (they are literal) and NUL-join (**27 records** on `09af63c`).
  5. Corpus B: ≥ 30 adversarial shapes covering every construct the report lists: nested heredocs, `<<-` and `<<\EOF`, quoted/unquoted/double-quoted delimiters, heredocs piped into `bash`/`sh`, `$(…)` and backticks in bodies, `gh` inside bodies, unterminated heredocs, CRLF endings, terminator with trailing spaces, `<<-` terminator with leading tabs, comments containing heredoc-like text, here-strings, two heredocs in sequence, an empty delimiter, escaped-newline continuation, a heredoc inside `$( … )`, and — at least ten of them — a heredoc whose terminator is the last line (the review's corpus has **42**; one record carries two heredocs on one line, and the classifier must take the *last* `<<` delimiter, which is what both lexers do).
  6. Run the driver over A, A2, B against `agentkit-orig` → `old-*.txt`. A ready-made driver, classifier, and the three corpora exist at `<scratchpad>/wave3/review/k3-corpus/` — reuse them instead of rebuilding when that directory still exists.
- [ ] **Step 4 (fix):** in `guard_gh_command_segments`, replace the one-line terminator branch `:1993` with the flush the destructive lexer already performs (`:1437-1443`), and pay the five added lines by cutting the duplicated `<<\EOF` comment `:2057-2062` to one line:

```bash
# before (:1993-1994)
            [[ $terminator_line == "$heredoc" ]] && { heredoc=''; heredoc_tabstrip=0; }
            continue
# after
            if [[ $terminator_line == "$heredoc" ]]; then
                heredoc=''
                heredoc_tabstrip=0
                # Flush the owner line as its own segment (issue #680): with no
                # command after the terminator it was otherwise never emitted.
                if [[ -n $segment ]]; then
                    printf '%s\n' "${segment%$'\n'}"
                    segment=''
                fi
            fi
            continue
```

```bash
# before (:2057-2062, six comment lines)
                            # An unquoted delimiter such as `<<\EOF` disables
                            # heredoc-body expansion the same way a quoted one
                            # does; bash strips the backslash for the purpose
                            # of matching the terminator, so the stored
                            # delimiter must too, or the real terminator line
                            # (bare "EOF") never matches "\EOF".
# after (one line; the full note stays at :1509-1514 in the destructive lexer)
                            # `<<\EOF`: strip the backslash so the bare terminator matches (see guard_destructive_command_segments).
```

Net: +9 (the one-liner becomes ten lines) −5 (six comment lines become one) = **+4** lines (2403 → **2407**, measured). Lower the ceiling in the loop at `tests/test-hooks.sh:2909` from `'lib/guard-lib.sh:2410'` to `'lib/guard-lib.sh:2407'` (`wc -l`). If the worker's edit lands at a different count, the ceiling is that count — never 2410.

- [ ] **Step 5 (corpus acceptance):** re-run the driver against the worktree's `agentkit/hooks/lib/guard-lib.sh` → `new-*.txt`. `diff old-gh-*.txt new-gh-*.txt`: **every differing record must satisfy the predicate "its last line equals its open heredoc's terminator"** (write `classify-diff.sh` that prints the record numbers that differ and, for each, whether the predicate holds; the run stops if any differing record fails it). `diff old-destructive-*.txt new-destructive-*.txt` must be **empty** (the destructive lexer is untouched). Then `diff new-gh-*.txt new-destructive-*.txt` restricted to records whose heredoc body is inert (quoted delimiter, non-shell consumer) must be **empty** — that is the #661 precondition. **Expected (measured twice, review and revision, byte-identical outputs):** A 184 records / 0 differ; A2 27 / 18 differ, all satisfy the predicate; B 42 / 25 differ, all satisfy the predicate; destructive old vs new identical on all three; new gh vs new destructive differs only on shell-consumer / unquoted-substitution bodies (`bash <<`, `$(…)`, backticks: 7 records on A2, 5 on B), never on an inert record. Record the three counts (identical / differing-by-predicate / total) in the PR body.
- [ ] **Step 6 (green):** `bash -n agentkit/hooks/lib/guard-lib.sh`; `shellcheck -x -P SCRIPTDIR -S style agentkit/hooks/lib/guard-lib.sh agentkit/hooks/pre-tool-use.sh agentkit/hooks/post-tool-use.sh agentkit/hooks/session-start.sh`; `shellcheck -S style -e SC1091,SC2034 tests/test-hooks.sh`; `AGENT_TEST_TIMEOUT_SCALE=3 tests/run-tests.sh --only hooks` → **666 assertions** (660 + 6), failures = the control set's 12 under `/tmp`, 0 in a `.worktrees/` checkout; full `tests/run-tests.sh` = control set.
- [ ] **Step 7: Shared step** with `SCOPE=hooks`, `TITLE='flush the heredoc owner line at the terminator in guard_gh_command_segments'`, `WHY='The gh heredoc lexer emitted zero segments for a command whose last line is a heredoc terminator, so cat > <foreign>/notes.md <<EOF ... EOF passed the scope and write guards unseen; the destructive lexer already flushed the owner line at the terminator, and the K3 corpus showed that flush as the only difference between the two lexers.'`, `WHAT='The terminator branch flushes the pending owner line exactly as guard_destructive_command_segments does; a trailing quoted heredoc to a foreign path now draws the scope advisory, and a trailing heredoc redirected into a protected path (.github/workflows/) is now denied like any other protected write -- both intended; an inert body to a non-protected target still draws no denial. Six new hooks assertions (both lexers, advisory, no-denial, protected-path denial); corpus comparison identical on every record except the trailing-terminator shape (<counts>); guard-lib 2403 -> 2407 lines, ceiling ratcheted. Unblocks #661.'`, `FILES=(agentkit/hooks/lib/guard-lib.sh tests/test-hooks.sh)`, `ISSUE=680`.

---

### Task 2 (#643): compose-worker-prompt test — path-neutral prompt ceiling

**Files:**
- Test only: `tests/test-compose-worker-prompt.sh` `:102-105` — `prompt=$(bash "$compose" --template issue-lead … --worktree "$repo" …)` and `assert_eq yes "$([[ ${#prompt} -le 20500 ]] && printf yes || printf no)" "issue-lead prompt stays at or under 20500 bytes (measured ${#prompt})"`. Fixture paths: `repo="$tmp/repo with spaces"` (`:74`), the contract's `skills= path=` is `$root/agentkit/skills` (`:73`); the composer substitutes `$agentkit` → `skills_path` (= the contract's skills path, `compose-worker-prompt.sh:257,1145`) and `$shared` → `$skills_path/.shared/scripts` (`:1147`).

**Premise check:** true on `09af63c` (`:102-105` is exactly the block the issue names).

**North star:** removes a false red — a CI or worktree at a longer path failing the suite for no change of content — and the re-measure/re-explain turn that follows it.

- [ ] **Step 1 (red):** replace `:105` with the path-neutral measurement and two placeholder-completeness fences, keeping the old ceiling for the moment:

```bash
# issue #643: the composed prompt embeds the skills-tree and worktree paths,
# so a raw byte count was a property of the checkout location. Measure with
# fixed placeholders substituted for both, and fence that nothing else leaks.
neutral_prompt=${prompt//"$repo"/<worktree>}
neutral_prompt=${neutral_prompt//"$root/agentkit/skills"/<agentkit>}
neutral_prompt=${neutral_prompt//"$(printf %q "$repo")"/<worktree-shell>}
assert_not_contains "$neutral_prompt" "$tmp" 'the path-neutral prompt carries no fixture temp path'
assert_not_contains "$neutral_prompt" "$root" 'the path-neutral prompt carries no checkout path'
assert_eq yes "$([[ ${#neutral_prompt} -le 20500 ]] && printf yes || printf no)" \
    "issue-lead prompt stays at or under 20500 path-neutral bytes (measured ${#neutral_prompt})"
```

Three substitutions, not two: the composer also emits the worktree in `printf %q` form (`worktree=/tmp/tmp.X/repo\ with\ spaces`, the fixture path has spaces), which the raw `$repo` substitution does not match — that is the `<worktree-shell>` line. Run `tests/run-tests.sh --only compose-worker-prompt`. The two `assert_not_contains` fences are the genuine red for the substitution: put them **above** the three substitution lines first (with `neutral_prompt=$prompt`) and confirm both FAIL (the raw prompt contains `$tmp` and `$root`; measured 263 / 2), then move them below → 263 / 0. If either still fails after the three substitutions, a fourth absolute path is embedded — find it with `grep -o "$tmp[^ ]*\|$root[^ ]*" <<< "$neutral_prompt" | sort -u`, add one more substitution with its own `<placeholder>`, and name it in the PR.

- [ ] **Step 2 (ratchet):** read the measured value from the assertion message (`measured N`; **18756** on `09af63c`), set the ceiling to exactly `N` in both the condition and the message, and run `--only compose-worker-prompt` once with `N-1` to see the ceiling itself go red (measured: 18755 → `FAIL … (measured 18756)`, 263 / 1), then with `N` → green. The ceiling is path-neutral, so it is exact: no slack.
- [ ] **Step 3 (green):** `shellcheck -S style -e SC1091,SC2034 tests/test-compose-worker-prompt.sh`; `tests/run-tests.sh --only compose-worker-prompt,compose-worker-prompt-scope,parallel-dispatch-contract` (263/0, 110/0, 626/0); full `tests/run-tests.sh` from the worktree **and** once from a copy at a deliberately longer path (`cp -r` into `${RUNNER_TEMP:-/dev/shm}/x/$(printf 'y%.0s' {1..40})/agent-kit` and run `--only compose-worker-prompt` there) — the measured value must be identical in both runs (18756 at a 146-character scratch root and at the 60-character `/dev/shm` path); quote both in the PR.
- [ ] **Step 4: Shared step** with `TYPE=test`, `SCOPE=compose-worker-prompt`, `TITLE='make the issue-lead prompt byte ceiling path-neutral'`, `WHY='The composed issue-lead prompt embeds the skills tree and worktree paths, so its byte ceiling measured 20423 at one checkout and 20603 at a 118-character root: a property of the path, not the template (wave-one review 6.3, wave-two review H2).'`, `WHAT='The test substitutes <worktree>, <worktree-shell> (the printf %q form the composer also emits) and <agentkit> for the absolute paths before measuring, fences that no fixture or checkout path survives the substitution, and ratchets the ceiling to the exact path-neutral minimum (18756); identical measurement proven at two checkout depths. Test-only; no skill markdown moves.'`, `FILES=(tests/test-compose-worker-prompt.sh)`, `ISSUE=643`.

---

### Task 3 (#607): chain-advance / authorize-queue / merge-pr — auto-retarget events, persisted proofs, keep-branch under delete-on-merge

**Files:**
- Modify: `agentkit/skills/parallel-issues/scripts/chain-advance.sh` (1035 lines; ceiling `tests/test-chain-advance.sh:1367` `'chain-advance.sh stays at or under 1045 lines'`) — `timeline_boundary()` `:190-206` (jq `select((.event // "") == "base_ref_changed")` at `:196`), `persist_boundary()` `:230-249` (jq `{pr:$pr,base:$base,headSha:$head,boundaryEpoch:$boundary}` at `:243`), `persisted_boundary()` `:251-264`, `boundary_for()` `:268-283` (die text `could not read a base_ref_changed timeline event or persisted retarget boundary; evidence provenance is unavailable` at `:282`), `retarget()` proof `printf 'retargeted pr #%s base=%s … boundarySource=%s provider-check=%s closing-issues=%s\n'` `:906-908`, comment essay `:285-292` (eight lines beginning `# Repository slug this checkout itself belongs to`).
- Modify: `agentkit/skills/pr-to-green/scripts/authorize-queue.sh` (628 lines; no line ceiling) — usage `:56-79`, `--retarget-proof` argv `:135-143`, the `retarget)` reconciliation branch `:544-580` (`proof_file=${retarget_proof_file[$recon_pr]-}` at `:546`, die `changed base with no --retarget-proof supplied` at `:548`, the `grep -F "retargeted pr #$recon_pr base=$recon_live_base "` loop at `:565-575`).
- Modify: `agentkit/skills/pr-to-green/scripts/merge-pr.sh` (334 lines; no line ceiling) — `repos/$repo` read `:253` (`"$GH_BIN" api "repos/$repo" >"$work_dir/repo.json"`), the keep branch `else printf 'branch_delete=skipped ref=%s\n' "$head_ref"` `:332-334`.
- Modify: `agentkit/skills/pr-to-green/references/auto-merge.md` (19100 B; ceiling `tests/test-pr-to-green-authorize-queue.sh:758` `-le 19300`, message `'auto-merge reference stays at or under 19300 bytes'`) — the stacked-retarget bullet `:93-97` and the branch-deletion paragraph `:270-282`.
- Modify: `agentkit/skills/pr-to-green/SKILL.md` (306 lines / 18222 B; under the generic `lint-skill-size.sh` 500-line / 5000-token gate, ≈ 444 tokens of headroom) — the `--retarget-proof` sentence `:295-297`.
- Tests: `tests/test-chain-advance.sh` (fake `gh` timelines at `:51,133,…,776`; idempotent-retarget block `:756-800`; persisted-boundary fixtures `:997-1005`), `tests/test-pr-to-green-authorize-queue.sh` (retarget fixtures `:519-535`; `run_authorize_provider`, `write_confirmed` helpers; `repo_root="$tmp/repo"` is a plain directory, `:14`), `tests/test-pr-to-green-merge-pr.sh` (fake `gh` `repos/owner/repo` branch `:38-41`; default-run assertions `:107-113`).

**Premise check against `09af63c`:** (a) the `base_ref_changed`-only select is at `:196` (the issue says `:213`), the die at `:282` (issue `:299`); both true. (b) The proof file is whatever the root redirected `chain-advance.sh --retarget`'s stdout into; `authorize-queue.sh` takes it only as `--retarget-proof PR:FILE` (`:135-143`); true. (c) **"exactly one `authorize-queue.sh` run per chain" is not satisfiable by this task without redesigning the authorization record**: `merge-pr.sh:204-211` requires the record's queue entry to match this exact `headSha` and `base`, and `review-transition.sh:344-358` requires it to be `RUNNABLE`; a retarget changes both, so the record must be re-derived once per retarget. What this task removes is the *hand bookkeeping* of that re-run: `chain-advance.sh --retarget` persists its proof line under Git metadata and `authorize-queue.sh --allow-mechanical-advance` finds it there without any `--retarget-proof PR:FILE` argument, so the re-run is the same argument-free command every time (scriptable, never a hand-written adapter). The record redesign is named in *Self-review → Not taken*. (d) `merge-pr.sh` has no `--keep-branch` flag on `09af63c`; keep is the default (`delete_branch=0`, `:34`), and the output the issue quotes is the `else` branch at `:333`. `authorize-queue.sh` does take `--keep-branch` (`:57-58`).

**North star:** removes the mid-merge adapter turn (three of five retargets in the reviewed run ran a patched copy), the per-PR `--retarget-proof` bookkeeping read, and the post-merge `git push origin <branch>:refs/heads/<branch>` restore the root typed after every merge.

- [ ] **Step 1 (red — event kind):** in `tests/test-chain-advance.sh`, directly after the idempotent block's last assertion (`:800` region, message `'repeat proof is byte-for-byte stable'` and the `idempotent_log` checks that follow it), add a fixture identical to `gh-idempotent` except the timeline returns only the auto-retarget event, then assert:

```bash
# issue #607: a delete-branch-on-merge repository auto-retargets stacked
# successors and records `automatic_base_change_succeeded`, never
# `base_ref_changed`; the proof must accept it and say which kind it saw.
sed 's/"event":"base_ref_changed"/"event":"automatic_base_change_succeeded"/' "$tmp/gh-idempotent" >"$tmp/gh-auto-retarget"
chmod +x "$tmp/gh-auto-retarget"
# The idempotent block above persisted a boundary for pr 7/main; clear it so
# the timeline event alone must prove this retarget (persisted fallback off).
persisted_boundary_json=$(git -C "$repo" rev-parse --absolute-git-dir)/chain-advance-evidence/chain-advance-pr-7-base-main.json
rm -f -- "$persisted_boundary_json"
set +e
auto_event_out=$(cd -- "$repo" && EDIT_STATE="$tmp/auto-event.state" GH_LOG="$tmp/auto-event.log" \
    PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-auto-retarget" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
auto_event_rc=$?
set -e
assert_eq '0' "$auto_event_rc" 'a timeline carrying only automatic_base_change_succeeded proves the retarget'
assert_contains "$auto_event_out" 'boundarySource=timeline boundaryEvent=automatic_base_change_succeeded' \
    'the proof records which timeline event kind proved the boundary'
assert_contains "$first_idempotent" 'boundaryEvent=base_ref_changed' \
    'a base_ref_changed proof records its event kind too'
```

**Why the `rm -f`:** the idempotent block leaves `chain-advance-pr-7-base-main.json` (headSha `1111…`) under `--absolute-git-dir` (`boundary_file`, `:220-228`), and `boundary_for` falls back to it — on unpatched code the headline `rc 0` assertion would already pass through `boundarySource=persisted`, a vacuous red. With the JSON cleared, unpatched code dies in `boundary_for` (**rc 2**, not 1: `die` runs after `RETARGET_APPLIED=true`, `:79-81`). The negative lives in Step 2, after the persisted-proof assertions, so its proof line cannot land after the auto-event line. `--only chain-advance` → these three FAIL (rc 2; no `boundaryEvent=` token).

- [ ] **Step 2 (red — persisted proof):** in the same suite, after Step 1, assert the proof line was persisted under the git **common** dir (the suite already proves worktree-controlled `.agent/evidence` is never trusted, `:997-1010`):

```bash
proof_persisted=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/chain-advance-evidence/chain-advance-pr-7-base-main.proof
assert_eq yes "$([[ -f $proof_persisted && ! -L $proof_persisted ]] && printf yes || printf no)" \
    'retarget persists its proof line as a regular file under Git metadata'
assert_eq "$(tail -n 1 "$proof_persisted")" "$(printf '%s\n' "$auto_event_out" | grep -F 'retargeted pr #7')" \
    'the persisted proof line is byte-identical to the printed one'
# negative: the same event kind for another base is still no proof (the base
# filter is kept). The successful run above re-persisted the boundary, so
# clear it again; die runs after RETARGET_APPLIED=true and exits 2.
sed 's/"base_ref":"main"/"base_ref":"other"/' "$tmp/gh-auto-retarget" >"$tmp/gh-auto-retarget-other"
chmod +x "$tmp/gh-auto-retarget-other"
rm -f -- "$persisted_boundary_json"
set +e
auto_other_out=$(cd -- "$repo" && EDIT_STATE="$tmp/auto-other.state" GH_LOG="$tmp/auto-other.log" \
    PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-auto-retarget-other" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
auto_other_rc=$?
set -e
assert_eq '2' "$auto_other_rc" 'an automatic_base_change_succeeded event for another base is no proof'
assert_contains "$auto_other_out" 'could not read a base_ref_changed or automatic_base_change_succeeded timeline event or persisted retarget boundary; evidence provenance is unavailable' \
    'the wrong-base refusal names both event kinds'
```

The negative pins the **new** die text (Step 5 changes it), never the old `:282` text — a negative on the old text goes red on green. **Red for Steps 1-2 (measured): `chain-advance` 154 assertions / 16 failed = control 11 + 5 new** — headline rc, event kind, `first_idempotent` kind, proof-file-exists, wrong-base text. Two of the seven pass vacuously on unpatched code and are stated as such: byte-identical (empty `tail` of a missing file vs empty `grep`) and the wrong-base rc (the old die also exits 2); their teeth are the file-exists and die-text assertions beside them.

- [ ] **Step 3 (red — proof auto-discovery):** in `tests/test-pr-to-green-authorize-queue.sh`, after the `retarget_proof_ok` block (`:519-535`, message `'a proven stacked retarget authorizes without redisplay'`), turn the fixture root into a repository and place the same proof line at the default location, then authorize **without** `--retarget-proof`:

```bash
# issue #607: chain-advance.sh --retarget persists its proof under Git
# metadata; --allow-mechanical-advance reads it from there, so the per-PR
# --retarget-proof PR:FILE bookkeeping is no longer required.
git init -q "$repo_root"
default_proof_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)/chain-advance-evidence
mkdir -p "$default_proof_dir"
cp -- "$retarget_proof_ok" "$default_proof_dir/chain-advance-pr-15-base-main.proof"
write_confirmed
default_proof_out=$(QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd \
    QUEUE_STATE_15=RUNNABLE run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance)
assert_eq "authorization=$auth queue=2" "$default_proof_out" \
    'a persisted chain-advance proof authorizes a stacked retarget with no --retarget-proof argument'
chmod 666 "$default_proof_dir/chain-advance-pr-15-base-main.proof"
write_confirmed
writable_proof_rc=0
QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    run_authorize_provider coderabbit:trigger:capability-default --allow-mechanical-advance \
    >"$tmp/writable-proof.out" 2>"$tmp/writable-proof.err" || writable_proof_rc=$?
assert_eq '1' "$writable_proof_rc" 'a group- or world-writable persisted proof is refused like an explicit one'
assert_contains "$(cat "$tmp/writable-proof.err")" 'persisted retarget proof must not be group- or world-writable' \
    'the refusal names the persisted proof and its mode'
rm -f -- "$default_proof_dir/chain-advance-pr-15-base-main.proof"
```

The rc-capture form is the only one that works: `run_authorize_provider` is a shell function and is not visible to `assert_rc … bash -c`, which would exit 127 and pass the fence for the wrong reason. `--only pr-to-green-authorize-queue` → the **suite aborts** (it runs under `set -euo pipefail`; `default_proof_out=$(…)` dies) with `authorize-queue.sh: pr 15 changed base with no --retarget-proof supplied; redisplay and reconfirm before authorization` — consistent with the suite's own style, and the red for this step.

- [ ] **Step 4 (red — keep-branch restore):** in `tests/test-pr-to-green-merge-pr.sh`, extend the fake `gh` `repos/owner/repo` branch (`:39-40`) to `printf '{"allow_squash_merge":%s,"allow_merge_commit":%s,"allow_rebase_merge":%s,"delete_branch_on_merge":%s}\n' … "\${DELETE_ON_MERGE:-false}"`, teach it a `POST repos/owner/repo/git/refs` route that prints `{"ref":"refs/heads/feat/demo"}` (the fake already distinguishes `-X DELETE` via `is_delete`; add `is_post` the same way), then after the default-run assertions (`:113`):

```bash
# issue #607: with delete_branch_on_merge on, GitHub deletes the merged head
# even when the run chose keep-branch; restore it here, never from the model.
: >"$tmp/merge.log"
out=$(DELETE_ON_MERGE=true REF_CHECK_MISSING=1 MERGE_PR_RESTORE_POLL_SECONDS=0 run_merge)
assert_contains "$out" 'branch_delete=restored ref=feat/demo reason=repo-delete-branch-on-merge' \
    'a head the repository setting deleted is restored when the run chose keep-branch'
assert_eq '1' "$(grep -c -- '-X POST repos/owner/repo/git/refs ' "$tmp/merge.log" || true)" \
    'the restore is one ref-create call carrying the merged head SHA'
: >"$tmp/merge.log"
out=$(DELETE_ON_MERGE=true MERGE_PR_RESTORE_POLL_SECONDS=0 run_merge)
assert_contains "$out" 'branch_delete=skipped ref=feat/demo note=repo-delete-branch-on-merge-pending' \
    'a head still present after the merge is left alone and the pending deletion is named'
```

`--only pr-to-green-merge-pr` → 71 assertions / 3 FAIL (measured).

- [ ] **Step 5 (fix — chain-advance.sh):**

```bash
# before (:196)
          | select((.event // "") == "base_ref_changed")
# after
          | select((.event // "") == "base_ref_changed" or (.event // "") == "automatic_base_change_succeeded")
```

Make the jq emit `[time, event] | @tsv` for the last matching event (replace `| ([.created_at, .createdAt] | first_nonempty) | select(length > 0)` with `| [(([.created_at, .createdAt] | first_nonempty)), .event] | select(.[0] | length > 0)` and the trailing `] | last // empty` with `] | last // empty | @tsv`). **`timeline_boundary` runs inside `$(…)` in `boundary_for` (`:270`), so it cannot set a global** — it splits locally and prints the pair:

```bash
    [[ -n $event_time ]] || return 1
    # Runs inside $(...) in boundary_for, so print the pair; the caller splits.
    local event_kind
    IFS=$'\t' read -r event_time event_kind <<<"$event_time"
    epoch=$(iso_to_epoch "$event_time") || return 1
    printf '%s\t%s\n' "$epoch" "$event_kind"
```

Declare `BOUNDARY_EVENT=''` beside `BOUNDARY_SOURCE=''` (`:25`). `persist_boundary` gains `--arg event "$BOUNDARY_EVENT"` and `boundaryEvent:$event` (`:243`). `persisted_boundary` selects on `.boundaryEpoch` being a positive integer, returns `[.boundaryEpoch, (.boundaryEvent // "persisted")] | @tsv`, and checks `[[ ${value%%$'\t'*} =~ ^[1-9][0-9]*$ ]]` (the hand-written fixtures at `:999,1005` carry no `boundaryEvent`, so `// "persisted"` keeps them valid). `boundary_for` splits **both** sources and passes the epoch alone to persistence — `persist_boundary --argjson` must receive a bare integer, never the tab pair:

```bash
    if boundary=$(timeline_boundary); then
        BOUNDARY_SOURCE=timeline
        IFS=$'\t' read -r BOUNDARY_EPOCH BOUNDARY_EVENT <<<"$boundary"
        persist_boundary "$head_sha" "$BOUNDARY_EPOCH" ||
            die 'could not persist the retarget boundary evidence'
    elif boundary=$(persisted_boundary "$head_sha"); then
        BOUNDARY_SOURCE=persisted
        IFS=$'\t' read -r BOUNDARY_EPOCH BOUNDARY_EVENT <<<"$boundary"
``` The `:282` die text becomes `could not read a base_ref_changed or automatic_base_change_succeeded timeline event or persisted retarget boundary; evidence provenance is unavailable`. The proof printf (`:906-908`) inserts ` boundaryEvent=%s` immediately after `boundarySource=%s` with `"$BOUNDARY_EVENT"` after `"$BOUNDARY_SOURCE"` — never at the end, because `authorize-queue.sh:571` anchors `closing-issues=[1-9][0-9]*$`. Then persist the line:

```bash
# The proof line is consumed by authorize-queue.sh from the root checkout, so
# it lives under the Git COMMON dir where every worktree of this repository
# resolves it; the boundary JSON above is per-invocation retry state and stays
# under the worktree's own git dir (--absolute-git-dir). Two paths on purpose.
proof_file() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [[ $common = /* && -d $common ]] && path_has_no_symlink "$common" || return 1
    printf '%s/chain-advance-evidence/chain-advance-pr-%s-base-%s.proof\n' "$common" "$PR" "${BASE//\//-}"
}

persist_proof_line() {
    local file dir
    file=$(proof_file) || return 1
    dir=${file%/*}
    [[ -d $dir && ! -L $dir ]] || mkdir -p -- "$dir" || return 1
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || return 1
    (umask 077; printf '%s\n' "$1" >>"$file")
}
```

In `retarget()`, capture the proof into `proof_line=$(printf '…' …)`, `printf '%s\n' "$proof_line"`, then `persist_proof_line "$proof_line" || printf '%s: could not persist the retarget proof under Git metadata; pass the printed line to authorize-queue.sh --retarget-proof %s:FILE\n' "$PROGNAME" "$PR" >&2` (advisory: the printed line is still the proof). Pay: wrap the eight-line essay `:285-292` into two lines (keeps `#577 F2`). Measured: 1035 → **1055** (+20: jq/tsv split/declare/persist args/persisted split/printf token/two functions with the four-line comment above/capture+persist, −6 essay); **raise the ceiling at `tests/test-chain-advance.sh:1367` to the measured count** with the comment `# 2026-09-09 issue #607: +20 for proof persistence and the event-kind token; measured.` (the added lines are a new durable artifact, not prose; nothing else in the file is safely cuttable in a fix PR).

- [ ] **Step 6 (fix — authorize-queue.sh):** add, near `reject_writable_by_others`:

```bash
# issue #607: chain-advance.sh --retarget persists its proof line under the
# repository's Git common dir; without an explicit --retarget-proof for this
# PR, that file is the proof. Same ownership and mode checks as the explicit one.
default_retarget_proof() {
    local pr=$1 base=$2 common file
    common=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    file="$common/chain-advance-evidence/chain-advance-pr-$pr-base-${base//\//-}.proof"
    [[ -f $file && ! -L $file && -O $file ]] || return 1
    reject_writable_by_others "$file" 'persisted retarget proof'
    printf '%s\n' "$file"
}
```

and in the `retarget)` branch replace `:546-548`:

```bash
# before
                proof_file=${retarget_proof_file[$recon_pr]-}
                [[ -n $proof_file ]] ||
                    die "pr $recon_pr changed base with no --retarget-proof supplied; redisplay and reconfirm before authorization"
# after
                proof_file=${retarget_proof_file[$recon_pr]-}
                [[ -n $proof_file ]] || proof_file=$(default_retarget_proof "$recon_pr" "$recon_live_base") || proof_file=''
                [[ -n $proof_file ]] ||
                    die "pr $recon_pr changed base with no --retarget-proof supplied and no persisted chain-advance.sh proof under Git metadata; redisplay and reconfirm before authorization"
```

Usage `:74-75`: `… a base change (a retarget) proven by the chain-advance.sh --retarget proof persisted under the repository Git metadata, or by a matching --retarget-proof PR:FILE naming that exact PR/base/head line, …`. Also accept the new token in the proof-line grammar: nothing to change — the `:565-571` loop tests token presence, not order, and `boundaryEvent=` sits before `provider-check=`.

- [ ] **Step 7 (fix — merge-pr.sh):** replace the keep branch `:332-334`:

```bash
# before
else
    printf 'branch_delete=skipped ref=%s\n' "$head_ref"
fi
# after
else
    keep_branch_after_merge
fi
```

with, defined above the merge call (near `find_open_dependents`):

```bash
# issue #607: a repository with delete_branch_on_merge deletes the merged head
# regardless of the run's keep-branch choice. Read the setting from the
# repos/ metadata already fetched, wait briefly for the deletion, and recreate
# the ref at the merged head -- restoration is this helper's job, never the
# model's. Fork heads are never touched (same rule as the delete path).
keep_branch_after_merge() {
    local attempt poll=${MERGE_PR_RESTORE_POLL_SECONDS:-2}
    if [[ $(jq -r '.delete_branch_on_merge // false' "$work_dir/repo.json") != true ||
          $head_repo_full != "$repo" || ! $head_ref =~ $BRANCH_RE ]]; then
        printf 'branch_delete=skipped ref=%s\n' "$head_ref"
        return 0
    fi
    for attempt in 1 2 3; do
        "$GH_BIN" api "repos/$repo/git/ref/heads/$head_ref" >/dev/null 2>&1 || break
        ((attempt < 3)) && sleep "$poll"
    done
    if ((attempt == 3)) && "$GH_BIN" api "repos/$repo/git/ref/heads/$head_ref" >/dev/null 2>&1; then
        printf 'branch_delete=skipped ref=%s note=repo-delete-branch-on-merge-pending\n' "$head_ref"
        return 0
    fi
    if "$GH_BIN" api -X POST "repos/$repo/git/refs" -f "ref=refs/heads/$head_ref" -f "sha=$head_sha" \
        >"$work_dir/restore.out" 2>"$work_dir/restore.err"; then
        printf 'branch_delete=restored ref=%s reason=repo-delete-branch-on-merge\n' "$head_ref"
    else
        printf 'branch_delete=repo-setting ref=%s reason=%s\n' "$head_ref" "$(head -n 1 "$work_dir/restore.err")"
    fi
}
```

The default fixture (`delete_branch_on_merge` false) takes the first branch, so `:110-113` (`branch_delete=skipped`, zero `git/refs/heads` calls) stay green; the restore POSTs to `git/refs` (no `/heads/` in the URL, the ref is a body field) and the presence check uses the singular `git/ref/heads/` route (`:301-309` explains why).

- [ ] **Step 8 (docs):** `auto-merge.md:94-97` → `… and either the proof line chain-advance.sh --retarget persisted under the repository Git metadata (found automatically) or --retarget-proof PR:FILE naming that exact line (matching base and head, ancestry=verified, green:post-retarget, an approval= token, a positive closing-issues=; behind=/generated-only=/boundaryEvent=/provider-check= tokens may precede it).` and `auto-merge.md:273-282`: add one sentence `With delete_branch_on_merge enabled the head is deleted by the repository regardless; merge-pr.sh restores it (branch_delete=restored) when the run chose keep-branch.` (fold into the existing paragraph). The two sentences measure **+237 B** (19100 → **19337**), over `:758`'s 19300 — **the ceiling moves to the measured 19337** with the comment `# 2026-09-09 issue #607: +237 B, the persisted proof and the delete-on-merge restore; measured.` (two new durable facts; the reference has no prose to trade). `pr-to-green/SKILL.md:295-297` → `Its proof is persisted under Git metadata and found by authorize-queue.sh --allow-mechanical-advance; pass --retarget-proof PR:FILE only when that persistence was reported as failed.` (306 lines → 306, 18222 → 18278 B; `tests/lint-skill-size.sh agentkit/skills` stays green — measured).
- [ ] **Step 9 (green):** `bash -n` + shellcheck on the three scripts; `tests/run-tests.sh --only chain-advance,pr-to-green-authorize-queue,pr-to-green-merge-pr,review-transition,pr-to-green-merge-gate` → **chain-advance 154 / 11 (= control), authorize-queue 108 / 0, merge-pr 71 / 0, review-transition 85 / 0, merge-gate 150 / 0** (measured); `tests/lint-skill-size.sh agentkit/skills`; `tests/lint-helper-refs.sh agentkit/skills`; full `tests/run-tests.sh` = control set.
- [ ] **Step 10: Shared step** with `SCOPE=chain-advance`, `TITLE='accept automatic_base_change_succeeded, persist the retarget proof, restore a keep-branch head the repository deleted'`, `WHY='A delete-branch-on-merge repository auto-retargets stacked successors and records automatic_base_change_succeeded; chain-advance.sh --retarget matched only base_ref_changed and died, so the reviewed run patched an invocation-local copy mid-merge, hand-registered every proof with --retarget-proof, and pushed each merged branch back by hand.'`, `WHAT='timeline_boundary accepts both event kinds with the same base and timestamp filters and the proof line records boundaryEvent=<kind>; the proof line is persisted under the Git common dir and authorize-queue.sh --allow-mechanical-advance reads it there, so the per-retarget re-authorization is one argument-free command (the authorization record still pins head/base per PR, so one run per retarget remains -- named in the plan); merge-pr.sh reads delete_branch_on_merge from the repos/ metadata it already fetches and recreates the head at the merged SHA when the run chose keep-branch (branch_delete=restored). Fixtures for both event kinds, wrong base (rc 2, new die text), persisted proof, writable proof, and both restore outcomes; chain-advance.sh 1035 -> 1055 lines (ceiling 1045 -> 1055, reason in the test); auto-merge.md 19100 -> 19337 B (ceiling 19300 -> 19337, reason in the test). Pre-existing, untouched: a --delete-branch run on a delete-on-merge repository still prints branch_delete=failed reason=not found.'`, `FILES=(agentkit/skills/parallel-issues/scripts/chain-advance.sh agentkit/skills/pr-to-green/scripts/authorize-queue.sh agentkit/skills/pr-to-green/scripts/merge-pr.sh agentkit/skills/pr-to-green/references/auto-merge.md agentkit/skills/pr-to-green/SKILL.md tests/test-chain-advance.sh tests/test-pr-to-green-authorize-queue.sh tests/test-pr-to-green-merge-pr.sh)`, `ISSUE=607`.

---

### Task 4 (#606): repo-config — one model-family predicate, corrected-form validation, symmetric reviewer keys, yolo degrade

**Files:**
- Modify: `agentkit/skills/.shared/scripts/repo-config.sh` (1045 lines; ceiling `tests/test-repo-config.sh:621` `'repo-config.sh stays at or under 1048 lines'`) — `worker_model_valid()` `:402-404` (comment `:398-401` `without hardcoding today's supported model names here`), `worker_models_roster_valid()` `:414-424`, `reviewer_roster_entry_valid()` `:431-438` (comment `:426-430`), the `validate()` case arms `:746-761` (`AGENT_ADVERSARIAL_REVIEWER)` `:754-756`, `AGENT_ADVERSARIAL_REVIEWER_FALLBACK) reviewer_roster_entry_valid "$value" ;;` `:757`, `AGENT_ADVERSARIAL_REVIEW_MODEL | …) worker_model_valid "$value"` `:758-760`), the warn ladder `:864-884` (`else warn "invalid value for $key on line $lineno, ignoring"` `:879-880`; `parse_failed=1` condition `:881-882` and `:916-917`), usage `:38`, `die_usage 'one of --export, …'` `:164`, the argv `case` `:113-134` (`--list-adversarial-efforts) mode='efforts' ;;` `:116`), the `efforts` early exit `:181-184`, the output `case` `:963` (`list | diagnose)`).
- Modify: `agentkit/skills/review-remote-pr/scripts/adversarial-run.sh` (856 lines; ceiling `tests/test-adversarial-run.sh:1116` `'adversarial-run.sh stays at or under 870 lines'`) — `reviewer_roster_family()` `:231-241` (comment `:231-234`, `gpt-5.6-*) printf codex ;;` `:238`), die text `:258` `is neither a claude-* nor a gpt-5.6-* model id`. **Only these hunks** (see *Overlap ruling*).
- Modify: `agentkit/skills/.shared/spawn-contract.md` (314 lines / 17943 B; no byte pin; its ```bash block is executed by `tests/test-spawn-contract-roster.sh` and pasted by roots) — `roster_entry_for_family()` `:32-47` (`codex:gpt-5.6-*) printf …` `:42`), `model_family()` `:99-107` (`gpt-5.6-*) printf codex ;;` `:102`), `resolve_worker_slot()` `:119-153` (the `has no entry for the running harness` stop `:129-130`), prose `:181-185`.
- Modify: `agentkit/skills/.shared/scripts/onboard-refresh.sh` (509 lines; no ceiling) — after the roster-hint block `:393-420` (`resolver=$self_dir/repo-config.sh` `:398`).
- Modify: `agentkit/skills/.shared/scripts/onboard-state.sh` (181 lines; no ceiling) — the `--preflight` report after `printf 'environment-preflight repo-root=%s\n'` `:103`.
- Tests: `tests/test-repo-config.sh` (`bad_roster_values` `:564-570`; reviewer compound block `:572-593` whose comment `:575` says `_FALLBACK counterpart accepts only the compound form`; `bad_reviewer_roster_values=('gpt-5.6-sol' …)` `:587`; ceiling `:621`), `tests/test-spawn-contract-roster.sh` (stub `repo-config.sh` `:28-43`, `run_resolver` `:52-70`, `has no entry` assertions `:135-141`), `tests/test-adversarial-run.sh` (roster block `:1030-1065`), `tests/test-onboard-refresh.sh` (`:110-135`), `tests/test-onboard-state.sh`.

**Premise check against `09af63c`:** (a) `worker_model_valid` accepts any `[A-Za-z0-9._:/-]` token (`:402-404`, issue says `:411`) — true. (b) `AGENT_ADVERSARIAL_REVIEWER` takes bare or compound, `_FALLBACK` compound only (`:754-757`; issue `:762-766`) — true. (c) **Write-time validation already exists**: `bootstrap-repo.sh:531-541` refuses to write a `config.env` its resolver warns about (`die 'refusing to write a config.env its own resolver warns about'`), so the gap is the validators, not the writer; the three values were hand-authored and never saw bootstrap. No `bootstrap-repo.sh` change. (d) There is no `--validate` mode; `--diagnose` (`:117`, `:890-893`) prints path diagnostics and exits 0. (e) The family glob lives in exactly three places: `repo-config.sh` has none (it is purely syntactic), `adversarial-run.sh:238`, `spawn-contract.md:42,102` — this task makes `repo-config.sh` the single home and the other two call it. (f) The Claude probe and the built-in default refresh are **not taken** (reasons in *Self-review*). (g) `--yolo` reaches the spawn block only as the root's shell variable `yolo_invocation` (`parallel-issues/SKILL.md:85` `yolo=${yolo_invocation:-false}`); no helper carries it.

**North star:** removes the 8-minute turn-1 round trip ("May I use gpt-6-astra?") and the 7.5-hour blocked review (dotted id) from a run, and the 14 repeated `invalid value for AGENT_ADVERSARIAL_REVIEWER_FALLBACK` lines from every helper call; `--validate` turns a mid-run discovery into a one-line answer at onboarding.

- [ ] **Step 1 (red — validator):** in `tests/test-repo-config.sh`, before the ceiling at `:621`, add:

```bash
# --- issue #606: the three hand-authored values that passed silently ------
printf 'AGENT_WORKER_MODELS=codex-gpt-6-astra,claude-opus-5\nAGENT_ADVERSARIAL_REVIEW_MODEL=claude-fable-5.1\nAGENT_ADVERSARIAL_REVIEWER_FALLBACK=codex\n' \
    > "$repo/.agent/config.env"
validate_rc=0
validate_out=$("$rc_sh" --repo-root "$repo" --validate 2>&1) || validate_rc=$?
assert_eq 1 "$validate_rc" '--validate exits non-zero when any declaration is invalid'
assert_contains "$validate_out" 'invalid value for AGENT_WORKER_MODELS on line 1, ignoring -- did you mean gpt-6-astra,claude-opus-5' \
    'a harness-prefixed roster entry is refused with the corrected roster'
assert_contains "$validate_out" 'invalid value for AGENT_ADVERSARIAL_REVIEW_MODEL on line 2, ignoring -- did you mean claude-fable-5-1' \
    'a dotted Claude model id is refused with the hyphenated form'
assert_not_contains "$validate_out" 'AGENT_ADVERSARIAL_REVIEWER_FALLBACK' \
    'a bare CLI name is valid for the fallback reviewer exactly as for the primary'
printf 'AGENT_WORKER_MODELS=gpt-6-astra,claude-opus-5\nAGENT_ADVERSARIAL_REVIEWER=gpt-6-astra-xhigh\n' > "$repo/.agent/config.env"
assert_rc 0 '--validate exits zero on a gpt-6-* roster and reviewer' -- "$rc_sh" --repo-root "$repo" --validate
assert_eq codex "$("$rc_sh" --model-family gpt-6-astra)" '--model-family names the codex family for a gpt-6-* id'
assert_eq claude "$("$rc_sh" --model-family claude-opus-5)" '--model-family names the claude family'
assert_eq opencode "$("$rc_sh" --model-family wrzcluster/qwen3-coder)" '--model-family names opencode for provider/model'
assert_rc 1 '--model-family fails for an unknown family' -- "$rc_sh" --model-family codex-gpt-6-astra
```

Update the stale comment `:575` (`the new _FALLBACK counterpart accepts only the compound form`) to `both accept the bare CLI name and the compound form (issue #606)`. `--only repo-config` → **180 assertions / 8 FAIL** (`--validate`/`--model-family` are unknown options → usage exit 2; measured).

- [ ] **Step 2 (red — spawn contract):** in `tests/test-spawn-contract-roster.sh`, extend the stub `repo-config.sh` (`:28-43`) so `--model-family` delegates to the **real** script (the test keeps pinning the real predicate, not a copy): add `--model-family) exec "$REAL_REPO_CONFIG" --model-family "$2" ;;` to its `case`, and export `REAL_REPO_CONFIG="$root/agentkit/skills/.shared/scripts/repo-config.sh"` in `run_resolver`; give `run_resolver` an optional third argument exported as `yolo_invocation`. Then after the `has no entry` block (`:141`):

```bash
# issue #606: a gpt-6-* roster entry resolves on Codex (the family glob no
# longer stops at gpt-5.6-*), and under --yolo a roster with no entry for the
# running harness falls through to the singular key or the built-in default
# with one stderr line instead of ending the turn.
printf 'AGENT_WORKER_MODELS=claude-sonnet-5,gpt-6-astra\n' > "$tmp/gpt6.env"
out=$(run_resolver "$tmp/gpt6.env" codex 2>/dev/null)
assert_contains "$out" 'worker_model=gpt-6-astra' 'a declared gpt-6-* roster entry resolves on Codex'
err=$(run_resolver "$tmp/incomplete-roster.env" codex true 2>&1 1>/dev/null); rc=$?
assert_eq 0 "$rc" 'under --yolo an incomplete roster does not end the turn'
assert_contains "$err" 'yolo: declared roster AGENT_WORKER_MODELS' 'the degrade is announced on stderr once'
assert_contains "$(run_resolver "$tmp/incomplete-roster.env" codex true 2>/dev/null)" 'worker_model=gpt-5.6-terra' \
    'and dispatch falls through to the declared singular key'
printf 'AGENT_WORKER_MODELS=claude-sonnet-5\n' > "$tmp/roster-only-claude.env"
assert_contains "$(run_resolver "$tmp/roster-only-claude.env" codex true 2>/dev/null)" 'worker_model=gpt-5.6-luna' \
    'with no singular key declared the yolo degrade lands on the harness built-in default'
```

**Where the yolo degrade lands (decided):** the yolo branch falls through to the singular-key path below it, so a declared `AGENT_WORKER_MODEL` still wins (declaration is authorization) and only an undeclared slot lands on the built-in default. `incomplete-roster.env` (`:109`) declares `AGENT_WORKER_MODEL=gpt-5.6-terra`, sanctioned for codex, so that fixture lands on **`gpt-5.6-terra`**; the roster-only fixture lands on `gpt-5.6-luna`. The stderr line (Step 6), the prose, and both assertions say exactly this. `--only spawn-contract-roster` → **28 assertions / 5 FAIL** (measured).

- [ ] **Step 3 (red — adversarial-run + onboarding):** `tests/test-adversarial-run.sh`, after the roster block (`:1057`): a `make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=gpt-6-astra-xhigh'` run on the claude harness with the codex peer present (`write_contract_at "$repo" claude codex "present path=$tmp/fake-codex"`, grant `openai`, fixture diff rendered like the roster block's) must exit 0 with `model=gpt-6-astra` in the receipt (today it dies with `unrecognized model family`). **Rewrite the roster-unknown block `:1086-1110` in the same step** — after Step 4 `reviewer_roster_entry_valid` requires a known family, so repo-config.sh drops `AGENT_ADVERSARIAL_REVIEWER=some-other-provider-high` before adversarial-run.sh ever sees it and the run falls to the pinned defaults; the old pins (`rc 1`, `unrecognized model family` and the value on adversarial-run's stderr) go red on green. Mirror the existing dropped-declaration block at `:569-593`: change the grant to `anthropic` (the pinned cross-provider default on a codex harness is claude) and replace the four assertions with

```bash
assert_eq 0 "$roster_unknown_rc" 'a roster compound in neither known family is dropped and the pinned defaults complete'
roster_unknown_validate_rc=0
roster_unknown_validate=$("$root/agentkit/skills/.shared/scripts/repo-config.sh" --repo-root "$repo_roster_unknown" --validate 2>&1) || roster_unknown_validate_rc=$?
assert_eq 1 "$roster_unknown_validate_rc" 'repo-config.sh --validate refuses a roster compound in neither known family'
assert_contains "$roster_unknown_validate" 'invalid value for AGENT_ADVERSARIAL_REVIEWER on line 1, ignoring -- accepted:' \
    'the refusal names the key and the accepted set (repo-config.sh drops it before adversarial-run.sh ever sees it)'
assert_not_contains "$(cat -- "$tmp/roster-unknown.err")" 'unrecognized model family' \
    'adversarial-run.sh itself says nothing about a value repo-config.sh already dropped'
assert_contains "$(cat -- "$tmp/roster-unknown.out")" 'provider=anthropic model=claude-opus-5' \
    'the run lands on the pinned cross-provider default, not on a guessed family'
assert_eq no "$( [[ -e $tmp/roster-unknown-codex.called ]] && printf yes || printf no )" \
    'an unrecognized family never silently launches codex'
```

(adversarial-run.sh discards repo-config's stderr at `:221` — `2>/dev/null` — so the refusal is pinned on `--validate` directly, never on the run's stderr; the block's header comment says the same). `tests/test-onboard-refresh.sh` after `:135`: a config carrying `AGENT_ADVERSARIAL_REVIEW_MODEL=claude-fable-5.1` makes `--report` print `config-validate= invalid` and `did you mean claude-fable-5-1`; a clean config prints `config-validate= ok`. `tests/test-onboard-state.sh`: `--preflight` prints the same `config-validate=` line. `--only adversarial-run,onboard-refresh,onboard-state` → **adversarial-run 175 / 8, onboard-refresh 36 / 3, onboard-state 29 / 1** (measured; the adversarial-run eight are the two gpt-6 assertions, five of the rewritten roster-unknown block, and the 853 ceiling).

- [ ] **Step 4 (fix — repo-config.sh, the single home):** **`model_family` goes beside the `readonly` arrays (directly after `ADVERSARIAL_REVIEW_EFFORT_ACCEPTED_NAMES`, `:82`), before argv parsing** — bash defines functions as it reads the file, and the `--model-family` early exit (below) runs at `~:187`, long before the validators around `:404` are defined; placed there it fails with `model_family: command not found` for every id and takes every roster consumer (adversarial-run, spawn-contract-roster, parallel-dispatch-contract) down with it. Moving the exit down instead does not work either — the script exits 0 at the config-file check (`~:209`) for a mode it does not know.

```bash
# Defined beside the readonly arrays so the --model-family early exit below
# can run before any repo-root/config-file resolution.
# model_family ID -- codex|claude|opencode, or exit 1 printing nothing. The ONE
# home for this predicate (issue #606): adversarial-run.sh and the
# spawn-contract.md resolver block call it through --model-family.
model_family() {
    case $1 in
        claude-*) printf claude ;;
        gpt-5.6-* | gpt-6-*) printf codex ;;
        */*) [[ $1 =~ ^[^/]+/[^/]+$ ]] && printf opencode || return 1 ;;
        *) return 1 ;;
    esac
}
```

The three helpers below go after `worker_model_valid` (`:404`):

```bash
# model_id_valid ID -- worker_model_valid plus the one shape the Claude CLI
# rejects: a dotted claude-* id (claude-fable-5.1 must be claude-fable-5-1).
model_id_valid() {
    worker_model_valid "$1" || return 1
    [[ $(model_family "$1") != claude || $1 != *.* ]]
}

# model_id_suggestion ID -- the corrected spelling for the two hand-authored
# mistakes the validators refuse, or nothing.
model_id_suggestion() {
    local id=$1 rest
    if [[ $(model_family "$id") == claude && $id == *.* ]]; then
        printf '%s' "${id//./-}"
    elif [[ $id =~ ^(codex|claude)-(.+)$ ]]; then
        rest=${BASH_REMATCH[2]}
        model_family "$rest" > /dev/null && printf '%s' "$rest"
    fi
}

# value_suggestion KEY VALUE -- the corrected whole value for a model-bearing
# key (roster CSV, reviewer compound, or bare id), or nothing.
value_suggestion() {
    local key=$1 value=$2 item effort out='' changed=0 model suggestion
    case $key in
        AGENT_WORKER_MODELS | AGENT_WORKER_MODELS_FALLBACK)
            local -a items=(); IFS=, read -ra items <<< "$value"
            for item in "${items[@]}"; do
                suggestion=$(model_id_suggestion "$item"); [[ -n $suggestion ]] && changed=1
                out+="${out:+,}${suggestion:-$item}"
            done ;;
        AGENT_ADVERSARIAL_REVIEWER | AGENT_ADVERSARIAL_REVIEWER_FALLBACK)
            for effort in "${ADVERSARIAL_REVIEW_EFFORT_ACCEPTED_NAMES[@]}"; do
                [[ $value == *-"$effort" ]] || continue
                model=${value%-"$effort"}; suggestion=$(model_id_suggestion "$model")
                [[ -n $suggestion ]] && { changed=1; out="$suggestion-$effort"; }
            done ;;
        *) suggestion=$(model_id_suggestion "$value"); [[ -n $suggestion ]] && { changed=1; out=$suggestion; } ;;
    esac
    ((changed)) && printf '%s' "$out"
}
```

Then: `worker_models_roster_valid` `:421` `worker_model_valid "$item" || return 1` → `model_id_valid "$item" && model_family "$item" > /dev/null || return 1` (a roster entry must belong to a known family — that is what makes `codex-gpt-6-astra` a write-time error; the singular `AGENT_WORKER_MODEL*` keys keep `worker_model_valid`, because `test-repo-config.sh:490-495` pins `gpt-9-custom` and `provider/model-v1` as accepted there and the sanctioned-set gate owns them). `reviewer_roster_entry_valid` `:435` → `model_id_valid "${value%-"$effort"}" && model_family "${value%-"$effort"}" > /dev/null && return 0`. Case arms `:754-757` → one arm `AGENT_ADVERSARIAL_REVIEWER | AGENT_ADVERSARIAL_REVIEWER_FALLBACK) adversarial_reviewer_valid "$value" || reviewer_roster_entry_valid "$value" ;;`; `:759` `worker_model_valid` → `model_id_valid`. Warn ladder: insert before the final `else` at `:879`:

```bash
        elif suggestion=$(value_suggestion "$key" "$value") && [[ -n $suggestion ]]; then
            warn "invalid value for $key on line $lineno, ignoring -- did you mean $suggestion"
```

(declare `suggestion` with the loop's other locals). Modes: usage `:38` adds `--validate | --model-family ID`; argv `:116` neighbour gains `--validate) mode='validate' ;;` and `--model-family) mode='family'; shift; (($#)) || die_usage '--model-family requires a MODEL-ID'; want_key=$1 ;;`; `:164`'s list adds `--validate`, `--model-family` (grep `tests/` for the literal `one of --export` first; if pinned, update that pin in the same PR); beside the `efforts` early exit `:181-184` add `if [[ $mode == family ]]; then model_family "$want_key" || exit 1; printf '\n'; exit 0; fi`; the two `parse_failed=1` conditions `:881-882` and `:916-917` become `[[ $mode == canonical || $mode == validate || ( $mode == resolve && … ) ]]`; the output `case` gains `validate) ((parse_failed == 0)) || exit 1 ;;`. Rewrite the now-false comment `:398-401` to `# Singular worker keys stay syntactic: an unsupported value must remain visible to the explicit-authorization gate. Family membership is checked only where a roster or reviewer entry claims one (model_family below).` and cut `:426-430` to two lines (`_FALLBACK` no longer "compound only"). Measured: 1045 → **1098** (+53); the ceiling at `tests/test-repo-config.sh:621` moves to the measured count with the comment `# 2026-09-09 issue #606: +53, the model-family predicate and corrected-form suggestions now live here and only here (adversarial-run.sh -3, spawn-contract.md -10). Measured.`

- [ ] **Step 5 (fix — adversarial-run.sh, family hunk only):**

```bash
# before (:231-241)
# reviewer_roster_family MODEL-ID -- the family (codex|claude) a roster id
# belongs to, mirroring spawn-contract.md's model_family without its
# unknown/opencode fallthrough: this runner launches exactly two CLIs, so an
# unrecognised family returns 1 (prints nothing) and the caller reports it.
reviewer_roster_family() {
    case $1 in
        claude-*) printf claude ;;
        gpt-5.6-*) printf codex ;;
        *) return 1 ;;
    esac
}
# after
# reviewer_roster_family MODEL-ID -- codex|claude from repo-config.sh's single
# model_family (issue #606); this runner launches exactly two CLIs, so
# opencode or unknown returns 1 (prints nothing) and the caller reports it.
reviewer_roster_family() {
    local family
    [[ -x $REPO_CONFIG_SH ]] && family=$("$REPO_CONFIG_SH" --model-family "$1" 2>/dev/null) || return 1
    [[ $family == codex || $family == claude ]] && printf '%s' "$family"
}
```

Die text `:258` → `'$ROSTER_MODEL' is not a claude-* or gpt-5.6-*/gpt-6-* model id` (no test pins the old text — `grep -rn 'neither a claude' tests` is empty; the roster-unknown block's `unrecognized model family` pin is rewritten in Step 3 because the value no longer reaches this die). Net −3 lines (856 → **853**, measured); ratchet `tests/test-adversarial-run.sh:1116` from 870 to 853 with the comment `# 2026-09-09 issue #606: -3, the family predicate now lives in repo-config.sh; measured.` — #609 then raises it again by its own measured delta.

- [ ] **Step 6 (fix — spawn-contract.md block):** `roster_entry_for_family` `:36-46` → the loop body becomes `[ "$(model_family "$item")" = "$family" ] && { printf '%s\n' "$item"; return 0; }` (the case and the OpenCode `=~` branch go: the predicate now answers both); `model_family` `:99-107` → `model_family() { "$agentkit/.shared/scripts/repo-config.sh" --model-family "$1" 2> /dev/null || printf unknown; }` (`resolve_worker_slot` compares against `unknown`, `:139`, unchanged); `model_in_sanctioned_set` unchanged (the sanctioned tier is policy, not family). In `resolve_worker_slot` replace `:129-130`:

```bash
# before
        printf '%s\n' "declared roster $roster_key='$roster_csv' has no entry for the running harness '$running_harness'; the roster is authoritative once declared and never falls back to $base or a built-in default -- add a $running_harness entry or remove the roster declaration" >&2
        exit 1
# after
        if [ "${yolo_invocation:-false}" = true ]; then
            printf '%s\n' "yolo: declared roster $roster_key='$roster_csv' has no entry for the running harness '$running_harness'; falling back to the singular key or the built-in default $native_default instead of stopping (issue #606)" >&2
        else
            printf '%s\n' "declared roster $roster_key='$roster_csv' has no entry for the running harness '$running_harness'; the roster is authoritative once declared and never falls back to $base or a built-in default -- add a $running_harness entry or remove the roster declaration" >&2
            exit 1
        fi
```

(the yolo branch falls through to the singular-key path below it — a declared `AGENT_WORKER_MODEL` still wins, an undeclared slot lands on `$native_default`; the message, the prose, and Step 2's assertions all say so). Prose `:183-185`: append `Under --yolo the same case falls through to the singular key or the harness built-in default with one stderr line: declaration is authorization, and a malformed declaration in an authorized run is a warning, not a stop.` Note the `roster_entry_for_family`'s `# OpenCode ids …` comment goes with its branch. Measured: 314 → 304 lines (−10).

- [ ] **Step 7 (fix — onboarding reports):** `onboard-refresh.sh`, after `:420`'s hint block: `config_validate_line='config-validate= ok'; if [[ -x $resolver && -r $config ]] && ! validate_err=$("$resolver" --repo-root "$repo_root" --validate 2>&1); then config_validate_line="config-validate= invalid: ${validate_err%%$'\n'*}"; fi` and print it with the other drift lines (find where `roster_hint_lines` is emitted and print immediately after; the `--report` summary flag pattern at `model-roster=hint` gets a sibling `config-validate=invalid` when non-empty). `onboard-state.sh` `--preflight` (after `:103`): the same five lines using `$self_dir/repo-config.sh`. Both are advisory (never exit non-zero on it — the drift advisory in the session contract reports it; onboarding refresh is an operator decision).
- [ ] **Step 8 (green):** `bash -n` + shellcheck on the four scripts; extract-and-check the md block the way the suite does (`awk '/^```bash$/{flag=1; next} /^```$/{flag=0} flag' agentkit/skills/.shared/spawn-contract.md > /tmp/r.sh && bash -n /tmp/r.sh && shellcheck -s bash -S style -e SC2154 /tmp/r.sh` — the block on `main` already reports `SC2148` (no shebang) and `SC2154 repository_root`; no new findings is the bar); `tests/run-tests.sh --only repo-config,spawn-contract-roster,adversarial-run,onboard-refresh,onboard-state,bootstrap-repo,parallel-dispatch-contract,skills-contract,probe-contract` → **repo-config 180/0, spawn-contract-roster 28/0, adversarial-run 175/0, onboard-refresh 36/0, onboard-state 29/0, bootstrap-repo 159/0, parallel-dispatch-contract 626/0, skills-contract 175/0, probe-contract 35/0** (measured); `tests/lint-skill-size.sh agentkit/skills`; `tests/lint-helper-refs.sh agentkit/skills`; full `tests/run-tests.sh`.
- [ ] **Step 9: Shared step** with `SCOPE=repo-config`, `TITLE='one model-family predicate, corrected-form validation, symmetric reviewer keys, yolo degrade'`, `WHY='Three hand-authored config.env values passed the validators and surfaced only mid-run: a codex-prefixed roster entry ended turn 1 with a question under --yolo, a dotted Claude id blocked every adversarial review for 7.5 hours, and a bare-CLI fallback reviewer printed invalid value fourteen times per session; the gpt-5.6-* family glob also rejected every gpt-6-* id outright, in three separate copies.'`, `WHAT='repo-config.sh owns the single model_family predicate (claude-*, gpt-5.6-*/gpt-6-*, provider/model) exposed as --model-family; roster and reviewer entries must belong to a known family and claude ids must not be dotted; --validate exits non-zero listing each invalid key with its corrected form (did you mean ...); AGENT_ADVERSARIAL_REVIEWER_FALLBACK accepts exactly what AGENT_ADVERSARIAL_REVIEWER accepts; adversarial-run.sh and the spawn-contract resolver block call the predicate instead of carrying copies; under --yolo a roster with no entry for the running harness falls through to the declared singular key or the harness built-in default with one stderr line instead of ending the turn; onboard-refresh and onboard-state report config-validate=. bootstrap-repo.sh already refused a config its resolver warns about, so hand-authored files are the only path this closes. repo-config 1045 -> 1098 lines (+53, reason in the test), adversarial-run 856 -> 853, spawn-contract.md 314 -> 304.'`, `FILES=(agentkit/skills/.shared/scripts/repo-config.sh agentkit/skills/review-remote-pr/scripts/adversarial-run.sh agentkit/skills/.shared/spawn-contract.md agentkit/skills/.shared/scripts/onboard-refresh.sh agentkit/skills/.shared/scripts/onboard-state.sh tests/test-repo-config.sh tests/test-spawn-contract-roster.sh tests/test-adversarial-run.sh tests/test-onboard-refresh.sh tests/test-onboard-state.sh)`, `ISSUE=606`.

---

### Task 5 (#609): adversarial review — payload size gate, declared exclusions, PR-scoped auto-review consent

**Branch:** `fix/issue-609` from `fix/issue-606` (chain; see *Overlap ruling*).

**Files:**
- Modify: `agentkit/skills/.shared/scripts/lib/canonical-diff.sh` (9 lines; no ceiling; sourced by `adversarial-run.sh:19` and `consent-record.sh`) — `canonical_diff()` `:4-9`.
- Modify: `agentkit/skills/review-remote-pr/scripts/adversarial-run.sh` — `build_diff()` `:436-447`, `main()` order `:830-836` (`resolve_base` → `build_diff` → `if resolve_base_declared_config; then select_reviewer …` → `compute_payload`), `receipt_line()` `:657-666`, `run_provider()` `:767-781` (`helper_args+=(--max-tokens 400000)` `:780` for openai, `--max-budget-usd 5.00` `:778` for anthropic), `write_blocked_result()`. **Only these hunks.**
- Modify: `agentkit/skills/review-remote-pr/scripts/consent-record.sh` (427 lines; no ceiling) — `payload_command()` base-sha render `:261-263` (`git --no-pager diff --find-renames --unified=25 "$resolved_sha...HEAD"`), `check_command()` `:400-403` (the two `expected=` exact matches).
- Modify: `agentkit/skills/review-remote-pr/references/adversarial-review.md` (19404 B; ceiling `tests/test-review-artifacts.sh:588` `-le 19600`) — `:142-146`.
- Tests: `tests/test-adversarial-run.sh` (fixture repo `:15-32`, `grant()` `:98-106`, receipt assertions are `assert_contains` only; ceiling `:1116`), `tests/test-consent-record.sh` (`:261-283`), `tests/test-cross-provider-consent.sh` (prose pins), `tests/test-adversarial-review-bounds.sh` (`:281,288` pin `DEFAULT_MAX_TOKENS=400000` in the codex helper and `--max-tokens 400000` in the skill text — untouched), `tests/test-review-artifacts.sh:588`. **`tests/test-canonical-diff.sh` does not exist on `09af63c`** (the lead's list named it); `canonical_diff` is exercised through `test-adversarial-run.sh`, which sources the lib, and `test-consent-record.sh`.

**Premise check against `09af63c`:** (a) the launch args are at `:767-781`, not `:816`, and the **Claude** launch carries `--max-budget-usd 5.00`, the Codex one `--max-tokens 400000` — a budget cap does not stop a 1.4M-token prompt from being sent. (b) `canonical-diff.sh` is 9 lines with no estimate and no exclusion — true. (c) The consent sentence is at `adversarial-review.md:145`, not `:182`. (d) The payload id is `REPO:PR:sha256(diff)` (`consent-record.sh:297`) and `check` accepts only an exact record (`:400-403`) — true. (e) **The real exclusion mechanism** is `AGENT_GENERATED_PATHS`: comma-separated relative prefixes validated by `generated_paths_valid` (`repo-config.sh:346-355`) and matched as `path == spec || path == spec/*` by `diff-facts.sh:82-100` and `gh-pr-state.sh:411-430`; `verification-baseline.sh` is the baseline-*red* classifier and carries no exclusion list. So the exclusions are `AGENT_GENERATED_PATHS` prefixes plus built-in vendored trees, expressed as git `:(exclude,top)` pathspecs. (f) **Trust boundary:** the declared prefixes must come from the PR's **base** revision, never the checkout under review (a PR could add `AGENT_GENERATED_PATHS=src` to hide itself) — the same rule `resolve_base_declared_config` (`:466-482`) already applies to the reviewer settings, so `canonical_diff` reads `origin/<base>:.agent/config.env` itself and both renderers (`adversarial-run` and `consent-record`) agree by construction.

**Deviations from the issue, stated:** lockfiles are **not** excluded — a dependency swap is exactly what a blind adversarial review should see, and `diff-facts.sh` classifies them separately already; the built-ins are `vendor`, `third_party`, `node_modules`. "The reduced payload is built automatically" is delivered as: declared and built-in exclusions are applied on every render, and the too-large refusal names the remedy (`AGENT_GENERATED_PATHS`) — there is no heuristic file-dropping, because a payload the reviewer never saw must be one the receipt can name.

**North star:** removes a spent launch with no verdict, the hand-built reduced diff, and the second consent question (one human round trip) from a run.

- [ ] **Step 1 (red — exclusions):** in `tests/test-adversarial-run.sh`, before the ceiling (`:1116`), build a trust repo (`make_trust_repo 'AGENT_GENERATED_PATHS=generated'`), commit on `feature` a change to `example.txt`, `generated/big.txt` and `vendor/lib.c`, run the script with the fake codex peer, and assert: the receipt contains **`exclusions=4`** (`receipt_line` emits `${#EXCLUSION_SPECS[@]}` = 3 built-ins + 1 declared) and `excluded_sha256=` followed by 64 hex; `adversarial.diff` in the run dir mentions `example.txt` and neither `generated/big.txt` nor `vendor/lib.c`; `adversarial.exclusions` lists `:(exclude,top)vendor`, `:(exclude,top)third_party`, `:(exclude,top)node_modules`, `:(exclude,top)generated`; `adversarial.excluded.diff` exists mode 0600 and mentions both excluded paths. **The fixture's grant must hash the same bytes the script will render:** `grant()` (`:98-106`) hashes the diff it is handed (`payload … --diff`, no `--base-ref`), while `compute_payload` hashes the excluded canonical render — a diff rendered the way every other block does gets `supplied diff does not match` / a consent refusal instead of the assertions. Render it with the same pathspecs:

```bash
git -C "$repo_excl" --no-pager diff --find-renames --unified=25 origin/main...HEAD -- ':/' ':(exclude,top)vendor' ':(exclude,top)third_party' ':(exclude,top)node_modules' ':(exclude,top)generated' >"$diff_excl"
```

Add a tamper case: the PR itself adds `AGENT_GENERATED_PATHS=example.txt` to `.agent/config.env` (grant rendered with the same four pathspecs) — the diff still contains `example.txt` and the config edit itself (base-revision config wins), and the existing `warn 'the reviewed diff changes .agent/config.env …'` line is on the run's stderr (`assert_contains "$(cat -- "$tmp/tamper.err")" …` — one capture, no fallback expression: under `set -u` a misspelled variable inside `$(… || …)` kills the subshell before the fallback). `--only adversarial-run` → FAIL.
- [ ] **Step 2 (red — size gate):** same suite: with `ADVERSARIAL_PAYLOAD_TOKEN_LIMIT=10` exported, a normal run exits non-zero **without invoking the fake helper** — `fake-codex` (`:77-93`) has **no** invocation marker today (the existing `roster-unknown-codex.called` assertion is vacuous); add `[[ -z ${FAKE_CODEX_CALLED:-} ]] || printf 'called\n' >>"$FAKE_CODEX_CALLED"` after its probe early-exit (`:85`) and pass `FAKE_CODEX_CALLED="$tmp/gate-codex.called"` to the run, the run dir carries `adversarial.payload-size` whose single line matches `^payload=too-large estimate=[1-9][0-9]* limit=10$`, `adversarial.result.json` has `.status == "blocked"` and `.blockedReason == "payload-too-large"`, the receipt says `verdict=blocked`, and **no** `launch-attempted` marker / consent check ran (assert the consent state file is untouched and `adversarial.launch-attempted` — the marker `write_launch_attempted` writes — is absent). With `ADVERSARIAL_PAYLOAD_TOKEN_LIMIT` unset the same run launches and `adversarial.payload-size` reads `payload=ok estimate=N limit=800000`. `--only adversarial-run` → FAIL.
- [ ] **Step 3 (red — PR-scoped consent):** in `tests/test-consent-record.sh` after `:283` (`'the prior payload is not reusable after replacement'`):

```bash
# issue #609: an auto-review-flag grant is scoped to the PR -- a reduced
# payload of the same repo/PR/provider inherits it; another PR does not.
assert_rc 0 'an auto-review grant covers a different payload digest for the same PR and provider' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$payload_one"
other_pr_payload="${payload_one%:*}"; other_pr_payload="${other_pr_payload%:*}:43:${payload_one##*:}"
assert_rc 10 'an auto-review grant never covers another PR' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$other_pr_payload"
grant=$(/bin/bash "$script" grant --state "$state" --provider openai --payload "$payload_two" --source interactive)
assert_rc 10 'an interactive grant stays exact-payload' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$payload_one"
```

(`payload_one`/`payload_two` are both `acme/widget:42:<digest>` in this suite — confirm with `printf '%s\n' "$payload_one" "$payload_two"` and, if the PR numbers differ, derive `payload_one_same_pr` from `payload_two`'s prefix.) `--only consent-record` → 86 assertions / 1 FAIL (the first; measured).
- [ ] **Step 4 (fix — canonical-diff.sh):**

```bash
#!/usr/bin/env bash
# Shared canonical PR-diff rendering for consent and adversarial review.

# Vendored trees excluded from every review payload regardless of declaration
# (issue #609); repository-specific generated paths come from the BASE
# revision's AGENT_GENERATED_PATHS, never from the checkout under review.
CANONICAL_DIFF_BUILTIN_EXCLUSIONS=(vendor third_party node_modules)

# canonical_diff_exclusions REV -- one `:(exclude,top)PREFIX` pathspec per line
# for REV's declared AGENT_GENERATED_PATHS plus the built-ins above. REV is
# `origin/<base>` or a full SHA; a REV without .agent/config.env yields only
# the built-ins.
canonical_diff_exclusions() {
    local rev=$1 resolver spec declared='' config_tmp
    local -a specs=("${CANONICAL_DIFF_BUILTIN_EXCLUSIONS[@]}") declared_items=()
    resolver=$(dirname -- "${BASH_SOURCE[0]}")/../repo-config.sh
    if [[ -x $resolver ]] && config_tmp=$(mktemp) && git show "$rev:.agent/config.env" >"$config_tmp" 2>/dev/null; then
        declared=$("$resolver" --repo-root "$(git rev-parse --show-toplevel)" --config-file "$config_tmp" \
            --get AGENT_GENERATED_PATHS 2>/dev/null) || declared=''
    fi
    rm -f -- "${config_tmp:-}"
    IFS=, read -ra declared_items <<< "$declared"
    for spec in "${specs[@]}" "${declared_items[@]}"; do
        while [[ $spec == ./* ]]; do spec=${spec#./}; done
        while [[ $spec == */ ]]; do spec=${spec%/}; done
        [[ -n $spec && $spec != . ]] || continue
        printf ':(exclude,top)%s\n' "$spec"
    done
}

# canonical_diff_range RANGE REV -- the exact diff flags every renderer uses.
canonical_diff_range() {
    local -a pathspecs=()
    mapfile -t pathspecs < <(canonical_diff_exclusions "$2")
    # ':/' anchors the pathspec at the repository top: the payload is
    # repo-relative from any cwd (`.` would shrink it from a subdirectory).
    git --no-pager diff --find-renames --unified=25 "$1" -- ':/' "${pathspecs[@]}"
}

canonical_diff() {
    local base_ref=${1:-}
    [[ -n $base_ref ]] || return 1
    git check-ref-format --branch "$base_ref" >/dev/null 2>&1 || return 1
    canonical_diff_range "origin/$base_ref...HEAD" "origin/$base_ref"
}

# canonical_diff_token_estimate FILE -- bytes / 3.5, rounded down.
canonical_diff_token_estimate() {
    local bytes
    bytes=$(wc -c <"$1") || return 1
    printf '%s\n' $(( bytes * 2 / 7 ))
}
```

`consent-record.sh:261-263`: replace the inline `git --no-pager diff … "$resolved_sha...HEAD"` with `canonical_diff_range "$resolved_sha...HEAD" "$resolved_sha"` (the comment above it — `The flags below mirror canonical_diff() exactly` — becomes true by construction; shorten it to one line).

- [ ] **Step 5 (fix — adversarial-run.sh):** near the top with the other readonly constants: `readonly ADVERSARIAL_PAYLOAD_TOKEN_LIMIT=${ADVERSARIAL_PAYLOAD_TOKEN_LIMIT:-800000}` with the comment `# issue #609: the reviewed run sent 1,383,825 estimated tokens against the 1,000,000 limit the Claude CLI reported; 800,000 leaves prompt and verdict headroom. Env-overridable for tests; shared by both providers (the Codex limit is not independently verified).` In `build_diff` after the emptiness checks, record the exclusion evidence:

```bash
    mapfile -t EXCLUSION_SPECS < <(canonical_diff_exclusions "origin/$BASE_REF")
    prepare_owned_artifact "$RUN_DIR/adversarial.exclusions"
    (umask 077; printf '%s\n' "${EXCLUSION_SPECS[@]}" >"$RUN_DIR/adversarial.exclusions")
    prepare_owned_artifact "$RUN_DIR/adversarial.excluded.diff"
    (umask 077; git --no-pager diff --find-renames --unified=25 "origin/$BASE_REF...HEAD" -- "${EXCLUSION_SPECS[@]/#:(exclude,top)/:(top)}" >"$RUN_DIR/adversarial.excluded.diff")
    EXCLUDED_SHA256=$(sha256sum -- "$RUN_DIR/adversarial.excluded.diff" | awk '{print $1}')
```

(declare `EXCLUSION_SPECS=()` and `EXCLUDED_SHA256=''` beside `PAYLOAD=''` at `:49`.) Add the gate:

```bash
# issue #609: refuse to spend on a payload the provider cannot hold; the
# one-line reason names the remedy instead of a launch with no verdict.
payload_size_gate() {
    local estimate verdict=ok
    estimate=$(canonical_diff_token_estimate "$RUN_DIR/adversarial.diff") || die 'could not measure the adversarial diff'
    ((estimate <= ADVERSARIAL_PAYLOAD_TOKEN_LIMIT)) || verdict=too-large
    prepare_owned_artifact "$RUN_DIR/adversarial.payload-size"
    (umask 077; printf 'payload=%s estimate=%s limit=%s\n' "$verdict" "$estimate" "$ADVERSARIAL_PAYLOAD_TOKEN_LIMIT" >"$RUN_DIR/adversarial.payload-size")
    [[ $verdict == ok ]] && return 0
    write_blocked_result payload-too-large "estimated $estimate tokens exceeds the $ADVERSARIAL_PAYLOAD_TOKEN_LIMIT-token launch limit; declare vendored or generated trees in AGENT_GENERATED_PATHS on the base branch and re-run"
    receipt_line
    return 1
}
```

`main` `:830-836` keeps `build_diff` first — **`build_diff` is the only place that fetches `origin/<base>`** (`git fetch --quiet origin "$BASE_REF"`, `:440`; `resolve_base` never does), and `resolve_base_declared_config` reads `origin/$BASE_REF` (`git diff --name-only … -- .agent/config.env`, `git show origin/$BASE_REF:.agent/config.env`), so running it before the fetch would judge a stale ref (a config change that landed on the base since the last fetch reads as "the PR touches config" → pinned defaults, or picks stale reviewer settings; the fixture's origin is local, so the suite cannot see it). The gate slots in after the reviewer is selected (a blocked result names PROVIDER/MODEL) and before `compute_payload`, consent, and any launch marker:

```bash
    resolve_base
    build_diff
    if resolve_base_declared_config; then
        select_reviewer "$BASE_CONFIG_FILE"
        require_helper_executable
    fi
    # issue #609: after select_reviewer (a blocked result names PROVIDER/MODEL)
    # and before compute_payload/consent/any launch marker.
    payload_size_gate || return 1
    compute_payload
```

`receipt_line` `:664-665` appends ` exclusions=%s excluded_sha256=%s` with `"${#EXCLUSION_SPECS[@]}" "${EXCLUDED_SHA256:-none}"`. `run_provider` `:777-781` unchanged (the helper caps stay; the gate runs before them). Measured: 853 → **883** (+30) on top of #606; the ceiling at `tests/test-adversarial-run.sh:1116` moves to 883 with `# 2026-09-09 issue #606: -3 (family predicate moved to repo-config.sh); issue #609: +30, the size gate and exclusion receipt; the renderers live in lib/canonical-diff.sh. Measured.`

- [ ] **Step 6 (fix — consent-record.sh check):** after the two exact matches `:400-403`:

```bash
    # issue #609: an auto-review-flag grant is scoped to the PR, so a reduced
    # payload (same repo, PR, and provider; different digest) inherits it.
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=${PAYLOAD%:*}:"
    [[ $record == "$expected"*';status=granted;source=auto-review-flag' ]] && return 0
```

(record format unchanged: `scope=PR-diff` stays literal so `adversarial-review.md:129,144` and every existing pin keep matching; the scope widening is a property of the `auto-review-flag` source, documented in Step 7.)

- [ ] **Step 7 (docs):** `adversarial-review.md:145` keeps the pinned phrase **verbatim** — `tests/test-cross-provider-consent.sh:37` asserts `'provider, PR, or diff changes'` (`'a changed PR or diff requires renewed consent'`) and a rewrite that drops it is 1 FAIL. The sentence becomes: `reuse it only for a retry of the exact same payload to the same provider and scope. If the destination provider, PR, or diff changes, obtain confirmation again -- except that an auto-review-flag grant covers the PR, so a reduced payload of the same PR to the same provider never re-asks.` And, after `:143`'s `(an empty diff is refused)`, insert `, after excluding vendor/, third_party/, node_modules/ and the base revision's AGENT_GENERATED_PATHS (listed with a checksum in the receipt); a payload estimated above the launch limit is refused before consent with payload=too-large in the run dir`. Measured: 19404 → **19789 B** (+385), over the 19600 ceiling — move `tests/test-review-artifacts.sh:588` to 19789 with `# 2026-09-09 issue #609: +385 B, two new facts (exclusions, size gate) and the PR-scoped auto-review grant; measured.` (three new durable facts; the reference has no prose to trade).
- [ ] **Step 8 (green):** `bash -n` + shellcheck on `canonical-diff.sh`, `adversarial-run.sh`, `consent-record.sh`; `tests/run-tests.sh --only adversarial-run,consent-record,cross-provider-consent,adversarial-review-bounds,review-artifacts,probe-contract,adversarial-review-cleanup` → **adversarial-run 199/0, consent-record 86/0, cross-provider-consent 63/0, adversarial-review-bounds 48/0, review-artifacts 158/0, probe-contract 35/0, adversarial-review-cleanup 13/0** (measured; red before the fix: adversarial-run 199 / 18, consent-record 86 / 1); `tests/lint-helper-refs.sh agentkit/skills`; `tests/lint-skill-size.sh agentkit/skills`; full `tests/run-tests.sh`.
- [ ] **Step 9: Shared step** with `SCOPE=adversarial-review`, `TITLE='size-check the payload, exclude vendored and declared generated trees, scope auto-review consent to the PR'`, `WHY='PR #254 carried a vendored winit copy (+66,761 lines); the review launched on a diff estimated at 1.38M tokens against a 1M limit, spent, and returned no verdict, and the reduced diff the root then built by hand re-asked consent because the grant was keyed to the exact payload digest.'`, `WHAT='lib/canonical-diff.sh renders every payload with :(exclude,top) pathspecs for vendor, third_party, node_modules and the BASE revision AGENT_GENERATED_PATHS (never the checkout under review), and estimates tokens at bytes/3.5; adversarial-run.sh refuses above ADVERSARIAL_PAYLOAD_TOKEN_LIMIT (800000) with payload=too-large estimate=N limit=M in the run dir and a blocked result naming the remedy, before consent and before any launch marker; the receipt carries exclusions=N excluded_sha256=<digest> and the run dir the exclusion list and the excluded diff; consent-record.sh check accepts any payload of the same repo, PR, and provider under an auto-review-flag grant (interactive grants stay exact). Lockfiles are deliberately not excluded; the payload is rendered repo-relative (:/) from any cwd; build_diff still fetches the base before the base-revision config is read. adversarial-run.sh 853 -> 883 (+30, reason in the test); adversarial-review.md 19404 -> 19789 B (reason in the test).'`, `FILES=(agentkit/skills/.shared/scripts/lib/canonical-diff.sh agentkit/skills/review-remote-pr/scripts/adversarial-run.sh agentkit/skills/review-remote-pr/scripts/consent-record.sh agentkit/skills/review-remote-pr/references/adversarial-review.md tests/test-adversarial-run.sh tests/test-consent-record.sh tests/test-review-artifacts.sh)`, `ISSUE=609`. `gh pr create` adds `--base fix/issue-606` while #606 is open.

---

## Ranking, parallelism, sequencing

| Order | Task | Issue | Files it owns | Risk |
|---|---|---|---|---|
| 1 | Task 1 | #680 | `hooks/lib/guard-lib.sh`, `tests/test-hooks.sh` | medium (security-sensitive lexer; corpus gate + 6 assertions) |
| 2 | Task 2 | #643 | `tests/test-compose-worker-prompt.sh` | none (test-only) |
| 3 | Task 3 | #607 | `chain-advance.sh`, `authorize-queue.sh`, `merge-pr.sh`, `auto-merge.md`, `pr-to-green/SKILL.md`, 3 suites | medium (merge path; 9 new fixtures) |
| 4 | Task 4 | #606 | `repo-config.sh`, `adversarial-run.sh` (family hunk), `spawn-contract.md`, `onboard-refresh.sh`, `onboard-state.sh`, 5 suites | medium (validator tightening; every declared value is re-judged) |
| 5 | Task 5 | #609 | `lib/canonical-diff.sh`, `adversarial-run.sh` (diff/gate/receipt hunks), `consent-record.sh`, `adversarial-review.md`, 3 suites | medium (consent semantics; base-revision trust boundary) |

**Overlap ruling.** Tasks 1, 2, 3 are file-disjoint from everything else and from each other. Tasks 4 and 5 both edit `review-remote-pr/scripts/adversarial-run.sh` and `tests/test-adversarial-run.sh`. The script hunks are disjoint — #606 touches only `reviewer_roster_family` `:231-241` and the die at `:258`; #609 touches `:49` (globals), `build_diff` `:436-447`, `receipt_line` `:664-665`, `main` `:830-836`, and adds two functions — and both suites only *append* blocks before the ceiling at `:1116`, but the **line ceiling is one number**, so the two must be accounted sequentially: `fix/issue-609` branches from `fix/issue-606`, #606 merges first, #609 retargets to `main` and rebases. Expect the retarget conflict on the ceiling line **and** on the adjacent appended test blocks (both tasks append just before `:1116`; if #606's block is edited during review the conflict widens) — resolve by keeping both blocks in order (#606's first) and the #609 ceiling number. Dispatch 1, 2, 3, 4 together; 5 when 4's worktree exists (it does not wait for 4's PR to merge). Merge order otherwise free.

**Foreclosure check.** #661 (lexer dedupe) becomes a pure delegation after Task 1 (the corpus gate in Step 5 is its precondition). #608 (waiter workers, max yields) touches `wait-discipline.md`, `stall-check.sh`, `gh-pr-state.sh --wait-ci`, and the spawn shape — none of which this wave edits; the spawn-contract block edit in Task 4 leaves the `collaboration.spawn_agent` shape untouched.

---

## Self-review

### Coverage — issue acceptance → task step

| Issue | Acceptance / fix bullet | Satisfied by |
|---|---|---|
| #680 | `printf 'cat > /tmp/x <<'EOF'\nfoo\nEOF\n' \| guard_gh_command_segments` emits `cat > /tmp/x <<'EOF'` | T1 Step 1 (exact literal asserted) |
| #680 | hooks suite red before / green after with new assertions on both lexers: owner line once; foreign target advised; inert body not denied | T1 Steps 1-2, 6 (red 666/17 = control + 5; green 666/12 = control) |
| #680 | the one new denial (trailing heredoc into a protected path) is stated and pinned | T1 *Behaviour change*, Step 2 deny assertion, Step 7 WHAT |
| #680 | no other corpus record changes | T1 Step 5 (predicate-classified diff; destructive lexer byte-identical; measured 0/18/25 differing on A/A2/B, all predicate-holds) |
| #680 | #661 becomes a pure refactor | T1 Step 5 third comparison |
| #643 | substitute placeholders for the absolute paths, ratchet to the path-neutral minimum, test-only | T2 Steps 1-3 (three substitutions — the `%q` form is the third; 18756 at two depths; red 263/2, N−1 red, N green) |
| #607 | `--retarget` succeeds on a timeline with only `automatic_base_change_succeeded`; records the kind | T3 Steps 1, 5 (genuine red: persisted boundary cleared first; `boundaryEvent=` populated through the `$(…)` boundary) |
| #607 | fixtures for both kinds, wrong base, missing event | T3 Steps 1-2 (both kinds; wrong base asserts rc 2 and the new die text; missing-event fixture already exists at `:1010+` `gh-no-timeline`) |
| #607 | one `authorize-queue.sh` run per five-PR chain | **partially**: T3 Steps 2-3, 6 remove the per-PR `--retarget-proof` bookkeeping; one argument-free re-run per retarget remains because `merge-pr.sh:204-211` / `review-transition.sh:344-358` pin head/base/state in the record (stated in the task and PR) |
| #607 | `--keep-branch` under delete-on-merge: head exists after `merge-pr.sh` returns, no model push | T3 Steps 4, 7 |
| #607 | integration: two-PR chain on a delete-on-merge repo | **not automated** (needs a live repo); the operator runs it once on the next chain — named in the PR Testing checklist |
| #606 | `--validate` on the three values exits non-zero with the corrected form | T4 Steps 1, 4 |
| #606 | `_FALLBACK=codex` valid iff `REVIEWER=codex` is | T4 Step 4 (one case arm) |
| #606 | `--yolo` with an unresolvable roster dispatches on the harness default, one line, no question | T4 Steps 2, 6 (valid-roster-no-entry case: falls through to the declared singular key — `gpt-5.6-terra` in the fixture — or the built-in default `gpt-5.6-luna` when none is declared; both pinned); the malformed `codex-gpt-6-astra` case degrades on every run via the validator (`worker_config_value` prints `using built-in default`) |
| #606 | dotted Claude id rejected before any review launches | T4 Step 4 (`model_id_valid` on `AGENT_ADVERSARIAL_REVIEW_MODEL*` and roster entries) |
| #606 | `onboard-refresh.sh` / `onboard-state.sh` run the validator; drift reports it | T4 Steps 3, 7 |
| #606 | Claude probe at preflight | **not taken**: adds a network call to every preflight; the incident id is caught at write/validate time for free |
| #606 | refresh built-in defaults (`gpt-5.6-luna`) | **not taken**: the sanctioned-tier policy has 47 pins in `test-compose-worker-prompt.sh` alone and is an operator decision; widening the family to `gpt-6-*` makes every declared gpt-6 id resolvable, which was the blocker |
| #609 | over-limit diff never launches; run dir gets `payload=too-large estimate=N limit=M` | T5 Steps 2, 5 |
| #609 | reduced payload built automatically | T5 Step 4 exclusions on every render; beyond declared/built-in trees the refusal names `AGENT_GENERATED_PATHS` (stated deviation) |
| #609 | `vendor/**` excluded by default and listed in the receipt with a checksum | T5 Steps 1, 4, 5 (`exclusions=4 excluded_sha256=`, `adversarial.exclusions`; repo-relative `:/` render; base fetched before the base-revision config is read) |
| #609 | reducing an already-consented PR's payload under `--auto-review` does not re-ask | T5 Steps 3, 6, 7 |
| #609 | unit: 1.4M-token fixture refuses, 300K launches | T5 Step 2 (limit overridden to 10 tokens for a cheap fixture; the same code path, the constant is env-driven) |
| #609 | unit: consent passes for a subset, fails for an added path | T5 Step 3 (subset = same PR digest change; "added path" = another PR — a hand-added path cannot reach `check` because `payload --base-ref` refuses a supplied diff that differs from the canonical render, `consent-record.sh:282-285`) |
| #609 | lockfiles / generated manifests excluded | **deviation**: lockfiles kept in the payload (reason in the task) |

### Placeholder scan

`<counts>` (T1 corpus counts in the PR body), `<scope>`/`<title>`/`<why>`/`<what>`/`<N>` in the shared-step template, `<worktree>`/`<worktree-shell>`/`<agentkit>` (deliberate substitution tokens in T2), and `<foreign>`/`<worktree>` (prose) are the intentional fill-ins; every ceiling and count elsewhere is a measured number from the revision run — a worker whose edit lands at a different count uses the measured one, never a higher ceiling. No `TODO`/`TBD`/`XXX` (`grep -nE 'TODO|TBD|XXX' <this file>` → none). Every line number carries a quoted anchor from `09af63c`.

### Ceiling table

| File | Pin (test:line) | Now | Expected delta | After |
|---|---|---|---|---|
| `hooks/lib/guard-lib.sh` | `test-hooks.sh:2909` `2410` | 2403 | +9 −5 = +4 | **2407** (measured; ratchet down) |
| `tests/test-compose-worker-prompt.sh` prompt bytes | `:105` `20500` | 20423 path-dependent | path-neutral measurement | **18756** (measured at two depths; exact) |
| `parallel-issues/scripts/chain-advance.sh` | `test-chain-advance.sh:1367` `1045` | 1035 | +20 | **1055** (measured; raise, reason in test) |
| `pr-to-green/references/auto-merge.md` | `test-pr-to-green-authorize-queue.sh:758` `19300 B` | 19100 | +237 B | **19337** (measured; raise, reason in test) |
| `pr-to-green/SKILL.md` | `lint-skill-size.sh` 500 lines / 5000 tokens | 306 / 18222 B | 0 lines, +56 B | 306 / 18278 B, gate clean (measured) |
| `.shared/scripts/repo-config.sh` | `test-repo-config.sh:621` `1048` | 1045 | +53 | **1098** (measured; raise, reason in test) |
| `review-remote-pr/scripts/adversarial-run.sh` | `test-adversarial-run.sh:1116` `870` | 856 | #606 −3; #609 +30 | #606 → **853**; #609 → **883** (both measured, reasons in test) |
| `review-remote-pr/references/adversarial-review.md` | `test-review-artifacts.sh:588` `19600 B` | 19404 | +385 B | **19789** (measured; raise, reason in test) |
| `.shared/spawn-contract.md` | no pin | 314 lines | −10 | 304 (measured) |
| `authorize-queue.sh`, `merge-pr.sh`, `consent-record.sh`, `lib/canonical-diff.sh`, `onboard-refresh.sh`, `onboard-state.sh` | no pin | — | — | — |
| executables under `agentkit/` | `test-helper-end-of-options.sh:30` `66` | 66 | 0 | 66 (`lib/canonical-diff.sh` stays non-executable) |

### Review findings folded in (2026-09-09 apply-and-run review, verdict ready-with-fixes)

Every High and Medium applied as the review specified; every Low applied — no disagreements.

| Id | Where | Disposition |
|---|---|---|
| H1 | T4 Step 4 | `model_family` defined beside the `readonly` arrays (`:82`), before argv parsing; early exit stays beside `efforts` |
| H2 | T3 Step 5 | `timeline_boundary` prints `epoch\tevent`; `boundary_for` splits both sources; `persist_boundary` receives `$BOUNDARY_EPOCH` |
| H3 | T3 Steps 1-2 | persisted JSON cleared before the auto-event fixture and before the negative; negative after the persisted-proof assertions; rc 2 + new die text |
| M1 | T4 Steps 2, 6 | fall-through kept; message, prose, and assertions say "singular key or built-in default"; `gpt-5.6-terra` and `gpt-5.6-luna` both pinned |
| M2 | T4 Step 3 | roster-unknown block rewritten: `--validate` refusal pinned, anthropic grant, pinned-default receipt, codex never launched |
| M3 | T5 Step 5 | `build_diff` first (it fetches the base); gate after `select_reviewer`, before `compute_payload` |
| M4 | T5 Step 4 | `-- ':/'` in `canonical_diff_range`; fixtures render with the same pathspecs |
| M5 | T5 Step 7 | `'provider, PR, or diff changes'` kept verbatim; exception clause appended |
| M6 | T5 Step 1 | grant rendered with the four `:(exclude,top)` pathspecs; `exclusions=4` |
| M7 | T1 | protected-path denial stated in the task, pinned by a deny assertion, named in the PR WHAT |
| M8 | T2 Step 1 | the `printf %q` worktree substitution named as the third line |
| L1 | T1 Steps 4, 6 | +4 → 2407; six new assertions → 666 |
| L2 | T3 Step 3 | rc-capture form is the text; "the suite aborts" stated |
| L3 | T3 Step 8 | auto-merge.md ceiling moves to the measured 19337 with the reason |
| L4 | T5 Step 7 | adversarial-review.md ceiling moves to the measured 19789 with the reason |
| L5 | Global | test lint is `-e SC1091,SC2034`, no new findings vs `main`; spawn-contract block lint likewise |
| L6 | T3 Step 5 | `proof_file` comment states why it uses the common dir while `boundary_file` uses the worktree git dir |

Re-verified on fresh `09af63c` copies (`<scratchpad>/wave3/revise/{t1..t5}`, reds in `{t1..t5}-red`, logs in `revise/logs/`): every red count above is measured, every owning suite is green at the control set, lints clean (no new findings), ceilings as tabled, corpus gate PASS with outputs byte-identical to the review's, `#643` measured 18756 at both depths. Full `tests/run-tests.sh` on each of the five green trees: 30 failing assertions, the same four suites and the same FAIL names as the control set (only the `hooks` and `chain-advance` totals grow, 660 → 666 and 147 → 154).

### Not verified while planning

- `tests/test-canonical-diff.sh` (named by the lead) does not exist; `canonical_diff` is pinned through `test-adversarial-run.sh` and `test-consent-record.sh`.
- The Codex context limit behind `ADVERSARIAL_PAYLOAD_TOKEN_LIMIT` is not independently verified; the constant is derived from the Claude figure in the incident evidence and is env-overridable.
- `git rev-parse --path-format=absolute --git-common-dir` (git ≥ 2.31) is already used by `test-chain-advance.sh:1003`; CI's git version was not re-checked.
- GitHub's delete-branch-on-merge timing relative to the merge API response (T3 Step 7's three-probe wait) is from the incident narrative (`#252` auto-retargeted after `#251` merged), not measured.
- The `:/` pathspec's byte-identity with the old `.` render from the repository top is inferred from the suite (the grant fixtures hash identically) and the review's subdirectory demonstration (2 files from top, 1 from `sub/` with `.`, 2 with `:/`), not from a separate byte diff.
- "new gh vs new destructive differs only on shell-consumer / unquoted-substitution records" (7 on A2, 5 on B) is the review's per-record classification; the revision re-ran the driver and matched the review's outputs byte-for-byte but did not re-classify those 12 records by hand.
