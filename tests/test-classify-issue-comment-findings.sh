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

# fp_for LIST_OUTPUT ID -- extracts the "fingerprint" field for one finding
# id out of `list`'s newline-delimited JSON, without hardcoding a sha256
# digest that would break the moment a header's wording changes.
fp_for() {
    jq -r --arg id "$2" 'select(.id == $id) | .fingerprint' <<<"$1"
}

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
p1_fp=$(fp_for "$list_out" '3001#0')
assert_eq '64' "${#p1_fp}" \
    'every finding carries a 64-character sha256 fingerprint'

# --- count: open/answered/total ----------------------------------------------

count_out=$("$script" count --comments "$comments") || count_out="RC=$?"
assert_eq 'open=3 answered=0 total=3' "$count_out" \
    'count reports every classified finding as open with no answered ledger'

# --- mark-answered: append-only, idempotent, then reflected in list/count ---

answered="$tmp/answered.ndjson"
mark_out=$("$script" mark-answered --answered "$answered" --id '3001#0' --sha abc1234 --fingerprint "$p1_fp") ||
    mark_out="RC=$?"
assert_contains "$mark_out" 'marked-answered id=3001#0' \
    'mark-answered reports the id it recorded'
assert_eq '600' "$(stat -c '%a' "$answered")" \
    'the answered ledger is created with mode 0600'

list_after=$("$script" list --comments "$comments" --answered "$answered") || list_after="RC=$?"
assert_contains "$list_after" '"id":"3001#0","comment_id":"3001","anchor":"3001","author":"coderabbitai[bot]","priority":"P1","kind":"priority","header":"Define and implement the local liveness evidence before stale-active dispatch."' \
    'the answered finding still reports its full classification'
assert_contains "$list_after" '"state":"answered"' \
    'a finding whose id AND fingerprint match the ledger reports answered'
assert_contains "$list_after" '"id":"3004#0"' \
    'an unrelated finding in the same list is unaffected'

count_after=$("$script" count --comments "$comments" --answered "$answered") || count_after="RC=$?"
assert_eq 'open=2 answered=1 total=3' "$count_after" \
    'count reflects exactly one answered finding after mark-answered'

lines_before=$(wc -l <"$answered")
dup_out=$("$script" mark-answered --answered "$answered" --id '3001#0' --sha def5678 --fingerprint "$p1_fp") ||
    dup_out="RC=$?"
assert_contains "$dup_out" 'already-answered' \
    'marking the same (id, fingerprint) pair twice is a no-op, not a duplicate record'
lines_after=$(wc -l <"$answered")
assert_eq "$lines_before" "$lines_after" \
    'an idempotent mark-answered call never appends a second ledger line'

# A distinct finding id on the SAME comment_id is tracked independently.
cq_actionable_fp=$(fp_for "$list_out" '3004#0')
"$script" mark-answered --answered "$answered" --id '3004#0' --sha 90abcde --fingerprint "$cq_actionable_fp" >/dev/null
count_two=$("$script" count --comments "$comments" --answered "$answered") || count_two="RC=$?"
assert_eq 'open=1 answered=2 total=3' "$count_two" \
    'two distinct findings on different comment ids answer independently'

# --- F2 (agent-kit#566 review): a zero Actionable count is never a finding --

zero_count_comments="$tmp/zero_count.json"
cat >"$zero_count_comments" <<'EOF'
[{"id": 6001, "user": {"login": "coderabbitai[bot]"},
  "body": "**Actionable comments posted: 0**"}]
EOF
zero_out=$("$script" list --comments "$zero_count_comments") || zero_out="RC=$?"
assert_eq '' "$zero_out" \
    'an "Actionable comments posted: 0" summary yields no finding at all'
zero_count=$("$script" count --comments "$zero_count_comments") || zero_count="RC=$?"
assert_eq 'open=0 answered=0 total=0' "$zero_count" \
    'count reports zero findings for a zero-count Actionable summary'

