#!/usr/bin/env bash
# Regression coverage for private review-artifact creation.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='review artifact isolation'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

claude="$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh"
codex="$root/agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh"
state="$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh"
skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
state_text=$(<"$state")

run_rejected() {
    local helper=$1 transcript=$2 stderr_file=$3
    local rc=0
    if [[ $helper == *claude* ]]; then
        CLAUDE_EXECUTABLE=/definitely/missing/claude \
            bash "$helper" --mode probe --model claude-opus-5 \
            --transcript "$transcript" > /dev/null 2>"$stderr_file" || rc=$?
    else
        CODEX_EXECUTABLE=/definitely/missing/codex \
            bash "$helper" --mode probe --model gpt-5.6-terra \
            --transcript "$transcript" > /dev/null 2>"$stderr_file" || rc=$?
    fi
    printf '%s' "$rc"
}

for helper in "$claude" "$codex"; do
    name=${helper##*/}
    shared_target="/tmp/agentkit-review-artifacts-${BASHPID}-${name}.shared"
    shared_err="$tmp/${name}.shared.err"
    rc=$(run_rejected "$helper" "$shared_target" "$shared_err")
    assert_eq 1 "$rc" "$name rejects a transcript in shared /tmp"
    assert_contains "$(cat -- "$shared_err")" '0700' "$name explains the private-directory requirement"
    assert_not_contains "$(cat -- "$shared_err")" 'BLOCKED' "$name rejects the path before invoking the CLI"
    rm -f -- "$shared_target"

    private_dir="$tmp/${name}.run"
    mkdir -- "$private_dir"
    chmod 700 -- "$private_dir"
    target="$private_dir/target"
    transcript="$private_dir/transcript"
    printf 'do not overwrite\n' > "$target"
    ln -s -- "$target" "$transcript"
    err="$tmp/${name}.symlink.err"
    rc=$(run_rejected "$helper" "$transcript" "$err")
    assert_eq 1 "$rc" "$name rejects a pre-existing transcript symlink"
    assert_eq 'do not overwrite' "$(<"$target")" "$name never follows the transcript symlink"

    rm -- "$transcript"
    transcript="$private_dir/fresh"
    rc=$(run_rejected "$helper" "$transcript" "$err")
    assert_eq 3 "$rc" "$name reaches CLI preflight only after securing a private transcript"
    assert_eq 600 "$(stat -c %a -- "$transcript")" "$name creates transcript with mode 0600"
    assert_eq 0 "$(wc -c <"$transcript")" "$name starts with an empty transcript"

    rc=$(run_rejected "$helper" "$transcript" "$err")
    assert_eq 3 "$rc" "$name safely refreshes an owned regular transcript"

done

assert_contains "$state_text" "[[ ! -L \$target ]]" \
    'gh-pr-state refuses artifact symlinks before refresh'
assert_contains "$state_text" "[[ ! -e \$target || ( -f \$target && -O \$target) ]]" \
    'gh-pr-state refreshes only owned regular-file artifacts'
assert_contains "$state_text" "mv -f -- \"\$staged\" \"\$target\"" \
    'gh-pr-state atomically replaces refreshed artifacts'

state_err="$tmp/gh-pr-state.err"
state_rc=0
bash "$state" --pr 1 --repo owner/repo --full --tmpdir /tmp \
    > /dev/null 2>"$state_err" || state_rc=$?
assert_eq 1 "$state_rc" 'gh-pr-state rejects shared /tmp for durable artifacts'
assert_contains "$(cat -- "$state_err")" '0700' 'gh-pr-state names the private directory requirement'

gh() {
    if [[ ${1:-} == pr && ${2:-} == view ]]; then
        printf '%s\n' '{"number":1,"isDraft":true,"mergeable":"MERGEABLE","headRefName":"feat/test","headRefOid":"deadbeef","statusCheckRollup":[]}'
    elif [[ ${1:-} == api && ${2:-} == graphql ]]; then
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
    else
        printf '%s\n' '[]'
    fi
}
export -f gh

owned_dir_run="$tmp/owned-dir.run"
mkdir -- "$owned_dir_run"
chmod 700 -- "$owned_dir_run"
mkdir -- "$owned_dir_run/pr_1_reviews.json"
printf 'keep this directory\n' > "$owned_dir_run/pr_1_reviews.json/sentinel"
owned_dir_err="$tmp/owned-dir.err"
owned_dir_rc=0
bash "$state" --pr 1 --repo owner/repo --full --tmpdir "$owned_dir_run" \
    > /dev/null 2>"$owned_dir_err" || owned_dir_rc=$?
assert_eq 1 "$owned_dir_rc" 'gh-pr-state rejects an owned directory artifact target'
assert_contains "$(cat -- "$owned_dir_err")" 'owned regular file' \
    'gh-pr-state explains the artifact type requirement'
assert_eq 'keep this directory' "$(<"$owned_dir_run/pr_1_reviews.json/sentinel")" \
    'gh-pr-state rejects the directory before publication'

skill_text=$(<"$skill")

# The skill's wrappers stage a verdict before publication. Environment-blocked
# rc=3 is special: its JSON tells the caller whether to fall back or retry, so
# it must survive. Every other failed producer remains non-canonical.
publish_verdict() {
    local producer=$1 verdict_path=$2 verdict_tmp="$2.tmp" rc=0
    rm -f -- "$verdict_path" "$verdict_tmp"
    if "$producer" >"$verdict_tmp"; then
        mv -f -- "$verdict_tmp" "$verdict_path"
    else
        rc=$?
        if ((rc == 3)); then
            mv -f -- "$verdict_tmp" "$verdict_path"
        else
            rm -f -- "$verdict_path" "$verdict_tmp"
        fi
        return "$rc"
    fi
}

blocked_producer="$tmp/blocked-producer.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "{\"status\":\"blocked\"}"' 'exit 3' >"$blocked_producer"
chmod +x "$blocked_producer"
blocked_verdict="$tmp/blocked.result.json"
blocked_rc=0
publish_verdict "$blocked_producer" "$blocked_verdict" || blocked_rc=$?
assert_eq 3 "$blocked_rc" 'an environment-blocked review retains its rc'
assert_eq '{"status":"blocked"}' "$(<"$blocked_verdict")" \
    'an environment-blocked review publishes its JSON artifact'
assert_eq no "$( [[ ! -e "$blocked_verdict.tmp" ]] && printf no || printf yes )" \
    'an environment-blocked review removes its temporary artifact'

failed_producer="$tmp/failed-producer.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" partial' 'exit 1' >"$failed_producer"
chmod +x "$failed_producer"
failed_verdict="$tmp/failed.result.json"
failed_rc=0
publish_verdict "$failed_producer" "$failed_verdict" || failed_rc=$?
assert_eq 1 "$failed_rc" 'a non-blocked review failure retains its rc'
assert_eq no "$( [[ ! -e "$failed_verdict" ]] && printf no || printf yes )" \
    'a non-blocked review failure leaves no final artifact'
assert_eq no "$( [[ ! -e "$failed_verdict.tmp" ]] && printf no || printf yes )" \
    'a non-blocked review failure removes its temporary artifact'

assert_contains "$skill_text" "mktemp -d \"\${TMPDIR:-/tmp}/review-remote-pr." \
    'the skill creates a random per-run artifact directory'
assert_contains "$skill_text" "chmod 700 -- \"\$RUN_DIR\"" \
    'the skill explicitly secures the run directory'
assert_not_contains "$skill_text" "claude_pr_\${PR}" \
    'the skill no longer uses PR-number-only Claude artifact paths'
assert_not_contains "$skill_text" "/tmp/pr_\${PR}_" \
    'the skill no longer uses shared PR-number-only state paths'
assert_contains "$skill_text" 're-set RUN_DIR to the Step 0c output; shell state does not persist' \
    'the skill guards per-shell review-artifact directory reuse'
assert_contains "$skill_text" "diff_path=\"\$RUN_DIR/adversarial.diff\"" \
    'the skill names one shared adversarial diff artifact'
assert_contains "$skill_text" "verdict_path=\"\$RUN_DIR/adversarial.result.json\"" \
    'the skill names one neutral adversarial verdict artifact'
assert_contains "$skill_text" 'verdict_tmp="$verdict_path.tmp"' \
    'the skill stages adversarial verdicts beside the final artifact'
assert_contains "$skill_text" 'mv -f -- "$verdict_tmp" "$verdict_path"' \
    'the skill publishes verdicts atomically after producer success'
assert_eq 2 "$(grep -Fc 'if ((review_rc == 3)); then' "$skill")" \
    'both adversarial wrappers publish their rc=3 blocked artifacts'
assert_contains "$skill_text" 'A final file' \
    'the skill defines completion by terminal producer events'
assert_contains "$skill_text" 'cross-cell heartbeat fallback' \
    'the skill documents the cross-cell heartbeat fallback'
assert_contains "$skill_text" '2 * --poll-seconds' \
    'the skill pins the heartbeat freshness window'
assert_contains "$skill_text" 'zero transcript growth across' \
    'the skill requires two unchanged byte samples before declaring death'
assert_contains "$skill_text" 'relaunch exactly once' \
    'the skill bounds relaunches to one after the death predicate'
assert_contains "$skill_text" 'launcher reports a terminal child' \
    'the skill prefers native launcher terminal state'
assert_not_contains "$skill_text" 'kill -0' \
    'the skill never recommends cross-cell PID probes'
assert_contains "$skill_text" 'bounded in both directions' \
    'the skill bounds the wait against both stalls and premature verdicts'
assert_not_contains "$skill_text" '>"$verdict_path"' \
    'the skill never streams directly into the final verdict path'
assert_not_contains "$skill_text" 'claude.result.json' \
    'the skill has no Claude-specific verdict path'
assert_not_contains "$skill_text" 'codex.result.json' \
    'the skill has no Codex-specific verdict path'

for helper in "$claude" "$codex"; do
    helper_text=$(<"$helper")
    helper_name=${helper##*/}
    assert_contains "$helper_text" 'STATUS_FILE="$TRANSCRIPT_PATH.status"' \
        "$helper_name derives the status sidecar beside the transcript"
    assert_contains "$helper_text" 'mv -f -- "$STATUS_TMP" "$STATUS_FILE"' \
        "$helper_name publishes status atomically in the transcript directory"
    assert_contains "$helper_text" 'wallClockEpoch' \
        "$helper_name records the wall-clock epoch in status"
    assert_contains "$helper_text" 'rm -f -- "$STATUS_FILE"' \
        "$helper_name removes status during cleanup"
done
diff_pattern="git --no-pager diff.*\"\\\$diff_path\""
diff_line=$(grep -n "$diff_pattern" "$skill" | head -1 | cut -d: -f1)
probe_line=$(grep -n '^probe_rc=0$' "$skill" | head -1 | cut -d: -f1)
if ((diff_line < probe_line)); then
    _pass 'the shared diff is created before probe branching'
else
    _fail 'the shared diff is created before probe branching' \
        "diff line: $diff_line" "probe line: $probe_line"
fi

finish
