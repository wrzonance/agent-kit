#!/usr/bin/env bash
# ak ship: commit with the trailer, push, open or reuse the draft PR.
# shellcheck disable=SC2016 # markdown code spans in single-quoted fixtures
TEST_NAME=v2-ship
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1
mkdir -p .ak
printf 'title: Fix the widget\n\n~~~untrusted\nbody\n~~~\n' >.ak/issue.md

out=$("$AK" ship 2>&1); rc=$?
assert_eq 2 "$rc" 'ship without --message is a usage error'

out=$("$AK" ship --message 'feat: nothing' 2>&1); rc=$?
assert_eq 1 "$rc" 'nothing ahead of base is refused'
assert_contains "$out" 'fix: ' 'the refusal names a fix'

lookup='api repos/acme/widget/pulls?head=acme:feat/issue-7&state=open'
route "$lookup" '[]'
route 'api repos/acme/widget/pulls?head=acme:feat/issue-7&state=closed*' '[]'
route 'api -X POST repos/acme/widget/pulls *' '{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}'
printf 'two\n' >src/b.txt
# A description a person cannot follow is refused before anything is committed (field PR bodies packed every change
# into one sentence under Why/What, and the operator rewrote each by hand).
printf '## Why\nBecause.\n' >"$WORK/body.md"
before=$(git rev-parse HEAD)
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1); rc=$?
assert_eq 1 "$rc" 'a description without the sections is refused'
assert_contains "$out" 'the PR description lacks: ## The problem, ## What changed, ## Tests' 'the refusal names the missing sections'
assert_contains "$out" 'fix: add the sections' 'the refusal says what to do'
assert_eq "$before" "$(git rev-parse HEAD)" 'a refused description commits nothing'
long=$(printf 'word %.0s' $(seq 50))
printf '## The problem\nIt broke.\n\n## What changed\nThe `x y z` helper now %s.\n\n## Tests\nOne.\n' "$long" >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1); rc=$?
assert_eq 1 "$rc" 'a 50-word sentence is refused'
assert_contains "$out" 'a sentence over 45 words, starting: The CODE helper now word' 'the refusal quotes how the sentence starts'
printf '## The problem\nShort one. Second sentence %s.\n\n## What changed\nx\n\n```\n## Tests\n```\n' "$(printf 'w %.0s' $(seq 44))" >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1)
assert_contains "$out" 'the PR description lacks: ## Tests' 'a heading inside a fenced block does not count'
printf '## The problem\nShort one. Second sentence %s.\n\n## What changed\nx\n\n## Tests\ny\n' "$(printf 'w %.0s' $(seq 44))" >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1)
assert_contains "$out" 'a sentence over 45 words, starting: Second sentence w w w' 'a 46-word sentence after the first is caught too'
# Run output is not what the tests prove, and a plan label means nothing to a reader who has not seen the plan (a field
# description ended its Tests section with a pasted command and `oracle=ci`, and explained a change as "for Packet 7").
ok_body='## The problem\nIt broke.\n\n## What changed\n%s\n\n## Tests\n%s\n'
# shellcheck disable=SC2059,SC2016
printf "$ok_body" 'x' '- `ak verify` passed. It reported `oracle=ci`, so CI decides.' >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1); rc=$?
assert_eq 1 "$rc" 'a status line in Tests refuses'
assert_contains "$out" 'the ## Tests section carries run output, starting: - `ak verify` passed' 'the refusal quotes the line'
# shellcheck disable=SC2059
printf "$ok_body" 'x' "- \`pytest $(printf 'tests/test_%s.py ' $(seq 20))\` passed." >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1)
assert_contains "$out" 'the ## Tests section carries run output' 'a pasted command in Tests refuses'
# shellcheck disable=SC2059
printf "$ok_body" 'The issued branch keeps its writer as required for Packet 7.' 'y' >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1)
assert_contains "$out" 'names "Packet 7", a label from the issue or its plan' 'a plan label refuses and is quoted'
assert_contains "$out" 'fix: say what that part is in plain words' 'the refusal says what to write instead'
# shellcheck disable=SC2059,SC2016
printf "$ok_body\n## Still to do\nTask 2 (the export endpoint) is left. %s.\n" 'The `Phase 2` cable type and `verify=pass` are product words here.' 'y' "$long" >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1)
assert_not_contains "$out" 'a label from' 'a backticked name and the Still to do list pass'
assert_not_contains "$out" 'run output' 'a status word outside Tests passes'
assert_contains "$out" 'a sentence over 45 words' 'that description reaches the next check'
# shellcheck disable=SC2059,SC2016
printf "$ok_body\n## Contests\nThe endpoint returns \`verify=required\`. %s.\n\n## Not still to do\nPacket 7.\n" 'x' 'y' "$long" >"$WORK/body.md"
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1)
assert_not_contains "$out" 'run output' 'a heading that only contains the word tests is not the Tests section'
assert_contains "$out" 'names "Packet 7"' 'only the exact Still to do heading exempts a label'
printf '## The problem\nIt broke when a user saved.\n\n## What changed\n- **Save.** `save()` in `src/b.txt` wrote nothing; it now writes the file.\n- %s\n- %s\n\n```text\n%s %s\n```\n\n## Tests\n`t.sh` proves the write.\n\nCloses #7\n' \
    "$(printf 'a %.0s' $(seq 30))" "$(printf 'b %.0s' $(seq 30))" "$long" "$long" >"$WORK/body.md"
