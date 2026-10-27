#!/usr/bin/env bash
# ak receipt: one PR comment with head, reviewer, findings and CI; writes .ak/result.
TEST_NAME=v2-receipt
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1
printf 'two\n' >src/b.txt
git add src && git commit -q -m 'add b' && git push -q -u origin HEAD 2>/dev/null
head=$(git rev-parse HEAD)
mkdir -p .ak
route 'api repos/acme/widget/pulls?head=acme:feat/issue-7&state=open' '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}]'
route "api repos/acme/widget/commits/$head/check-runs?per_page=100 --paginate" '{"check_runs":[{"name":"t","status":"completed","conclusion":"success"}]}'
route 'api -X POST repos/acme/widget/issues/9/comments *' '{"html_url":"https://github.com/acme/widget/pull/9#issuecomment-1"}'

printf 'P1|bad thing\n' >"$WORK/bad"
out=$("$AK" receipt --findings "$WORK/bad" 2>&1); rc=$?
assert_eq 1 "$rc" 'a finding without a disposition is refused'
assert_contains "$out" 'P1|bad thing' 'the refusal quotes the line'

out=$("$AK" receipt 2>&1); rc=$?
assert_eq 1 "$rc" 'a bare receipt before any review is refused'
assert_contains "$out" 'fix: ak review' 'the refusal names the review command, not a findings flag'

printf 'model=gpt-5.6-sol reviewer=codex\n\nfindings\n' >.ak/review.md
printf 'P1|null deref in parser|fixed abc1234\n\nP2|rename helper|declined: churn outside the issue\n' >"$WORK/findings"
: >"$FAKE_GH_LOG"
out=$("$AK" receipt --findings "$WORK/findings" 2>&1); rc=$?
assert_eq 0 "$rc" 'receipt succeeds'
assert_contains "$out" 'receipt=https://github.com/acme/widget/pull/9#issuecomment-1' 'receipt prints the comment URL'
assert_contains "$out" "pr=https://github.com/acme/widget/pull/9 ci=green review=done head=$head" 'receipt prints the result line'
assert_contains "$(cat "$FAKE_GH_LOG")" '-F body=@' 'the body is posted from a file'
body=$(cat .ak/receipt.md)
assert_contains "$body" 'This was written agentically; verify its assertions:' 'the comment opens with the banner'
assert_contains "$body" "$head" 'the comment names the reviewed head'
assert_contains "$body" 'gpt-5.6-sol' 'the comment names the reviewer model'
assert_contains "$body" 'P1 | null deref in parser | fixed abc1234' 'a fixed finding is listed'
assert_contains "$body" 'P2 | rename helper | declined: churn outside the issue' 'a declined finding is listed'
assert_contains "$body" 'CI: green' 'the comment carries the CI state'
result=$(cat .ak/result)
assert_contains "$result" 'pr=https://github.com/acme/widget/pull/9' 'result has the PR'
assert_contains "$result" 'ci=green' 'result has CI'
assert_contains "$result" 'review=done' 'result has the review status'
assert_contains "$result" "head=$head" 'result has the head'
assert_contains "$result" 'note=findings=2 fixed=1 declined=1' 'result notes the dispositions'
assert_not_contains "$result" 'ci-only' 'a PR whose CI never failed names no CI-only check'
assert_not_contains "$result" 'base-red' 'a green PR names no base-red check'
# A second receipt on one head updates the first comment (a field PR carried two receipts 32 s apart, and a receipt
# run again after CI concluded left the earlier ci=pending one standing). Only a comment that is a receipt for this
# head counts: one that quotes it, or a receipt for another head, is left alone.
routes=$(cat "$FAKE_GH_ROUTES")
jq -n --arg h "$head" '[{id: 54, user: {login: "me"}, body: "> This was written agentically; verify its assertions:\n>\n> **ak receipt** for head `\($h)`"},
    {id: 55, user: {login: "me"}, body: "This was written agentically; verify its assertions:\n\n**ak receipt** for head `\($h)`\n\n- CI: pending"},
    {id: 56, user: {login: "me"}, body: "This was written agentically; verify its assertions:\n\n**ak receipt** for head `0000000`"},
    {id: 58, user: {login: "someone-else"}, body: "This was written agentically; verify its assertions:\n\n**ak receipt** for head `\($h)`\n\n- CI: green"}]' >"$WORK/comments.json"
