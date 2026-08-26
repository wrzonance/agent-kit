#!/usr/bin/env bash
# Contract coverage for review-ledger.sh: the durable per-PR review ledger
# (read / status / append) from issue #477.
set -uo pipefail

TEST_NAME='review-ledger'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/review-ledger.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

head1='1111111111111111111111111111111111111a'
head2='2222222222222222222222222222222222222b'
head3='3333333333333333333333333333333333333c'
payload='owner/repo:1:abababababababababababababababababababababababababababababab'
payload_other='owner/repo:1:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'

make_comments() {
    local out=$1 body=$2 id=${3:-42}
    jq -n --arg body "$body" --argjson id "$id" '[{"id":$id,"body":$body}]' >"$out"
}

ledger_body() {
    # $1 = reviews JSON array (compact)
    printf 'This was written agentically; verify its assertions:\n'
    printf '<!-- review-remote-pr:agent-doc -->\n'
    printf '## Review ledger\n'
    printf '<!-- review-ledger:v1 -->\n'
    printf '```json\n'
    jq -n --argjson reviews "$1" '{version:1, pr:1, repo:"owner/repo", reviews:$reviews}'
    printf '```\n'
    printf '<!-- /review-ledger:v1 -->\n'
    printf '🤖 Co-authored by Test.\n'
}

# -- read: absent -----------------------------------------------------------

empty_comments="$tmp/empty.json"
printf '%s\n' '[]' >"$empty_comments"

out=$("$script" read --repo owner/repo --pr 1 --comments "$empty_comments" 2>"$tmp/read-absent.err")
rc=$?
assert_eq '11' "$rc" 'read exits 11 when no ledger comment exists'
assert_eq '' "$out" 'read prints nothing to stdout when absent'

# -- read: present & valid ---------------------------------------------------

one_review="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head1\",\"diff_payload\":\"$payload\"}]"
valid_comments="$tmp/valid.json"
make_comments "$valid_comments" "$(ledger_body "$one_review")" 42

out=$("$script" read --repo owner/repo --pr 1 --comments "$valid_comments")
rc=$?
assert_eq '0' "$rc" 'read exits 0 for a well-formed ledger'
assert_contains "$out" 'comment_id=42' 'read reports the ledger comment id'
assert_contains "$out" "$head1" 'read reports the ledger JSON contents'

# -- read: present but malformed fence (blocks, never reads as absent) ------

bad_body=$(printf '%s\n%s\n%s\n%s\n' \
    '<!-- review-ledger:v1 -->' '```json' '{not valid json' '```' )
bad_body="$bad_body"$'\n''<!-- /review-ledger:v1 -->'
malformed_comments="$tmp/malformed.json"
make_comments "$malformed_comments" "$bad_body" 7

out=$("$script" read --repo owner/repo --pr 1 --comments "$malformed_comments" 2>"$tmp/malformed.err")
rc=$?
assert_eq '1' "$rc" 'read exits 1 (blocks) on an unparseable ledger fence'
assert_eq '' "$out" 'read prints nothing to stdout when blocked'
assert_not_contains "$(cat "$tmp/malformed.err")" 'no review-ledger comment found' \
    'a malformed ledger is never reported with the absent message'

# -- status: absent ----------------------------------------------------------

out=$("$script" status --repo owner/repo --pr 1 --comments "$empty_comments" --head "$head1")
rc=$?
assert_eq '11' "$rc" 'status exits 11 when the ledger is absent'
assert_eq 'absent' "$out" 'status prints absent when the ledger is absent'

# -- status: covered-head ----------------------------------------------------

out=$("$script" status --repo owner/repo --pr 1 --comments "$valid_comments" --head "$head1")
rc=$?
assert_eq '0' "$rc" 'status exits 0 for a matching head_sha'
assert_eq 'covered-head' "$out" 'status reports covered-head for a matching head_sha'

# -- status: covered-diff (base-merge-only advance preserves diff_payload) --

out=$("$script" status --repo owner/repo --pr 1 --comments "$valid_comments" \
    --head "$head2" --diff-payload "$payload")
rc=$?
assert_eq '0' "$rc" 'status exits 0 when the diff payload matches a different head'
assert_eq 'covered-diff' "$out" 'status reports covered-diff when only the diff payload matches'

# -- status: stale (source-changing commit changes the diff payload) --------

out=$("$script" status --repo owner/repo --pr 1 --comments "$valid_comments" \
    --head "$head2" --diff-payload "$payload_other")
rc=$?
assert_eq '10' "$rc" 'status exits 10 when neither head nor diff payload matches'
assert_eq 'stale' "$out" 'status reports stale when neither head nor diff payload matches'

