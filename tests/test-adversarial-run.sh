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

mkdir -- "$repo/.agent"
contract="$repo/.agent/env-contract.txt"
write_contract() {
    local harness=$1 peer=$2 state=$3
    printf '%s\n' \
        'repo=acme/widget' \
        "harness= name=$harness trailer=\"Test <test@example.invalid>\" other=$peer" \
        "peer-cli= $peer $state" >"$contract"
    chmod 600 -- "$contract"
}
write_contract codex claude "present path=$tmp/fake-claude"

fake_bin="$tmp/bin"
mkdir -- "$fake_bin"
cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == api && ${2:-} == repos/acme/widget/pulls/42 ]] || exit 1
printf '%s\n' "{\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$FAKE_HEAD_OID\"}}"
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
# Records that the provider CLI was actually launched. A consent gate that
# blocks must leave no marker: absence of a result file alone would still pass
# if a regression launched the provider and simply failed to publish.
[[ -z ${FAKE_CLAUDE_CALLED:-} ]] || printf 'called\n' >>"$FAKE_CLAUDE_CALLED"
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
    local run_dir=$1 provider=$2 diff=${3:-$expected} payload
    mkdir -- "$run_dir" "$run_dir/state"
    chmod 700 "$run_dir" "$run_dir/state"
    payload=$(/bin/bash "$consent" payload --repo acme/widget --pr 42 --diff "$diff")
    /bin/bash "$consent" grant --state "$run_dir/state/cross-provider-consent" \
        --provider "$provider" --payload "$payload" --source interactive >/dev/null
}

missing="$tmp/missing"
mkdir -- "$missing"
chmod 700 "$missing"
printf '%s\n' 'stale result' >"$missing/adversarial.result.json"
missing_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/missing.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$missing") \
    >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_rc=$?
assert_eq 1 "$missing_rc" 'missing consent blocks before provider launch'
assert_contains "$(cat -- "$tmp/missing.err")" 'consent' 'missing consent is named'
assert_eq no "$( [[ -e $missing/adversarial.result.json ]] && printf yes || printf no )" \
    'missing consent does not publish a verdict'
assert_eq no "$( [[ -e $tmp/missing.called ]] && printf yes || printf no )" \
    'missing consent never launches the provider CLI at all'

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

# A leftover findings ledger from a prior attempt in a reused RUN_DIR must be
# rejected before the provider is ever launched -- not after paying for the
# review, which is the defect this file regression-tests (#393).
badmode_run="$tmp/badmode-run"
grant "$badmode_run" anthropic
printf '%s\n' stale >"$badmode_run/findings.ndjson"
chmod 644 -- "$badmode_run/findings.ndjson"
badmode_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/badmode.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$badmode_run") \
    >"$tmp/badmode.out" 2>"$tmp/badmode.err" || badmode_rc=$?
assert_eq 1 "$badmode_rc" 'a wrong-mode findings ledger fails before launch'
assert_contains "$(cat -- "$tmp/badmode.err")" "$badmode_run/findings.ndjson" \
    'wrong-mode findings ledger failure names the path'
assert_eq no "$( [[ -e $tmp/badmode.called ]] && printf yes || printf no )" \
    'wrong-mode findings ledger never launches the provider CLI'
assert_eq no "$( [[ -e $badmode_run/adversarial.diff ]] && printf yes || printf no )" \
    'wrong-mode findings ledger check happens before diff construction'

symlink_run="$tmp/symlink-run"
grant "$symlink_run" anthropic
ln -s /etc/passwd "$symlink_run/findings.ndjson"
symlink_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/symlink.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$symlink_run") \
    >"$tmp/symlink.out" 2>"$tmp/symlink.err" || symlink_rc=$?
assert_eq 1 "$symlink_rc" 'a symlinked findings ledger fails before launch'
assert_contains "$(cat -- "$tmp/symlink.err")" "$symlink_run/findings.ndjson" \
    'symlinked findings ledger failure names the path'
assert_eq no "$( [[ -e $tmp/symlink.called ]] && printf yes || printf no )" \
    'symlinked findings ledger never launches the provider CLI'
assert_eq no "$( [[ -e $symlink_run/adversarial.diff ]] && printf yes || printf no )" \
    'symlinked findings ledger check happens before diff construction'

