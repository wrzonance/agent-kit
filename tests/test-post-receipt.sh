#!/usr/bin/env bash
# Contract coverage for post-receipt.sh: the one-spend adversarial-review
# receipt precheck and publish subcommands.
set -uo pipefail

TEST_NAME='post-receipt'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/post-receipt.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

marker='<!-- adversarial-review:spent -->'

# -- fixtures -----------------------------------------------------------

spent_comments="$tmp/spent.json"
printf '%s\n' \
  '[{"id":1,"body":"unrelated"},{"id":2,"body":"receipt here\n'"$marker"'\nmore"}]' \
  >"$spent_comments"

not_spent_comments="$tmp/not-spent.json"
printf '%s\n' '[{"id":1,"body":"just talk, no marker here"}]' >"$not_spent_comments"

empty_comments="$tmp/empty.json"
printf '%s\n' '[]' >"$empty_comments"

bad_json="$tmp/bad.json"
printf '%s\n' 'this is not json' >"$bad_json"

# -- precheck: spent ------------------------------------------------------

out=$("$script" precheck --comments "$spent_comments")
rc=$?
assert_eq '0' "$rc" 'precheck exits 0 when the marker is present'
assert_eq 'spent' "$out" 'precheck prints spent when the marker is present'

# -- precheck: not-spent (marker provably absent) -------------------------

out=$("$script" precheck --comments "$not_spent_comments")
rc=$?
assert_eq '10' "$rc" 'precheck exits 10 when the marker is provably absent'
assert_eq 'not-spent' "$out" 'precheck prints not-spent when the marker is provably absent'

out=$("$script" precheck --comments "$empty_comments")
rc=$?
assert_eq '10' "$rc" 'precheck exits 10 on an empty comment array'
assert_eq 'not-spent' "$out" 'precheck prints not-spent on an empty comment array'

# -- precheck: fail-closed, missing file -----------------------------------

out=$("$script" precheck --comments "$tmp/does-not-exist.json" 2>"$tmp/missing.err")
rc=$?
assert_eq '1' "$rc" 'precheck exits 1 when the comments artifact is missing'
assert_eq '' "$out" 'precheck emits no stdout result when the artifact is missing'
assert_contains "$(cat "$tmp/missing.err")" 'evidence unavailable' \
    'precheck missing-artifact error says evidence is unavailable'

# -- precheck: fail-closed, invalid JSON -----------------------------------

out=$("$script" precheck --comments "$bad_json" 2>"$tmp/badjson.err")
rc=$?
assert_eq '1' "$rc" 'precheck exits 1 on invalid JSON'
assert_eq '' "$out" 'precheck emits no stdout result on invalid JSON'
assert_contains "$(cat "$tmp/badjson.err")" 'evidence unavailable' \
    'precheck invalid-JSON error says evidence is unavailable'

# -- precheck: fail-closed, no jq on PATH ----------------------------------

no_jq_dir="$tmp/no-jq"
mkdir -p "$no_jq_dir"
# Invoke bash directly (bypassing the script's own #!/usr/bin/env bash) so a
# PATH stripped down to prove jq's absence does not also strip env's ability
# to find bash itself.
out=$(PATH="$no_jq_dir" /bin/bash "$script" precheck --comments "$spent_comments" 2>"$tmp/nojq.err")
rc=$?
assert_eq '1' "$rc" 'precheck exits 1 when jq is missing from PATH'
assert_eq '' "$out" 'precheck emits no stdout result when jq is missing'
assert_contains "$(cat "$tmp/nojq.err")" 'jq' 'missing-jq error names jq'
assert_contains "$(cat "$tmp/nojq.err")" 'evidence unavailable' \
    'missing-jq error says evidence is unavailable'

# -- publish: stub gh transport --------------------------------------------
#
# Mirrors test-gh-comment.sh's inline stub: echoes the posted payload back as
# the verification GET, so gh-comment.sh's byte-compare passes and the exact
# rendered body lands in GH_PAYLOAD for inspection.
cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [[ " $* " == *" --input - "* ]]; then
    cat >"$GH_PAYLOAD"
    jq --argjson id 501 --arg url 'https://example.invalid/comments/501' \
        '. + {id: $id, html_url: $url}' "$GH_PAYLOAD"
    exit 0
fi
jq '. + {id: 501}' "$GH_PAYLOAD"
EOF
chmod +x "$tmp/gh"

run_publish() {
    GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
        "$script" publish "$@"
}

rendered_body() {
    jq -r '.body' "$tmp/payload.json"
}

# -- publish: renders every field, exactly one marker ----------------------

: >"$tmp/gh.log"
out=$(run_publish --pr 14 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason 'peer CLI available' \
    --p1 1 --p2 2 \
    --finding 'Missing input validation|fixed|abc1234,def5678' \
    --finding 'Debatable naming|declined|style preference, no behavior change' \
    --agent-identity 'Claude Opus 5')
