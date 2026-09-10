# Fix wave four — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four open issues, one draft PR each, failing test first. (1) **#661** `guard_gh_command_segments` and `guard_destructive_command_segments` are the same 110-line quote/heredoc lexer kept in sync by hand; since #680 flushed the trailing-heredoc owner line in the gh lexer, the only remaining difference is what happens to a heredoc *body*, so the gh lexer becomes a `drop` mode of the destructive one (−110 lines of the most security-sensitive code in the tree, proven byte-identical on a 253-record corpus). (2) **#611** `worker-prompts.md` promises the worker that a PreToolUse guard writes `.agent/evidence/paths-touched.ndjson` and tells it to name the file in its completion report; on harnesses where the hook is not armed no file exists and every worker spends report tokens explaining its absence — `worktree-commit.sh` now writes the ledger at every commit, so the hand-back always carries it, and the prompt stops asking for a mention. (3) **#610** two of five HonkHonk workers ended turn 1 with `BLOCKED class=write-set` because a dependency change drags `Cargo.lock` and a CI-checked generated file the root never predicted, and one blocked again on a read-only `~/.cargo` the contract never redirected — the dispatch-plan validator now completes a predicted manifest with its lockfile and CI-declared siblings (`--fix` appends them), the body classifier gains a `--classify-deps` axis that tells the root to predict the manifest at all, and `caches=`/`agent-run.sh` carry `CARGO_HOME` and `GOMODCACHE` beside uv/npm/pip. (4) **#613** the root hand-edits run state and PR bodies with inline Python (129 heredocs in one run) because the kit keeps its redrive/parked bookkeeping in bash arrays and has no checkbox operation — a `run-state.sh get|set|append|unset` helper over the run directory and a `gh-body.sh … --tick TEXT [--note TEXT]` option replace the class, and the two SKILL.md bookkeeping sentences point at them.

**Architecture:** Four branches from `abdc88a` (`origin/main`, every wave-three PR merged): `refactor/issue-661`, `fix/issue-611`, `fix/issue-610`, `refactor/issue-613`. **All four are file-disjoint** (see *Overlap ruling*) — no chains; dispatch together, merge in any order. The four worktrees **already exist** at `abdc88a` under `.worktrees/{refactor/issue-661,fix/issue-611,fix/issue-610,refactor/issue-613}` (clean, `git status --short` empty); use them, do not re-create.

**Tech Stack:** Bash test suite (`tests/run-tests.sh`; `--only NAME[,NAME]` takes `tests/test-*.sh` suite names; suites are glob-discovered, so a new `tests/test-*.sh` file needs no registration), `shellcheck -x -P SCRIPTDIR -S style` on every shipped script, `tests/lint-*.sh agentkit/skills`, `tests/lint-versioned-plugin-paths.sh agentkit`, `gh` over REST, git worktrees under `.worktrees/`.

**Spec:** the four issue bodies with comments in `<scratchpad>/wave4/issue-{611,661,610,613}.md`; the wave-two K3 brief `<scratchpad>/wave4/k3-brief-from-wave2.md` and its BLOCKED report `.superpowers/sdd/2026-09-08-size-wave-two-helpers-hooks/task-3-report.md`. The wave-three review corpus **still exists on disk** at `<scratchpad>/wave3/review/k3-corpus/` (driver `run-lexer.sh`, `classify-diff.sh`, `corpus-{a,a2,b}.nul` = 184/27/42 records) and is reused as-is. Where an issue body's premise is stale on `abdc88a` the task says so and plans from the code (every task below has at least one such correction).

## Global Constraints