# A safe (owned, mode-0600, regular, non-symlink) but NON-EMPTY pre-existing
# ledger must still be refused: silently accepting it would carry a prior
# review's dispositions into this review's receipt (follow-up to #393, PR
# #412 adversarial review).
nonempty_run="$tmp/nonempty-run"
grant "$nonempty_run" anthropic
printf '%s\n' '{"title":"prior finding","sha":"abc1234","verdict":"declined","rationale":"stale"}' \
    >"$nonempty_run/findings.ndjson"
chmod 600 -- "$nonempty_run/findings.ndjson"
nonempty_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/nonempty.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$nonempty_run") \
    >"$tmp/nonempty.out" 2>"$tmp/nonempty.err" || nonempty_rc=$?
assert_eq 1 "$nonempty_rc" 'a non-empty pre-existing findings ledger fails before launch'
assert_contains "$(cat -- "$tmp/nonempty.err")" "$nonempty_run/findings.ndjson" \
    'non-empty findings ledger failure names the path'
assert_contains "$(cat -- "$tmp/nonempty.err")" 'prior review' \
    'non-empty findings ledger failure explains why it is refused'
assert_eq no "$( [[ -e $tmp/nonempty.called ]] && printf yes || printf no )" \
    'non-empty findings ledger never launches the provider CLI'
assert_eq no "$( [[ -e $nonempty_run/adversarial.diff ]] && printf yes || printf no )" \
    'non-empty findings ledger check happens before diff construction'

# An empty, already-owned mode-0600 ledger (e.g. pre-created by the caller
# before launch) is a legitimate starting state and must not block the run.
preempty_run="$tmp/preempty-run"
grant "$preempty_run" anthropic
: >"$preempty_run/findings.ndjson"
chmod 600 -- "$preempty_run/findings.ndjson"
preempty_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$preempty_run") \
    >"$tmp/preempty.out" 2>"$tmp/preempty.err" || preempty_rc=$?
assert_eq 0 "$preempty_rc" 'a pre-existing empty owned mode-0600 ledger allows the run to complete'
assert_eq yes "$( [[ -f $preempty_run/findings.ndjson ]] && printf yes || printf no )" \
    'the pre-existing empty ledger survives a completed review'
assert_eq 0 "$(wc -c <"$preempty_run/findings.ndjson")" \
    'the pre-existing empty ledger is left empty by the runner itself'

write_contract claude codex "present path=$tmp/fake-codex"
codex_peer_run="$tmp/codex-peer-run"
grant "$codex_peer_run" openai
codex_peer_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_peer_run") \
    >"$tmp/codex-peer.out" 2>"$tmp/codex-peer.err" || codex_peer_rc=$?
assert_eq 0 "$codex_peer_rc" 'Claude harness selects the Codex peer helper'
assert_contains "$(cat -- "$tmp/codex-peer.out")" 'provider=openai' \
    'Claude harness receipt names the Codex peer provider'
assert_contains "$(cat -- "$tmp/codex-peer.out")" 'model=gpt-5.6-terra' \
    'Claude harness receipt names the Codex peer model'
assert_contains "$(cat -- "$tmp/codex-peer.out")" 'mode=cross-provider' \
    'Claude harness and Codex peer are genuinely cross-provider'

# A grant recorded under the peer-cli= CLI name ("codex") must satisfy the
# runner's check, which is keyed on the model-provider token ("openai") --
# the root should never have to read the runner source to find the "right"
# --provider token for consent-record.sh grant (#392).
codex_alias_run="$tmp/codex-alias-run"
grant "$codex_alias_run" codex
codex_alias_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_alias_run") \
    >"$tmp/codex-alias.out" 2>"$tmp/codex-alias.err" || codex_alias_rc=$?
assert_eq 0 "$codex_alias_rc" \
    'a consent grant recorded under the codex CLI name satisfies the runner check'
assert_contains "$(cat -- "$tmp/codex-alias.out")" 'provider=openai' \
    'a codex-CLI-name grant still completes the openai-provider review'

write_contract claude claude "present path=$tmp/fake-claude"
same_harness_run="$tmp/same-harness-run"
grant "$same_harness_run" anthropic
same_harness_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$same_harness_run") \
    >"$tmp/same-harness.out" 2>"$tmp/same-harness.err" || same_harness_rc=$?