out=$("$script" status --repo owner/repo --pr 1 --comments "$valid_comments" --head "$head2")
rc=$?
assert_eq '10' "$rc" 'status exits 10 (stale) when no --diff-payload is given and head does not match'
assert_eq 'stale' "$out" 'status reports stale with no diff payload and a non-matching head'

# -- status: legacy entry without diff_payload can only reach covered-head or stale --

legacy_review="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head3\"}]"
legacy_comments="$tmp/legacy.json"
make_comments "$legacy_comments" "$(ledger_body "$legacy_review")" 43

out=$("$script" status --repo owner/repo --pr 1 --comments "$legacy_comments" \
    --head "$head1" --diff-payload "$payload")
rc=$?
assert_eq '10' "$rc" 'status exits 10 for a legacy no-diff_payload entry even with a diff-payload argument'
assert_eq 'stale' "$out" 'a legacy entry without diff_payload never reaches covered-diff'

# -- status: present but malformed fence blocks (never absent) --------------

out=$("$script" status --repo owner/repo --pr 1 --comments "$malformed_comments" --head "$head1" \
    2>"$tmp/status-malformed.err")
rc=$?
assert_eq '1' "$rc" 'status exits 1 (blocks) on an unparseable ledger fence'
assert_eq '' "$out" 'status prints nothing on the stdout verdict line when blocked'

# -- status: kind/provider filtering -----------------------------------------

mixed_reviews="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head1\"},{\"kind\":\"bot\",\"provider\":\"coderabbit\",\"head_sha\":\"$head2\"}]"
mixed_comments="$tmp/mixed.json"
make_comments "$mixed_comments" "$(ledger_body "$mixed_reviews")" 44

out=$("$script" status --repo owner/repo --pr 1 --comments "$mixed_comments" --head "$head2" \
    --kind bot --provider coderabbit)
rc=$?
assert_eq '0' "$rc" 'status exits 0 for a matching kind+provider filter'
assert_eq 'covered-head' "$out" 'status honors kind/provider filtering'

out=$("$script" status --repo owner/repo --pr 1 --comments "$mixed_comments" --head "$head2" \
    --kind adversarial)
rc=$?
assert_eq '10' "$rc" 'status exits 10 when an entry exists for the kind filter but not at this head'
assert_eq 'stale' "$out" 'status reports stale, not absent, when the kind has an entry at a different head'

out=$("$script" status --repo owner/repo --pr 1 --comments "$mixed_comments" --head "$head1" \
    --kind bot --provider github-actions)
rc=$?
assert_eq '11' "$rc" 'status exits 11 when no entry matches the requested kind+provider at all'
assert_eq 'absent' "$out" 'status reports absent only when the kind/provider filter matches zero entries'

# -- status: zero network calls -- a stub gh that fails proves nothing was invoked --

fake_gh_dir="$tmp/fake-bin"
mkdir -p "$fake_gh_dir"
cat >"$fake_gh_dir/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh must never be invoked by status\n' >&2
exit 99
EOF
chmod +x "$fake_gh_dir/gh"
out=$(PATH="$fake_gh_dir:$PATH" "$script" status --repo owner/repo --pr 1 \
    --comments "$valid_comments" --head "$head1")
rc=$?
assert_eq '0' "$rc" 'status succeeds with no gh on PATH beyond a failing stub (never invoked)'
assert_eq 'covered-head' "$out" 'status result is unaffected by a failing gh stub'

# -- status: force-push demotes covered-diff to stale (fail-closed rule 5) --
# An old head_sha unreachable from the current head, even with a matching
# diff_payload (a force-push can coincidentally reproduce identical diff
# bytes), must never be trusted as covered-diff.

git_tmp="$tmp/git-repo"
mkdir -p "$git_tmp"
if command -v git >/dev/null 2>&1 &&
    git -C "$git_tmp" init -q >/dev/null 2>&1; then
    git -C "$git_tmp" config user.email test@example.com
    git -C "$git_tmp" config user.name test
    printf 'one\n' >"$git_tmp/f.txt"
    git -C "$git_tmp" add f.txt
    git -C "$git_tmp" commit -q -m base
    old_head=$(git -C "$git_tmp" rev-parse HEAD)
    printf 'two\n' >"$git_tmp/f.txt"
    git -C "$git_tmp" add f.txt
    git -C "$git_tmp" commit -q -m onward
    forward_head=$(git -C "$git_tmp" rev-parse HEAD)

    forward_review="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$old_head\",\"diff_payload\":\"$payload\"}]"
    forward_comments="$tmp/forward.json"
    make_comments "$forward_comments" "$(ledger_body "$forward_review")" 50

    out=$("$script" status --repo owner/repo --pr 1 --comments "$forward_comments" \
        --head "$forward_head" --diff-payload "$payload" --repo-root "$git_tmp")
    rc=$?
    assert_eq '0' "$rc" 'status trusts covered-diff when the old head IS an ancestor of the new head'
    assert_eq 'covered-diff' "$out" 'ancestor old head with matching diff payload reads as covered-diff'

    # Reset to a sibling commit that is NOT a descendant of old_head, so
    # old_head is unreachable from it (simulating a force-push rewrite).
    git -C "$git_tmp" checkout -q --orphan rewritten
    printf 'three\n' >"$git_tmp/f.txt"
    git -C "$git_tmp" add f.txt
    git -C "$git_tmp" commit -q -m rewritten
    rewritten_head=$(git -C "$git_tmp" rev-parse HEAD)

    out=$("$script" status --repo owner/repo --pr 1 --comments "$forward_comments" \
        --head "$rewritten_head" --diff-payload "$payload" --repo-root "$git_tmp")
    rc=$?
    assert_eq '10' "$rc" 'status demotes covered-diff to stale when old head is unreachable from new head'
    assert_eq 'stale' "$out" 'a force-push (unreachable old head) is reported stale despite a matching diff payload'
