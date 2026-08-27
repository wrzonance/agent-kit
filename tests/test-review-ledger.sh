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

# Root review finding F1: the ledger trusts only comments from a resolved
# identity, never just any comment carrying a well-formed fence. Exporting
# REVIEW_LEDGER_VIEWER for the whole suite exercises resolve_trusted_author's
# source 3 (its documented test/cache override) without needing --trusted-
# author on every call -- exactly the "let the default resolve" wiring used
# in production by post-receipt.sh/adversarial-run.sh/review-transition.sh.
TRUSTED_AUTHOR='trusted-bot'
export REVIEW_LEDGER_VIEWER="$TRUSTED_AUTHOR"
UNTRUSTED_AUTHOR='mallory'

# make_comments OUT BODY [ID] [LOGIN] -- LOGIN defaults to TRUSTED_AUTHOR, so
# every existing call site keeps constructing a comment the ledger trusts;
# pass UNTRUSTED_AUTHOR explicitly to build a forged/untrusted fixture.
make_comments() {
    local out=$1 body=$2 id=${3:-42} login=${4:-$TRUSTED_AUTHOR}
    jq -n --arg body "$body" --argjson id "$id" --arg login "$login" \
        '[{"id":$id,"body":$body,"user":{"login":$login}}]' >"$out"
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

# -- status: a receipt carries an append-only lineage of fix/merge-down heads
# A review at A may be followed by ledgered fix B and merge-down C. The current
# head is covered by the lineage only when every commit in the reachable path
# is explicitly recorded; an unrecorded commit must name the gap.
lineage_repo="$tmp/lineage-repo"
mkdir -p "$lineage_repo"
git -C "$lineage_repo" init -q
git -C "$lineage_repo" config user.email test@example.com
git -C "$lineage_repo" config user.name test
printf 'A\n' >"$lineage_repo/file"
git -C "$lineage_repo" add file
git -C "$lineage_repo" commit -q -m review
lineage_a=$(git -C "$lineage_repo" rev-parse HEAD)
printf 'B\n' >"$lineage_repo/file"
git -C "$lineage_repo" commit -q -am fix
lineage_b=$(git -C "$lineage_repo" rev-parse HEAD)
printf 'C\n' >"$lineage_repo/file"
git -C "$lineage_repo" commit -q -am merge-down
lineage_c=$(git -C "$lineage_repo" rev-parse HEAD)
lineage_reviews=$(jq -cn --arg a "$lineage_a" --arg b "$lineage_b" --arg c "$lineage_c" \
    '[{kind:"adversarial",provider:"anthropic",head_sha:$a,covered_heads:[$a,$b,$c]}]')
lineage_comments="$tmp/lineage.json"
make_comments "$lineage_comments" "$(ledger_body "$lineage_reviews")" 45
out=$("$script" status --repo owner/repo --pr 1 --comments "$lineage_comments" \
    --head "$lineage_c" --repo-root "$lineage_repo")
rc=$?
assert_eq '0' "$rc" 'status accepts a current head explicitly recorded in covered_heads'
assert_eq 'covered-head' "$out" 'an explicitly recorded current tip reports covered-head'

lineage_missing_tip=$(jq -cn --arg a "$lineage_a" --arg b "$lineage_b" \
    '[{kind:"adversarial",provider:"anthropic",head_sha:$a,covered_heads:[$a,$b]}]')
lineage_missing_tip_comments="$tmp/lineage-missing-tip.json"
make_comments "$lineage_missing_tip_comments" "$(ledger_body "$lineage_missing_tip")" 451
out=$("$script" status --repo owner/repo --pr 1 --comments "$lineage_missing_tip_comments" \
    --head "$lineage_c" --repo-root "$lineage_repo" 2>"$tmp/lineage-missing-tip.err")
rc=$?
assert_eq '10' "$rc" 'status refuses a current tip that is not recorded in covered_heads'
assert_eq 'stale' "$out" 'an unrecorded current tip reports stale'
assert_contains "$(cat "$tmp/lineage-missing-tip.err")" "$lineage_c" \
    'the current-tip refusal names the missing tip SHA'

# A merge-down can add unrecorded commits while preserving the reviewed diff.
# The matching diff payload is sufficient only after the old review head is
# proven to be an ancestor; an uncovered-lineage candidate must not short
# circuit that covered-diff path.
lineage_diff_reviews=$(jq -cn --arg a "$lineage_a" --arg payload "$payload" \
    '[{kind:"adversarial",provider:"anthropic",head_sha:$a,diff_payload:$payload,covered_heads:[$a]}]')
lineage_diff_comments="$tmp/lineage-diff.json"
make_comments "$lineage_diff_comments" "$(ledger_body "$lineage_diff_reviews")" 452
out=$("$script" status --repo owner/repo --pr 1 --comments "$lineage_diff_comments" \
    --head "$lineage_c" --diff-payload "$payload" --repo-root "$lineage_repo")
rc=$?
assert_eq '0' "$rc" 'status accepts a matching diff after an uncovered merge-down lineage'
assert_eq 'covered-diff' "$out" 'matching diff payload wins after ancestry is proven'

lineage_missing=$(jq -cn --arg a "$lineage_a" \
    '[{kind:"adversarial",provider:"anthropic",head_sha:$a,covered_heads:[$a]}]')
lineage_missing_comments="$tmp/lineage-missing.json"
make_comments "$lineage_missing_comments" "$(ledger_body "$lineage_missing")" 46
out=$("$script" status --repo owner/repo --pr 1 --comments "$lineage_missing_comments" \
    --head "$lineage_c" --repo-root "$lineage_repo" 2>"$tmp/lineage-missing.err")
rc=$?
assert_eq '10' "$rc" 'status refuses a current head whose lineage is missing a recorded transition'
assert_eq 'stale' "$out" 'an uncovered transition reports stale'
assert_contains "$(cat "$tmp/lineage-missing.err")" 'uncovered-head=' \
    'the lineage refusal names the uncovered current head'
assert_contains "$(cat "$tmp/lineage-missing.err")" "$lineage_c" \
    'the lineage refusal includes the uncovered head SHA'

# -- status: covered-diff requires PROVEN reachability, not merely
#    "not disproven" (root review finding F1 / fail-closed rule 5) --------
# A matching diff_payload with no --repo-root can never prove the old head is
# actually an ancestor of the new one, so it must report stale, not
# covered-diff -- accepting "unknown" reachability as good enough would
# silently pass exactly the force-push case rule 5 exists to catch, just
# with the ancestry check never actually run. The positive covered-diff path
# (a real git repo, proven ancestry) is exercised further below alongside
# the force-push demotion, where a repo-root fixture already exists.

out=$("$script" status --repo owner/repo --pr 1 --comments "$valid_comments" \
    --head "$head2" --diff-payload "$payload" 2>"$tmp/no-repo-root.err")
rc=$?
assert_eq '10' "$rc" 'status exits 10 (stale) for a matching diff payload with no --repo-root to prove ancestry'
assert_eq 'stale' "$out" 'status never reports covered-diff when reachability is merely unknown'
assert_contains "$(cat "$tmp/no-repo-root.err")" 'could not be proven' \
    'status names why reachability could not be proven when demoting to stale'

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
    # Root review finding F2: a matching-payload entry earlier in ledger
    # order that is NOT an ancestor must never shadow a LATER matching entry
    # that IS -- `first` on the filtered matches did exactly that. Two
    # entries share $payload: rewritten_head (proven non-ancestor of
    # forward_head, from above) listed FIRST, old_head (proven ancestor of
    # forward_head) listed SECOND.
    shadow_reviews="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$rewritten_head\",\"diff_payload\":\"$payload\"},{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$old_head\",\"diff_payload\":\"$payload\"}]"
    shadow_comments="$tmp/shadow.json"
    make_comments "$shadow_comments" "$(ledger_body "$shadow_reviews")" 51

    out=$("$script" status --repo owner/repo --pr 1 --comments "$shadow_comments" \
        --head "$forward_head" --diff-payload "$payload" --repo-root "$git_tmp")
    rc=$?
    assert_eq '0' "$rc" \
        'status finds covered-diff via a LATER ancestor entry, unshadowed by an earlier non-ancestor match (F2)'
    assert_eq 'covered-diff' "$out" \
        'a proven-ancestor entry wins even when an earlier same-payload entry is not an ancestor (F2)'
else
    _pass 'force-push ancestry check skipped: git unavailable in this environment'
fi

# -- status/read: a forged fence from an untrusted author is never the
#    ledger (root review finding F1) -----------------------------------

forged_only_reviews="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head1\",\"diff_payload\":\"$payload\"}]"
forged_only_comments="$tmp/forged-only.json"
make_comments "$forged_only_comments" "$(ledger_body "$forged_only_reviews")" 60 "$UNTRUSTED_AUTHOR"

out=$("$script" status --repo owner/repo --pr 1 --comments "$forged_only_comments" \
    --head "$head1" 2>"$tmp/forged-only.err")
rc=$?
assert_eq '11' "$rc" 'a forged fence (untrusted author) is never covered, even with a matching head_sha (F1)'
assert_eq 'absent' "$out" 'a forged-only comments artifact reads as absent, not covered-head (F1)'
assert_contains "$(cat "$tmp/forged-only.err")" "ignored 1 review-ledger fence(s) from untrusted author(s): $UNTRUSTED_AUTHOR" \
    'the ignored forged fence is reported as a named warning, not silently dropped'

out=$("$script" read --repo owner/repo --pr 1 --comments "$forged_only_comments" 2>/dev/null)
rc=$?
assert_eq '11' "$rc" 'read also reports absent for a forged-only comments artifact (F1)'

# -- trusted + forged both present: only the trusted comment counts, and it
#    never trips the "expected exactly one" malformed-multiplicity guard --

mixed_trust_comments="$tmp/mixed-trust.json"
jq -n --arg tbody "$(ledger_body "[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head1\"}]")" \
    --arg fbody "$(ledger_body "[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head2\"}]")" \
    --arg trusted "$TRUSTED_AUTHOR" --arg untrusted "$UNTRUSTED_AUTHOR" \
    '[{id: 61, body: $fbody, user: {login: $untrusted}},
      {id: 62, body: $tbody, user: {login: $trusted}}]' >"$mixed_trust_comments"