rc=$?
assert_eq '0' "$rc" 'publish exits 0 on a successful post'
assert_contains "$out" 'posted id=501' 'publish surfaces gh-comment.sh'"'"' confirmation'

body=$(rendered_body)
assert_contains "$body" 'This was written agentically; verify its assertions:' \
    'publish body carries the agentic attribution banner'
assert_contains "$body" '<!-- review-remote-pr:agent-doc -->' \
    'publish body carries the agent-doc marker'
assert_contains "$body" '## Adversarial review receipt' \
    'publish body carries the receipt heading'
assert_contains "$body" 'provider=anthropic' 'publish body records the provider'
assert_contains "$body" 'model=claude-opus-5' 'publish body records the model'
assert_contains "$body" 'effort=high' 'publish body records the effort'
assert_contains "$body" 'mode=cross-provider' 'publish body records the mode'
assert_contains "$body" 'reason: peer CLI available' 'publish body records the mode reason'
assert_contains "$body" 'P1=1' 'publish body records the P1 count'
assert_contains "$body" 'P2=2' 'publish body records the P2 count'
assert_contains "$body" 'total=3' 'publish body computes the total from P1+P2'
assert_contains "$body" 'Co-authored by Claude Opus 5.' 'publish body credits the agent identity'

marker_count=$(grep -o -- "$marker" <<<"$body" | wc -l | tr -d ' ')
assert_eq '1' "$marker_count" 'publish body carries exactly one spent marker'

# -- publish: finding lines for both fixed and declined shapes -------------

assert_contains "$body" 'Confirmed finding: Missing input validation' \
    'publish body renders the fixed finding title'
assert_contains "$body" 'verdict=fixed' 'publish body records the fixed verdict'
assert_contains "$body" 'fix commit SHA(s)=abc1234,def5678' \
    'publish body records the fix commit SHAs'
assert_contains "$body" 'Confirmed finding: Debatable naming' \
    'publish body renders the declined finding title'
assert_contains "$body" 'verdict=declined' 'publish body records the declined verdict'
assert_contains "$body" 'decline rationale=style preference, no behavior change' \
    'publish body records the decline rationale'
assert_not_contains "$body" 'none confirmed' \
    'publish body does not claim a clean review when findings were given'

# -- publish: 'none confirmed' when no --finding is given ------------------

: >"$tmp/gh.log"
run_publish --pr 15 --repo owner/repo --comments "$not_spent_comments" \
    --provider openai --model gpt-5.6-sol --effort xhigh \
    --mode blind-fallback --mode-reason 'peer CLI absent' \
    --p1 0 --p2 0 \
    --agent-identity 'Codex gpt-5.6-sol' >/dev/null
clean_body=$(rendered_body)
assert_contains "$clean_body" 'Confirmed finding: none confirmed' \
    'publish body records none confirmed when no finding is given'
assert_contains "$clean_body" 'mode=blind-fallback' \
    'publish body records the blind-fallback mode'

# -- publish: verified-skip line is optional --------------------------------

: >"$tmp/gh.log"
run_publish --pr 16 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider \
    --p1 0 --p2 0 \
    --skip-rationale 'comments/formatting only' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5' >/dev/null
skip_body=$(rendered_body)
assert_contains "$skip_body" 'Verified-skip rationale: comments/formatting only' \
    'publish body records the verified-skip rationale when given'
assert_contains "$skip_body" 'mechanical oracle=diff --stat parity check' \
    'publish body records the mechanical oracle when given'

assert_not_contains "$clean_body" 'Verified-skip rationale' \
    'publish body omits the verified-skip line when not given'

# -- publish: refuses when already spent ------------------------------------

: >"$tmp/gh.log"
already_out=$(run_publish --pr 17 --repo owner/repo --comments "$spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider \
    --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>"$tmp/already-spent.err")
already_rc=$?
assert_eq '11' "$already_rc" 'publish refuses with exit 11 when the receipt is already spent'
assert_eq '' "$already_out" 'publish emits no stdout result when refusing a double spend'
assert_contains "$(cat "$tmp/already-spent.err")" 'already spent' \
    'publish refusal names the reason'
assert_eq '' "$(cat "$tmp/gh.log" 2>/dev/null || true)" \
    'publish never calls gh-comment.sh when the receipt is already spent'

# -- publish: usage errors --------------------------------------------------

run_publish --pr 18 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode not-a-real-mode --p1 0 --p2 0 --agent-identity x >/dev/null 2>&1
assert_eq '2' "$?" 'publish rejects an unrecognized --mode value'

run_publish --pr 18 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --p1 0 --p2 0 \
    --finding 'no pipes here' --agent-identity x >/dev/null 2>&1
assert_eq '2' "$?" 'publish rejects a malformed --finding value'

run_publish --pr 18 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --p1 0 --p2 0 \
    --skip-rationale 'only a rationale, no oracle' --agent-identity x >/dev/null 2>&1
assert_eq '2' "$?" 'publish rejects --skip-rationale without --oracle'

finish