export CLAUDECODE=1
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1); rc=$?
unset CLAUDECODE
head=$(git rev-parse HEAD)
assert_eq 0 "$rc" 'ship succeeds'
assert_contains "$out" "pr=https://github.com/acme/widget/pull/9 head=$head" 'ship prints the PR and head'
msg=$(git log -1 --format=%B)
assert_contains "$msg" 'feat: add b' 'the commit carries the message'
assert_contains "$msg" 'Co-Authored-By: Claude <noreply@anthropic.com>' 'the commit carries the harness trailer'
assert_eq "$head" "$(git -C "$WORK/origin.git" rev-parse feat/issue-7)" 'the branch is pushed to origin'
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" '-F draft=true' 'the PR is created as a draft'
assert_contains "$log" '-f base=main' 'the PR targets the base'
assert_contains "$log" '-f title=Fix the widget' 'the title comes from .ak/issue.md'
body=$(cat .ak/pr-body.md)
assert_contains "$body" 'This was written agentically; verify its assertions:' 'the body opens with the banner'
assert_contains "$body" '`save()` in `src/b.txt` wrote nothing; it now writes the file.' 'the body carries the body file'
assert_contains "$body" 'Closes #7' 'the body closes the issue'
assert_eq 1 "$(grep -c 'Closes #7' <<<"$body")" 'a description that already closes the issue gets no second closing line'
assert_contains "$body" 'Co-authored by the Claude agent.' 'the body closes with the attribution'
assert_eq '' "$(git status --porcelain)" '.ak/ state is not committed'

: >"$FAKE_GH_ROUTES"
: >"$FAKE_GH_LOG"
route "$lookup" '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}]'
out=$("$AK" ship --message 'feat: again' 2>&1); rc=$?
assert_eq 0 "$rc" 'a re-ship with nothing staged succeeds'
assert_eq "$head" "$(git rev-parse HEAD)" 'nothing staged means no new commit'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/9' 'the existing PR is reused'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'POST' 'an existing PR is not recreated or edited'

out=$(AGENT_BASE_BRANCH=feat/issue-7 "$AK" ship --message 'feat: x' 2>&1); rc=$?
assert_eq 1 "$rc" 'shipping from the base branch is refused'
assert_contains "$out" 'base branch' 'the base-branch refusal names the cause'

git -C "$repo" push -q origin HEAD:refs/heads/feat/other 2>/dev/null
git -C "$repo" fetch -q origin
git -C "$repo" worktree add -q -b fix-thing "$WORK/prwt" origin/feat/other
cd "$WORK/prwt" || exit 1
mkdir -p .ak && printf '12\n' >.ak/pr && printf 'feat/other\n' >.ak/base
: >"$FAKE_GH_ROUTES"
route 'api repos/acme/widget/pulls?head=acme:fix-thing&state=open' '[{"number":12,"html_url":"https://github.com/acme/widget/pull/12"}]'
printf 'pr\n' >src/pr.txt
out=$("$AK" ship --message 'fix: pr fix' 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR worktree without an issue number ships'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/12' 'a PR worktree reuses its PR'

# A branch whose PR already merged never gets a second PR (bench 2026-10-01: a merge-down respawn opened #138).
: >"$FAKE_GH_ROUTES"
route 'api repos/acme/widget/pulls?head=acme:*&state=open' '[]'
route 'api repos/acme/widget/pulls?head=acme:*&state=closed*' '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9","merged_at":"2026-10-01T00:00:00Z"}]'
route 'api -X POST repos/acme/widget/pulls *' '{"number":10,"html_url":"https://github.com/acme/widget/pull/10"}'
printf 'more\n' >>src/b.txt
: >"$FAKE_GH_LOG"
out=$("$AK" ship --message 'fix: after merge' 2>&1); rc=$?
assert_eq 0 "$rc" 'shipping after the PR merged is not an error'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/9 merged already' 'ship names the merged PR'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X POST repos/acme/widget/pulls ' 'no duplicate PR is opened'

# A merge-down must merge the base, not copy its changes (field run: a resolver's hand-made commit left the branch
# without its base, so the next update conflicted again and a second resolver was spawned).
git -C "$repo" checkout -q -b feat/moved origin/main
printf 'moved\n' >"$repo/src/moved.txt"
git -C "$repo" add src && git -C "$repo" commit -q -m moved && git -C "$repo" push -q origin feat/moved 2>/dev/null
git -C "$repo" checkout -q main
git fetch -q origin
printf 'origin/feat/moved\n' >.ak/resolve
printf 'copied\n' >src/moved.txt
out=$("$AK" ship --message 'merge: feat/moved into feat/issue-7' 2>&1); rc=$?
assert_eq 1 "$rc" 'a resolve that did not merge its base is refused'
assert_contains "$out" 'fix: git merge origin/feat/moved' 'the refusal names the merge to run'
git checkout -q HEAD~1 -- src/moved.txt 2>/dev/null || git rm -q src/moved.txt
git commit -q -m 'drop the copy'
git merge -q --no-edit origin/feat/moved
out=$("$AK" ship --message 'merge: feat/moved into feat/issue-7' 2>&1); rc=$?
assert_eq 0 "$rc" 'a real merge of the base ships'
assert_eq no "$([[ -e .ak/resolve ]] && echo yes || echo no)" 'ship clears the resolve marker once the base is merged'
printf 'origin/feat/gone\n' >.ak/resolve
printf 'again\n' >>src/b.txt
out=$("$AK" ship --message 'merge: feat/gone into feat/issue-7' 2>&1); rc=$?
assert_eq 1 "$rc" 'an unfetchable merge-down base is refused, not checked against a stale ref'
assert_contains "$out" 'cannot fetch feat/gone' 'the refusal names the base it could not fetch'
rm -f .ak/resolve

finish