printf 'api --paginate repos/acme/widget/issues/9/comments?per_page=100\t%s\t0\n%s\n' "$WORK/comments.json" "$routes" >"$FAKE_GH_ROUTES"
route 'api user --jq .login' 'me'
route 'api -X PATCH repos/acme/widget/issues/comments/58 *' '{"html_url":"https://github.com/acme/widget/pull/9#issuecomment-58"}'
route 'api -X PATCH repos/acme/widget/issues/comments/55 *' '{"html_url":"https://github.com/acme/widget/pull/9#issuecomment-55"}'
: >"$FAKE_GH_LOG"
out=$("$AK" receipt --findings "$WORK/findings" 2>&1); rc=$?
assert_eq 0 "$rc" 'a second receipt on the same head succeeds'
assert_contains "$out" 'receipt=https://github.com/acme/widget/pull/9#issuecomment-55' 'it names the comment it updated'
assert_contains "$(cat "$FAKE_GH_LOG")" 'api -X PATCH repos/acme/widget/issues/comments/55 -F body=@' 'the receipt for this head is updated in place'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X POST repos/acme/widget/issues/9/comments' 'no second comment is posted for the head'
jq 'map(select(.id != 55))' "$WORK/comments.json" >"$WORK/comments.tmp" && mv -f "$WORK/comments.tmp" "$WORK/comments.json"
: >"$FAKE_GH_LOG"
out=$("$AK" receipt --findings "$WORK/findings" 2>&1)
assert_contains "$out" 'receipt=https://github.com/acme/widget/pull/9#issuecomment-1' 'a head with no receipt of its own gets a new comment'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PATCH' 'a quoted receipt, a receipt for another head and a look-alike from another account are not edited'
# An update GitHub refuses still leaves a receipt: it is posted as a new comment.
jq -n --arg h "$head" '[{id: 57, user: {login: "me"}, body: "This was written agentically; verify its assertions:\n\n**ak receipt** for head `\($h)`"}]' >"$WORK/comments.json"
out=$("$AK" receipt --findings "$WORK/findings" 2>&1); rc=$?
assert_eq 0 "$rc" 'a refused update is not a failed receipt'
assert_contains "$out" 'receipt=https://github.com/acme/widget/pull/9#issuecomment-1' 'the receipt is posted instead'
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"
# A check the base branch fails too is named in the result note, so the collect line shows that the base is red
# (field run: the receipt called a check that was red on the default branch CI-only, and the root kept waiting).
main=$(git ls-remote origin refs/heads/main | cut -f1)
red='{"check_runs":[{"name":"t","status":"completed","conclusion":"failure"},{"name":"own","status":"completed","conclusion":"failure"}]}'
printf '%s' "$red" >"$WORK/red-head.json"
printf '{"check_runs":[{"name":"t","status":"completed","conclusion":"failure"}]}' >"$WORK/red-main.json"
printf 'api repos/acme/widget/commits/%s/check-runs?per_page=100 --paginate\t%s\t0\napi repos/acme/widget/commits/%s/check-runs?per_page=100 --paginate\t%s\t0\n%s\n' \
    "$head" "$WORK/red-head.json" "$main" "$WORK/red-main.json" "$routes" >"$FAKE_GH_ROUTES"