else
    _pass 'force-push ancestry check skipped: git unavailable in this environment'
fi

# -- append: fresh ledger (no prior comment), posts via gh-comment.sh -------

gh_comment_stub="$tmp/gh-comment-stub.sh"
cat >"$gh_comment_stub" <<'EOF'
#!/usr/bin/env bash
mode=post
id=999
while (($#)); do
    case $1 in
        --update) mode=update; id=$2; shift 2 ;;
        --body-file) bf=$2; shift 2 ;;
        --pr|--repo) shift 2 ;;
        *) shift ;;
    esac
done
cp -- "$bf" "$GH_COMMENT_STUB_OUT"
if [[ $mode == update ]]; then
    printf 'updated id=%s url=https://example/%s verified=exact\n' "$id" "$id"
else
    printf 'posted id=%s url=https://example/%s verified=exact\n' "$id" "$id"
fi
EOF
chmod +x "$gh_comment_stub"

entry_fresh="$tmp/entry-fresh.json"
printf '%s\n' "{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head1\",\"diff_payload\":\"$payload\"}" \
    >"$entry_fresh"

out=$(GH_COMMENT_STUB_OUT="$tmp/fresh-body.txt" "$script" append --repo owner/repo --pr 1 \
    --comments "$empty_comments" --entry-file "$entry_fresh" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub")
rc=$?
assert_eq '0' "$rc" 'append exits 0 when creating a fresh ledger comment'
assert_contains "$out" 'posted id=999' 'append posts (not updates) when no ledger comment exists yet'
assert_contains "$(cat "$tmp/fresh-body.txt")" "$head1" \
    'the posted body carries the new entry head_sha'
assert_contains "$(cat "$tmp/fresh-body.txt")" '<!-- review-ledger:v1 -->' \
    'the posted body carries the ledger open fence'

# -- append: existing ledger, updates in place, is append-only --------------

entry_second="$tmp/entry-second.json"
printf '%s\n' "{\"kind\":\"bot\",\"provider\":\"coderabbit\",\"head_sha\":\"$head2\",\"state\":\"APPROVED\"}" \
    >"$entry_second"

out=$(GH_COMMENT_STUB_OUT="$tmp/updated-body.txt" "$script" append --repo owner/repo --pr 1 \
    --comments "$valid_comments" --entry-file "$entry_second" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub")
rc=$?
assert_eq '0' "$rc" 'append exits 0 when updating an existing ledger comment'
assert_contains "$out" 'updated id=42' 'append updates the existing ledger comment id in place'
updated_body=$(cat "$tmp/updated-body.txt")
assert_contains "$updated_body" "$head1" \
    'append preserves the original entry in the updated ledger (append-only)'
assert_contains "$updated_body" "$head2" \
    'append adds the new entry alongside the original (append-only)'

# -- append: refuses a malformed entry ---------------------------------------

bad_entry="$tmp/bad-entry.json"
printf '%s\n' '{"kind":"unknown","provider":"x","head_sha":"deadbeef"}' >"$bad_entry"
out=$("$script" append --repo owner/repo --pr 1 --comments "$empty_comments" \
    --entry-file "$bad_entry" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub" 2>&1)
rc=$?
assert_eq '1' "$rc" 'append refuses an entry with an invalid kind'
assert_contains "$out" 'entry does not match the ledger entry schema' \
    'append names the schema failure for a malformed entry'

# -- append: refuses to append onto a malformed ledger -----------------------

out=$("$script" append --repo owner/repo --pr 1 --comments "$malformed_comments" \
    --entry-file "$entry_fresh" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub" 2>&1)
rc=$?
assert_eq '1' "$rc" 'append refuses to write onto a present-but-unparseable ledger'

finish
