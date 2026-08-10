#!/usr/bin/env bash
# Regression coverage for private review-artifact creation.
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
done

state_err="$tmp/gh-pr-state.err"
state_rc=0
bash "$state" --pr 1 --repo owner/repo --full --tmpdir /tmp \
    > /dev/null 2>"$state_err" || state_rc=$?
assert_eq 1 "$state_rc" 'gh-pr-state rejects shared /tmp for durable artifacts'
assert_contains "$(cat -- "$state_err")" '0700' 'gh-pr-state names the private directory requirement'

skill_text=$(<"$skill")
assert_contains "$skill_text" "mktemp -d \"\${TMPDIR:-/tmp}/review-remote-pr." \
    'the skill creates a random per-run artifact directory'
assert_contains "$skill_text" "chmod 700 -- \"\$RUN_DIR\"" \
    'the skill explicitly secures the run directory'
assert_not_contains "$skill_text" "claude_pr_\${PR}" \
    'the skill no longer uses PR-number-only Claude artifact paths'
assert_not_contains "$skill_text" "/tmp/pr_\${PR}_" \
    'the skill no longer uses shared PR-number-only state paths'

finish
