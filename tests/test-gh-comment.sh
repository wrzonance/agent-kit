#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='gh-comment'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_LOG"
if [[ " $* " == *" --input - "* ]]; then
    cat >"$GH_PAYLOAD"
    id=101
    [[ " $* " == *"/replies "* ]] && id=102
    [[ " $* " == *" -X PATCH "* ]] && id=103
    [[ " $* " == *"pulls/14/comments -X POST"* ]] && id=104
    jq --argjson id "$id" --arg url "https://example.invalid/comments/$id" \
        '. + {id: $id, html_url: $url}' "$GH_PAYLOAD"
    exit 0
fi
if [[ ${GH_MISMATCH:-0} == 1 ]]; then
    jq -n '{body: "tampered"}'
else
    jq '. + {id: 101}' "$GH_PAYLOAD"
fi
EOF
chmod +x "$tmp/gh"

body="$tmp/body.txt"
# shellcheck disable=SC2016
printf '%s\n' 'Fixed in `abc1234`.' 'literal $HOME and $(id)' >"$body"

run_comment() {
    GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
        GH_MISMATCH="${GH_MISMATCH:-0}" \
        PATH="$tmp:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-comment.sh" "$@"
}

output=$(run_comment --pr 14 --repo owner/repo --body-file "$body")
assert_contains "$output" 'posted id=101' 'top-level comment is posted and verified'
jq -j '.body' "$tmp/payload.json" >"$tmp/payload-body.txt"
if cmp -s "$body" "$tmp/payload-body.txt"; then
    _pass 'the API payload preserves the exact body bytes'
else
    _fail 'the API payload preserves the exact body bytes' \
        'the payload body differs from the source file'
fi
assert_contains "$(cat "$tmp/gh.log")" 'repos/owner/repo/issues/14/comments' \
    'top-level comments use the issue comment endpoint'

output=$(run_comment --pr 14 --repo owner/repo --body-file "$body" --reply-to 55)
assert_contains "$output" 'posted id=102' 'thread reply is posted and verified'
assert_contains "$(tail -n 2 "$tmp/gh.log")" \
    'repos/owner/repo/pulls/14/comments/55/replies' \
    'replies use the review-thread endpoint'

output=$(run_comment --pr 14 --repo owner/repo --body-file "$body" --update 66)
assert_contains "$output" 'updated id=103' 'conversation update is patched and verified'
assert_contains "$(tail -n 2 "$tmp/gh.log")" \
    'repos/owner/repo/issues/comments/66' 'updates use the issue-comment endpoint'

anchor_repo="$tmp/anchor-repo"
git init -q "$anchor_repo"
git -C "$anchor_repo" config user.name test
git -C "$anchor_repo" config user.email test@example.invalid
printf 'line\n' >"$anchor_repo/dir:name.txt"
git -C "$anchor_repo" add -- .
git -C "$anchor_repo" commit -qm init
anchor_body="$tmp/anchor-body.txt"
printf '%s\n' 'Review this line.' >"$anchor_body"
anchor_output=$(cd "$anchor_repo" && run_comment --pr 14 --repo owner/repo \
    --body-file "$anchor_body" --anchor 'dir:name.txt:7' --side LEFT --start-line 3)
assert_contains "$anchor_output" 'posted id=104' 'anchored comment is posted and verified'
assert_eq 'dir:name.txt' "$(jq -r '.path' "$tmp/payload.json")" 'anchor splits paths on the last colon'
assert_eq '7' "$(jq -r '.line' "$tmp/payload.json")" 'anchor carries its line'
assert_eq '3' "$(jq -r '.start_line' "$tmp/payload.json")" 'anchor carries its range start'
assert_eq 'LEFT' "$(jq -r '.start_side' "$tmp/payload.json")" 'anchor carries its range side'

set +e
export GH_MISMATCH=1
output=$(run_comment --pr 14 --repo owner/repo --body-file "$body" 2>"$tmp/mismatch.err")
rc=$?
unset GH_MISMATCH
set -e
assert_eq '1' "$rc" 'a stored-body mismatch fails the command'
assert_contains "$(cat "$tmp/mismatch.err")" 'stored body does not match' \
    'mismatch output explains that nothing was resolved'

finish