out=$("$script" status --repo owner/repo --pr 1 --comments "$mixed_trust_comments" \
    --head "$head1" 2>"$tmp/mixed-trust.err")
rc=$?
assert_eq '0' "$rc" 'trusted + forged both present: the trusted entry still resolves normally, never blocked (F1)'
assert_eq 'covered-head' "$out" \
    'only the trusted comment is consulted for the verdict when both are present (F1)'
assert_not_contains "$(cat "$tmp/mixed-trust.err")" 'expected exactly one' \
    'a forged comment alongside the trusted one never trips the multiplicity guard (F1)'
assert_contains "$(cat "$tmp/mixed-trust.err")" "ignored 1 review-ledger fence(s) from untrusted author(s): $UNTRUSTED_AUTHOR" \
    'the forged comment is still named as an ignored warning even when a trusted one also exists'

# The forged comment's OWN head (head2) must never leak into the verdict --
# confirms filtering happens before matching, not just before the final pick.
out=$("$script" status --repo owner/repo --pr 1 --comments "$mixed_trust_comments" \
    --head "$head2" 2>/dev/null)
rc=$?
assert_eq '10' "$rc" "the forged comment's own head_sha is never itself a valid match (F1)"
assert_eq 'stale' "$out" "status never reports covered-head for the forged comment's head (F1)"