assert_eq 0 "$same_harness_rc" 'same-harness selection completes'
assert_contains "$(cat -- "$tmp/same-harness.out")" 'provider=anthropic' \
    'same-harness receipt names the selected provider'
assert_contains "$(cat -- "$tmp/same-harness.out")" 'mode=blind-fallback' \
    'same-harness selection uses blind-fallback mode'
assert_not_contains "$(cat -- "$tmp/same-harness.out")" 'mode=cross-provider' \
    'same-harness selection can never emit cross-provider mode'

write_contract claude codex 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
claude_fallback_run="$tmp/claude-fallback-run"
grant "$claude_fallback_run" anthropic
claude_fallback_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$claude_fallback_run") \
    >"$tmp/claude-fallback.out" 2>"$tmp/claude-fallback.err" || claude_fallback_rc=$?
assert_eq 0 "$claude_fallback_rc" 'Claude harness uses a same-harness fallback when its peer is absent'
assert_contains "$(cat -- "$tmp/claude-fallback.out")" 'provider=anthropic' \
    'Claude fallback receipt names the running provider'
assert_contains "$(cat -- "$tmp/claude-fallback.out")" 'model=claude-opus-5' \
    'Claude fallback receipt names the running model'
assert_contains "$(cat -- "$tmp/claude-fallback.out")" 'mode=blind-fallback' \
    'Claude fallback receipt names blind mode'

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
cp -- "$root/agentkit/skills/.shared/scripts/lib/canonical-diff.sh" \
    "$malformed_root/skills/.shared/scripts/lib/canonical-diff.sh"
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

write_contract codex claude 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
codex_run="$tmp/codex-run"
grant "$codex_run" openai
codex_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_run") \
    >"$tmp/codex.out" 2>"$tmp/codex.err" || codex_rc=$?
assert_eq 0 "$codex_rc" 'contract peer absence selects the blind fallback once'
assert_contains "$(cat -- "$tmp/codex.out")" 'provider=openai' 'fallback receipt line names OpenAI'
assert_contains "$(cat -- "$tmp/codex.out")" 'mode=blind-fallback' 'fallback receipt line names blind mode'
assert_contains "$(cat -- "$tmp/codex.out")" 'P1=0' 'fallback receipt line counts P1 findings'
assert_contains "$(cat -- "$tmp/codex.out")" 'P2=0' 'fallback receipt line counts P2 findings'

write_contract codex claude "present path=$tmp/fake-claude"


# --- a blocked result must never carry a verdict object --------------------
# status="blocked" alongside a findings-shaped verdict previously validated, and
# receipt_line read the verdict object rather than the status -- so a review that
# never happened reported verdict=findings with P1/P2 counts. A blocked run
# produced no review; it has no verdict to report.
verdict_root="$tmp/verdict-plugin"
verdict_script_dir="$verdict_root/skills/review-remote-pr/scripts"
mkdir -p -- "$verdict_script_dir" "$verdict_root/skills/.shared/scripts/lib"
cp -- "$script" "$verdict_script_dir/adversarial-run.sh"
cp -- "$consent" "$verdict_script_dir/consent-record.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" \
    "$verdict_root/skills/.shared/scripts/lib/private-dir.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/canonical-diff.sh" \
    "$verdict_root/skills/.shared/scripts/lib/canonical-diff.sh"
cat >"$verdict_script_dir/claude-adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($#)); do
    case $1 in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' '{"status":"blocked","blockedReason":"provider refused","verdict":{"verdict":"findings","findings":[{"priority":"P1","location":"a.sh:1","failureScenario":"x","smallestFix":"y"}]}}' >"$output"
exit 3
EOF
chmod +x "$verdict_script_dir/adversarial-run.sh" "$verdict_script_dir/consent-record.sh" \
    "$verdict_script_dir/claude-adversarial-review.sh"

verdict_run="$tmp/verdict-run"
grant "$verdict_run" anthropic
verdict_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" \
    bash "$verdict_script_dir/adversarial-run.sh" --pr 42 --repo acme/widget \
        --run-dir "$verdict_run") \
    >"$tmp/verdict.out" 2>"$tmp/verdict.err" || verdict_rc=$?