"$AK" receipt --findings "$WORK/findings" >/dev/null 2>&1
assert_contains "$(cat .ak/result)" 'ci=red' 'a red head is recorded as red'
assert_contains "$(cat .ak/result)" '; base-red: t (also red on main)' 'the result note names the check the base branch fails too'
assert_not_contains "$(cat .ak/result)" 'base-red: t,own' 'a failure of its own is not called base-red'
# Any valid base name is reported: one with characters outside the plain set (release/c++) used to drop the note.
git push -q origin "$main:refs/heads/release/c++" 2>/dev/null
printf 'release/c++\n' >.ak/base
"$AK" receipt --findings "$WORK/findings" >/dev/null 2>&1
assert_contains "$(cat .ak/result)" '; base-red: t (also red on release/c++)' 'a base named release/c++ is still reported'
rm -f .ak/base
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"
"$AK" receipt --findings "$WORK/findings" >/dev/null 2>&1
# Checks only CI caught reach the operator through the result note (a field repo paid a CI round per PR for a type check).
printf 'lint\nmypy\n' >.ak/ci-only
"$AK" receipt --findings "$WORK/findings" >/dev/null 2>&1
assert_contains "$(cat .ak/result)" 'note=findings=2 fixed=1 declined=1; ci-only: lint,mypy' 'the result note names the checks only CI caught'
# A record the checkout brought along (tracked) is a branch author's text, not ak's: it never reaches the note.
git add -f .ak/ci-only
"$AK" receipt --findings "$WORK/findings" >/dev/null 2>&1
assert_not_contains "$(cat .ak/result)" 'ci-only' 'a tracked record is ignored'
git rm -q --cached .ak/ci-only
rm -f .ak/ci-only

rm .ak/review.md
touch .ak/review.unavailable
printf 'none\n' >"$WORK/none"
out=$("$AK" receipt --findings "$WORK/none" 2>&1); rc=$?
assert_eq 0 "$rc" 'a none findings file is accepted'
assert_contains "$out" 'review=unavailable' 'an unavailable reviewer is reported'
assert_contains "$(cat .ak/receipt.md)" 'Findings: none' 'no findings is stated'

rm .ak/review.unavailable
out=$("$AK" receipt --findings "$WORK/none" 2>&1); rc=$?
assert_eq 1 "$rc" 'a receipt before any review attempt is refused'
assert_contains "$out" 'fix: ak review' 'the refusal names the review command'
touch .ak/review.unavailable

# A worker that ships part of an issue names the rest (2026-10-01 field run: an issue asked for two PRs).
printf 'none\n' >"$WORK/none2"
: >"$FAKE_GH_LOG"
# A partial PR must not close its issue on merge (a field PR for task 1 of 7 said "Closes #N").
routes=$(cat "$FAKE_GH_ROUTES")
printf 'Intro.\n\nCloses #7\n\nSee also closes #70.\nFIXED: #7, resolves acme/widget#7 and close https://github.com/acme/widget/issues/7.\nfixes GH-7; Resolved http://www.github.com/ACME/Widget/issues/7 and closes acmeXwidget#7\nFixes other/repo#7 and closes https://github.com/other/repo/issues/7\n' >"$WORK/prbody.txt"
printf 'api repos/acme/widget/pulls/9 --jq*\t%s\t0\napi -X PATCH repos/acme/widget/pulls/9 *\t-\t0\n%s\n' "$WORK/prbody.txt" "$routes" >"$FAKE_GH_ROUTES"
out=$("$AK" receipt --findings "$WORK/none2" --remaining 'Packet B (add-in dialogs) needs its own PR' 2>&1); rc=$?
assert_eq 0 "$rc" 'receipt accepts --remaining'
assert_contains "$(cat .ak/result)" 'remaining: Packet B (add-in dialogs) needs its own PR' 'the result note carries what is left'
assert_contains "$(cat .ak/receipt.md)" 'Remaining: Packet B (add-in dialogs) needs its own PR' 'the receipt comment names what is left'
assert_contains "$(cat "$FAKE_GH_LOG")" 'api -X PATCH repos/acme/widget/pulls/9 -F body=@' 'a partial PR has its body rewritten'
assert_contains "$(cat .ak/pr-body.md)" 'Part of #7' 'the closing line becomes Part of'
assert_not_contains "$(cat .ak/pr-body.md)" 'Closes #7' 'nothing in the body still closes the issue'
assert_contains "$(cat .ak/pr-body.md)" 'closes #70' 'a line about another issue is left alone'
assert_contains "$(cat .ak/pr-body.md)" 'Part of #7, Part of acme/widget#7 and Part of https://github.com/acme/widget/issues/7.' 'every closing form GitHub reads is rewritten: colon, any case, owner/repo and URL'
assert_eq 0 "$(grep -v 'other/repo' .ak/pr-body.md | sed 's/closes acmeXwidget#7//' | grep -ciE '(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+[^[:space:]]*(#|issues/)7([^0-9]|$)')" 'no closing keyword for the issue survives'
assert_contains "$(cat .ak/pr-body.md)" 'Part of GH-7; Part of http://www.github.com/ACME/Widget/issues/7 and closes acmeXwidget#7' 'GH-N, www and any-case repository names are rewritten; a look-alike repository name is not'
assert_contains "$(cat .ak/pr-body.md)" 'Fixes other/repo#7 and closes https://github.com/other/repo/issues/7' 'issue 7 of another repository is left alone'
printf 'api repos/acme/widget/pulls/9 --jq*\t-\t1\n%s\n' "$routes" >"$FAKE_GH_ROUTES"
out=$("$AK" receipt --findings "$WORK/none2" --remaining 'y' 2>&1); rc=$?
assert_eq 1 "$rc" 'a partial receipt stops when the PR body cannot be read'
assert_contains "$out" 'could not read the body of PR #9' 'the refusal says why'
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"
printf '7 or 8\n' >.ak/issue
out=$("$AK" receipt --findings "$WORK/none2" --remaining 'y' 2>&1); rc=$?
assert_eq 1 "$rc" 'an issue number that is not digits is refused, never put in a pattern'
printf '7\n' >.ak/issue
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"
# Findings are arguments, and none are needed when the review found nothing (08c2516 bench: 8 of 12 workers spent a
# turn writing .ak/findings before the receipt).
rm -f .ak/findings
out=$("$AK" receipt 2>&1); rc=$?
assert_eq 0 "$rc" 'an unavailable review needs no findings argument'
assert_contains "$(cat .ak/receipt.md)" 'Findings: none' 'the receipt states none'
assert_eq none "$(cat .ak/findings)" 'the decided findings are kept for a later receipt'

