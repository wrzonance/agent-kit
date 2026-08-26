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

findings_file="$tmp/findings.ndjson"

reset_findings() {
    : >"$findings_file"
}

# post-receipt.sh now requires the runner's validated result beside the ledger,
# and each record's severity must account for the receipt's P1/P2 split.
printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"m","transcript":"t","verdict":{"verdict":"findings","findings":[{"priority":"P1","location":"a:1","failureScenario":"x","smallestFix":"y"}]}}' \
    >"$tmp/adversarial.result.json"
chmod 600 -- "$tmp/adversarial.result.json"

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
if [[ ${GH_FAIL_POST:-0} == 1 && " $* " == *" --input - "* ]]; then
    cat >/dev/null
    printf '%s\n' 'simulated ambiguous POST failure' >&2
    exit 1
fi
if [[ -n ${GH_RECOVERY_JSON:-} && "$*" == *'repos/owner/repo/issues/24/comments'* ]]; then
    cat -- "$GH_RECOVERY_JSON"
    exit 0
fi
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
        "$script" publish --findings-file "$findings_file" "$@"
}

# publish now records the spend into the artifact it was handed, so a second
# publish against the same file correctly refuses at 11. Independent cases below
# therefore start from a pristine, marker-free artifact; the double-publish case
# deliberately does not reset, which is the whole point of it.
reset_not_spent() {
    printf '%s\n' '[{"id":1,"body":"just talk, no marker here"}]' >"$not_spent_comments"
}

rendered_body() {
    jq -r '.body' "$tmp/payload.json"
}

# -- publish: renders every field, exactly one marker ----------------------

: >"$tmp/gh.log"
reset_not_spent
reset_findings
jq -cn '{title:"Missing input validation",severity:"P1",verdict:"fixed",sha:"abc1234,def5678"}' \
    >"$findings_file"
jq -cn '{title:"Debatable naming",severity:"P2",verdict:"declined",rationale:"style preference, no behavior change"}' \
    >>"$findings_file"
jq -cn '{title:"Unrelated cleanup",severity:"P2",verdict:"declined",rationale:"not required for this change"}' \
    >>"$findings_file"