# --- F3 (agent-kit#566 review): distinct finding kinds in one comment never
# suppress each other -- only overlapping/identical blocks dedupe ---------

mixed_comments="$tmp/mixed.json"
cat >"$mixed_comments" <<'EOF'
[{"id": 7001, "user": {"login": "coderabbitai[bot]"},
  "body": "**P1 — Fix the null check before dereferencing.** Also, **Actionable comments posted: 1**"}]
EOF
mixed_out=$("$script" list --comments "$mixed_comments") || mixed_out="RC=$?"
assert_contains "$mixed_out" '"id":"7001#0"' \
    'a comment mixing a priority call-out and an Actionable summary yields the priority finding'
assert_contains "$mixed_out" '"kind":"priority"' \
    'the first finding in a mixed comment is the priority call-out'
assert_contains "$mixed_out" '"id":"7001#1"' \
    'the same comment ALSO yields the distinct Actionable finding -- priority no longer suppresses it'
assert_contains "$mixed_out" '"kind":"actionable"' \
    'the second finding in a mixed comment is the Actionable summary'
mixed_count=$("$script" count --comments "$mixed_comments") || mixed_count="RC=$?"
assert_eq 'open=2 answered=0 total=2' "$mixed_count" \
    'both findings in a mixed priority+actionable comment count independently'

# An outside-diff-range scan spanning a priority call-out's own line DOES
# dedupe against it -- this is the same-issue overlap case F3 still requires.
overlap_comments="$tmp/overlap.json"
cat >"$overlap_comments" <<'EOF'
[{"id": 7002, "user": {"login": "coderabbitai[bot]"},
  "body": "**P1 — Fix code outside diff range issue.**"}]
EOF
overlap_out=$("$script" list --comments "$overlap_comments") || overlap_out="RC=$?"
overlap_count=$("$script" count --comments "$overlap_comments") || overlap_count="RC=$?"
assert_eq 'open=1 answered=0 total=1' "$overlap_count" \
    'an outside-diff-range phrase inside a priority call-out'"'"'s own line dedupes into one finding'
assert_contains "$overlap_out" '"kind":"priority"' \
    'the surviving deduped finding keeps the more specific priority kind'

# --- F4 (agent-kit#566 review): identity is (id, fingerprint), not id alone
# -- an edited comment at the SAME comment_id/index is still open ----------

edit_before="$tmp/edit_before.json"
cat >"$edit_before" <<'EOF'
[{"id": 8001, "user": {"login": "coderabbitai[bot]"},
  "body": "**P1 — Original finding text before the bot edited it.**"}]
EOF
edit_list_before=$("$script" list --comments "$edit_before") || edit_list_before="RC=$?"
edit_fp_before=$(fp_for "$edit_list_before" '8001#0')
edit_answered="$tmp/edit_answered.ndjson"
"$script" mark-answered --answered "$edit_answered" --id '8001#0' --sha aaaa111 \
    --fingerprint "$edit_fp_before" >/dev/null
still_answered=$("$script" list --comments "$edit_before" --answered "$edit_answered")
assert_contains "$still_answered" '"state":"answered"' \
    'before any edit, the finding correctly reports answered'

edit_after="$tmp/edit_after.json"
cat >"$edit_after" <<'EOF'
[{"id": 8001, "user": {"login": "coderabbitai[bot]"},
  "body": "**P1 — A completely different finding after a bot edit at the same index.**"}]
EOF
edit_list_after=$("$script" list --comments "$edit_after" --answered "$edit_answered") ||
    edit_list_after="RC=$?"
assert_contains "$edit_list_after" '"id":"8001#0"' \
    'the edited comment still classifies to the same comment_id#index identity'
assert_contains "$edit_list_after" '"state":"open"' \
    'an id match with a DIFFERENT fingerprint (the comment was edited) is still open, never answered'
edit_count_after=$("$script" count --comments "$edit_after" --answered "$edit_answered") ||
    edit_count_after="RC=$?"
assert_eq 'open=1 answered=0 total=1' "$edit_count_after" \
    'count treats the edited finding as open despite the stale id match in the ledger'

