#!/usr/bin/env bash
# Boundary coverage for the one-shot adversarial review orchestrator.
set -uo pipefail

TEST_NAME='adversarial run'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/adversarial-run.sh"
consent="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
origin="$tmp/origin.git"
git init --bare --quiet "$origin"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$origin"
printf '%s\n' base >"$repo/example.txt"
git -C "$repo" add example.txt
git -C "$repo" commit --quiet -m base
git -C "$repo" push --quiet -u origin main
git -C "$repo" switch --quiet -c feature
printf '%s\n' changed >"$repo/example.txt"
git -C "$repo" commit --quiet -am change
head_oid=$(git -C "$repo" rev-parse HEAD)
export FAKE_HEAD_OID=$head_oid

fake_bin="$tmp/bin"
mkdir -- "$fake_bin"
cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == pr && ${2:-} == view ]] || exit 1
case " $* " in
    *' headRefOid '*) printf '%s\n' "$FAKE_HEAD_OID" ;;
    *) printf '%s\n' main ;;
esac
EOF
chmod +x "$fake_bin/gh"

cat >"$tmp/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5","tools":["StructuredOutput"],"mcp_servers":[]}'
if [[ ${FAKE_INVALID:-} == 1 ]]; then
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"no_findings","findings":[],"unexpected":true},"modelUsage":{"claude-opus-5":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
else
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"findings","findings":[{"priority":"P1","location":"example.txt:1","failureScenario":"breaks","smallestFix":"repair"},{"priority":"P2","location":"example.txt:1","failureScenario":"degrades","smallestFix":"repair"}]},"modelUsage":{"claude-opus-5":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
fi
EOF
chmod +x "$tmp/fake-claude"

cat >"$tmp/fake-codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == exec && ${2:-} == --help ]]; then
    printf '%s\n' '--model --config --sandbox --ephemeral --ignore-user-config'
    printf '%s\n' '--ignore-rules --skip-git-repo-check --output-schema'
    printf '%s\n' '--output-last-message --json'
    exit 0
fi
last_file=''
while (($#)); do
    if [[ $1 == --output-last-message ]]; then last_file=$2; shift 2; else shift; fi
done
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
EOF
chmod +x "$tmp/fake-codex"

expected="$tmp/expected.diff"
git -C "$repo" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$expected"

grant() {
    local run_dir=$1 provider=$2 payload
    mkdir -- "$run_dir" "$run_dir/state"
    chmod 700 "$run_dir" "$run_dir/state"
    payload=$(/bin/bash "$consent" payload --repo acme/widget --pr 42 --diff "$expected")
    /bin/bash "$consent" grant --state "$run_dir/state/cross-provider-consent" \
        --provider "$provider" --payload "$payload" --source interactive >/dev/null
}

missing="$tmp/missing"
mkdir -- "$missing"
chmod 700 "$missing"
printf '%s\n' 'stale result' >"$missing/adversarial.result.json"
missing_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$missing") \
    >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_rc=$?
assert_eq 1 "$missing_rc" 'missing consent blocks before provider launch'
assert_contains "$(cat -- "$tmp/missing.err")" 'consent' 'missing consent is named'
assert_eq no "$( [[ -e $missing/adversarial.result.json ]] && printf yes || printf no )" \
    'missing consent does not publish a verdict'

mismatch_run="$tmp/mismatch-run"
mkdir -- "$mismatch_run" "$mismatch_run/state"
chmod 700 "$mismatch_run" "$mismatch_run/state"
mismatch_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" FAKE_HEAD_OID=0000000000000000000000000000000000000000 \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$mismatch_run") \
    >"$tmp/mismatch.out" 2>"$tmp/mismatch.err" || mismatch_rc=$?
assert_eq 1 "$mismatch_rc" 'checkout that is not the PR head is rejected'
assert_contains "$(cat -- "$tmp/mismatch.err")" 'does not match PR head' \
    'checkout mismatch names the PR head invariant'
assert_eq no "$( [[ -e $mismatch_run/adversarial.diff ]] && printf yes || printf no )" \
    'checkout mismatch does not build a review diff'

claude_run="$tmp/claude-run"
grant "$claude_run" anthropic
claude_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$claude_run") \
    >"$tmp/claude.out" 2>"$tmp/claude.err" || claude_rc=$?
assert_eq 0 "$claude_rc" 'consented Claude review completes'
assert_eq yes "$( [[ -s $claude_run/adversarial.diff ]] && printf yes || printf no )" \
    'orchestrator writes the shared adversarial diff'
assert_eq yes "$( [[ -s $claude_run/adversarial.result.json ]] && printf yes || printf no )" \
    'orchestrator writes the canonical result'
assert_eq yes "$( [[ -f $claude_run/findings.ndjson ]] && printf yes || printf no )" \
    'a completed review initializes the findings ledger'
assert_eq 600 "$(stat -c %a "$claude_run/findings.ndjson")" \
    'the initialized findings ledger is owner-private'
assert_eq 0 "$(wc -c <"$claude_run/findings.ndjson")" \
    'a clean starting ledger has no dispositions'
assert_contains "$(cat -- "$tmp/claude.out")" 'provider=anthropic' 'receipt line names provider'
assert_contains "$(cat -- "$tmp/claude.out")" 'model=claude-opus-5' 'receipt line names model'
assert_contains "$(cat -- "$tmp/claude.out")" 'mode=cross-provider' 'receipt line names mode'
assert_contains "$(cat -- "$tmp/claude.out")" 'P1=1' 'receipt line counts P1 findings'
assert_contains "$(cat -- "$tmp/claude.out")" 'P2=1' 'receipt line counts P2 findings'

invalid_run="$tmp/invalid-run"
grant "$invalid_run" anthropic
invalid_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" FAKE_INVALID=1 \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$invalid_run") \
    >"$tmp/invalid.out" 2>"$tmp/invalid.err" || invalid_rc=$?
assert_eq 1 "$invalid_rc" 'schema-invalid provider output blocks the review'
assert_eq blocked "$(jq -r '.status' <"$invalid_run/adversarial.result.json")" \
    'schema-invalid provider output publishes a blocked result'
assert_eq no "$( [[ -e $invalid_run/findings.ndjson ]] && printf yes || printf no )" \
    'a blocked review does not initialize the findings ledger'
assert_contains "$(cat -- "$tmp/invalid.out")" 'verdict=blocked' \
    'schema-invalid provider output cannot emit a clean verdict'

malformed_root="$tmp/malformed-plugin"
malformed_script_dir="$malformed_root/skills/review-remote-pr/scripts"
mkdir -p -- "$malformed_script_dir" "$malformed_root/skills/.shared/scripts/lib"
cp -- "$script" "$malformed_script_dir/adversarial-run.sh"
cp -- "$consent" "$malformed_script_dir/consent-record.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" \
    "$malformed_root/skills/.shared/scripts/lib/private-dir.sh"
cat >"$malformed_script_dir/claude-adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($#)); do
    case $1 in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' '{"status":"blocked","blockedReason":"test","verdict":"blocked"}' >"$output"
exit 3
EOF
chmod +x "$malformed_script_dir/adversarial-run.sh" "$malformed_script_dir/consent-record.sh" \
    "$malformed_script_dir/claude-adversarial-review.sh"

malformed_run="$tmp/malformed-run"
grant "$malformed_run" anthropic
malformed_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" \
    bash "$malformed_script_dir/adversarial-run.sh" --pr 42 --repo acme/widget \
        --run-dir "$malformed_run") \
    >"$tmp/malformed.out" 2>"$tmp/malformed.err" || malformed_rc=$?
assert_eq 1 "$malformed_rc" 'malformed blocked result fails closed'
assert_contains "$(cat -- "$tmp/malformed.out")" 'verdict=blocked' \
    'malformed blocked result still emits a safe receipt'
assert_not_contains "$(cat -- "$tmp/malformed.err")" 'Cannot index' \
    'malformed blocked result does not crash receipt parsing'
assert_eq blocked "$(jq -r '.status' <"$malformed_run/adversarial.result.json")" \
    'malformed blocked result is replaced with a validated blocked result'

codex_run="$tmp/codex-run"
grant "$codex_run" openai
codex_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_run" --peer-cli-absent) \
    >"$tmp/codex.out" 2>"$tmp/codex.err" || codex_rc=$?
assert_eq 0 "$codex_rc" 'peer-cli-absent selects the blind fallback once'
assert_contains "$(cat -- "$tmp/codex.out")" 'provider=openai' 'fallback receipt line names OpenAI'
assert_contains "$(cat -- "$tmp/codex.out")" 'mode=blind-fallback' 'fallback receipt line names blind mode'
assert_contains "$(cat -- "$tmp/codex.out")" 'P1=0' 'fallback receipt line counts P1 findings'
assert_contains "$(cat -- "$tmp/codex.out")" 'P2=0' 'fallback receipt line counts P2 findings'

finish