# Every finding the review printed needs a disposition (PR bench 2026-10-01: a P1 was answered with "none").
printf 'reviewer=claude model=m head=h\nP1: undo drops the count — src/store.js:33 — x\nP2: rename — a — b\n' >.ak/review.md
printf 'none\n' >"$WORK/undecided"
out=$("$AK" receipt --findings "$WORK/undecided" 2>&1); rc=$?
assert_eq 1 "$rc" 'a receipt that leaves review findings undecided is refused'
assert_contains "$out" 'the review has 2 findings but the findings file decides 0' 'the refusal counts the gap'
assert_contains "$out" 'P1: undo drops the count' 'the refusal names the undecided finding'
printf 'P1|undo drops the count|fixed abc1234\nP2|rename|declined: out of scope\n' >"$WORK/decided"
out=$("$AK" receipt --findings "$WORK/decided" 2>&1); rc=$?
assert_eq 0 "$rc" 'a receipt that decides every finding is accepted'
rm -f .ak/findings
out=$("$AK" receipt 2>&1); rc=$?
assert_eq 1 "$rc" 'a bare receipt with undecided review findings is refused'
assert_contains "$out" 'the review has 2 findings and no dispositions were given' 'the refusal counts the findings'
assert_contains "$out" "fix: ak receipt --finding 'P1|title|fixed <sha>' --finding 'P2|title|declined: reason'" 'the fix line shows the flag'
printf 'reviewer=claude model=m head=h\n- P1: undo drops the count — src/store.js:33 — x\n' >.ak/review.md
out=$("$AK" receipt 2>&1); rc=$?
assert_eq 1 "$rc" 'a bare receipt refuses a bulleted review finding'
assert_contains "$out" 'the review has 1 findings and no dispositions were given' 'the refusal counts the finding syntax review accepts'
out=$("$AK" receipt --findings "$WORK/undecided" 2>&1); rc=$?
assert_eq 1 "$rc" 'a receipt cannot leave a bulleted review finding undecided'
assert_contains "$out" 'the review has 1 findings but the findings file decides 0' 'disposition validation counts bulleted findings too'
printf 'reviewer=claude model=m head=h\nthis review did not follow the requested format\n' >.ak/review.md
out=$("$AK" receipt 2>&1); rc=$?
assert_eq 1 "$rc" 'a bare receipt refuses an unparsed review'
assert_contains "$out" 'the review findings could not be parsed' 'the refusal does not call an unparsed review clean'
printf 'reviewer=claude model=m head=h\nP1: undo drops the count — src/store.js:33 — x\nP2: rename — a — b\n' >.ak/review.md
out=$("$AK" receipt --finding 'P1|undo drops the count|fixed abc1234' --finding 'P2|rename|declined: out of scope' 2>&1); rc=$?
assert_eq 0 "$rc" 'findings given as arguments are accepted'
assert_contains "$(cat .ak/result)" 'note=findings=2 fixed=1 declined=1' 'argument findings reach the result'
assert_eq $'P1|undo drops the count|fixed abc1234\nP2|rename|declined: out of scope' "$(cat .ak/findings)" 'the decided lines are written to .ak/findings'
out=$("$AK" receipt 2>&1); rc=$?
assert_eq 0 "$rc" 'a bare receipt reuses the earlier findings (a merge-down)'
assert_contains "$(cat .ak/result)" 'note=findings=2 fixed=1 declined=1' 'the reused findings reach the result'
out=$("$AK" receipt --finding 'P1|bad' 2>&1); rc=$?
assert_eq 1 "$rc" 'a malformed --finding is refused'
assert_contains "$out" 'malformed finding: P1|bad' 'the refusal quotes the argument'
out=$("$AK" receipt --finding '' 2>&1); rc=$?
assert_eq 1 "$rc" 'an explicitly empty --finding is refused'
assert_contains "$out" 'findings input is empty' 'empty argument findings do not reuse saved dispositions'
: >"$WORK/empty-findings"
out=$("$AK" receipt --findings "$WORK/empty-findings" 2>&1); rc=$?
assert_eq 1 "$rc" 'an explicitly empty findings file is refused'
assert_contains "$out" 'findings input is empty' 'an empty findings file does not reuse saved dispositions'
printf 'reviewer=claude model=m head=h\nNO FINDINGS\n' >.ak/review.md
rm -f .ak/findings
out=$("$AK" receipt 2>&1); rc=$?
assert_eq 0 "$rc" 'a clean review needs no findings argument'
assert_contains "$(cat .ak/receipt.md)" 'Findings: none' 'a clean review posts none'
printf 'reviewer=claude model=m head=h\nP1: undo drops the count — src/store.js:33 — x\nP2: rename — a — b\n' >.ak/review.md
cp "$WORK/decided" .ak/findings