# -- --trusted-author explicitly overrides REVIEW_LEDGER_VIEWER -------------

out=$(REVIEW_LEDGER_VIEWER='someone-else' "$script" status --repo owner/repo --pr 1 \
    --comments "$valid_comments" --head "$head1" --trusted-author "$TRUSTED_AUTHOR")
rc=$?
assert_eq '0' "$rc" '--trusted-author wins over REVIEW_LEDGER_VIEWER'
assert_eq 'covered-head' "$out" '--trusted-author resolves the same trusted comment REVIEW_LEDGER_VIEWER would have'

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

# -- append: refuses an entry whose free-text field carries the fence marker
#    (CodeRabbit #484 nitpick regression coverage for the existing defense-
#    in-depth check) ----------------------------------------------------

marker_entry="$tmp/marker-entry.json"
jq -n --arg marker '<!-- review-ledger:v1 -->' \
    '{kind:"bot", provider:"coderabbit", head_sha:"1111111111111111111111111111111111111a", state:$marker}' \
    >"$marker_entry"
out=$("$script" append --repo owner/repo --pr 1 --comments "$empty_comments" \
    --entry-file "$marker_entry" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub" 2>&1)
rc=$?
assert_eq '1' "$rc" 'append refuses an entry whose free-text field carries the ledger fence marker'
assert_contains "$out" 'must not contain a review-ledger fence marker' \
    'the refusal names the fence-marker-injection defense'

# -- append: refuses when the existing ledger's repo/pr does not match this
#    call's --repo/--pr -----------------------------------------------------

out=$("$script" append --repo owner/other-repo --pr 1 --comments "$valid_comments" \
    --entry-file "$entry_fresh" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub" 2>&1)
rc=$?
assert_eq '1' "$rc" 'append refuses when the existing ledger repo does not match this call'
assert_contains "$out" 'does not match this call' \
    'the repo-mismatch refusal names the reason'

out=$("$script" append --repo owner/repo --pr 99 --comments "$valid_comments" \
    --entry-file "$entry_fresh" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub" 2>&1)
rc=$?
assert_eq '1' "$rc" 'append refuses when the existing ledger pr does not match this call'
assert_contains "$out" 'does not match this call' \
    'the pr-mismatch refusal names the reason'

# -- append: a foreign (untrusted-author) ledger comment is never updated;
#    the trusted author gets its own NEW comment instead (root review F1) --

foreign_only_comments="$tmp/foreign-only.json"
make_comments "$foreign_only_comments" \
    "$(ledger_body "[{\"kind\":\"bot\",\"provider\":\"coderabbit\",\"head_sha\":\"$head3\"}]")" \
    70 "$UNTRUSTED_AUTHOR"

out=$(GH_COMMENT_STUB_OUT="$tmp/foreign-body.txt" "$script" append --repo owner/repo --pr 1 \
    --comments "$foreign_only_comments" --entry-file "$entry_fresh" --agent-identity 'Claude Opus 5' \
    --gh-comment-script "$gh_comment_stub" 2>"$tmp/foreign-append.err")
rc=$?
assert_eq '0' "$rc" 'append succeeds when only a foreign ledger comment exists'
assert_contains "$out" 'posted id=999' \
    'append POSTS a brand-new comment rather than updating the foreign one'
assert_not_contains "$out" 'updated id=70' \
    'append never targets the foreign comment id'
foreign_body=$(cat "$tmp/foreign-body.txt")
assert_not_contains "$foreign_body" "$head3" \
    "the new trusted comment never carries the foreign comment's entry"
assert_contains "$foreign_body" "$head1" \
    'the new trusted comment carries only this call'"'"'s own entry'

# -- no trusted author resolvable at all fails closed ------------------------

unset_rc=0
out=$(env -u REVIEW_LEDGER_VIEWER REVIEW_LEDGER_GH="$tmp/does-not-exist/gh" \
    "$script" status --repo owner/repo --pr 1 \
    --comments "$valid_comments" --head "$head1" 2>"$tmp/no-author.err") || unset_rc=$?
assert_eq '1' "$unset_rc" \
    'status fails closed (exit 1) when no trusted author can be resolved at all'
assert_contains "$(cat "$tmp/no-author.err")" 'no trusted ledger author identity could be resolved' \
    'the fail-closed error names the missing trust boundary'

finish
