#!/usr/bin/env bash
# Boundary coverage for classify-issue-comment-findings.sh (agent-kit#566):
# CodeRabbit/Code-Quality findings posted as plain issue comments must enter
# triage the same way body nitpicks and review threads do.
set -uo pipefail

TEST_NAME='classify-issue-comment-findings'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/classify-issue-comment-findings.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- fixture modeled on agent-kit PR #552's shape (see the issue evidence):
# a coderabbitai[bot] chat-reply issue comment ending in a bolded P1 call-out,
# a human comment that must never be classified, and a github-code-quality[bot]
# comment carrying both an Actionable block and an outside-diff-range note.
comments="$tmp/pr_552_issue_comments.json"
cat >"$comments" <<'EOF'
[
  {"id": 3001, "user": {"login": "coderabbitai[bot]"},
   "body": "@thewrz I found one blocking issue. **P1 — Define and implement the local liveness evidence before stale-active dispatch.** Please address before merge."},
  {"id": 3002, "user": {"login": "coderabbitai[bot]"},
   "body": "Reviewing files that changed in this pull request..."},
  {"id": 3003, "user": {"login": "someone-human"},
   "body": "**P1 — a human wrote this, it must never be classified as a finding**"},
  {"id": 3004, "user": {"login": "github-code-quality[bot]"},
   "body": "**Actionable comments posted: 2**\n\nSome details about outside diff range comments."}
]
EOF

# --- list: classification shape ----------------------------------------------

list_out=$("$script" list --comments "$comments") || list_out="RC=$?"
assert_contains "$list_out" '"id":"3001#0"' \
    'the #552-shaped P1 chat reply yields exactly one finding keyed comment#index'
assert_contains "$list_out" '"priority":"P1"' \
    'the priority marker is parsed out of the bolded call-out'
assert_contains "$list_out" '"header":"Define and implement the local liveness evidence before stale-active dispatch."' \
    'the finding header is the trimmed text between the dash and the closing markers'
assert_contains "$list_out" '"surface":"issue-comment"' \
    'every finding is tagged surface=issue-comment'
assert_contains "$list_out" '"anchor":"3001"' \
    'the comment id is the reply anchor'
assert_contains "$list_out" '"state":"open"' \
    'a finding with no answered ledger reports open'
assert_not_contains "$list_out" '"comment_id":"3002"' \
    'a plain acknowledgement comment with no P[0-9]/Actionable/outside-diff-range block yields no finding'
assert_not_contains "$list_out" '"comment_id":"3003"' \
    'a human-authored comment is never classified as a finding, even with a matching P1 pattern'
assert_contains "$list_out" '"id":"3004#0"' \
    'github-code-quality[bot] Actionable block is classified as a finding'
assert_contains "$list_out" '"kind":"actionable"' \
    'the Actionable block is tagged kind=actionable'
assert_contains "$list_out" '"id":"3004#1"' \
    'the same comment also yields a distinct outside-diff-range finding'
assert_contains "$list_out" '"kind":"outside-diff-range"' \
    'the outside-diff-range note is tagged kind=outside-diff-range'

# --- count: open/answered/total ----------------------------------------------

count_out=$("$script" count --comments "$comments") || count_out="RC=$?"
assert_eq 'open=3 answered=0 total=3' "$count_out" \
    'count reports every classified finding as open with no answered ledger'

# --- mark-answered: append-only, idempotent, then reflected in list/count ---

answered="$tmp/answered.ndjson"
mark_out=$("$script" mark-answered --answered "$answered" --id '3001#0' --sha abc1234) || mark_out="RC=$?"
assert_contains "$mark_out" 'marked-answered id=3001#0' \
    'mark-answered reports the id it recorded'
assert_eq '600' "$(stat -c '%a' "$answered")" \
    'the answered ledger is created with mode 0600'

list_after=$("$script" list --comments "$comments" --answered "$answered") || list_after="RC=$?"
assert_contains "$list_after" '"id":"3001#0","comment_id":"3001","anchor":"3001","author":"coderabbitai[bot]","priority":"P1","kind":"priority","header":"Define and implement the local liveness evidence before stale-active dispatch.","state":"answered"' \
    'the answered finding now reports state=answered'
assert_contains "$list_after" '"id":"3004#0"' \
    'an unrelated finding in the same list is unaffected'

count_after=$("$script" count --comments "$comments" --answered "$answered") || count_after="RC=$?"
assert_eq 'open=2 answered=1 total=3' "$count_after" \
    'count reflects exactly one answered finding after mark-answered'

lines_before=$(wc -l <"$answered")
dup_out=$("$script" mark-answered --answered "$answered" --id '3001#0' --sha def5678) || dup_out="RC=$?"
assert_contains "$dup_out" 'already-answered' \
    'marking the same finding id twice is a no-op, not a duplicate record'
lines_after=$(wc -l <"$answered")
assert_eq "$lines_before" "$lines_after" \
    'an idempotent mark-answered call never appends a second ledger line'

# A distinct finding id on the SAME comment_id is tracked independently.
"$script" mark-answered --answered "$answered" --id '3004#0' --sha 90abcde >/dev/null
count_two=$("$script" count --comments "$comments" --answered "$answered") || count_two="RC=$?"
assert_eq 'open=1 answered=2 total=3' "$count_two" \
    'two distinct findings on different comment ids answer independently'

# --- usage/evidence failures --------------------------------------------------

rc=0
"$script" list --comments "$tmp/does-not-exist.json" >/dev/null 2>"$tmp/err1" || rc=$?
assert_eq '1' "$rc" 'a missing --comments file fails closed with exit 1'
assert_contains "$(cat -- "$tmp/err1")" 'evidence unavailable' \
    'the missing-file failure names evidence unavailable, never a silent zero findings'

rc=0
"$script" mark-answered --answered "$answered" --id 'not-a-valid-id' --sha abc1234 \
    >/dev/null 2>"$tmp/err2" || rc=$?
assert_eq '2' "$rc" 'mark-answered rejects an id that is not COMMENT_ID#INDEX'

rc=0
"$script" mark-answered --answered "$answered" --id '9#0' --sha 'not-hex' \
    >/dev/null 2>"$tmp/err3" || rc=$?
assert_eq '2' "$rc" 'mark-answered rejects a non-hexadecimal sha'

rc=0
"$script" >/dev/null 2>"$tmp/err4" || rc=$?
assert_eq '2' "$rc" 'no subcommand is a usage error'

# A symlinked answered ledger is refused outright (defense in depth, matching
# the repo's other local ledgers).
ln -s /etc/passwd "$tmp/answered-link.ndjson"
rc=0
"$script" mark-answered --answered "$tmp/answered-link.ndjson" --id '1#0' --sha abc1234 \
    >/dev/null 2>"$tmp/err5" || rc=$?
assert_eq '1' "$rc" 'mark-answered refuses to write through a symlinked ledger path'

finish