# Comments on the PR from review bots and people are findings too (a field root went to merge a PR carrying two
# unresolved code-quality threads): the receipt refuses while any thread is open.
route 'api graphql -F owner=acme -F name=widget -F n=9 *' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"path":"src/a.cs","line":294,"comments":{"nodes":[{"author":{"login":"github-code-quality"},"body":"Generic catch clause\nmore"}]}},{"id":"T2","isResolved":false,"path":"src/a.cs","line":231,"comments":{"nodes":[{"author":{"login":"github-code-quality"},"body":"Generic catch"}]}},{"id":"T3","isResolved":true,"path":"src/b.cs","line":1,"comments":{"nodes":[{"author":{"login":"alice"},"body":"done"}]}}]}}}}}'
mv "$FAKE_GH_ROUTES" "$WORK/routes.old" && { tail -n 1 "$WORK/routes.old"; head -n -1 "$WORK/routes.old"; } >"$FAKE_GH_ROUTES"
out=$("$AK" receipt --findings "$WORK/decided" 2>&1); rc=$?
assert_eq 1 "$rc" 'a receipt with open review threads is refused'
assert_contains "$out" 'PR #9 has 2 unresolved review threads (github-code-quality: 2)' 'the refusal counts the open threads by author'
assert_contains "$out" 'fix: ak threads' 'the refusal points at ak threads'

finish