# Re-answering the EDITED finding under its new fingerprint is a fresh
# record, not a duplicate of the stale one -- the ledger accumulates both.
edit_fp_after=$(fp_for "$edit_list_after" '8001#0')
assert_not_contains "$edit_fp_after" "$edit_fp_before" \
    'the edited comment produces a different fingerprint than the original'
reanswer_out=$("$script" mark-answered --answered "$edit_answered" --id '8001#0' --sha bbbb222 \
    --fingerprint "$edit_fp_after") || reanswer_out="RC=$?"
assert_contains "$reanswer_out" 'marked-answered id=8001#0' \
    'answering the edited finding under its new fingerprint is accepted as a new record'
edit_count_final=$("$script" count --comments "$edit_after" --answered "$edit_answered") ||
    edit_count_final="RC=$?"
assert_eq 'open=0 answered=1 total=1' "$edit_count_final" \
    'the edited finding now reports answered under its own fingerprint'

# --- usage/evidence failures --------------------------------------------------

rc=0
"$script" list --comments "$tmp/does-not-exist.json" >/dev/null 2>"$tmp/err1" || rc=$?
assert_eq '1' "$rc" 'a missing --comments file fails closed with exit 1'
assert_contains "$(cat -- "$tmp/err1")" 'evidence unavailable' \
    'the missing-file failure names evidence unavailable, never a silent zero findings'

rc=0
"$script" mark-answered --answered "$answered" --id 'not-a-valid-id' --sha abc1234 \
    --fingerprint "$p1_fp" >/dev/null 2>"$tmp/err2" || rc=$?
assert_eq '2' "$rc" 'mark-answered rejects an id that is not COMMENT_ID#INDEX'

rc=0
"$script" mark-answered --answered "$answered" --id '9#0' --sha 'not-hex' \
    --fingerprint "$p1_fp" >/dev/null 2>"$tmp/err3" || rc=$?
assert_eq '2' "$rc" 'mark-answered rejects a non-hexadecimal sha'

rc=0
"$script" mark-answered --answered "$answered" --id '9#0' --sha abc1234 \
    >/dev/null 2>"$tmp/err3b" || rc=$?
assert_eq '2' "$rc" 'mark-answered requires --fingerprint'

rc=0
"$script" mark-answered --answered "$answered" --id '9#0' --sha abc1234 \
    --fingerprint 'not-a-sha256-digest' >/dev/null 2>"$tmp/err3c" || rc=$?
assert_eq '2' "$rc" 'mark-answered rejects a malformed (non-64-hex) fingerprint'

rc=0
"$script" >/dev/null 2>"$tmp/err4" || rc=$?
assert_eq '2' "$rc" 'no subcommand is a usage error'

# A symlinked answered ledger is refused outright (defense in depth, matching
# the repo's other local ledgers).
ln -s /etc/passwd "$tmp/answered-link.ndjson"
rc=0
"$script" mark-answered --answered "$tmp/answered-link.ndjson" --id '1#0' --sha abc1234 \
    --fingerprint "$p1_fp" >/dev/null 2>"$tmp/err5" || rc=$?
assert_eq '1' "$rc" 'mark-answered refuses to write through a symlinked ledger path'

# A missing sha256sum/shasum fails closed with a diagnosed evidence-unavailable
# message, never an unexplained bash abort from `set -e` mid-fingerprint.
no_sha_bin="$tmp/no-sha-bin"
mkdir -p "$no_sha_bin"
ln -s "$(command -v jq)" "$no_sha_bin/jq"
rc=0
PATH="$no_sha_bin" /bin/bash "$script" list --comments "$comments" >/dev/null 2>"$tmp/err6" || rc=$?
assert_eq '1' "$rc" 'list fails closed when neither sha256sum nor shasum is on PATH'
assert_contains "$(cat -- "$tmp/err6")" 'evidence unavailable' \
    'the missing-hash-tool failure is a diagnosed evidence-unavailable, not a silent abort'

finish