- **Repository:** `wrzonance/agent-kit`, trunk `main` at `abdc88a` (`origin/main`; the local `main` ref in the root checkout is stale at `09af63c` — always read anchors from a worktree or `origin/main`). Line numbers below are from `abdc88a`; **re-anchor with the quoted text before every edit.**
- **Never edit the root checkout** (`~/github/agent-kit`); every task works in its pre-created worktree. If a worktree is missing: `git fetch origin && git worktree add .worktrees/<branch> -b <branch> origin/main`.
- **Never commit to `main`.** Branches: `refactor/issue-661`, `fix/issue-611`, `fix/issue-610`, `refactor/issue-613`.
- **One PR per task, always `gh pr create --draft`.** PR body opens with `This was written agentically; verify its assertions:`, carries Why / What / Testing checkboxes, and closes with `Closes #N` followed by `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- **Commits:** Conventional Commits, trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, made with `"$agentkit/.shared/scripts/worktree-commit.sh" --exact -- FILES` where `agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills` — never `git add -A` (`.agent/` carries local state).
- **New files under `agentkit/`: exactly one.** `tests/test-helper-end-of-options.sh:30` pins `assert_eq 66 "${#helpers[@]}"` executables; Task 4 adds `agentkit/skills/.shared/scripts/run-state.sh` because #613's acceptance requires a state helper and no existing script owns local run state (`review-ledger.sh` is a forge-side comment ledger, `session-ledger.sh` a decision ledger, `run-dir.sh` only resolves the directory). Task 4 moves that pin to **67** and says why in the test comment. The new helper must accept a trailing `--` (that suite's contract) and needs no `references.md` entry (the manifest lists references, not helpers). No other task adds a file under `agentkit/`. Task 4 also adds `tests/test-run-state.sh` (tests are outside `agentkit/`; discovery is by glob).
- **Ceilings ratchet down, never up.** Every helper line ceiling and reference byte ceiling named below is quoted from the test that pins it. Lines a fix adds are paid for in the same file, or the ceiling moves by the **measured** delta with the reason stated in the test comment and the PR body. After every task the ceiling is set to the measured after-count (no slack) — never above it. The ceiling table in *Self-review* lists every one.
- **`bash -n` + `shellcheck -x -P SCRIPTDIR -S style`** on every touched script before commit; `shellcheck -S style -e SC1091,SC2034` on every touched test (every `tests/test-*.sh` on `main` already reports `SC2034 TEST_NAME appears unused`; the bar is **no new findings versus `main`**). Never delete or move a `# shellcheck disable=` directive.
- **Ecosystem-neutrality gate** (`tests/run-tests.sh` step `ecosystem-neutrality`): any shipped `.sh`/`.md` line matching `(pnpm|yarn)\b` or `<tool> (run|test|ci|install|build|check|lint|fmt|typecheck)` for `npm|pnpm|yarn|bun|cargo|uv|poetry|pipenv|go|make|just|task|mvn|gradle|pytest|tox` must carry an inline `# ecosystem-allow: <reason>` marker. Task 3's manifest table and dependency-signal regexes are detection code and carry it per line.
- **Verification before push:** the owning suites via `--only`, then the full `tests/run-tests.sh`, `tests/lint-skill-size.sh agentkit/skills`, `tests/lint-helper-refs.sh agentkit/skills`, `tests/lint-versioned-plugin-paths.sh agentkit`. **Baseline** (measured on `abdc88a` in `.worktrees/fix/issue-611`, `AGENT_TEST_TIMEOUT_SCALE=3`, all 0 failed): `hooks` 666, `worktree-commit` 138, `gh-body` 103, `agent-preflight` 168, `agent-run-cmd` 93, `write merge plan test-root detection (#550)` 37 (suite name `write-merge-plan-testroots`), `work-shape` 22, `parallel-dispatch-contract` 626, `compose-worker-prompt` 263, `triage-issues` 55, `fast-mode-contract` 43, `run-dir` 94, `helper end-of-options` 67, `prepare-issue-artifacts` 80. A worktree under `~/github/agent-kit/.worktrees/` shows 0 environmental failures; a copy under `/tmp` shows `hooks: 666 assertions, 2 failed` (both `command-derived target cannot self-authorize: … /tmp/…` on the scratchpad path, not the wave-three control set of `hooks` 12 / `chain-advance` 11 / `bench tier0` 6 / `session ledger` 1) — a green run is one whose failures are exactly that set for the location.
- **GitHub API:** REST via `gh api` for issues/PRs; `"$agentkit/parallel-issues/scripts/move-github-project-item.sh"` for board moves. No other `gh` mutation.
- **North star guard:** every task names the turn, read, block, or confirmation it removes from a run. Nothing here adds a human round trip; the one new gate (#610 manifest completion) fires at plan-validation time — before any worker exists — and `--fix` resolves it without a question.
- **Hooks bite the implementer:** the installed 0.7.4 plugin's hooks may deny-once a pasted heredoc that starts a line with a helper basename, or `grep -r "$HOME"`. Retry the same command once.
- **Shell values in the shared step contain no apostrophes** (they are single-quoted). Write "does not", never "doesn't".

---

## Shared step: commit, push, and open the draft PR

Every task's final step runs this exact recipe from inside its worktree with its own values.

```bash
agentkit=/home/adam/.claude/plugins/cache/agent-kit/agentkit/0.7.4/skills
TYPE=<fix|refactor>                        # from the task
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

Then the orchestrator (not the worker) moves the issue: `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number "$ISSUE" --status "In review" --repo wrzonance/agent-kit`.

---

### Task 0: Board state

**Files:** none (board only).

- [ ] **Step 1:** confirm the four issues are open and on the board: `"$agentkit/.shared/scripts/board-list.sh" --issue 661`, then 611, 610, 613.
- [ ] **Step 2:** move each to In progress as its worker is dispatched (not before): `"$agentkit/parallel-issues/scripts/move-github-project-item.sh" --issue-number N --status "In progress" --repo wrzonance/agent-kit` for N in 661 611 610 613.
- [ ] **Step 3:** each task's shared step moves its issue to In review when the draft PR opens. Done is GitHub's own close-on-merge (`Closes #N`); a redundant hand move is harmless.

---

### Task 1 (#661): guard-lib — one heredoc lexer, `drop` mode for the gh consumers

**Files:**
- Modify: `agentkit/hooks/lib/guard-lib.sh` — `guard_destructive_command_segments()` `:1405-1543` (header comment `:1401-1404` begins `# Like guard_gh_command_segments, but a heredoc BODY is dropped only when inert:`; locals `:1406` `local input=$1 line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0`; terminator condition `:1419` `if ((heredoc_no_expand)) && ! guard_heredoc_consumer_is_shell "$owner"; then`); `guard_gh_command_segments()` `:1977-2093` (header comment `:1972-1976` begins `# Split shell command text at unquoted separators while dropping heredoc bodies.`).
- Test: `tests/test-hooks.sh` — the #680 assertions `:1628-1643` (last message `'both lexers agree on a trailing inert heredoc: one owner-line segment each'`), the hook line-ceiling loop `:2944` (`'lib/guard-lib.sh:2407'`).
- Scratch (not committed): `<scratchpad>/wave3/review/k3-corpus/` (reused) and `<scratchpad>/wave4/k3/` (this task's outputs).

**Premise check against `abdc88a`:** the K3 report's blocker is gone. Its sole differing shape — a heredoc whose terminator is the last line — differed because the gh lexer never flushed the owner line; #680 (`c6bd250`) added exactly the destructive lexer's flush to the gh terminator branch (`:1991-2000`, comment `Flush the owner line as its own segment (issue #680)`). The two functions now differ only in (a) the destructive lexer's `owner`/`body`/`heredoc_no_expand` bookkeeping and its body-recovery branch `:1419-1433`, and (b) the gh lexer's longer `<<-` comment. **Measured gate on `abdc88a` (this plan, not the worker):** a scratch copy of the lib patched exactly as Step 3 below, driven by the wave-three `run-lexer.sh` over corpora A/A2/B: `guard_gh_command_segments` old vs new **byte-identical on all 184 / 27 / 42 records**; `guard_destructive_command_segments` old vs new **byte-identical on all 253**; new-gh vs new-destructive identical on all of A, differing on A2/B only where the body is a shell consumer or carries unquoted substitutions (the recover-mode records the K3 report classified). Patched lib measured **2297 lines** with a bare delegation; the exact text in Step 3 keeps one explanatory comment line → **2298**. The issue's "13 callers unchanged" is stale: on `abdc88a` there are **5** gh-lexer consumers (`:221`, `:475`, `:795`, `:2168`, `:2301`) and **3** destructive ones (`:1424`, `:1430` recursive, `:1557`; plus `pre-tool-use.sh:136`, `post-tool-use.sh:55`), all unchanged by this task.

**Behaviour change, stated plainly:** none. Every gh-lexer consumer receives byte-identical output on the whole corpus; the destructive lexer's default (`recover`) path is untouched. The `drop` argument only short-circuits the body branch; the terminator flush, `<<-` tab-strip, quoted/`<<\EOF` delimiter handling, and end-of-line flush are the destructive lexer's existing code.

**North star:** −110 lines of hook code read on every session start and every guard firing (2407 → 2298, measured), and one lexer to patch the next time a heredoc shape fails open (#680 had to be fixed in one copy and re-proven against the other).

- [ ] **Step 1 (red — ceiling):** in `tests/test-hooks.sh:2944` change `'lib/guard-lib.sh:2407'` to `'lib/guard-lib.sh:2298'`. `AGENT_TEST_TIMEOUT_SCALE=3 tests/run-tests.sh --only hooks` → 666 assertions / 1 failed (`lib/guard-lib.sh stays at or under 2298 lines (measured 2407)`).
- [ ] **Step 2 (red — drop mode is the gh lexer):** directly after `:1643` (`'both lexers agree on a trailing inert heredoc: one owner-line segment each'`) add:

```bash
# issue #661: guard_gh_command_segments IS guard_destructive_command_segments
# in drop mode. A body handed to a shell is recovered and re-segmented by the
# destructive lexer (issue #364) and never by the gh lexer -- the one place the
# two modes must differ, pinned so a future edit cannot quietly merge them.
shell_body_payload=$'bash <<\'EOF\'\nrm -rf /tmp/x\nEOF'
mapfile -t recover_segs < <(
    source "$hooks/lib/guard-lib.sh" 2>/dev/null
    guard_destructive_command_segments "$shell_body_payload"
)
mapfile -t drop_segs < <(
    source "$hooks/lib/guard-lib.sh" 2>/dev/null
    guard_destructive_command_segments "$shell_body_payload" drop
)
mapfile -t gh_shell_segs < <(
    source "$hooks/lib/guard-lib.sh" 2>/dev/null
    guard_gh_command_segments "$shell_body_payload"
)
assert_eq '2' "${#recover_segs[@]}" \
    'recover mode re-segments a shell-consumer heredoc body (recovered command plus owner line)'
assert_eq '1' "${#drop_segs[@]}" \
    'drop mode emits only the owner line for a shell-consumer heredoc'
assert_eq "${gh_shell_segs[*]-}" "${drop_segs[*]-}" \
    'the gh lexer is the destructive lexer in drop mode'
```

`--only hooks` → 669 assertions / **3 failed** (ceiling; `drop mode emits only the owner line` gets 2 because the second argument is ignored today; `the gh lexer is the destructive lexer in drop mode` gets `bash <<'EOF'` vs `rm -rf /tmp/x bash <<'EOF'`). Measured on `abdc88a`: recover mode prints `rm -rf /tmp/x` then `bash <<'EOF'`; the gh lexer prints `bash <<'EOF'` alone — those are the values the assertions above pin.

- [ ] **Step 3 (fix):** three edits in `agentkit/hooks/lib/guard-lib.sh`.

```bash
# before (:1401-1406)
# Like guard_gh_command_segments, but a heredoc BODY is dropped only when inert:
# a quoted-delimiter body to a data sink stays dropped (issue #351); an UNQUOTED
# body's substitutions and any body handed to a shell are recovered and
# recursively re-segmented (issue #364).
guard_destructive_command_segments() {
    local input=$1 line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0
# after (same six lines)
# The one quote/heredoc lexer. mode=recover (default): a heredoc BODY is dropped
# only when inert -- a quoted-delimiter body to a data sink stays dropped (issue
# #351); an UNQUOTED body's substitutions and any body handed to a shell are
# recovered and recursively re-segmented (issue #364). mode=drop: every body is
# dropped (guard_gh_command_segments, issue #661).
guard_destructive_command_segments() {
    local input=$1 mode=${2:-recover} line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0
```

(The header grows from four comment lines to five: +1.)

```bash
# before (:1419)
                if ((heredoc_no_expand)) && ! guard_heredoc_consumer_is_shell "$owner"; then
# after
                if [[ $mode == drop ]] || { ((heredoc_no_expand)) && ! guard_heredoc_consumer_is_shell "$owner"; }; then
```

```bash
# before (:1972-2093): the five-line header comment, then the 117-line function body
# after (the header comment stays verbatim; the body becomes)
guard_gh_command_segments() {
    # One lexer, two modes (issue #661): drop never recovers a heredoc body.
    guard_destructive_command_segments "$1" drop
}
```

Net: 2407 −110 (gh body is 114 lines, `:1977-2090`, → 4, incl. the closing brace) +1 (destructive header) = **2298** measured for exactly this text. If the worker's edit lands at a different count, the ceiling in Step 1 is that count — never 2407.

- [ ] **Step 4 (corpus acceptance — the gate that blocked K3):** in `<scratchpad>/wave4/k3/`: `mkdir -p base/hooks/lib new/hooks/lib && git show abdc88a:agentkit/hooks/lib/guard-lib.sh > base/hooks/lib/guard-lib.sh && cp <worktree>/agentkit/hooks/lib/guard-lib.sh new/hooks/lib/ && ln -s <worktree>/agentkit/skills base/skills && ln -s <worktree>/agentkit/skills new/skills` (the lib aborts at load unless `../../skills/.shared/scripts/lib` resolves relative to `BASH_SOURCE[0]`). Then, with `K=<scratchpad>/wave3/review/k3-corpus`, for each corpus `c` in `a a2 b` and each function `fn` in `guard_gh_command_segments guard_destructive_command_segments`: `bash "$K/run-lexer.sh" base/hooks/lib/guard-lib.sh "$K/corpus-$c.nul" $fn > base-<fn>-$c.txt` and the same for `new/`. **Gate:** `cmp base-gh-$c.txt new-gh-$c.txt` and `cmp base-destructive-$c.txt new-destructive-$c.txt` must be **byte-identical for all six pairs** (measured on `abdc88a`: identical, 184/27/42 records each). If any pair differs the task **stops** and reports the record (`"$K/classify-diff.sh" base-… new-… "$K/corpus-$c.nul"` prints the numbers); nothing is committed. Record `identical=253/253 (A 184, A2 27, B 42)` in the PR body. If `$K` no longer exists, rebuild it from the wave-three plan's Task 1 Step 3 recipe (`docs/superpowers/plans/2026-09-09-fix-wave-three.md`).
- [ ] **Step 5 (green):** `bash -n agentkit/hooks/lib/guard-lib.sh`; `shellcheck -x -P SCRIPTDIR -S style agentkit/hooks/lib/guard-lib.sh agentkit/hooks/pre-tool-use.sh agentkit/hooks/post-tool-use.sh agentkit/hooks/session-start.sh`; `shellcheck -S style -e SC1091,SC2034 tests/test-hooks.sh`; `AGENT_TEST_TIMEOUT_SCALE=3 tests/run-tests.sh --only hooks` → **669 assertions / 0 failed** in the worktree; full `tests/run-tests.sh` green.
- [ ] **Step 6: Shared step** with `TYPE=refactor`, `SCOPE=hooks`, `TITLE='make guard_gh_command_segments the drop mode of the destructive lexer'`, `WHY='guard_gh_command_segments and guard_destructive_command_segments were the same 110-line quote/heredoc state machine kept in sync by hand; after #680 flushed the trailing-heredoc owner line in the gh lexer, the only difference left was whether a heredoc body is recovered.'`, `WHAT='guard_destructive_command_segments takes mode=recover|drop; the gh lexer is a delegation in drop mode. Corpus gate: old vs new byte-identical for both lexers on all 253 records (A 184, A2 27, B 42); three new hooks assertions pin that drop mode never recovers a shell-consumer body while recover mode does; guard-lib 2407 -> 2298 lines, ceiling ratcheted.'`, `FILES=(agentkit/hooks/lib/guard-lib.sh tests/test-hooks.sh)`, `ISSUE=661`.

---

### Task 2 (#611): worktree-commit — write the paths-touched ledger at hand-back; stop promising a hook

**Files:**
- Modify: `agentkit/skills/.shared/scripts/worktree-commit.sh` (793 lines; `verify_trailers()` `:722-750` with its five-line comment `:722-726` beginning `# Validation catches a malformed --trailer before it is ever staged, but it` and the six-line comment `:735-740` beginning `# Pin the separator this read is parsed with: a repository-local`; `main()` `:773-792`, `verify_trailers` call `:790`, `report_commit` `:791`; `report_commit()` `:713-719` already computes `git show --pretty=format: --name-only --no-renames HEAD`).
- Modify: `agentkit/skills/parallel-issues/references/worker-prompts.md` `:84-85` (the two-line paragraph beginning `The PreToolUse guard records every content-bearing write in`).
- Test: `tests/test-worktree-commit.sh` (`new_repo` `:544-555` creates `.agent/` and `feature`; the partial-trio block ends `:1018`; ceiling `:1020-1021` `-le 800` / `'worktree-commit.sh stays at or under 800 lines'`; `TEST_TRAILER` `:18`).
- Test: `tests/test-compose-worker-prompt.sh:113-114` (`-le 18756` / `"issue-lead prompt stays at or under 18756 path-neutral bytes (measured ${#neutral_prompt})"`).
- Not touched: `tests/test-parallel-dispatch-contract.sh:1389` (`assert_contains "$worker_prompts_text" 'paths-touched.ndjson'`) — the literal stays in the rewritten paragraph, so the pin keeps passing; do not edit that file (Task 4 owns it).

**Premise check against `abdc88a`:** the paragraph has moved again since the issue's second comment — it is `:84-85`, not `:89-90`, still unconditional and still ends `and name it in the completion report`. The correction comments' option (1), "make the paragraph conditional on the contract recording `hooks= paths-touched=armed`", has **no anchor**: `agent-preflight.sh` emits no `hooks=` fact at all (`grep -n 'hooks=' agent-preflight.sh` → nothing), and adding a probe of the harness's hook state is a new contract fact with its own validation surface. Option (2) needs nothing new: `worktree-commit.sh` already runs in the worktree at every hand-back commit and already computes the commit's path list. The guard's writer (`guard_record_write_targets` `:967-1003`) keeps writing per-call records when armed; this task makes the ledger exist regardless. Consumers: on `abdc88a` **no script reads the file** (`grep -rn paths-touched agentkit/skills` → the prompt only); it is forensic evidence for the root's cross-write reconstruction, so the record shape mirrors the guard's (`tool`, `cwd`, `paths_touched`) and adds `commit`.

**North star:** removes the "Expected `.agent/evidence/paths-touched.ndjson` was not generated by the harness; no ledger was fabricated" sentence from every worker report (4 of 5 in the reviewed run) and the root's empty forensic read after a cross-write.

- [ ] **Step 1 (red):** in `tests/test-worktree-commit.sh`, after the partial-trio block (`:1018`, message `'the partial-trio refusal names the requirement'`) and before the ceiling block, add:

```bash
# issue #611: every commit appends its paths to .agent/evidence/paths-touched.ndjson,
# so a hand-back carries the ledger even when no PreToolUse hook was armed.
ledger_repo="$tmp/paths-touched-repo"
new_repo "$ledger_repo"
printf 'two\n' > "$ledger_repo/second.txt"
git -C "$ledger_repo" add -- second.txt
git -C "$ledger_repo" commit -qm 'second tracked file'
printf 'changed one\n' > "$ledger_repo/base.txt"
printf 'changed two\n' > "$ledger_repo/second.txt"
printf 'new\n' > "$ledger_repo/untracked.txt"
ledger_rc=0
(cd "$ledger_repo" && "$script" --exact --message 'feat: three paths' --trailer "$TEST_TRAILER" \
    -- base.txt second.txt untracked.txt >/dev/null 2>&1) || ledger_rc=$?
assert_eq '0' "$ledger_rc" 'a two-modified-one-untracked commit succeeds'
ledger_file="$ledger_repo/.agent/evidence/paths-touched.ndjson"
assert_eq yes "$([[ -f $ledger_file ]] && printf yes || printf no)" \
    'worktree-commit.sh writes .agent/evidence/paths-touched.ndjson at hand-back with no hook armed'
assert_eq 'base.txt second.txt untracked.txt' \
    "$(jq -r '.paths_touched[]' "$ledger_file" 2>/dev/null | sort | paste -sd ' ')" \
    'the ledger lists the two modified and the one previously untracked path'
assert_eq 'worktree-commit' "$(jq -r '.tool' "$ledger_file" 2>/dev/null)" \
    'the ledger record names worktree-commit as its writer'
assert_eq "$(git -C "$ledger_repo" rev-parse HEAD)" "$(jq -r '.commit' "$ledger_file" 2>/dev/null)" \
    'the ledger record carries the commit it describes'
assert_eq '600' "$(stat -c %a -- "$ledger_file" 2>/dev/null)" \
    'the ledger is owner-private, as the guard writes it'
printf 'again\n' > "$ledger_repo/base.txt"
(cd "$ledger_repo" && "$script" --exact --message 'feat: second commit' --trailer "$TEST_TRAILER" \
    -- base.txt >/dev/null 2>&1) || true
assert_eq '2' "$(wc -l < "$ledger_file" 2>/dev/null | tr -d '[:space:]')" \
    'a second commit appends a second record instead of rewriting the ledger'
```

`tests/run-tests.sh --only worktree-commit` → 145 assertions / **6 failed** (everything after the first: no file exists). One record per commit with a `paths_touched` array — the issue's "three NDJSON records" is met as three paths in one record (`jq -r '.paths_touched[]'` yields three lines), matching the guard's per-call shape so one `jq` reads both writers.

- [ ] **Step 2 (fix — the writer):** in `worktree-commit.sh`, after `verify_trailers()` (`:750`) add:

```bash
# Append this commit's paths to the ledger the PreToolUse guard keeps when it is
# armed (issue #611): a worker whose harness never armed the hook still hands
# back a complete .agent/evidence/paths-touched.ndjson. Same predicates as the
# guard (owned, non-symlink .agent and evidence dir; owner-private file), and
# deliberately non-blocking -- an evidence hiccup must never fail the commit.
record_paths_touched() {
    local root evidence_dir ledger record paths_json
    local -a paths=()
    root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ -d $root/.agent && ! -L $root/.agent && -O $root/.agent ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        printf '%s: jq not found; paths-touched ledger not written\n' "$PROGNAME" >&2; return 0; }
    mapfile -t paths < <(git show --pretty=format: --name-only --no-renames HEAD | awk 'NF')
    ((${#paths[@]})) || return 0
    evidence_dir=$root/.agent/evidence
    [[ -e $evidence_dir || -L $evidence_dir ]] || mkdir -m 700 -- "$evidence_dir" 2>/dev/null || return 0
    [[ -d $evidence_dir && ! -L $evidence_dir && -O $evidence_dir ]] || return 0
    ledger=$evidence_dir/paths-touched.ndjson
    [[ ! -L $ledger ]] || return 0
    paths_json=$(jq -nc '$ARGS.positional' --args "${paths[@]}" 2>/dev/null) || return 0
    record=$(jq -nc --arg ts "$(date +%s)" --arg sha "$(git rev-parse HEAD)" --arg cwd "$root" \
        --argjson paths "$paths_json" \
        '{timestamp:($ts|tonumber),session:"",tool:"worktree-commit",tool_call_id:"",commit:$sha,cwd:$cwd,command:"",paths_touched:$paths}' \
        2>/dev/null) || return 0
    (umask 077; printf '%s\n' "$record" >>"$ledger") 2>/dev/null || true
}
```

and in `main()` insert `record_paths_touched` between `verify_trailers` (`:790`) and `report_commit` (`:791`) (the writer block is 26 fenced lines plus 1 blank separator plus this call, +28). Pay part of those +28 lines in the same file: cut the five-line `verify_trailers` comment `:722-726` to two lines (`# Read the trailers back off the commit we just made and fail loudly, before the` / `# success record prints, if git's own parser disagreed with ours about one.`) and the six-line separator comment `:735-740` to two (`# Pin the separator: a repository-local trailer.separators config that drops ':'` / `# would otherwise change how git parses the very trailer this helper validated.`) → −7. Net **+21** → 793 → **814** measured for this text; set `tests/test-worktree-commit.sh:1020-1021` to the measured count (`-le 814` / `'… stays at or under 814 lines'`) with the comment `# issue #611: +21 lines for the hand-back paths-touched ledger writer.`. Never above the measured number.

- [ ] **Step 3 (fix — the prompt):** in `worker-prompts.md` replace `:84-85` exactly:

```markdown
# before
The PreToolUse guard records every content-bearing write in `<worktree>/.agent/evidence/paths-touched.ndjson`;
never delete, truncate, or rewrite it, and name it in the completion report.
# after
`worktree-commit.sh` appends each commit's paths to `<worktree>/.agent/evidence/paths-touched.ndjson`
(the PreToolUse guard adds per-call records when armed); never delete or rewrite it.
```

Measured: −1 byte (188 → 187); the literal `paths-touched.ndjson` survives for `test-parallel-dispatch-contract.sh:1389`; the completion-report instruction is gone (acceptance 2). `worker-prompts.md` has no byte pin of its own (`test-bench-tier0.sh:105` measures a synthetic copy).

- [ ] **Step 4 (ratchet the composed-prompt ceiling):** `tests/run-tests.sh --only compose-worker-prompt` and read `measured N` from the `issue-lead prompt stays at or under 18756 path-neutral bytes` message; set both the condition and the message at `:113-114` to `N` (**18755** expected if the paragraph is inside the composed issue-lead prompt; if the measurement is unchanged at 18756 the paragraph is outside the composed region — leave the ceiling and say so in the PR). Never above the measured value.
- [ ] **Step 5 (green):** `bash -n` + `shellcheck -x -P SCRIPTDIR -S style agentkit/skills/.shared/scripts/worktree-commit.sh`; `shellcheck -S style -e SC1091,SC2034 tests/test-worktree-commit.sh tests/test-compose-worker-prompt.sh`; `tests/run-tests.sh --only worktree-commit,compose-worker-prompt,parallel-dispatch-contract` → 145/0, 263/0, 626/0; `tests/lint-skill-size.sh agentkit/skills`, `tests/lint-helper-refs.sh agentkit/skills` clean (`worker-prompts.md` is a reference, not a SKILL.md, so the bare `worktree-commit.sh` mention is not a first-mention violation; the parallel-issues SKILL.md already names the helper by full path); full `tests/run-tests.sh` green.
- [ ] **Step 6: Shared step** with `TYPE=fix`, `SCOPE=worktree-commit`, `TITLE='write the paths-touched ledger at every commit instead of promising a hook does'`, `WHY='worker-prompts.md told every worker that the PreToolUse guard records its writes in .agent/evidence/paths-touched.ndjson and to name the file in its report; on a harness where the hook is not armed no file exists, four of five HonkHonk workers spent report tokens explaining its absence, and the root had nothing to read after a cross-write.'`, `WHAT='worktree-commit.sh appends one owner-private NDJSON record per commit (tool=worktree-commit, commit sha, paths_touched) to the same ledger, non-blocking and with the guard predicates; the prompt paragraph states that fact, keeps the never-rewrite rule, and drops the completion-report mention. Seven new worktree-commit assertions; worktree-commit.sh 793 -> 814 lines (ceiling moved by the measured delta, reason in the test); composed issue-lead prompt ceiling ratcheted to the measured <N>.'`, `FILES=(agentkit/skills/.shared/scripts/worktree-commit.sh agentkit/skills/parallel-issues/references/worker-prompts.md tests/test-worktree-commit.sh tests/test-compose-worker-prompt.sh)`, `ISSUE=611`.

---

### Task 3 (#610): dispatch — dependency-shaped write sets, a dependency signal, and Cargo/Go caches

**Files:**
- Modify: `agentkit/skills/parallel-issues/scripts/write-merge-plan.sh` (776 lines, no line pin; `declare -A missing_roots_by_issue=()` / `declare -a missing_issue_order=()` `:424-425`; per-entry validation loop `:489-552` (`while IFS=$'\t' read -r issue patterns exclusions; do` `:490`, the unmatched-glob check `:492-498`, `((${#chain_test_roots[@]})) || continue` `:499`); the violation/remedy/`--fix` block `:559-618`; helpers `glob_regex` `:190`, `tree_glob_matches` `:231`, `path_is_ancestor_or_equal` `:298`).
- Modify: `agentkit/skills/.shared/scripts/triage-issues.sh` (503 lines; `classify_work_shape()` `:52-86`; argv `:132-136` `--classify-shape)`; routing `:148-155` `if ((classify_shape_supplied)); then`).
- Modify: `agentkit/skills/.shared/scripts/agent-preflight.sh:958` (`emit "caches= root=$root reason=$reason home-cache=$home_cache UV_CACHE_DIR=$root/uv NPM_CONFIG_CACHE=$root/npm PIP_CACHE_DIR=$root/pip XDG_CACHE_HOME=$root"`).
- Modify: `agentkit/skills/.shared/scripts/agent-run.sh` `select_caches()` `:245-265` (`export_cache_var PIP_CACHE_DIR "$root/pip"` `:264`).
- Modify: `agentkit/skills/parallel-issues/references/triage-and-selection.md` (37574 bytes; the `--classify-shape` recipe `:155-159`, verdict table `:170-173`, the paragraph `Write-set intersection checks always add shared root files by default` `:391-396`).
- Tests: `tests/test-write-merge-plan-testroots.sh` (37 assertions; append before `finish`), `tests/test-work-shape.sh` (22; fixtures `implementation_fixture`, `false_positive_fixture`; `run_classify` `:28-30`; append before `finish`), `tests/test-agent-preflight.sh` (ceiling `:1264-1265` `-le 1330` / `'agent-preflight.sh stays at or under 1330 lines'`; `new_repo` `:30-36`), `tests/test-agent-run-cmd.sh` (`make_repo` `:14-20`; log lookup pattern `:45`; ceiling `:511-512` `-le 1595`), `tests/test-triage-issues.sh:238-239` (`-le 506` / `'triage-issues.sh stays at or under 506 lines'`), `tests/test-fast-mode-contract.sh:167-168` (`-le 37700` / `'triage-and-selection reference stays at or under 37700 bytes'`).

**Premise check against `abdc88a`:** three corrections. (a) The issue's fix bullet points at `compose-worker-prompt.sh --write-set` and `prepare-issue-artifacts.sh`; neither predicts anything — the composer only validates and renders the globs it is given (`:151-153`, `emit_write_set` `:636-646`) and `prepare-issue-artifacts.sh` fetches and fences the issue. The prediction is root prose (`triage-and-selection.md:260-270`, "taken from this conflict analysis") and the only mechanical check is `write-merge-plan.sh --validate-only`, which already resolves every glob against the chain-base tree and demands declared test roots with a `--fix` remedy — that is where the completion belongs. (b) The prose rule the issue asks for **already exists** (`:391-396`: "Write-set intersection checks always add shared root files by default … build configuration, lockfiles, and generated contracts") and was not followed; enforcement, not more prose, is the fix. (c) `detect-toolchains.sh` does know Cargo (`RUST_MARKER` `:213`, `gen_rust_tasks` `:455`), but `node-roots`/`py-roots` feed nothing outside preflight (`grep -rn 'node-roots' agentkit` → preflight only; `runners= repo-runner=` is the only runners token `agent-run.sh` consumes), so a `cargo-roots` token would be a dead fact — **not added**; `CARGO_HOME` is emitted unconditionally like uv/npm/pip (`select_caches` is ecosystem-agnostic by design, `agent-run.sh:259-263`). `RUSTUP_HOME` is not redirected: a read-only rustup toolchain is not a cache and redirecting it would hide the toolchain. `GOCACHE` already follows `XDG_CACHE_HOME`; `GOMODCACHE` does not (defaults to `~/go/pkg/mod`), so it is added. The worker prompt already states the cache env once (`worker-prompts.md:118`, "agent-run.sh supplies the run's caches…"; `:615` "Never export cache or CA variables yourself") — no prompt change.

**North star:** removes the turn-1 `BLOCKED class=write-set` → `needs-paths:` → root `jq` patch → `followup_task` → new worker turn cycle for every dependency-shaped issue (two of five in the reviewed run), and the `class=other remaining-step=resume-dependency-spike-with-writable-Cargo-cache` block (one more round trip) — three worker turn ends the root could have predicted.

- [ ] **Step 1 (red — manifest completion):** append to `tests/test-write-merge-plan-testroots.sh` before `finish`:

```bash
# --- issue #610: a predicted dependency manifest drags its lockfile and the
# generated files whose CI workflow paths: trigger on that lockfile. ---------
dep_base="$tmp/dep-base"
mkdir -p "$dep_base/src" "$dep_base/packaging/flatpak" "$dep_base/.github/workflows" "$dep_base/.agent"
printf '%s\n' 'fn main() {}' >"$dep_base/src/main.rs"
printf '%s\n' '[package]' 'name = "honk"' >"$dep_base/Cargo.toml"
printf '%s\n' '# lock' >"$dep_base/Cargo.lock"
printf '%s\n' '[]' >"$dep_base/packaging/flatpak/cargo-sources.json"
cat >"$dep_base/.github/workflows/flatpak-cargo-sources.yml" <<'EOF'
name: flatpak-cargo-sources
on:
  push:
    paths:
      - 'Cargo.lock'
      - "packaging/flatpak/cargo-sources.json"
      - .github/workflows/flatpak-cargo-sources.yml
  pull_request:
    paths: [Cargo.lock, 'packaging/flatpak/cargo-sources.json']
jobs:
  check:
    steps:
      - run: echo check
EOF
printf '%s\n' 'AGENT_CMD_TEST=cargo test' >"$dep_base/.agent/config.env" # ecosystem-allow: fixture
git init -q -b main "$dep_base"
git -C "$dep_base" config user.email test@example.invalid
git -C "$dep_base" config user.name test
git -C "$dep_base" add -- .
git -C "$dep_base" commit -qm 'cargo repo with a CI-checked generated file'

dep_plan="$tmp/dep.json"
cat >"$dep_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 52, "predictedWriteSet": ["src/**", "Cargo.toml"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
dep_rc=0
dep_err=$("$writer" --dispatch-plan "$dep_plan" --chain-base "$dep_base" --validate-only 2>&1 >/dev/null) || dep_rc=$?
assert_eq 1 "$dep_rc" 'a predicted manifest without its lockfile is a validation failure'
assert_contains "$dep_err" 'Cargo.lock' 'the manifest completion names the lockfile'
assert_contains "$dep_err" 'packaging/flatpak/cargo-sources.json' \
    'the manifest completion names the generated file whose CI workflow triggers on the lockfile'
assert_not_contains "$dep_err" 'omits its companion: .github/workflows' \
    'the workflow file itself is never demanded as a companion'
assert_rc 0 '--fix appends the companions to predictedWriteSet' -- \
    "$writer" --dispatch-plan "$dep_plan" --chain-base "$dep_base" --validate-only --fix
assert_eq 'src/**,Cargo.toml,Cargo.lock,packaging/flatpak/cargo-sources.json' \
    "$(jq -r '.entries[0].predictedWriteSet | join(",")' "$dep_plan")" \
    '--fix records the lockfile and the CI-declared generated file, in order, once'
assert_rc 0 'a completed dependency write set validates cleanly' -- \
    "$writer" --dispatch-plan "$dep_plan" --chain-base "$dep_base" --validate-only

nodep_plan="$tmp/nodep.json"
cat >"$nodep_plan" <<'EOF'
{
  "schemaVersion": 1,
  "entries": [{"issue": 53, "predictedWriteSet": ["src/**"]}],
  "conflictMap": {"pairs": [], "revisions": []}
}
EOF
assert_rc 0 'a write set that names no manifest is never asked for a lockfile' -- \
    "$writer" --dispatch-plan "$nodep_plan" --chain-base "$dep_base" --validate-only
```

`tests/run-tests.sh --only write-merge-plan-testroots` → 45 assertions / **4 failed** (rc 1, the two `contains`, the `join` equality; `--fix` and the two clean validations pass already). (`AGENT_CMD_TEST=cargo test` declares no test-root directory — argv[0] has no `/` — so the existing test-root rule stays out of this fixture.)

- [ ] **Step 2 (fix — manifest completion in the validator):** in `write-merge-plan.sh`, after `path_is_ancestor_or_equal()` (`:298-308`) add:

```bash
# --- dependency-manifest completion (issue #610) ----------------------------
# A predicted manifest drags its lockfile and the generated files whose CI
# freshness workflow triggers on that lockfile: two of five workers in the
# 2026-09-05 run blocked on turn 1 with class=write-set for exactly these paths.
# The table enumerates what a repository MIGHT use; it prescribes nothing.
readonly MANIFEST_LOCKS='Cargo.toml:Cargo.lock package.json:package-lock.json package.json:pnpm-lock.yaml package.json:yarn.lock package.json:bun.lockb go.mod:go.sum pyproject.toml:uv.lock pyproject.toml:poetry.lock Pipfile:Pipfile.lock Gemfile:Gemfile.lock composer.json:composer.lock' # ecosystem-allow: detection

tree_has_path() {
    local wanted=$1 path
    for path in "${chain_tree_paths[@]}"; do [[ $path == "$wanted" ]] && return 0; done
    return 1
}

# Literal (non-glob) entries listed beside LOCK in any `paths:` block of a
# tracked .github/workflows file, minus the workflow files themselves. Read
# from the chain-base ref, never the live checkout.
workflow_lock_siblings() {
    local lock=$1 wf
    for wf in "${chain_tree_paths[@]}"; do
        [[ $wf == .github/workflows/*.yml || $wf == .github/workflows/*.yaml ]] || continue
        git -C "$chain_root" show "$chain_ref:$wf" 2>/dev/null | awk -v lock="$lock" '
            function strip(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/^["'"'"']|["'"'"']$/, "", s); return s }
            function flush(   i, hit) {
                hit = 0; for (i = 1; i <= c; i++) if (items[i] == lock) hit = 1
                if (hit) for (i = 1; i <= c; i++) if (items[i] != lock && items[i] !~ /[*?[]/ && items[i] !~ /^\.github\//) print items[i]
                c = 0; delete items; inlist = 0 }
            /^[[:space:]]*paths:[[:space:]]*\[/ { s = $0; sub(/^[^[]*\[/, "", s); sub(/\].*$/, "", s); n = split(s, a, ",")
                for (i = 1; i <= n; i++) { v = strip(a[i]); if (v != "") items[++c] = v }; flush(); next }
            /^[[:space:]]*paths:[[:space:]]*$/ { inlist = 1; next }
            inlist && /^[[:space:]]*-[[:space:]]*/ { v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); v = strip(v); if (v != "") items[++c] = v; next }
            inlist { flush() }
            END { flush() }'
    done | awk 'NF && !seen[$0]++'
}

# Prints, one per line and in discovery order, every companion the given
# prediction patterns must add: for each tree path a pattern matches whose
# basename is a manifest, the lockfile beside it (when tracked) and that
# lockfile's workflow siblings (when tracked), minus what a pattern already covers.
manifest_companions_missing() {
    local -a patterns=("$@") companions=()
    local pattern regex path pair manifest lock dir companion covered
    for pattern in "${patterns[@]}"; do
        regex=$(glob_regex "$pattern")
        for path in "${chain_tree_paths[@]}"; do
            [[ $path =~ $regex ]] || continue
            for pair in $MANIFEST_LOCKS; do
                manifest=${pair%%:*}; lock=${pair##*:}
                [[ ${path##*/} == "$manifest" ]] || continue
                dir=${path%"$manifest"}
                tree_has_path "$dir$lock" || continue
                companions+=("$dir$lock")
                while IFS= read -r companion; do
                    [[ -n $companion ]] && tree_has_path "$companion" && companions+=("$companion")
                done < <(workflow_lock_siblings "$dir$lock")
            done
        done
    done
    ((${#companions[@]})) || return 0
    while IFS= read -r companion; do
        covered=0
        for pattern in "${patterns[@]}"; do
            regex=$(glob_regex "$pattern")
            [[ $companion =~ $regex ]] && { covered=1; break; }
        done
        ((covered)) || printf '%s\n' "$companion"
    done < <(printf '%s\n' "${companions[@]}" | awk '!seen[$0]++')
}
```

Then wire it into the validation: beside `:424-425` add `declare -A missing_companions_by_issue=()` and `declare -a companion_issue_order=()`; in the per-entry loop, directly after the unmatched-glob check (`:492-498`, before `((${#chain_test_roots[@]})) || continue` at `:499`) add:

```bash
            while IFS= read -r companion; do
                [[ -n $companion ]] || continue
                violation_lines+=("issue #$issue predictedWriteSet names a dependency manifest but omits its companion: $companion; add it to predictedWriteSet (a manifest change regenerates its lockfile and every file whose CI workflow paths: trigger on that lockfile)")
                if [[ -z ${missing_companions_by_issue[$issue]+yes} ]]; then
                    missing_companions_by_issue[$issue]=$companion
                    companion_issue_order+=("$issue")
                else
                    missing_companions_by_issue[$issue]+=",$companion"
                fi
            done < <(manifest_companions_missing "${prediction_patterns[@]}")
```

In the remedy/`--fix` block: change `if ((${#missing_issue_order[@]})); then` (`:563`) to `if ((${#missing_issue_order[@]} + ${#companion_issue_order[@]})); then`; inside the `--fix` branch, after the test-root `for issue in "${missing_issue_order[@]}"` loop, add the companion loop:

```bash
                for issue in "${companion_issue_order[@]}"; do
                    IFS=',' read -ra companions <<< "${missing_companions_by_issue[$issue]}"
                    companions_json=$(printf '%s\n' "${companions[@]}" | jq -R . | jq -sc .)
                    fix_filter+=" | (.entries[] | select(.issue == $issue) | .predictedWriteSet) |= (. + $companions_json | reduce .[] as \$p ([]; if index(\$p) then . else . + [\$p] end))"
                done
```

(the `\$p` escaping is required: `fix_filter+=" … "` is double-quoted, so an un-escaped `$p` is expanded by bash — under `set -u` that fails with `p: unbound variable` — the escaped form above is what must ship.)

and make the two `fix=applied issues=` prints list `"${missing_issue_order[@]}" "${companion_issue_order[@]}"` de-duplicated (`printf '%s\n' … | awk '!seen[$0]++' | paste -sd,`). In the printed remedy, after the test-root loop, print the companion patches the same way with `remedy_ws_filter='(.entries[] | select(.issue == $issue) | .predictedWriteSet) |= (. + $paths | reduce .[] as $p ([]; if index($p) then . else . + [$p] end))'` (a second `# shellcheck disable=SC2016` comment; `--argjson paths`) — the same `reduce` filter `--fix` applies (this variable is single-quoted, so `$p` needs no escaping here), so the printed remedy and the applied patch produce the identical array; the test-root patch keeps `unique`, where order does not matter. Update the comment at `:553-558` ("which only ever understands testRootExclusions patches") to name both patch kinds, and reword the remedy header from "remedy -- apply each entry testRootExclusions patch below" to "remedy -- apply each entry patch below" (the printed patches are not all testRootExclusions ones). Measured line count after the edit: write-merge-plan.sh **873** lines (no pin; record the measured count in the PR).

- [ ] **Step 3 (red — dependency signal):** append to `tests/test-work-shape.sh` before `finish`:

```bash
# --- issue #610: the dependency-signal axis, the same pure-text mode ---------
dep_fixture="$tmp/dep-body.txt"
printf '%s\n' 'Add the ebur128 crate for loudness metering and regenerate the Flatpak sources.' >"$dep_fixture"
out=$(PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-deps "$dep_fixture")
assert_contains "$out" 'dependency-signal=' 'a dependency-shaped body prints the dependency-signal key'
assert_contains "$out" 'ebur128 crate' 'the printed signal names the matched dependency phrase'
assert_not_contains "$out" $'\n' 'the dependency classifier prints exactly one line'
out=$(PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-deps "$implementation_fixture")
assert_eq 'dependency-signal=-' "$out" 'a body with no dependency language prints the dash sentinel'
out=$(PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-deps "$false_positive_fixture")
assert_eq 'dependency-signal=-' "$out" 'read-only mode flag prose is not a dependency signal'
lock_fixture="$tmp/lock-body.txt"
printf '%s\n' 'Bump the pinned versions in Cargo.lock so CI stops flagging the advisory.' >"$lock_fixture"
out=$(PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-deps "$lock_fixture")
assert_contains "$out" 'dependency-signal=Bump the pinned versions in Cargo.lock' \
    'a lockfile mention is a dependency signal'
deps_combo_rc=0
PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-deps "$dep_fixture" --json >/dev/null 2>&1 || deps_combo_rc=$?
assert_eq 2 "$deps_combo_rc" '--classify-deps does not combine with the query flags'
```

`--only work-shape` → 29 assertions / **5 failed** (`--classify-deps` is an unknown argument today: empty output, rc 2 — the combination assertion and the "exactly one line" assertion (`assert_not_contains "$out" $'\n'`, vacuously true on empty output) both pass by accident).

- [ ] **Step 4 (fix — `--classify-deps`):** in `triage-issues.sh`, after `classify_work_shape()` (`:86`) add:

```bash
# Does the body name a dependency change (add/bump/remove a crate, package,
# module; a package-manager add/update command; a manifest or lockfile by
# name)? A hit tells the root to predict the manifest, its lockfile, and the
# CI-declared generated files up front (issue #610). Crude on purpose, like
# classify_work_shape: a miss is never proof, a hit is a signal to confirm.
classify_dependency_signal() {
    local file=$1
    [[ -f $file && -r $file ]] || die_usage "--classify-deps file not readable: $file"
    local -a signals=(
        '\b(add|adds|adding|added|introduce|introduces|bump|bumps|bumping|upgrade|upgrades|update|updates|pin|pins|remove|removes|replace|replaces|swap|swaps)( the| a| an| new)? [^[:space:]]+ (crate|crates|dependency|dependencies|package|packages|module|modules|gem|gems)\b'
        '\b(cargo add|cargo update|npm (install|i|add|update)|pnpm (add|install|update)|yarn (add|upgrade)|go get|go mod tidy|pip install|uv (add|lock)|poetry (add|lock)|bundle (add|update))\b' # ecosystem-allow: detection
        '\b(Cargo\.(toml|lock)|package(-lock)?\.json|pnpm-lock\.yaml|yarn\.lock|go\.(mod|sum)|pyproject\.toml|uv\.lock|poetry\.lock|requirements[^[:space:]]*\.txt|Gemfile(\.lock)?)\b' # ecosystem-allow: detection
    )
    local pattern matched
    pattern=$(IFS='|'; printf '%s' "${signals[*]}")
    matched=$(grep -iE -m 1 -- "$pattern" "$file" || true)
    matched=$(printf '%s' "$matched" | tr -d '[:cntrl:]')
    matched="${matched#"${matched%%[![:space:]]*}"}"
    matched="${matched%"${matched##*[![:space:]]}"}"
    matched="${matched#[-*+] }"
    if [[ -n $matched ]]; then
        ((${#matched} <= 160)) || matched="${matched:0:160}..."
        printf 'dependency-signal=%s\n' "$matched"
    else
        printf 'dependency-signal=-\n'
    fi
}
```

Add `classify_deps_file=''` / `classify_deps_supplied=0` beside `:97-98`; an argv arm after `:136` (`--classify-deps) shift; (($#)) || die_usage '--classify-deps requires a file path'; classify_deps_file=$1; classify_deps_supplied=1 ;;`); a routing block mirroring `:148-155` (same "does not combine with the query flags" check, plus `((classify_shape_supplied == 0)) || die_usage '--classify-deps does not combine with --classify-shape'`, then `classify_dependency_signal "$classify_deps_file"; exit 0`); the usage line `:32` gains `       %s --classify-deps FILE\n`; the header comment `:9-10` gains one line. Every line carrying a tool+subcommand word carries the `# ecosystem-allow: detection` marker (the gate is per line). The new `--classify-deps` routing block sits, by construction, textually *after* the existing `--classify-shape` block, which already `exit 0`s before the new block's own "does not combine" check ever runs — so the mirror check must also go into the pre-existing shape block: after `[[ -n $classify_shape_file ]] || …` at `:149` insert `((classify_deps_supplied == 0)) || die_usage '--classify-shape does not combine with --classify-deps'` (+1 line; without it, `triage-issues.sh --classify-deps F --classify-shape F` silently prints `work-shape=… signal=-` and exits 0). Measured after-count 549 lines before this mirror line, **550** with it; set `tests/test-triage-issues.sh:238-239` to the measured count (the worker's own `wc -l` wins over this estimate) with the comment `# issue #610: +N lines for the --classify-deps body classifier, including the --classify-shape mirror check.`

- [ ] **Step 5 (red — caches):** in `tests/test-agent-preflight.sh` before the ceiling block (`:1263`) add:

```bash
# issue #610: caches= names the Cargo and Go module caches beside uv/npm/pip, so a
# worker never rediscovers a read-only ~/.cargo or ~/go/pkg/mod mid-turn.
cargo_repo=$(new_repo)
cargo_out=$(env -u AGENT_CACHE_ROOT -u XDG_CACHE_HOME TMPDIR="$tmp" "$script" --worktree "$cargo_repo" --no-write 2>/dev/null)
cargo_line=$(grep '^caches=' <<< "$cargo_out")
cargo_root=$(sed -n 's/^caches= root=\([^[:space:]]*\).*/\1/p' <<< "$cargo_line")
assert_contains "$cargo_line" " CARGO_HOME=$cargo_root/cargo " 'caches= names CARGO_HOME under the selected cache root'
assert_contains "$cargo_line" " GOMODCACHE=$cargo_root/go-mod" 'caches= names GOMODCACHE under the selected cache root'
```

and in `tests/test-agent-run-cmd.sh` before the ceiling block (`:510`):

```bash
# issue #610: with an unwritable cache home the wrapper redirects CARGO_HOME and
# GOMODCACHE beside uv/npm/pip, so a Cargo or Go dependency step never fails on a
# read-only ~/.cargo the contract never mentioned.
cache_repo=$(make_repo)
mkdir -p "$cache_repo/tools"
# shellcheck disable=SC2016  # the literal $CARGO_HOME belongs to the fixture script
printf '#!/bin/sh\nprintf "%%s:%%s\\n" "$CARGO_HOME" "$GOMODCACHE"\n' > "$cache_repo/tools/show-caches"
chmod +x "$cache_repo/tools/show-caches"
printf 'AGENT_CMD_TEST=tools/show-caches\n' > "$cache_repo/.agent/config.env"
ro_home="$tmp/ro-home"
mkdir -p "$ro_home"
chmod 500 "$ro_home"
(cd "$cache_repo" && env -u AGENT_CACHE_ROOT -u XDG_CACHE_HOME -u CARGO_HOME -u GOMODCACHE \
    HOME="$ro_home" TMPDIR="$tmp" "$real_run_sh" --cmd test >/dev/null 2>&1) || true
chmod 700 "$ro_home"
cache_log=$(find "$cache_repo/.agent/logs" -type f -name '*-test.log' -print -quit)
assert_contains "$(cat "$cache_log")" "$tmp/agent-cache-$(id -u)/cargo:$tmp/agent-cache-$(id -u)/go-mod" \
    'CARGO_HOME and GOMODCACHE are redirected under the fallback cache root'
```

`--only agent-preflight,agent-run-cmd` → 170 / **2 failed**, 94 / **1 failed** (the log holds `:` today). The `chmod 700` before the assertion keeps the suite's `rm -rf "$tmp"` trap able to clean up (the preflight suite does the same at `:842`).

- [ ] **Step 6 (fix — caches):** `agent-preflight.sh:958` becomes

```bash
    emit "caches= root=$root reason=$reason home-cache=$home_cache UV_CACHE_DIR=$root/uv NPM_CONFIG_CACHE=$root/npm PIP_CACHE_DIR=$root/pip XDG_CACHE_HOME=$root CARGO_HOME=$root/cargo GOMODCACHE=$root/go-mod"
```

(0 lines; the fixture `caches=` lines in `test-agent-preflight.sh:144,785,813,817` and `test-create-issue-worktree.sh:152` are *inputs* to the never-widen comparator, which reads only `root=`/`reason=`, so they stay as they are.) In `agent-run.sh` after `:264` (`export_cache_var PIP_CACHE_DIR "$root/pip"`) add:

```bash
    export_cache_var CARGO_HOME "$root/cargo"   # ecosystem-allow: environment code, not a claim about which toolchain the repo uses
    export_cache_var GOMODCACHE "$root/go-mod"  # ecosystem-allow: same; GOCACHE already follows XDG_CACHE_HOME
```

(+2 → 1593; ratchet `tests/test-agent-run-cmd.sh:511-512` to `1593`. `agent-preflight.sh` stays 1323; ratchet `:1264-1265` to `1323` since the task touches the file.) The preflight comment `:923-924` ("Mirrors agent-run.sh's selection exactly") stays true.

- [ ] **Step 7 (prose):** in `triage-and-selection.md`: (i) inside the `--classify-shape` fenced block (`:155-159`) add, after `:158`, the line `"$agentkit/.shared/scripts/triage-issues.sh" --classify-deps "$body_file"`; (ii) after the paragraph ending `axis exists to stop.` (`:176-177`) add:

```markdown

A `dependency-signal=` other than `-` means the body names a dependency change: put every dependency
manifest in the chain-base tree (`Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`) into that entry's
`predictedWriteSet`; the validator then demands each manifest's lockfile plus the generated files whose CI
workflow `paths:` trigger on that lockfile, and `--fix` appends them (#610).
```

(iii) in the paragraph at `:391-396` append the sentence ` \`write-merge-plan.sh --validate-only\` enforces the manifest → lockfile → CI-sibling part; \`--fix\` applies it.` Measured: +583 B (i+ii+iii) → 37574 → **38157** B, over the 37700 pin; set `tests/test-fast-mode-contract.sh:167-168` to **38157** (measured; moved by delta) with the comment `# issue #610: the dependency-signal recipe and the validator's manifest completion.` `tests/lint-skill-size.sh` (references need a Contents block over 100 lines — present) and `lint-helper-refs.sh` (`triage-issues.sh` is already named by full path at `:158`) stay clean.

- [ ] **Step 8 (green):** `bash -n` + `shellcheck -x -P SCRIPTDIR -S style` on `write-merge-plan.sh`, `triage-issues.sh`, `agent-preflight.sh`, `agent-run.sh`; `shellcheck -S style -e SC1091,SC2034` on the six touched tests; `tests/run-tests.sh --only write-merge-plan-testroots,write-merge-plan,write-merge-plan-protected-paths,work-shape,triage-issues,agent-preflight,agent-run-cmd,fast-mode-contract,create-issue-worktree` → 45/0, 29/0, 170/0, 94/0 and the rest at baseline; the `ecosystem-neutrality` step of the full `tests/run-tests.sh` passes (every detection line marked); full run green.
- [ ] **Step 9: Shared step** with `TYPE=fix`, `SCOPE=dispatch`, `TITLE='complete dependency-shaped write sets and carry CARGO_HOME and GOMODCACHE in the contract caches'`, `WHY='Two of five HonkHonk workers ended turn 1 with BLOCKED class=write-set because a dependency change drags Cargo.lock and a CI-checked generated file the root never predicted, and one blocked again on a read-only Cargo cache the env contract never redirected; each block is a worker turn end, a root patch, and a followup_task.'`, `WHAT='write-merge-plan.sh --validate-only demands, for every predicted dependency manifest, the tracked lockfile beside it and the literal paths listed with that lockfile in any .github/workflows paths: block, and --fix appends them in order; triage-issues.sh --classify-deps FILE prints dependency-signal=<match|-> so the root predicts the manifest at all; caches= and agent-run.sh redirect CARGO_HOME and GOMODCACHE beside uv/npm/pip. New assertions: testroots +8, work-shape +7, agent-preflight +2, agent-run-cmd +1. Ceilings: triage-issues.sh 503 -> <N> and triage-and-selection.md 37574 -> <N> B moved by the measured delta (reasons in the tests); agent-run.sh 1591 -> 1593 and agent-preflight.sh 1323 ratcheted to measured.'`, `FILES=(agentkit/skills/parallel-issues/scripts/write-merge-plan.sh agentkit/skills/.shared/scripts/triage-issues.sh agentkit/skills/.shared/scripts/agent-preflight.sh agentkit/skills/.shared/scripts/agent-run.sh agentkit/skills/parallel-issues/references/triage-and-selection.md tests/test-write-merge-plan-testroots.sh tests/test-work-shape.sh tests/test-agent-preflight.sh tests/test-agent-run-cmd.sh tests/test-triage-issues.sh tests/test-fast-mode-contract.sh)`, `ISSUE=610`.

---

### Task 4 (#613): root state — `run-state.sh` and `gh-body.sh --tick` replace inline Python

**Files:**
- Create: `agentkit/skills/.shared/scripts/run-state.sh` (executable, `chmod 755`).
- Create: `tests/test-run-state.sh` (suite name `run-state`; glob-discovered).
- Modify: `agentkit/skills/.shared/scripts/gh-body.sh` (536 lines, no line pin; globals `:16-31`; `usage()` `:35-64`; `parse_args()` `:75-162` — the post-`--` body-option guard `:102-105`, the `--json` arm `:149-152`; `main()` `:475` `parse_args "$@"` / `validate_body` / `run_mutation`).
- Modify: `agentkit/skills/.shared/github-body-policy.md` (898 bytes; pin `tests/test-gh-body.sh:597-598` `-le 920` / `'github-body-policy stays at or under 920 bytes'`).
- Modify: `agentkit/skills/parallel-issues/SKILL.md` `:686` (the `- **BLOCKED** →` bullet) and `:925` (the final-sweep paragraph beginning `then run \`post-receipt.sh" status\``).
- Tests: `tests/test-gh-body.sh` (103 assertions; `run_body` `:145`; `$body` `:138-143`; the `pr edit` assertion `:191-192`), `tests/test-parallel-dispatch-contract.sh:533-538` (pins `'receipt_redrive_attempted'` and `'++parked_count'`), `tests/test-helper-end-of-options.sh:30` (`assert_eq 66 …`).

**Premise check against `abdc88a`:** two corrections and one no-op. (a) `run-state.json`, `auto-merge-progress.json`, `merge-body.md` are **not kit artifacts** — the HonkHonk root invented them because the skill keeps its own bookkeeping in bash memory: `auto_redrive_attempted[issue]` (`SKILL.md:686`), `receipt_redrive_attempted[pr]` and `++parked_count` (`:925`); a resumed root session loses all three, which is exactly why the root reached for a file. The kit's durable local state lives under `run-dir.sh --run-id "$RUN_ID"` (`.agent/evidence/run-<ID>/`, already used cross-skill from `triage-and-selection.md:26` and `SKILL.md:846`), so `run-state.sh` keeps one `run-state.json` there; `pr-to-green/SKILL.md` has no in-memory counters (`grep -n '_attempted\|++' pr-to-green/SKILL.md` → nothing) and is not touched. (b) No kit recipe flips a checkbox: `compose-pr-body.sh` renders `- [ ] item` (`:88-107`), nothing ticks one; `--tick` is a new `gh-body.sh edit` option and its pointer goes in `github-body-policy.md` (the body-transport policy every root reads), not in a SKILL.md at its token ceiling. (c) "Remove the root-side research step if one exists" — **none exists**: the root's prior-art step is a forge digest (merged-ref/ADR pointers, `SKILL.md:287-303`, `:416`), never a web search; the HonkHonk searches were off-script. No change; stated in the PR.

**North star:** removes the per-run class of bespoke `python3 - <<'PY'` state edits (129 in the reviewed run's 490 shell calls): one helper call per state change, one per checkbox flip, and a redrive/parked record that survives a resumed session instead of being re-derived from transcript memory.

- [ ] **Step 1 (red — run-state):** create `tests/test-run-state.sh`:

```bash
#!/usr/bin/env bash
# Suite: run-state.sh keeps one validated, owner-private JSON object per run
# (issue #613) so the root records redrive/parked bookkeeping with one call
# instead of an inline Python heredoc, and a resumed session reads it back.
set -uo pipefail

TEST_NAME='run-state'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
state="$tmp/run-state.json"

assert_rc 0 'set creates the state file' -- "$script" set --file "$state" --path redrive.52 --value 1
assert_eq '1' "$("$script" get --file "$state" --path redrive.52)" 'get reads back what set wrote'
assert_eq '600' "$(stat -c %a -- "$state")" 'the state file is owner-private'
assert_rc 0 'set without --value stores true' -- "$script" set --file "$state" --path redrive.16
assert_eq 'true' "$("$script" get --file "$state" --path redrive.16)" 'a bare set reads back as true'
assert_rc 0 'set --json stores a structured value' -- \
    "$script" set --file "$state" --path prLoops.251 --json '{"status":"review-running","attempts":2}'
assert_eq 'review-running' "$("$script" get --file "$state" --path prLoops.251.status)" 'get walks into a nested object'
assert_eq '{"status":"review-running","attempts":2}' "$("$script" get --file "$state" --path prLoops.251)" \
    'get prints a non-scalar value as compact JSON'
absent_rc=0
absent_out=$("$script" get --file "$state" --path prLoops.999 2>/dev/null) || absent_rc=$?
assert_eq '11' "$absent_rc" 'get on an absent path exits 11'
assert_eq '' "$absent_out" 'and prints nothing'
assert_rc 0 'append starts an array' -- "$script" append --file "$state" --path parked --value 253
assert_rc 0 'append extends it' -- "$script" append --file "$state" --path parked --value 254
assert_eq '["253","254"]' "$("$script" get --file "$state" --path parked)" 'append keeps insertion order'
append_scalar_rc=0
"$script" append --file "$state" --path redrive.52 --value x >/dev/null 2>&1 || append_scalar_rc=$?
assert_eq '1' "$append_scalar_rc" 'append onto a non-array refuses'
assert_rc 0 'unset removes a path' -- "$script" unset --file "$state" --path redrive.16
unset_rc=0; "$script" get --file "$state" --path redrive.16 >/dev/null 2>&1 || unset_rc=$?
assert_eq '11' "$unset_rc" 'an unset path reads as absent'
assert_eq 'true' "$(jq -e 'type == "object"' "$state")" 'the file stays a JSON object throughout'

printf 'not json\n' > "$tmp/broken.json"
broken_rc=0
broken_err=$("$script" get --file "$tmp/broken.json" --path a 2>&1 >/dev/null) || broken_rc=$?
assert_eq '1' "$broken_rc" 'an unparseable state file blocks instead of reading as empty'
assert_contains "$broken_err" 'unparseable' 'the block names the cause'
ln -s "$state" "$tmp/link.json"
link_rc=0; "$script" set --file "$tmp/link.json" --path a --value 1 >/dev/null 2>&1 || link_rc=$?
assert_eq '1' "$link_rc" 'a symlinked state file is refused'
bad_path_rc=0; "$script" set --file "$state" --path 'a..b' --value 1 >/dev/null 2>&1 || bad_path_rc=$?
assert_eq '2' "$bad_path_rc" 'an empty path segment is a usage error'
usage_rc=0; "$script" set --file "$state" >/dev/null 2>&1 || usage_rc=$?
assert_eq '2' "$usage_rc" 'set without --path is a usage error'
marker_rc=0; marker_out=$("$script" -- 2>&1) || marker_rc=$?
assert_eq '2' "$marker_rc" 'a bare -- is a usage error'
assert_not_contains "$marker_out" 'unknown argument' 'the -- marker itself is never rejected'

repo="$tmp/repo"
mkdir -p "$repo/.agent"
assert_rc 0 '--run-id resolves the file through run-dir.sh' -- \
    "$script" set --run-id wave4-run --repo-root "$repo" --path redrive.7 --value 1
assert_eq '1' "$(jq -r '.redrive["7"]' "$repo/.agent/evidence/run-wave4-run/run-state.json")" \
    'the run-scoped state lives at <run dir>/run-state.json'

finish
```

`chmod +x tests/test-run-state.sh`; `tests/run-tests.sh --only run-state` → **every assertion fails** (no script; `assert_rc` reports 127). Also raise the executable pin now: `tests/test-helper-end-of-options.sh:30` → `assert_eq 67 "${#helpers[@]}" 'the contract covers every executable shipped helper'` with the comment `# 67 since issue #613 added .shared/scripts/run-state.sh.` → `--only helper-end-of-options` → 1 failed (66 found).

- [ ] **Step 2 (fix — `run-state.sh`):** create `agentkit/skills/.shared/scripts/run-state.sh` (≈150 lines, `chmod 755`):

```bash
#!/usr/bin/env bash
# run-state.sh -- one validated, owner-private JSON object of run bookkeeping
# (redrive attempts, parked PRs, per-PR loop status) so the root records a state
# change with one call and a resumed session reads it back (issue #613). The
# file is <run dir>/run-state.json (run-dir.sh --run-id) or an explicit --file.
set -euo pipefail
umask 077
readonly PROGNAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
readonly SCRIPT_DIR
# Same shared->skill resolution shape as review-provider-config.sh:14.
RUN_DIR_SH=${RUN_STATE_RUN_DIR_SH:-$SCRIPT_DIR/../../review-remote-pr/scripts/run-dir.sh}
readonly PATH_RE='^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$'
ACTION=''; FILE=''; RUN_ID=''; REPO_ROOT=''; KEY_PATH=''; VALUE=''; JSON_VALUE=''; VALUE_SET=0

usage() {
    cat <<EOF
Usage: $PROGNAME get|set|append|unset (--file FILE | --run-id ID [--repo-root DIR]) --path a.b.c [--value V | --json J]
get     print the value at --path (scalars raw, objects/arrays compact JSON); exit 11 when absent
set     store --value (string), --json (parsed), or true when neither is given
append  append --value/--json to the array at --path (created when absent; a non-array refuses)
unset   remove --path
The file must be absent or an owned, non-symlink regular file holding one JSON object; anything
else exits 1 (never read as empty). Writes are atomic (temp file beside it, mode 0600, rename).
Exit: 0 ok; 1 evidence unavailable or unparseable state; 2 usage; 11 get: absent.
EOF
}
die() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; exit 1; }
die_usage() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; usage >&2; exit 2; }
require_value() { [[ -n ${2:-} ]] || die_usage "option $1 requires a value"; }

parse_args() {
    (($#)) || die_usage 'a subcommand is required'
    case $1 in
        get|set|append|unset) ACTION=$1; shift ;;
        --) shift; (($# == 0)) || die_usage "unexpected argument after --: $1"; die_usage 'a subcommand is required' ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown subcommand: $1" ;;
    esac
    while (($#)); do
        case $1 in
            --) shift; (($# == 0)) || die_usage "unexpected argument after --: $1"; break ;;
            --file) require_value "$1" "${2:-}"; FILE=$2; shift 2 ;;
            --run-id) require_value "$1" "${2:-}"; RUN_ID=$2; shift 2 ;;
            --repo-root) require_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
            --path) require_value "$1" "${2:-}"; KEY_PATH=$2; shift 2 ;;
            --value) require_value "$1" "${2:-}"; VALUE=$2; VALUE_SET=1; shift 2 ;;
            --json) require_value "$1" "${2:-}"; JSON_VALUE=$2; VALUE_SET=1; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $KEY_PATH ]] || die_usage '--path is required'
    [[ $KEY_PATH =~ $PATH_RE ]] || die_usage "--path must be dot-separated [A-Za-z0-9_-] segments: $KEY_PATH"
    [[ -z $VALUE || -z $JSON_VALUE ]] || die_usage '--value and --json are mutually exclusive'
    [[ $ACTION != get && $ACTION != unset || $VALUE_SET == 0 ]] || die_usage "$ACTION takes no --value/--json"
    if [[ -n $FILE && -n $RUN_ID ]]; then die_usage '--file and --run-id are mutually exclusive'; fi
    [[ -n $FILE || -n $RUN_ID ]] || die_usage 'either --file or --run-id is required'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
}

resolve_file() {
    [[ -z $RUN_ID ]] && return 0
    local run_dir
    local -a args=(--run-id "$RUN_ID")
    [[ -z $REPO_ROOT ]] || args+=(--repo-root "$REPO_ROOT")
    [[ -x $RUN_DIR_SH ]] || die "run-dir.sh not found at $RUN_DIR_SH; evidence unavailable"
    run_dir=$("$RUN_DIR_SH" "${args[@]}") || die 'could not resolve the run directory'
    FILE=$run_dir/run-state.json
}

# The file is trusted only as an owned, non-symlink regular JSON object.
read_state() {
    [[ ! -L $FILE ]] || die "state file must not be a symlink: $FILE"
    if [[ ! -e $FILE ]]; then STATE='{}'; return 0; fi
    [[ -f $FILE && -O $FILE ]] || die "state file must be an owned regular file: $FILE"
    STATE=$(jq -ec 'if type == "object" then . else error("not an object") end' "$FILE" 2>/dev/null) ||
        die "unparseable run state (not one JSON object): $FILE"
}

jq_path() { jq -nc --arg p "$KEY_PATH" '$p | split(".")'; }

value_json() {
    if [[ -n $JSON_VALUE ]]; then
        jq -c '.' <<< "$JSON_VALUE" 2>/dev/null || die_usage "--json is not valid JSON: $JSON_VALUE"
    elif ((VALUE_SET)); then
        jq -nc --arg v "$VALUE" '$v'
    else
        printf 'true'
    fi
}

write_state() {
    local next=$1 dir staged
    dir=$(dirname -- "$FILE")
    [[ -d $dir && ! -L $dir ]] || die "state directory must be an existing directory: $dir"
    staged=$(mktemp "$dir/.run-state.XXXXXX") || die "could not stage the state file in $dir"
    printf '%s\n' "$next" >"$staged" || { rm -f -- "$staged"; die "could not write the state file: $FILE"; }
    chmod 600 -- "$staged"
    mv -f -- "$staged" "$FILE" || { rm -f -- "$staged"; die "could not replace the state file: $FILE"; }
}

main() {
    parse_args "$@"
    resolve_file
    read_state
    local path next present value=''
    path=$(jq_path)
    if [[ $ACTION == set || $ACTION == append ]]; then
        value=$(value_json) || exit $?
    fi
    case $ACTION in
        get)
            present=$(jq -r --argjson p "$path" 'getpath($p) | if . == null then "absent" else "present" end' <<< "$STATE")
            [[ $present == present ]] || exit 11
            jq -r --argjson p "$path" 'getpath($p) | if type == "string" then . else tojson end' <<< "$STATE"
            ;;
        set)
            next=$(jq -c --argjson p "$path" --argjson v "$value" 'setpath($p; $v)' <<< "$STATE") || die 'could not set the path'
            write_state "$next"
            ;;
        append)
            next=$(jq -ec --argjson p "$path" --argjson v "$value" \
                '(getpath($p)) as $cur | if $cur == null then setpath($p; [$v]) elif ($cur | type) == "array" then setpath($p; $cur + [$v]) else error("not an array") end' \
                <<< "$STATE" 2>/dev/null) || die "append target is not an array: $KEY_PATH"
            write_state "$next"
            ;;
        unset)
            next=$(jq -c --argjson p "$path" 'delpaths([$p])' <<< "$STATE") || die 'could not unset the path'
            write_state "$next"
            ;;
    esac
}

main "$@"
```

Notes the worker must keep: `--value` always stores a **string** (`"253"`, hence the test's `["253","254"]`); numbers and booleans go through `--json`; `set` with neither stores `true`. `get` on a key whose value is JSON `null` reads as absent (11) — documented in usage. The `-h|--help` arm before the subcommand check keeps `run-state.sh --help` working. `bash -n` + `shellcheck -x -P SCRIPTDIR -S style` clean. `tests/run-tests.sh --only run-state,helper-end-of-options` → 26/0 (26 assertions; the `run-state.sh accepts a trailing -- marker` pass lands in the end-of-options suite), 68/0.

- [ ] **Step 3 (red — `--tick`):** in `tests/test-gh-body.sh` after `:192` (`'PR edit verifies a target with no gh stdout URL'`) add:

```bash
# issue #613: --tick flips exactly one unchecked Testing checkbox in the body
# file, then the ordinary exact-verify edit proves the flipped body landed.
tick_body="$tmp/tick-body.md"
printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    '## Testing' \
    '- [ ] Unit tests pass' \
    '- [ ] CI green' \
    '' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' >"$tick_body"
output=$(run_body pr edit 41 --repo owner/repo --body-file "$tick_body" --tick 'CI green' --note '8/8 checks passed on abc1234')
assert_contains "$output" 'updated pr #41' '--tick still runs the exact-verify edit'
assert_contains "$(cat "$tick_body")" '- [x] CI green (8/8 checks passed on abc1234)' \
    '--tick flips the named checkbox and appends the note'
assert_contains "$(cat "$tick_body")" '- [ ] Unit tests pass' '--tick leaves the other checkbox unchecked'
assert_eq yes "$(cmp -s "$tick_body" "$tmp/stored.md" && printf yes || printf no)" \
    'the ticked file is byte-for-byte the body gh stored'
tick_dup="$tmp/tick-dup.md"
printf '%s\n' 'This was written agentically; verify its assertions:' '' \
    '- [ ] CI green (fresh)' '- [ ] CI green (main)' '' '🤖 Co-authored by Codex gpt-5.6-luna.' >"$tick_dup"
gh_calls_before=$(wc -l <"$tmp/gh.log" | tr -d '[:space:]')
tick_dup_rc=0
tick_dup_err=$(run_body pr edit 41 --repo owner/repo --body-file "$tick_dup" --tick 'CI green' 2>&1 >/dev/null) || tick_dup_rc=$?
assert_eq '1' "$tick_dup_rc" 'an ambiguous --tick refuses'
assert_contains "$tick_dup_err" 'matches 2' 'the ambiguous refusal counts the matches'
assert_contains "$(cat "$tick_dup")" '- [ ] CI green (fresh)' 'an ambiguous --tick leaves the file untouched'
assert_eq "$gh_calls_before" "$(wc -l <"$tmp/gh.log" | tr -d '[:space:]')" 'an ambiguous --tick never calls gh'
tick_none_rc=0
run_body pr edit 41 --repo owner/repo --body-file "$tick_body" --tick 'Nonexistent' >/dev/null 2>&1 || tick_none_rc=$?
assert_eq '1' "$tick_none_rc" 'a --tick with no match refuses'
tick_create_rc=0
run_body pr create --repo owner/repo --body-file "$body" --tick 'CI green' >/dev/null 2>&1 || tick_create_rc=$?
assert_eq '1' "$tick_create_rc" '--tick is refused on create'
```

`--only gh-body` → 113 assertions / **7 failed** (today `--tick`/`--note` pass through to the stub as `gh` options: the file never changes, the ambiguous and no-match edits succeed, create succeeds).

- [ ] **Step 4 (fix — `--tick`):** in `gh-body.sh`: globals `TICK_TEXT=''` / `TICK_NOTE=''` after `:31`; in `parse_args` add `--tick|--tick=*|--note|--note=*` to the post-`--` refusal list (`:102-105`, "body options must precede --") and, before the `--json` arm (`:149`), the arms

```bash
            --tick) require_value "$1" "${2-}"; TICK_TEXT=$2; shift 2 ;;
            --tick=*) TICK_TEXT=${1#*=}; shift ;;
            --note) require_value "$1" "${2-}"; TICK_NOTE=$2; shift 2 ;;
            --note=*) TICK_NOTE=${1#*=}; shift ;;
```

add after `validate_expected_closing_issue()` (`:215`):

```bash
# --tick TEXT: flip exactly one unchecked "- [ ] TEXT..." checkbox in the body
# file to "- [x] ..." (appending " (NOTE)" with --note) before the mutation, so
# the same exact-verify edit proves the flipped body landed (issue #613). Zero
# or several matches refuse without touching the file or calling gh.
apply_tick() {
    if [[ -z $TICK_TEXT ]]; then
        [[ -z $TICK_NOTE ]] || die '--note requires --tick'
        return 0
    fi
    [[ $ACTION == edit ]] || die '--tick applies to edit only'
    [[ $TICK_TEXT != *$'\n'* && $TICK_NOTE != *$'\n'* ]] || die '--tick and --note must be single-line'
    local line matches=0 staged
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "- [ ] $TICK_TEXT"* ]] && matches=$((matches + 1))
    done <"$BODY_FILE"
    ((matches == 1)) || die "--tick must match exactly one unchecked checkbox; '- [ ] $TICK_TEXT' matches $matches"
    staged=$(mktemp "$(dirname -- "$BODY_FILE")/.gh-body-tick.XXXXXX") || die 'could not stage the ticked body'
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "- [ ] $TICK_TEXT"* ]]; then
            line="- [x] ${line#- \[ \] }"
            [[ -z $TICK_NOTE ]] || line+=" ($TICK_NOTE)"
        fi
        printf '%s\n' "$line"
    done <"$BODY_FILE" >"$staged" || { rm -f -- "$staged"; die 'could not write the ticked body'; }
    chmod --reference="$BODY_FILE" "$staged" 2>/dev/null || chmod 600 "$staged"
    mv -f -- "$staged" "$BODY_FILE" || { rm -f -- "$staged"; die 'could not replace the body file with its ticked copy'; }
    printf 'ticked: - [x] %s\n' "$TICK_TEXT" >&2
}
```

call it in `main()` between `validate_body` and `WORK_DIR=$(mktemp …)`; document it in `usage()` (`--tick TEXT [--note TEXT]  (edit only) flip the one unchecked "- [ ] TEXT..." checkbox, appending " (NOTE)", before the exact-verify edit`). The `printf '%s\n'` rewrite normalises a missing trailing newline — the body policy already requires file-backed bodies the helper wrote, so none lacks one. Measured after-count recorded in the PR (≈ 536 + 45; no pin).

- [ ] **Step 5 (red — prose pins):** in `tests/test-parallel-dispatch-contract.sh:533-538` change the two pins to the new literals:

```bash
assert_contains "$final_sweep_section" 'receipt-redrive.<pr>' \
    'receipt recovery is tracked per PR in run-state for a one-shot limit'
…
assert_contains "$final_sweep_section" 'run-state.sh append --path parked' \
    'non-recoverable receipt evidence is recorded in run-state, not a bash counter'
```

`--only parallel-dispatch-contract` → 626 / **2 failed**.

- [ ] **Step 6 (fix — SKILL.md pointers, byte-neutral):** in `agentkit/skills/parallel-issues/SKILL.md` replace, inside `:686`:

```markdown
# before
Before redrive, clear the blocker. For `write-set`, the root must widen the fence and recheck every active worker; only after the blocker clears, do one `collaboration.followup_task` and record `auto_redrive_attempted[issue]`. If the same lead is unavailable, use a fresh lead with preserved state and the exact resume command `followup_task(<same lead>, "Resume issue #<N> at: <remaining-step>")`; other blockers park.
# after
Before redrive, clear the blocker (`write-set`: widen the fence, recheck every active worker); only after the blocker clears, do one `collaboration.followup_task` and record (`$agentkit/.shared/scripts/run-state.sh set --run-id "$RUN_ID" --path redrive.<N>`). If the same lead is unavailable, give a fresh lead an exact resume command `followup_task(<lead>, "Resume issue #<N> at: <remaining-step>")`; other blockers park.
```

and inside `:925`:

```markdown
# before
`10:receipt=none` re-enters the draft loop once per PR (`receipt_redrive_attempted[pr]`); duplicate/invalid evidence is not recoverable — park the PR, `++parked_count`, report it, and never deadlock; handoff cannot print on a miss.
# after
`10:receipt=none` re-enters the draft loop once per PR (`run-state.sh` `receipt-redrive.<pr>`); duplicate/invalid evidence is unrecoverable: park the PR (`run-state.sh append --path parked`), report; handoff cannot print on a miss.
```

Measured: +1 B net → 71388 → **71389** body bytes, 946 lines unchanged, `lint-skill-size.sh` estimate `71389/4 = 17847` tokens (rounded down) — the `KNOWN_OVERSIZE[parallel-issues]="946:17847:900"` entry **holds unchanged**; if the worker's wording lands high enough to cross to 17848 it must be cut back, never the ceiling raised. The first mention uses the full `$agentkit/.shared/scripts/run-state.sh` path (`lint-helper-refs.sh` `scan_first_mentions` requires it); the later bare mentions are allowed. Every pinned phrase survives: `only after the blocker clears`, `widen the fence`, `exact resume command`, `one automatic re-drive`, `same lead is unavailable`, `10:receipt=none`, `duplicate/invalid`, `re-enters the draft loop`, `handoff cannot print`, `coverage= prs=`. `$RUN_ID` is defined at `SKILL.md:93`.

- [ ] **Step 7 (policy pointer):** append to `agentkit/skills/.shared/github-body-policy.md`:

```markdown

A Testing checkbox in a stored body is flipped with `gh-body.sh pr|issue edit N --body-file FILE --tick TEXT [--note TEXT]`: exactly one unchecked `- [ ] TEXT…` line becomes `- [x] …` (note appended in parentheses) before the same exact-verify edit; never hand-edit the file.
```

Measured +281 B → 1179; set `tests/test-gh-body.sh:597-598` to the measured count with the comment `# issue #613: +281 B for the --tick pointer.` (the policy is read by every root that posts a body — the pointer belongs here, not in a SKILL.md at its ceiling).

- [ ] **Step 8 (green):** `bash -n` + `shellcheck -x -P SCRIPTDIR -S style agentkit/skills/.shared/scripts/run-state.sh agentkit/skills/.shared/scripts/gh-body.sh`; `shellcheck -S style -e SC1091,SC2034 tests/test-run-state.sh tests/test-gh-body.sh tests/test-parallel-dispatch-contract.sh tests/test-helper-end-of-options.sh`; `tests/run-tests.sh --only run-state,gh-body,parallel-dispatch-contract,helper-end-of-options` → 26/0, 113/0, 626/0, 68/0; `tests/lint-skill-size.sh agentkit/skills` (parallel-issues at 946:17847), `tests/lint-helper-refs.sh agentkit/skills`, `tests/lint-versioned-plugin-paths.sh agentkit` clean; full `tests/run-tests.sh` green (the `skill helper invocations` and `markdown code blocks` steps see the new inline recipe fragments as prose, not fenced blocks).
- [ ] **Step 9: Shared step** with `TYPE=refactor`, `SCOPE=root-state`, `TITLE='add run-state.sh and gh-body.sh --tick so the root stops hand-editing state with inline Python'`, `WHY='The reviewed HonkHonk root issued 129 python3 heredocs out of 490 shell calls to edit run bookkeeping and PR-body checkboxes, because the skill keeps redrive and parked state in bash arrays a resumed session loses and gh-body.sh has no checkbox operation.'`, `WHAT='run-state.sh get|set|append|unset keeps one validated owner-private JSON object at <run dir>/run-state.json (run-dir.sh --run-id) or --file, atomic writes, exit 11 on absent, 1 on unparseable; gh-body.sh edit --tick TEXT [--note TEXT] flips exactly one unchecked checkbox before the existing exact-verify edit and refuses zero or several matches without calling gh; parallel-issues SKILL.md records redrive and parked state through the helper (byte-neutral at the 17847-token ceiling); github-body-policy.md carries the --tick pointer. New suite test-run-state.sh (26 assertions); gh-body +10; executable pin 66 -> 67. No root-side research step exists to remove: prior art is the Step 2 forge digest.'`, `FILES=(agentkit/skills/.shared/scripts/run-state.sh agentkit/skills/.shared/scripts/gh-body.sh agentkit/skills/.shared/github-body-policy.md agentkit/skills/parallel-issues/SKILL.md tests/test-run-state.sh tests/test-gh-body.sh tests/test-parallel-dispatch-contract.sh tests/test-helper-end-of-options.sh)`, `ISSUE=613`.

---

## Ranking, parallelism, sequencing

| Order | Task | Issue | Branch | Files it owns | Risk |
|---|---|---|---|---|---|
| 1 | Task 1 | #661 | `refactor/issue-661` | `hooks/lib/guard-lib.sh`, `tests/test-hooks.sh` | low (gate already measured green on `abdc88a`; 253/253 identical) |
| 2 | Task 2 | #611 | `fix/issue-611` | `worktree-commit.sh`, `worker-prompts.md`, `tests/test-worktree-commit.sh`, `tests/test-compose-worker-prompt.sh` | low (additive writer, non-blocking) |
| 3 | Task 3 | #610 | `fix/issue-610` | `write-merge-plan.sh`, `triage-issues.sh`, `agent-preflight.sh`, `agent-run.sh`, `triage-and-selection.md`, 6 suites | medium (new validation rule; awk over workflow YAML) |
| 4 | Task 4 | #613 | `refactor/issue-613` | new `run-state.sh`, `gh-body.sh`, `github-body-policy.md`, `parallel-issues/SKILL.md`, new `tests/test-run-state.sh`, 3 suites | medium (new helper; SKILL.md at its token ceiling) |

**Overlap ruling.** The four tasks are **file-disjoint**: Task 1 alone touches `guard-lib.sh`/`test-hooks.sh` (Task 2's ledger writer lives in `worktree-commit.sh`, not the hook lib); Task 2 touches `worker-prompts.md` and Task 4 `parallel-issues/SKILL.md` (different files, different ceilings); Task 3 touches `triage-and-selection.md` and no SKILL.md; the `caches=` fixture lines in `test-create-issue-worktree.sh` are left alone. `tests/test-parallel-dispatch-contract.sh` is edited **only by Task 4** — Task 2 keeps the `paths-touched.ndjson` literal so its existing pin `:1389` passes untouched. `tests/test-helper-end-of-options.sh` is edited only by Task 4. No shared ceiling line, hence **no chains**: dispatch all four together; merge in any order; the only merge-time interaction is the harmless union of four independent test additions.

**Foreclosure check.** #608 (waiter workers, max yields) touches `wait-discipline.md`, `stall-check.sh`, `gh-pr-state.sh --wait-ci` and the spawn shape — none edited here. #612 (`FORMAT_FIX`) touches the declared-command vocabulary in `repo-config.sh`/`agent-run.sh --cmd`; Task 3's `agent-run.sh` edit is confined to `select_caches`.

---

## Self-review

### Coverage — issue acceptance → task step

| Issue | Acceptance / fix bullet | Satisfied by |
|---|---|---|
| #661 | one implementation with a drop-all-bodies mode; callers unchanged | T1 Step 3 (`mode=${2:-recover}`; 5 gh + 3 destructive consumers untouched) |
| #661 | the hooks suite is the oracle; corpus comparison is the acceptance check | T1 Steps 2, 4 (669/0; 253/253 byte-identical on both lexers — measured on `abdc88a` while planning) |
| #661 | behaviour byte-identical; guard-lib 2370 → 2264 predicted | T1 Step 4 (identical); 2407 → **2298** on today's tree (Step 3 arithmetic) |
| #611 | after hand-back `paths-touched.ndjson` exists and lists every changed path, hooks disabled | T2 Steps 1-2 (no hook in the fixture; three paths; second commit appends) |
| #611 | completion reports no longer mention the file | T2 Step 3 (instruction removed; `:1389` pin kept) |
| #611 | unit: two modified + one untracked → three records | T2 Step 1 — **as three paths in one per-commit record** (guard-shaped; stated deviation) |
| #611 | option 1, prompt conditional on `hooks= paths-touched=armed` | **not taken**: no `hooks=` contract fact exists; the ledger-at-commit option needs no new probe |
| #610 | "add crate X" dispatches with `Cargo.toml`, `Cargo.lock`, CI-declared generated files | T3 Steps 3-4 (`--classify-deps` names the signal) + Step 7 (root predicts the manifest) + Steps 1-2 (validator completes lockfile + workflow siblings; `--fix`) |
| #610 | `env-contract.txt` for a Cargo repo carries `CARGO_HOME=` under `caches=` | T3 Steps 5-6 (unconditional, like uv/npm/pip; `GOMODCACHE` beside it) |
| #610 | neither #16- nor #52-style issue blocks on turn 1 | T3 Steps 2, 6 (companions predicted before dispatch; cache writable inside `agent-run.sh`) |
| #610 | unit: write-set prediction on a dependency fixture; preflight emits `CARGO_HOME` | T3 Steps 1, 3, 5 |
| #610 | `cargo-roots` in the contract; `RUSTUP_HOME`; `detect-toolchains.sh` table | **not taken** (dead token — no consumer of `*-roots` exists; rustup is a toolchain, not a cache; the toolchain table is not on the dispatch path) — stated in the task |
| #610 | worker prompt states the cache env once | already true (`worker-prompts.md:118,615`); no change |
| #613 | `run-state.sh set|get|append --file F --path a.b.c --value V`, validated JSON, atomic write | T4 Steps 1-2 (+ `unset`, `--json`, `--run-id` via `run-dir.sh`) |
| #613 | `gh-body.sh --tick 'Fresh CI' --note '…'` flips one checkbox, then exact-verify | T4 Steps 3-4 (sole-match invariant; zero/several refuse before any `gh` call) |
| #613 | skills' recipes use the helper instead of inline Python | T4 Step 6 (`:686`, `:925`), Step 7 (body policy) |
| #613 | remove the root-side research step; root performs no web search | **no such step exists** (`SKILL.md:287-303`, `:416` are forge digests) — stated; no change |
| #613 | unit: set/get round trip; invalid JSON rejected; `--tick` on a two-checkbox body | T4 Steps 1, 3 |
| #613 | a chain run's root transcript contains zero inline Python for state | **not automated** (needs a live run); the next `parallel-issues` run is the check — named in the PR Testing list |

### Placeholder scan

`<N>` (shared step, `redrive.<N>`, `receipt-redrive.<pr>`, prose), `<scope>`/`<title>`/`<why>`/`<what>` (shared-step template), `<worktree>` (prose and the prompt literal), `<run dir>` (prose), `<scratchpad>` (= `/tmp/claude-1000/-home-adam-github-agent-kit/c8271f1d-01eb-41e9-bc21-3daab578d54b/scratchpad`), and `<N>` inside the two WHAT strings (measured ceilings the worker fills in) are the intentional fill-ins. No `TODO`/`TBD`/`XXX`. Every line number carries a quoted anchor from `abdc88a`. Every measured number below is from this plan's own runs on `abdc88a` except the red/green assertion counts of Tasks 2-4, which are by construction (see *Not verified*).

### Ceiling table

| File | Pin (test:line) | Now | Expected delta | After |
|---|---|---|---|---|
| `hooks/lib/guard-lib.sh` | `test-hooks.sh:2944` `2407` | 2407 | −110 +1 | **2298** (measured for the exact text; ratchet down) |
| `.shared/scripts/worktree-commit.sh` | `test-worktree-commit.sh:1021` `800` | 793 | +28 −7 | **814** (measured; moved by delta, reason in test) |
| composed issue-lead prompt (path-neutral bytes) | `test-compose-worker-prompt.sh:114` `18756` | 18756 | −1 | **18755** expected (measured; ratchet) |
| `parallel-issues/references/worker-prompts.md` | no pin | 45911 B | −1 B | 45910 B |
| `.shared/scripts/agent-preflight.sh` | `test-agent-preflight.sh:1265` `1330` | 1323 | 0 | **1323** (ratchet down) |
| `.shared/scripts/agent-run.sh` | `test-agent-run-cmd.sh:512` `1595` | 1591 | +2 | **1593** (ratchet down) |
| `.shared/scripts/triage-issues.sh` | `test-triage-issues.sh:239` `506` | 503 | +47 | **550** (measured, incl. the T3-2 mirror check; reason in test — measured after-count wins) |
| `parallel-issues/scripts/write-merge-plan.sh` | no pin | 776 | +97 | **873** (measured, in PR) |
| `parallel-issues/references/triage-and-selection.md` | `test-fast-mode-contract.sh:168` `37700 B` | 37574 | +583 B | **38157** (measured; moved by delta, reason in test) |
| `parallel-issues/SKILL.md` | `lint-skill-size.sh` `KNOWN_OVERSIZE` `946:17847:900` | 946 lines / 71388 B / 17847 tok | 0 lines, +1 B | 946 / 71389 B / **17847** tok (entry unchanged) |
| `.shared/github-body-policy.md` | `test-gh-body.sh:598` `920 B` | 898 | +281 B | **1179** (measured; moved by delta, reason in test) |
| `.shared/scripts/gh-body.sh` | no pin | 536 | +≈45 | ≈581 (measured, in PR) |
| `.shared/scripts/run-state.sh` | no pin (new) | — | ≈150 | ≈150 (measured, in PR) |
| executables under `agentkit/skills` | `test-helper-end-of-options.sh:30` `66` | 66 | +1 | **67** (`run-state.sh`; reason in test) |
| `hooks` assertions | — | 666 | +3 | 669 |

### Executable-count pin status

`find agentkit/skills -type f -name '*.sh' -perm -111 | wc -l` = **66** on `abdc88a`. Task 4 adds exactly one executable (`run-state.sh`, `chmod 755`) and moves the pin to 67 in the same PR; `run-state.sh -- ` exits 2 with `a subcommand is required` (no `unknown argument` text, so the roster's marker check passes). Tasks 1-3 add no executables (Task 3's fixture script lives under the test's `$tmp`).

### Not verified while planning

- Tasks 2-4 red/green assertion counts (145/6, 45/4, 29/5, 170/2, 94/1, 113/7, 626/2, 26/all) are by construction from the baseline totals; only Task 1's corpus gate and 666-baseline were executed. A worker whose count differs reports the measured number.
- Whether `worker-prompts.md:84-85` is inside the composed issue-lead prompt: the composer streams the whole template (`compose-worker-prompt.sh:1162`) with placeholder substitution; T2 Step 4 reads the measured value rather than assuming 18755.
- `workflow_lock_siblings` was prototyped on a single-document workflow with block-list and flow-list `paths:` (both forms parsed; the workflow's own path excluded); multi-document YAML (`---`), `paths-ignore:`, and anchors/aliases are out of scope and the awk ignores them.
- The `env -u … HOME=<0500 dir>` shape for the `agent-run.sh` cache test assumes git and the wrapper need no writable HOME for `--cmd test` on a fixture repo; the preflight suite already runs under an unwritable HOME (`:840-842`), but the wrapper's own path was not exercised while planning.
- `gh-body.sh --tick` on a body whose last line lacks a trailing newline is normalised by the rewrite; the policy already requires helper-written files, so no such body should exist.
- The K3 corpus reuse assumes `<scratchpad>/wave3/review/k3-corpus/` survives until the worker runs; the wave-three plan's rebuild recipe is the fallback.

### Review applied

A reviewer applied this plan verbatim on scratch copies (`<scratchpad>/wave4/review/REVIEW.md`, control + t1-t4) and found 11 defects, all folded in above: T1-1 (guard-lib ceiling arithmetic, 2297 → 2298), T2-1 (worktree-commit line accounting, 810 → 814), T3-1 (unescaped `$p` in the `--fix` write-set filter), T3-2 (unreachable `--classify-deps`/`--classify-shape` combination check), T3-3 (markdown list-marker collision with the `-` no-signal sentinel), T3-4 (new shellcheck SC2016 finding in a test fixture), T3-5 (work-shape red count, measured ceilings, remedy header/filter wording), T4-1 (jq `tojson` insertion order, not sorted), T4-2 (dropped pinned phrase "same lead is unavailable"), T4-3 (`--json false`/`null` wrongly refused), T4-4 (`die_usage` inside a `$(…)` subshell not stopping the parent). Also folded in: the two Minor notes (26/0 not 27/0; the `--tick` usage() line stays a stated requirement) and the Global Constraints `/tmp` control-set correction.