assert_eq 1 "$verdict_rc" 'a blocked result carrying a verdict object fails closed'
assert_contains "$(cat -- "$tmp/verdict.out")" 'verdict=blocked' \
    'a blocked result never reports the verdict it carried'
assert_contains "$(cat -- "$tmp/verdict.out")" 'P1=0' \
    'a blocked result reports no P1 findings'
assert_not_contains "$(cat -- "$tmp/verdict.out")" 'verdict=findings' \
    'a blocked review is never reported as a completed one'

config="$repo/.agent/config.env"

# --- a declared reviewer overrides the peer-CLI default (issue #452) -------
# The peer (claude) is present and would normally be selected -- proving the
# declaration wins over it, not merely agrees with it, is the actual test.
write_contract codex claude "present path=$tmp/fake-claude"
printf 'AGENT_ADVERSARIAL_REVIEWER=codex\nAGENT_ADVERSARIAL_REVIEW_MODEL=gpt-5.6-sol\nAGENT_ADVERSARIAL_REVIEW_EFFORT=xhigh\n' \
    >"$config"
declared_run="$tmp/declared-run"
grant "$declared_run" openai
declared_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$declared_run") \
    >"$tmp/declared.out" 2>"$tmp/declared.err" || declared_rc=$?
assert_eq 0 "$declared_rc" 'a declared, available reviewer completes'
assert_contains "$(cat -- "$tmp/declared.out")" 'provider=openai' \
    'AGENT_ADVERSARIAL_REVIEWER overrides the peer-CLI provider'
assert_contains "$(cat -- "$tmp/declared.out")" 'model=gpt-5.6-sol' \
    'AGENT_ADVERSARIAL_REVIEW_MODEL overrides the hardcoded model'
assert_contains "$(cat -- "$tmp/declared.out")" 'effort=xhigh' \
    'AGENT_ADVERSARIAL_REVIEW_EFFORT overrides the hardcoded effort'
assert_contains "$(cat -- "$tmp/declared.out")" 'mode=blind-fallback' \
    'declaring the running harness itself as reviewer is blind-fallback mode'

# --- a declared reviewer absent on this machine falls back and says so -----
# The contract already probed the peer once and recorded it absent; the
# declaration must not silently launch a CLI the contract says is not there.
write_contract claude codex 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
printf 'AGENT_ADVERSARIAL_REVIEWER=codex\nAGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK=custom-fallback-model\nAGENT_ADVERSARIAL_REVIEW_EFFORT=medium\n' \
    >"$config"
absent_run="$tmp/absent-run"
grant "$absent_run" anthropic
absent_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$absent_run") \
    >"$tmp/absent.out" 2>"$tmp/absent.err" || absent_rc=$?
assert_eq 0 "$absent_rc" 'a declared but absent reviewer still completes via fallback'
assert_contains "$(cat -- "$tmp/absent.err")" "declared adversarial reviewer 'codex'" \
    'the fallback is announced, naming the declared reviewer'
assert_contains "$(cat -- "$tmp/absent.err")" 'not available on this machine' \
    'the announcement explains why it fell back'
assert_contains "$(cat -- "$tmp/absent.err")" "falling back to the running harness 'claude'" \
    'the announcement names the fallback target'
assert_contains "$(cat -- "$tmp/absent.out")" 'provider=anthropic' \
    'the fallback lands on the running harness provider, not the absent one'
assert_contains "$(cat -- "$tmp/absent.out")" 'model=custom-fallback-model' \
    'AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK supplies the fallback model'
assert_contains "$(cat -- "$tmp/absent.out")" 'effort=medium' \
    'AGENT_ADVERSARIAL_REVIEW_EFFORT still applies to the fallback'
assert_contains "$(cat -- "$tmp/absent.out")" 'mode=blind-fallback' \
    'an absent-reviewer fallback can never be reported as cross-provider'

# --- the same absence, with no fallback model declared ----------------------
# Falls back to that CLI's ordinary built-in default rather than an empty model.
printf 'AGENT_ADVERSARIAL_REVIEWER=codex\n' >"$config"
nofallback_run="$tmp/nofallback-run"
grant "$nofallback_run" anthropic
nofallback_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$nofallback_run") \
    >"$tmp/nofallback.out" 2>"$tmp/nofallback.err" || nofallback_rc=$?