out=$(run_publish --pr 14 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason 'peer CLI available' \
    --p1 1 --p2 2 \
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

# -- publish: 'none confirmed' when the findings ledger is empty -------------

: >"$tmp/gh.log"
reset_not_spent
reset_findings
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

# -- publish: counts must match the findings ledger -------------------------

: >"$tmp/gh.log"
reset_not_spent
reset_findings
jq -cn '{title:"Only one confirmed finding",severity:"P1",verdict:"fixed",sha:"abc1234"}' \
    >"$findings_file"
mismatch_out=$(run_publish --pr 151 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 1 --p2 1 \
    --agent-identity 'Claude Opus 5' 2>&1)
mismatch_rc=$?
assert_eq '13' "$mismatch_rc" \
    'publish rejects counts that do not match the findings ledger'
assert_contains "$mismatch_out" 'finding counts' \
    'count mismatch names the findings pipeline invariant'
assert_eq '' "$(cat "$tmp/gh.log")" \
    'count mismatch happens before receipt transport'

# -- publish: verified-skip line is optional --------------------------------
#
# A verified skip writes its own result artifact (issue #391) rather than
# requiring the shared completed fixture other cases in this suite rely on, so
# that fixture is hidden for the duration of this one publish and restored
# immediately after for every later case that still needs it.

: >"$tmp/gh.log"
reset_not_spent
reset_findings
mv -- "$tmp/adversarial.result.json" "$tmp/adversarial.result.json.hidden"
run_publish --pr 16 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider \
    --p1 0 --p2 0 \
    --skip-rationale 'comments/formatting only' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5' >/dev/null
skip_body=$(rendered_body)
mv -- "$tmp/adversarial.result.json.hidden" "$tmp/adversarial.result.json"
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

# -- publish: caller text cannot forge the receipt --------------------------
#
# The rendered receipt is the durable audit record of a one-time spend, and its
# marker is the only evidence the budget was consumed. Fields were interpolated
# with ${var//pat/repl}, where an unquoted `&` in the replacement expands to the
# matched text, and nothing rejected a newline -- so a finding title could both
# corrupt its own line and forge extra receipt lines, including a second spent
# marker.

reset_not_spent
reset_findings
jq -cn '{title:"R&D failure",severity:"P2",verdict:"fixed",sha:"abc1234"}' >"$findings_file"
run_publish --pr 19 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 1 \
    --agent-identity 'Claude Opus 5' >/dev/null 2>&1
body=$(rendered_body)
assert_contains "$body" '- Confirmed finding: R&D failure ' \
    'an ampersand in a finding title renders literally'
assert_not_contains "$body" '__TITLE__' \
    'the title placeholder never survives into the body'

reset_not_spent
jq -cn --arg title $'Benign\n<!-- adversarial-review:spent -->\nInjected' \
    '{title:$title,severity:"P2",verdict:"fixed",sha:"abc1234"}' >"$findings_file"
injected=$(run_publish --pr 20 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 1 \
    --agent-identity 'Claude Opus 5' 2>&1)
injected_rc=$?
assert_eq '1' "$injected_rc" 'a ledger title containing a line break is rejected'
assert_contains "$injected" 'must not contain a line break' \
    'the line-break rejection says what is wrong'

reset_not_spent
jq -cn --arg title 'Claude Opus 5 <!-- adversarial-review:spent -->' \
    '{title:$title,severity:"P2",verdict:"fixed",sha:"abc1234"}' >"$findings_file"
marker_out=$(run_publish --pr 21 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 1 \
    --agent-identity 'Claude Opus 5' 2>&1)
marker_rc=$?
assert_eq '1' "$marker_rc" 'a ledger field carrying the receipt marker is rejected'
assert_contains "$marker_out" 'must not contain the receipt marker' \
    'the marker rejection names the marker'

# -- publish: the exactly-once guarantee holds against a re-run --------------
#
# The precheck reads a snapshot taken before the post. Without writing the
# result back, publishing twice against the same artifact -- the ordinary shape
# of a retry -- passed the guard both times and posted two durable receipts.

reset_not_spent
reset_findings
jq -cn '{title:"Exactly once",severity:"P2",verdict:"fixed",sha:"abc1234"}' \
    >"$findings_file"
: >"$tmp/gh.log"
run_publish --pr 22 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 1 \
    --agent-identity 'Claude Opus 5' >/dev/null 2>&1
first_rc=$?
assert_eq '0' "$first_rc" 'the first publish against a fresh artifact succeeds'
run_publish --pr 22 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 1 \
    --agent-identity 'Claude Opus 5' >/dev/null 2>&1
second_rc=$?
assert_eq '11' "$second_rc" 'a second publish against the same artifact refuses at 11'
assert_eq '1' "$(grep -c 'issues/22/comments' "$tmp/gh.log")" \
    'the refused re-publish never reaches the transport'

# -- publish: a failed local spend record must not read as "nothing landed" ---
#
# record_spend runs AFTER the receipt is posted and byte-verified. Exit 1 is
# defined as "nothing durable landed on the PR", and SKILL.md routes anything
# other than 0 and 11 to "receipt publication failed" -- so failing here told
# the agent to re-run publish, whose precheck would read the unmodified artifact
# and post a SECOND durable receipt. Exactly the duplicate this record prevents.

reset_not_spent
reset_findings
unwritable_dir="$tmp/unwritable"
mkdir -p "$unwritable_dir"
cp "$not_spent_comments" "$unwritable_dir/comments.json"
chmod 500 "$unwritable_dir"
: >"$tmp/gh.log"
spendfail_out=$(GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
    "$script" publish --findings-file "$findings_file" --pr 23 --repo owner/repo --comments "$unwritable_dir/comments.json" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
spendfail_rc=$?
chmod 700 "$unwritable_dir"
assert_eq '0' "$spendfail_rc" \
    'an unrecordable spend still exits 0, because the receipt did land'
assert_eq '1' "$(grep -c 'issues/23/comments' "$tmp/gh.log")" \
    'the receipt was posted exactly once before the record failed'
assert_contains "$spendfail_out" 'receipt POSTED and verified' \
    'the warning states the receipt landed'
assert_contains "$spendfail_out" 'do NOT re-run publish' \
    'the warning steers away from the duplicate-producing retry'

# -- publish: ambiguous failure requires fresh live recovery evidence --------

reset_not_spent
reset_findings
: >"$tmp/gh.log"
recovery_out=$(GH_FAIL_POST=1 GH_RECOVERY_JSON="$spent_comments" run_publish \
    --pr 24 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
recovery_rc=$?
assert_eq '11' "$recovery_rc" \
    'an ambiguous failed post returns spent when fresh live comments contain the marker'
assert_contains "$recovery_out" 'fresh live comments contain the receipt marker' \
    'ambiguous recovery reports the fresh marker evidence'
assert_eq '2' "$(grep -c 'repos/owner/repo/issues/24/comments' "$tmp/gh.log")" \
    'ambiguous recovery fetches live comments after the failed POST'

reset_not_spent
reset_findings
: >"$tmp/gh.log"
recovery_out=$(GH_FAIL_POST=1 GH_RECOVERY_JSON="$not_spent_comments" run_publish \
    --pr 24 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
recovery_rc=$?
assert_eq '1' "$recovery_rc" \
    'an ambiguous failed post remains blocked when fresh live comments lack the marker'
assert_contains "$recovery_out" 'fresh live comments contain no receipt marker' \
    'ambiguous recovery does not treat a cached not-spent artifact as proof'

# -- publish: --require-pushed enforces clean and origin-reachable state ------

push_repo="$tmp/push-repo"
push_origin="$tmp/push-origin.git"
git init -q --bare "$push_origin"
git init -q "$push_repo"
git -C "$push_repo" config user.email test@example.invalid
git -C "$push_repo" config user.name test
git -C "$push_repo" switch -q -c main
printf '%s\n' base >"$push_repo/file.txt"
git -C "$push_repo" add file.txt
git -C "$push_repo" commit -qm base
git -C "$push_repo" remote add origin "$push_origin"
git -C "$push_repo" push -q -u origin main
git -C "$push_repo" fetch -q origin main
reset_not_spent
reset_findings
: >"$tmp/gh.log"
push_out=$(cd -- "$push_repo" && run_publish --pr 25 --repo owner/repo \
    --comments "$not_spent_comments" --require-pushed \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5')
push_rc=$?
assert_eq '0' "$push_rc" '--require-pushed permits a clean pushed HEAD'
assert_contains "$push_out" 'posted id=501' '--require-pushed still uses the verified transport'

printf '%s\n' dirty >"$push_repo/dirty.txt"
reset_not_spent
reset_findings
: >"$tmp/gh.log"
dirty_out=$(cd -- "$push_repo" && run_publish --pr 26 --repo owner/repo \
    --comments "$not_spent_comments" --require-pushed \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
dirty_rc=$?
assert_eq '12' "$dirty_rc" '--require-pushed refuses a dirty tree'
assert_contains "$dirty_out" 'worktree is dirty' '--require-pushed names the dirty-tree refusal'
assert_eq '' "$(cat "$tmp/gh.log")" 'dirty-tree refusal happens before transport'
rm -f -- "$push_repo/dirty.txt"

git -C "$push_repo" commit --allow-empty -qm unpushed
reset_not_spent
reset_findings
: >"$tmp/gh.log"
unpushed_out=$(cd -- "$push_repo" && run_publish --pr 27 --repo owner/repo \
    --comments "$not_spent_comments" --require-pushed \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
unpushed_rc=$?
assert_eq '12' "$unpushed_rc" '--require-pushed refuses an unpushed HEAD'
assert_contains "$unpushed_out" 'not reachable from an origin' \
    '--require-pushed names the missing origin reachability'
assert_eq '' "$(cat "$tmp/gh.log")" 'unpushed refusal happens before transport'

# -- publish: usage errors --------------------------------------------------

reset_not_spent
reset_findings
run_publish --pr 18 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode not-a-real-mode --p1 0 --p2 0 --agent-identity x >/dev/null 2>&1
assert_eq '2' "$?" 'publish rejects an unrecognized --mode value'

reset_not_spent
printf '%s\n' 'not a JSON record' >"$findings_file"
run_publish --pr 18 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --p1 0 --p2 0 --agent-identity x >/dev/null 2>&1
assert_eq '1' "$?" 'publish rejects a malformed findings file'

reset_not_spent
reset_findings
run_publish --pr 18 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --p1 0 --p2 0 \
    --skip-rationale 'only a rationale, no oracle' --agent-identity x >/dev/null 2>&1
assert_eq '2' "$?" 'publish rejects --skip-rationale without --oracle'



# --- the receipt must be bound to a real review ----------------------------
# An owned, schema-valid ledger proved nothing about whether adversarial-run.sh
# ever ran, and the P1/P2 split was taken on the caller's word. Either gap lets a
# receipt attest to a review that did not happen, or misreport what it found.

reset_not_spent
reset_findings
jq -cn '{title:"No runner ever ran",severity:"P2",verdict:"fixed",sha:"abc1234"}' >"$findings_file"
mv -- "$tmp/adversarial.result.json" "$tmp/adversarial.result.json.hidden"
missing_result=$(run_publish --pr 24 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 1 \
    --agent-identity 'Claude Opus 5' 2>&1)
missing_result_rc=$?
mv -- "$tmp/adversarial.result.json.hidden" "$tmp/adversarial.result.json"
assert_eq '1' "$missing_result_rc" 'publish refuses without the runner result beside the ledger'
assert_contains "$missing_result" 'validated adversarial review result is required' \
    'the refusal names the missing runner provenance'

reset_not_spent
reset_findings
jq -cn '{title:"One P2 finding",severity:"P2",verdict:"fixed",sha:"abc1234"}' >"$findings_file"
swapped=$(run_publish --pr 25 --repo owner/repo --comments "$not_spent_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 1 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
swapped_rc=$?
assert_eq '13' "$swapped_rc" 'publish refuses a severity split the ledger does not support'
assert_contains "$swapped" 'ledger severities are P1=0 P2=1' \
    'the refusal names the split the ledger actually holds'

# --- verified skip publishes without a prior adversarial-run.sh call --------
# (issue #391) A documented skip never runs adversarial-run.sh, so no
# adversarial.result.json exists yet. publish must write that result artifact
# itself instead of refusing the whole skip path for a file only the runner it
# was told it could skip would produce.

skip_dir="$tmp/skip-run"
mkdir -p "$skip_dir"
chmod 700 "$skip_dir"
skip_findings="$skip_dir/findings.ndjson"
: >"$skip_findings"

fresh_comments() {
    local path=$1
    printf '%s\n' '[{"id":1,"body":"just talk, no marker here"}]' >"$path"
}

skip_comments="$tmp/skip-not-spent.json"
fresh_comments "$skip_comments"

: >"$tmp/gh.log"
skip_out=$(GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
    "$script" publish --findings-file "$skip_findings" --pr 401 --repo owner/repo \
    --comments "$skip_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --skip-rationale 'comments/formatting only' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5')
skip_rc=$?
assert_eq '0' "$skip_rc" \
    'publish succeeds for a verified skip with no prior adversarial-run.sh call'
assert_contains "$skip_out" 'posted id=501' \
    'the verified-skip publish surfaces gh-comment.sh'"'"' confirmation'
assert_eq 'yes' "$([[ -f $skip_dir/adversarial.result.json ]] && printf yes || printf no)" \
    'publish writes its own result artifact for a verified skip'

skip_result_status=$(jq -r '.status' "$skip_dir/adversarial.result.json")
assert_eq 'skipped' "$skip_result_status" \
    'the skip result artifact records status=skipped'
skip_result_rationale=$(jq -r '.skipRationale' "$skip_dir/adversarial.result.json")
assert_eq 'comments/formatting only' "$skip_result_rationale" \
    'the skip result artifact records the skip rationale'
skip_result_oracle=$(jq -r '.oracle' "$skip_dir/adversarial.result.json")
assert_eq 'diff --stat parity check' "$skip_result_oracle" \
    'the skip result artifact records the mechanical oracle'

skip_publish_body=$(jq -r '.body' "$tmp/payload.json")
assert_contains "$skip_publish_body" "$marker" \
    'the verified-skip publish body carries the spent marker'
assert_contains "$skip_publish_body" 'Verified-skip rationale: comments/formatting only' \
    'the verified-skip publish body records the rationale'

# precheck now reports spent, using the comments artifact record_spend rewrote
skip_precheck_out=$("$script" precheck --comments "$skip_comments")
skip_precheck_rc=$?
assert_eq '0' "$skip_precheck_rc" 'precheck reports spent after a verified-skip publish'
assert_eq 'spent' "$skip_precheck_out" 'precheck prints spent after a verified-skip publish'

# -- verified skip: an existing matching skip result is accepted idempotently -

skip_comments2="$tmp/skip-not-spent-2.json"
fresh_comments "$skip_comments2"
: >"$tmp/gh.log"
skip_out2=$(GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
    "$script" publish --findings-file "$skip_findings" --pr 402 --repo owner/repo \
    --comments "$skip_comments2" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --skip-rationale 'comments/formatting only' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5')
skip_rc2=$?
assert_eq '0' "$skip_rc2" \
    'publish accepts an already-matching verified-skip result idempotently'
assert_contains "$skip_out2" 'posted id=501' \
    'the idempotent verified-skip publish reaches the transport'

# -- verified skip: a mismatched existing skip result is refused ------------

skip_comments3="$tmp/skip-not-spent-3.json"
fresh_comments "$skip_comments3"
mismatch_skip_out=$(GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
    "$script" publish --findings-file "$skip_findings" --pr 403 --repo owner/repo \
    --comments "$skip_comments3" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --skip-rationale 'a different rationale' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5' 2>&1)
mismatch_skip_rc=$?
assert_eq '1' "$mismatch_skip_rc" \
    'publish refuses a verified skip whose rationale/oracle does not match the existing result'
assert_contains "$mismatch_skip_out" 'does not match this verified skip' \
    'the mismatch refusal names the reason'

# -- verified skip: a real completed result is never overwritten ------------

completed_dir="$tmp/skip-vs-completed"
mkdir -p "$completed_dir"
chmod 700 "$completed_dir"
completed_findings="$completed_dir/findings.ndjson"
: >"$completed_findings"
printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"m","transcript":"t","verdict":{"verdict":"no_findings","findings":[]}}' \
    >"$completed_dir/adversarial.result.json"
chmod 600 -- "$completed_dir/adversarial.result.json"

skip_comments4="$tmp/skip-not-spent-4.json"
fresh_comments "$skip_comments4"
completed_vs_skip_out=$(GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
    "$script" publish --findings-file "$completed_findings" --pr 404 --repo owner/repo \
    --comments "$skip_comments4" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --skip-rationale 'comments/formatting only' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5' 2>&1)
completed_vs_skip_rc=$?
assert_eq '1' "$completed_vs_skip_rc" \
    'publish refuses to overwrite a real completed result with a verified-skip result'
assert_contains "$completed_vs_skip_out" 'does not match this verified skip' \
    'the overwrite refusal names the reason'
completed_result_status=$(jq -r '.status' "$completed_dir/adversarial.result.json")
assert_eq 'completed' "$completed_result_status" \
    'the real completed result is left untouched by the refused skip'

# -- verified skip: a multi-document artifact is never treated as a match ---
# A bare `jq -e` (no -s) tests every top-level JSON value in the input and
# bases its exit status on only the LAST one. A file holding a completed
# runner result as its first document and a matching skipped document second
# therefore passed the old check even though the artifact also recorded a
# completed review -- the no-silent-overwrite contract requires exactly one
# document, matching validate_runner_provenance's own `jq -s -e` shape.

multidoc_dir="$tmp/skip-vs-multidoc"
mkdir -p "$multidoc_dir"
chmod 700 "$multidoc_dir"
multidoc_findings="$multidoc_dir/findings.ndjson"
: >"$multidoc_findings"
{
    printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"m","transcript":"t","verdict":{"verdict":"no_findings","findings":[]}}'
    printf '%s\n' '{"status":"skipped","skipRationale":"comments/formatting only","oracle":"diff --stat parity check"}'
} >"$multidoc_dir/adversarial.result.json"
chmod 600 -- "$multidoc_dir/adversarial.result.json"

skip_comments5="$tmp/skip-not-spent-5.json"
fresh_comments "$skip_comments5"
multidoc_out=$(GH_COMMENT_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD="$tmp/payload.json" \
    "$script" publish --findings-file "$multidoc_findings" --pr 405 --repo owner/repo \
    --comments "$skip_comments5" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --skip-rationale 'comments/formatting only' --oracle 'diff --stat parity check' \
    --agent-identity 'Claude Opus 5' 2>&1)
multidoc_rc=$?
assert_eq '1' "$multidoc_rc" \
    'publish refuses a verified skip against a multi-document result artifact'
assert_contains "$multidoc_out" 'does not match this verified skip' \
    'the multi-document refusal names the reason'
multidoc_doc_count=$(jq -s 'length' "$multidoc_dir/adversarial.result.json")
assert_eq '2' "$multidoc_doc_count" \
    'the multi-document result artifact is left untouched by the refused skip'

# -- publish: --head-sha renders head/diff-payload lines and appends a
#    review-ledger.sh entry (issue #477) --------------------------------
#
# Its own stub (rather than the shared "$tmp/gh"): the ledger append issues a
# SECOND gh-comment.sh-routed POST against the same GH_PAYLOAD-style capture,
# which would overwrite the receipt body before this test can inspect it. This
# stub instead dumps every posted body to its own numbered file under
# GH_PAYLOAD_DIR, keyed by call order, so both posts stay inspectable.
head_gh_dir="$tmp/head-gh"
mkdir -p "$head_gh_dir"
cat >"$head_gh_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [[ " $* " == *" --input - "* ]]; then
    n=$(($(cat "$GH_PAYLOAD_DIR/count" 2>/dev/null || echo 0) + 1))
    printf '%s' "$n" >"$GH_PAYLOAD_DIR/count"
    cat >"$GH_PAYLOAD_DIR/payload-$n.json"
    jq --argjson id "$((500 + n))" --arg url "https://example.invalid/comments/$((500 + n))" \
        '. + {id: $id, html_url: $url}' "$GH_PAYLOAD_DIR/payload-$n.json"
    exit 0
fi
n=$(cat "$GH_PAYLOAD_DIR/count")
jq '. + {id: (500 + '"$n"')}' "$GH_PAYLOAD_DIR/payload-$n.json"
EOF
chmod +x "$head_gh_dir/gh"

head_sha='1111111111111111111111111111111111111a'
diff_payload='owner/repo:900:abababababababababababababababababababababababababababababab'

: >"$tmp/gh.log"
: >"$head_gh_dir/count"
head_comments="$tmp/head-not-spent.json"
printf '%s\n' '[{"id":1,"body":"just talk, no marker here"}]' >"$head_comments"
reset_findings
# review-ledger.sh append (invoked internally by append_ledger_entry) needs
# a trusted-author identity to resolve; REVIEW_LEDGER_VIEWER pins it to a
# deterministic test value instead of falling through to a live `gh api
# user` call (issue #477 root review finding F1).
head_out=$(GH_COMMENT_GH="$head_gh_dir/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD_DIR="$head_gh_dir" \
    REVIEW_LEDGER_VIEWER='ledger-test-author' \
    "$script" publish --findings-file "$findings_file" \
    --pr 900 --repo owner/repo --comments "$head_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' \
    --head-sha "$head_sha" --diff-payload "$diff_payload" --harness claude)
head_rc=$?
assert_eq '0' "$head_rc" 'publish exits 0 with --head-sha given'
assert_contains "$head_out" 'posted id=501' \
    'publish surfaces the receipt gh-comment.sh confirmation on stdout'
assert_eq '2' "$(cat "$head_gh_dir/count")" \
    'publish with --head-sha makes exactly one additional POST for the ledger comment'

head_body=$(jq -r '.body' "$head_gh_dir/payload-1.json")
assert_contains "$head_body" "- Reviewed head: $head_sha" \
    'publish body records the reviewed head SHA'
assert_contains "$head_body" "- Diff payload: $diff_payload" \
    'publish body records the diff payload'
# A clean (zero-finding) review still gets a head line -- closing the
# no-SHA-on-a-clean-review hole the issue calls out explicitly.
assert_contains "$head_body" 'Confirmed finding: none confirmed' \
    'a clean review still renders none confirmed'

ledger_body=$(jq -r '.body' "$head_gh_dir/payload-2.json")
assert_contains "$ledger_body" '<!-- review-ledger:v1 -->' \
    'the second POST carries the review-ledger fence'
assert_contains "$ledger_body" "$head_sha" \
    'the review-ledger entry records the reviewed head SHA'
assert_contains "$ledger_body" '"kind": "adversarial"' \
    'the review-ledger entry records kind=adversarial'
assert_contains "$ledger_body" '"reviewed_at"' \
    'the review-ledger entry records a reviewed_at timestamp (CodeRabbit #484 nitpick)'
# shellcheck disable=SC2016  # single-quoted on purpose: a literal sed pattern, not meant to expand.
reviewed_at_value=$(sed -n '/```json/,/```/p' <<<"$ledger_body" | sed '1d;$d' | jq -r '.reviews[0].reviewed_at')
assert_eq 'yes' "$([[ $reviewed_at_value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && printf yes || printf no)" \
    'the reviewed_at timestamp is UTC ISO-8601, matching the launch-marker convention'

# -- publish: omitting --head-sha renders neither line, and no ledger call -

: >"$tmp/gh.log"
: >"$head_gh_dir/count"
rm -f -- "$head_gh_dir"/payload-*.json
no_head_comments="$tmp/no-head-not-spent.json"
printf '%s\n' '[{"id":1,"body":"just talk, no marker here"}]' >"$no_head_comments"
reset_findings
GH_COMMENT_GH="$head_gh_dir/gh" GH_LOG="$tmp/gh.log" GH_PAYLOAD_DIR="$head_gh_dir" \
    "$script" publish --findings-file "$findings_file" \
    --pr 901 --repo owner/repo --comments "$no_head_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' >/dev/null
assert_eq '1' "$(cat "$head_gh_dir/count")" \
    'publish makes no ledger POST when --head-sha is omitted'
no_head_body=$(jq -r '.body' "$head_gh_dir/payload-1.json")
assert_not_contains "$no_head_body" '- Reviewed head:' \
    'publish body carries no head line when --head-sha is omitted'

# -- publish: append_ledger_entry derives --repo-root via `git rev-parse
#    --show-toplevel` (CodeRabbit review of PR #484, issue #477 T1) --------
# Without --repo-root, resolve_trusted_author inside review-ledger.sh's
# append call could never see a repository-declared AGENT_LEDGER_AUTHOR and
# silently fell back to REVIEW_LEDGER_VIEWER/gh instead. A PRE-EXISTING
# ledger comment authored by the CONFIGURED author (not the REVIEW_LEDGER_
# VIEWER decoy set for this call) must be UPDATED in place -- proving append
# resolved the same configured identity, not created as a second comment
# under the wrong (env-var) identity.

git_fixture="$tmp/repo-root-fixture"
mkdir -p "$git_fixture/.agent"
git init -q "$git_fixture"
git -C "$git_fixture" config user.email test@example.com
git -C "$git_fixture" config user.name test
configured_author='configured-ledger-author'
printf 'AGENT_LEDGER_AUTHOR=%s\n' "$configured_author" >"$git_fixture/.agent/config.env"

# A stub that resolves the target comment id from the endpoint URL for a
# --update (PATCH) call, or assigns a fresh id for a plain create (POST) --
# so an update-in-place and a wrongly-created second comment are
# distinguishable after the fact by inspecting which id each call used.
repo_root_gh_dir="$tmp/repo-root-gh"
mkdir -p "$repo_root_gh_dir"
cat >"$repo_root_gh_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
if [[ " $* " == *" --input - "* ]]; then
    n=$(($(cat "$GH_PAYLOAD_DIR/count" 2>/dev/null || echo 0) + 1))
    printf '%s' "$n" >"$GH_PAYLOAD_DIR/count"
    cat >"$GH_PAYLOAD_DIR/payload-$n.json"
    endpoint=''
    for arg in "$@"; do [[ $arg == repos/* ]] && endpoint=$arg; done
    if [[ $endpoint =~ /issues/comments/([0-9]+)$ ]]; then
        id="${BASH_REMATCH[1]}"
    else
        id=$((500 + n))
    fi
    printf '%s' "$id" >"$GH_PAYLOAD_DIR/id-$n"
    jq --argjson id "$id" --arg url "https://example.invalid/comments/$id" \
        '. + {id: $id, html_url: $url}' "$GH_PAYLOAD_DIR/payload-$n.json"
    exit 0
fi
n=$(cat "$GH_PAYLOAD_DIR/count")
id=$(cat "$GH_PAYLOAD_DIR/id-$n")
jq --argjson id "$id" '. + {id: $id}' "$GH_PAYLOAD_DIR/payload-$n.json"
EOF
chmod +x "$repo_root_gh_dir/gh"

existing_ledger_reviews='[{"kind":"adversarial","provider":"anthropic","head_sha":"9999999999999999999999999999999999999a","diff_payload":"owner/repo:902:deadbeef"}]'
repo_root_comments="$tmp/repo-root-comments.json"
jq -n --argjson reviews "$existing_ledger_reviews" --arg login "$configured_author" \
    '[{id: 70, user: {login: $login}, body: ("<!-- review-ledger:v1 -->\n```json\n" +
        ({version:1, pr:902, repo:"owner/repo", reviews:$reviews} | tojson) +
        "\n```\n<!-- /review-ledger:v1 -->")}]' >"$repo_root_comments"

: >"$tmp/repo-root-gh.log"
: >"$repo_root_gh_dir/count"
reset_findings
new_head_sha='2222222222222222222222222222222222222b'
(cd "$git_fixture" && GH_COMMENT_GH="$repo_root_gh_dir/gh" GH_LOG="$tmp/repo-root-gh.log" \
    GH_PAYLOAD_DIR="$repo_root_gh_dir" REVIEW_LEDGER_VIEWER='decoy-env-author' \
    "$script" publish --findings-file "$findings_file" \
    --pr 902 --repo owner/repo --comments "$repo_root_comments" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' \
    --head-sha "$new_head_sha") >/dev/null
repo_root_rc=$?
assert_eq '0' "$repo_root_rc" 'publish succeeds when append_ledger_entry must derive --repo-root itself'
assert_eq '2' "$(cat "$repo_root_gh_dir/count")" \
    'exactly two writes happen: the receipt create, and the ledger append'
assert_eq '70' "$(cat "$repo_root_gh_dir/id-2")" \
    'the ledger append PATCHes the existing trusted comment id (CodeRabbit #484 T1), never creating a second one'
assert_contains "$(cat "$tmp/repo-root-gh.log")" 'issues/comments/70' \
    'the second write targets the existing comment endpoint by id'
repo_root_ledger_body=$(jq -r '.body' "$repo_root_gh_dir/payload-2.json")
assert_contains "$repo_root_ledger_body" "$new_head_sha" \
    'the updated ledger comment carries the new entry'
assert_contains "$repo_root_ledger_body" '9999999999999999999999999999999999999a' \
    'the updated ledger comment still preserves the pre-existing entry (append-only)'

finish