assert_eq 0 "$nofallback_rc" 'absence with no declared fallback model still completes'
assert_contains "$(cat -- "$tmp/nofallback.out")" 'model=claude-opus-5' \
    'with no AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK, the fallback CLI keeps its own built-in default'

# --- an invalid declared reviewer is refused, not silently substituted ------
# repo-config.sh drops it (naming the accepted set on its own stderr) before
# adversarial-run.sh ever sees it, so this must behave exactly like no
# declaration at all: the peer-CLI default, byte-identical.
write_contract codex claude "present path=$tmp/fake-claude"
printf 'AGENT_ADVERSARIAL_REVIEWER=gemini\n' >"$config"
invalid_reviewer_run="$tmp/invalid-reviewer-run"
grant "$invalid_reviewer_run" anthropic
invalid_reviewer_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$invalid_reviewer_run") \
    >"$tmp/invalid-reviewer.out" 2>"$tmp/invalid-reviewer.err" || invalid_reviewer_rc=$?
assert_eq 0 "$invalid_reviewer_rc" 'an invalid declared reviewer still completes via the default'
assert_contains "$(cat -- "$tmp/invalid-reviewer.out")" 'provider=anthropic' \
    'an invalid AGENT_ADVERSARIAL_REVIEWER falls through to the peer-CLI default provider'
assert_contains "$(cat -- "$tmp/invalid-reviewer.out")" 'mode=cross-provider' \
    'an invalid declaration is never treated as an availability fallback'
assert_not_contains "$(cat -- "$tmp/invalid-reviewer.err")" 'AGENT_ADVERSARIAL_REVIEWER' \
    'adversarial-run.sh itself says nothing about a value repo-config.sh already dropped'

# --- AGENT_ADVERSARIAL_REVIEW_MODEL alone, with no REVIEWER declared -------
# A bare model id has no CLI to be interpreted against; the peer-CLI default
# selection (and its own default model) must stay byte-identical.
printf 'AGENT_ADVERSARIAL_REVIEW_MODEL=should-be-ignored\n' >"$config"
bare_model_run="$tmp/bare-model-run"
grant "$bare_model_run" anthropic
bare_model_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$bare_model_run") \
    >"$tmp/bare-model.out" 2>"$tmp/bare-model.err" || bare_model_rc=$?
assert_eq 0 "$bare_model_rc" 'an undeclared reviewer with a bare model id still completes'
assert_contains "$(cat -- "$tmp/bare-model.out")" 'model=claude-opus-5' \
    'a bare AGENT_ADVERSARIAL_REVIEW_MODEL is ignored without a declared reviewer'
assert_contains "$(cat -- "$tmp/bare-model.out")" 'mode=cross-provider' \
    'the peer-CLI default selection is unaffected'

rm -f -- "$config"

# A tracked `.agent` symlink bypasses leaf-only provenance checks: Git tracks
# the link itself, not the resolved `.agent/env-contract.txt` path. The runner
# must reject it before consulting attacker-controlled reviewer facts or
# invoking the external reviewer CLI.
rm -rf -- "$repo/.agent"
mkdir -- "$repo/contract-redirect"
ln -s contract-redirect "$repo/.agent"
write_contract codex claude "present path=$tmp/fake-claude"
git -C "$repo" add -- .agent contract-redirect/env-contract.txt
git -C "$repo" commit --quiet -m 'test: track redirected environment contract'
FAKE_HEAD_OID=$(git -C "$repo" rev-parse HEAD)
export FAKE_HEAD_OID
redirect_expected="$tmp/redirect.expected.diff"
git -C "$repo" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$redirect_expected"
redirect_run="$tmp/tracked-parent-symlink-run"
grant "$redirect_run" anthropic "$redirect_expected"
redirect_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/tracked-parent-symlink.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$redirect_run") \
    >"$tmp/tracked-parent-symlink.out" 2>"$tmp/tracked-parent-symlink.err" || redirect_rc=$?
assert_eq 1 "$redirect_rc" 'tracked environment-contract parent symlink is rejected'
assert_contains "$(cat -- "$tmp/tracked-parent-symlink.err")" \
    'environment contract directory is a symlink' \
    'tracked parent symlink names the provenance violation'
assert_eq no "$( [[ -e $tmp/tracked-parent-symlink.called ]] && printf yes || printf no )" \
    'tracked parent symlink never launches the reviewer CLI'

finish
