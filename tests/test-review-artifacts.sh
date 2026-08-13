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
review_lib="$root/agentkit/skills/.shared/scripts/lib/adversarial-review.sh"
skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
state_text=$(<"$state")
review_lib_text=$(<"$review_lib")

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

# --output: the helper's own atomic-publish flag. Covers the Claude helper's
# fixture path (rc 0 publish, rc 3 publish, rc 1 leaves no file, unsafe
# directory refusal), reusing the same fake-CLI fixture technique the bounds
# suite already established rather than inventing a new one.
output_diff="$tmp/output.diff"
printf '%s\n' 'diff --git a/example.txt b/example.txt' '+safe' >"$output_diff"

cat >"$tmp/fake-claude-output-success" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-test","tools":["StructuredOutput"],"mcp_servers":[]}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"no_findings","findings":[]},"modelUsage":{"claude-test":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
EOF
chmod +x "$tmp/fake-claude-output-success"

cat >"$tmp/fake-claude-output-hang" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
sleep 5
EOF
chmod +x "$tmp/fake-claude-output-hang"

output_run="$tmp/output.run"
mkdir -- "$output_run"
chmod 700 -- "$output_run"

# --output is documented as ADDITIVE, so it must not be allowed to name another
# artifact. prepare_output runs after prepare_transcript and clears a
# pre-existing target, so aliasing the transcript deleted the raw audit trail
# the verdict is meant to be checkable against -- silently, before the reviewer
# had even run. Both helpers reject it, and the check is canonical so a
# relative spelling of the same file cannot slip past.
for alias_helper in "$claude" "$codex"; do
    alias_name=$(basename "$alias_helper" | cut -d- -f1)
    alias_transcript="$output_run/$alias_name-alias.transcript"
    alias_rc=0
    bash "$alias_helper" --mode review --model m --diff "$output_diff" \
        --transcript "$alias_transcript" --output "$alias_transcript" \
        > "$tmp/$alias_name-alias.out" 2> "$tmp/$alias_name-alias.err" || alias_rc=$?
    assert_eq 1 "$alias_rc" "--output: $alias_name rejects an --output that aliases --transcript"
    assert_contains "$(cat "$tmp/$alias_name-alias.err")" 'must not alias another artifact' \
        "--output: $alias_name says the paths alias"

    alias_rel_rc=0
    ( cd "$output_run" && bash "$alias_helper" --mode review --model m \
        --diff "$output_diff" --transcript "$alias_name-rel.transcript" \
        --output "./$alias_name-rel.transcript" ) \
        > /dev/null 2> "$tmp/$alias_name-rel.err" || alias_rel_rc=$?
    assert_eq 1 "$alias_rel_rc" "--output: $alias_name rejects a relative alias of the transcript"

    for status_alias in "$alias_transcript.status" "$alias_transcript.status.tmp"; do
        status_rc=0
        bash "$alias_helper" --mode review --model m --diff "$output_diff" \
            --transcript "$alias_transcript" --output "$status_alias" \
            > /dev/null 2> "$tmp/$alias_name-status.err" || status_rc=$?
        assert_eq 1 "$status_rc" \
            "--output: $alias_name rejects an --output aliasing $(basename "$status_alias")"
    done

    alias_diff_rc=0
    bash "$alias_helper" --mode review --model m --diff "$output_diff" \
        --transcript "$output_run/$alias_name-diffalias.transcript" \
        --output "$output_diff" > /dev/null 2> "$tmp/$alias_name-diffalias.err" || alias_diff_rc=$?
    assert_eq 1 "$alias_diff_rc" "--output: $alias_name rejects an --output that aliases --diff"
    assert_eq yes "$( [[ -s $output_diff ]] && printf yes || printf no )" \
        "--output: $alias_name leaves the diff intact after refusing"
done

# rc 0: the completed verdict is published atomically beside the transcript.
success_output="$output_run/success.result.json"
success_stdout="$tmp/output-success.stdout"
success_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude-output-success" bash "$claude" \
    --mode review --model claude-test --diff "$output_diff" \
    --transcript "$output_run/success.transcript" --poll-seconds 1 \
    --max-duration-seconds 30 --max-budget-usd 0.25 \
    --output "$success_output" >"$success_stdout" || success_rc=$?
assert_eq 0 "$success_rc" '--output: a completed review still exits 0'
assert_eq no "$( [[ ! -e "$success_output.tmp" ]] && printf no || printf yes )" \
    '--output: a completed review leaves no temporary artifact'
assert_eq yes "$( [[ -f $success_output ]] && printf yes || printf no )" \
    '--output: a completed review publishes the output artifact'
assert_eq 600 "$(stat -c %a -- "$success_output")" \
    '--output: the published completed artifact is mode 0600'
assert_eq "$(<"$success_stdout")" "$(<"$success_output")" \
    '--output: the published completed artifact matches stdout exactly'
assert_contains "$(<"$success_output")" '"status": "completed"' \
    '--output: the published artifact carries the completed status'

# rc 3: environment-blocked still publishes its JSON, same as stdout.
blocked_output="$output_run/blocked.result.json"
blocked_stdout="$tmp/output-blocked.stdout"
blocked_rc=0
CLAUDE_EXECUTABLE=/definitely/missing/claude bash "$claude" \
    --mode probe --model claude-test \
    --transcript "$output_run/blocked.transcript" \
    --output "$blocked_output" >"$blocked_stdout" 2>/dev/null || blocked_rc=$?
assert_eq 3 "$blocked_rc" '--output: an environment-blocked review still exits 3'
assert_eq no "$( [[ ! -e "$blocked_output.tmp" ]] && printf no || printf yes )" \
    '--output: a blocked review leaves no temporary artifact'
assert_eq "$(<"$blocked_stdout")" "$(<"$blocked_output")" \
    '--output: the published blocked artifact matches stdout exactly'
assert_contains "$(<"$blocked_output")" '"status":"blocked"' \
    '--output: the published artifact carries the blocked status'

# rc 1: a real failure (duration ceiling) publishes nothing at all.
failure_output="$output_run/failure.result.json"
failure_err="$tmp/output-failure.err"
failure_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude-output-hang" bash "$claude" \
    --mode probe --model claude-test \
    --transcript "$output_run/failure.transcript" --poll-seconds 1 \
    --max-duration-seconds 1 --output "$failure_output" \
    >/dev/null 2>"$failure_err" || failure_rc=$?
assert_eq 1 "$failure_rc" '--output: a real review failure still exits 1'
assert_eq no "$( [[ ! -e "$failure_output" ]] && printf no || printf yes )" \
    '--output: a real review failure leaves no output artifact'
assert_eq no "$( [[ ! -e "$failure_output.tmp" ]] && printf no || printf yes )" \
    '--output: a real review failure leaves no temporary artifact'

# Unsafe output directory: refused before the CLI is ever invoked (mode 0755,
# not 0700 -- the same bar prepare_transcript already enforces on its own
# directory), regardless of whether the reviewer binary exists.
unsafe_dir="$tmp/output-unsafe-dir"
mkdir -- "$unsafe_dir"
chmod 755 -- "$unsafe_dir"
unsafe_output="$unsafe_dir/result.json"
unsafe_err="$tmp/output-unsafe.err"
unsafe_rc=0
CLAUDE_EXECUTABLE=/definitely/missing/claude bash "$claude" \
    --mode probe --model claude-test \
    --transcript "$output_run/unsafe.transcript" \
    --output "$unsafe_output" >/dev/null 2>"$unsafe_err" || unsafe_rc=$?
assert_eq 1 "$unsafe_rc" '--output: an unsafe output directory is refused'
assert_contains "$(<"$unsafe_err")" '0700' \
    '--output: the refusal names the private-directory requirement'
assert_not_contains "$(<"$unsafe_err")" 'BLOCKED' \
    '--output: the unsafe directory is refused before invoking the CLI'
assert_eq no "$( [[ ! -e "$unsafe_output" ]] && printf no || printf yes )" \
    '--output: an unsafe output directory never receives an artifact'

# Codex --output behavioral coverage: same rc-0/rc-3 fixture technique as the
# Claude helper above, reusing the fake-codex-success fixture from
# test-adversarial-review-bounds.sh. publish_output()/prepare_output() are
# independently maintained copies in each script, so Claude fixture coverage
# alone does not exercise a codex-only regression (wrong variable, corrupted
# body, chmod-after-mv).
cat >"$tmp/fake-codex-output-success" <<'EOF'
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
    if [[ $1 == --output-last-message ]]; then
        last_file=$2
        shift 2
    else
        shift
    fi
done
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}'
printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
EOF
chmod +x "$tmp/fake-codex-output-success"

codex_success_output="$output_run/codex-success.result.json"
codex_success_stdout="$tmp/codex-output-success.stdout"
codex_success_rc=0
CODEX_EXECUTABLE="$tmp/fake-codex-output-success" bash "$codex" \
    --mode review --model gpt-test --diff "$output_diff" \
    --transcript "$output_run/codex-success.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-tokens 1024 \
    --output "$codex_success_output" >"$codex_success_stdout" || codex_success_rc=$?
assert_eq 0 "$codex_success_rc" 'Codex --output: a completed review still exits 0'
assert_eq no "$( [[ ! -e "$codex_success_output.tmp" ]] && printf no || printf yes )" \
    'Codex --output: a completed review leaves no temporary artifact'
assert_eq yes "$( [[ -f $codex_success_output ]] && printf yes || printf no )" \
    'Codex --output: a completed review publishes the output artifact'
assert_eq 600 "$(stat -c %a -- "$codex_success_output")" \
    'Codex --output: the published completed artifact is mode 0600'
assert_eq "$(<"$codex_success_stdout")" "$(<"$codex_success_output")" \
    'Codex --output: the published completed artifact matches stdout exactly'
assert_contains "$(<"$codex_success_output")" '"status": "completed"' \
    'Codex --output: the published artifact carries the completed status'

# rc 3: environment-blocked (missing codex binary) still publishes its JSON.
codex_blocked_output="$output_run/codex-blocked.result.json"
codex_blocked_stdout="$tmp/codex-output-blocked.stdout"
codex_blocked_rc=0
CODEX_EXECUTABLE=/definitely/missing/codex bash "$codex" \
    --mode probe --model gpt-test \
    --transcript "$output_run/codex-blocked.jsonl" \
    --output "$codex_blocked_output" >"$codex_blocked_stdout" 2>/dev/null || codex_blocked_rc=$?
assert_eq 3 "$codex_blocked_rc" 'Codex --output: an environment-blocked review still exits 3'
assert_eq no "$( [[ ! -e "$codex_blocked_output.tmp" ]] && printf no || printf yes )" \
    'Codex --output: a blocked review leaves no temporary artifact'
assert_eq "$(<"$codex_blocked_stdout")" "$(<"$codex_blocked_output")" \
    'Codex --output: the published blocked artifact matches stdout exactly'
assert_contains "$(<"$codex_blocked_output")" '"status":"blocked"' \
    'Codex --output: the published artifact carries the blocked status'

for helper in "$claude" "$codex"; do
    helper_text=$(<"$helper")
    helper_name=${helper##*/}
    assert_contains "$helper_text" '--output) require_value'         "$helper_name accepts an --output flag"
    assert_contains "$helper_text" 'review_publish_output "$final_json"'         "$helper_name delegates completed publication to the shared library"
    assert_contains "$helper_text" 'source "$SCRIPT_DIR/../../.shared/scripts/lib/adversarial-review.sh"'         "$helper_name sources the shared lifecycle library"
    assert_not_contains "$helper_text" 'publish_output() {'         "$helper_name has no duplicate publication implementation"
    assert_not_contains "$helper_text" 'prepare_transcript() {'         "$helper_name has no duplicate transcript implementation"
    assert_not_contains "$helper_text" 'verify_verdict() {'         "$helper_name has no duplicate verdict implementation"
done

assert_contains "$review_lib_text" 'review_publish_output() {'     'shared library owns output publication'
assert_contains "$review_lib_text" 'OUTPUT_TMP="$OUTPUT_PATH.tmp"'     'shared library stages output beside the final path'
assert_contains "$review_lib_text" 'mv -f -- "$OUTPUT_TMP" "$OUTPUT_PATH"'     'shared library publishes output atomically'
assert_contains "$review_lib_text" 'review_prepare_transcript() {'     'shared library owns transcript preparation'
assert_contains "$review_lib_text" 'review_cleanup() {'     'shared library owns lifecycle cleanup'
assert_contains "$review_lib_text" 'review_poll_progress() {'     'shared library owns interruptible progress polling'
assert_contains "$review_lib_text" 'review_classify_blocked_reason() {'     'shared library owns blocked-reason classification'
assert_contains "$review_lib_text" 'review_verify_verdict() {'     'shared library owns verdict verification'
assert_contains "$review_lib_text" 'rm -f -- "$STATUS_FILE"' \
    'shared library removes status during cleanup'
assert_contains "$review_lib_text" 'review_publish_output "$json"' \
    'shared library publishes blocked verdict before stdout'
assert_contains "$review_lib_text" 'printf' \
    'shared library emits blocked verdict after publication'
assert_contains "$review_lib_text" '"$json"' \
    'shared library emits the blocked JSON object'
assert_contains "$review_lib_text" 'exit 3'     'shared library preserves blocked exit status'


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
adversarial_ref="$root/agentkit/skills/review-remote-pr/references/adversarial-review.md"
adversarial_text=$(<"$adversarial_ref")
review_refs_dir="$root/agentkit/skills/review-remote-pr/references"
# Negative pins must cover the whole split skill (body + all references) --
# a banned pattern planted in either half is an equally real regression.
skill_union_text=$(cat -- "$skill" "$review_refs_dir"/*.md)

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
assert_not_contains "$skill_union_text" "claude_pr_\${PR}" \
    'the skill no longer uses PR-number-only Claude artifact paths'
assert_not_contains "$skill_union_text" "/tmp/pr_\${PR}_" \
    'the skill no longer uses shared PR-number-only state paths'
assert_contains "$skill_text" 're-set RUN_DIR to the Step 0c output; shell state does not persist' \
    'the skill guards per-shell review-artifact directory reuse'
# The diff/verdict recipe itself now lives in references/adversarial-review.md
# (SKILL.md only names when to read it); the Step 0c artifact-directory pins
# checked above stay targeted at SKILL.md, since that's where they still live.
assert_contains "$adversarial_text" "diff_path=\"\$RUN_DIR/adversarial.diff\"" \
    'the skill names one shared adversarial diff artifact'
assert_contains "$adversarial_text" "verdict_path=\"\$RUN_DIR/adversarial.result.json\"" \
    'the skill names one neutral adversarial verdict artifact'
# Verdict staging/atomic publication is delegated to each wrapper's --output
# flag (see the helper loop above, which checks OUTPUT_TMP staging and the
# rc=3 publish-before-exit ordering in both scripts directly), not
# reimplemented in the reference doc; it only documents that delegation at
# each call site.
assert_eq 2 "$(grep -Fc -- '--output atomically publishes' "$adversarial_ref" || true)" \
    'the skill documents atomic verdict staging at both call sites'
assert_eq 2 "$(grep -Fc 'rc 0 (completed) and rc 3 (blocked), never created or left behind on rc 1.' "$adversarial_ref" || true)" \
    'both adversarial wrappers publish their rc=3 blocked artifacts'
assert_contains "$adversarial_text" 'A final file' \
    'the skill defines completion by terminal producer events'
assert_contains "$adversarial_text" 'cross-cell heartbeat fallback' \
    'the skill documents the cross-cell heartbeat fallback'
assert_contains "$adversarial_text" '2 * --poll-seconds' \
    'the skill pins the heartbeat freshness window'
assert_contains "$adversarial_text" 'zero transcript growth across' \
    'the skill requires two unchanged byte samples before declaring death'
assert_contains "$adversarial_text" 'relaunch exactly once' \
    'the skill bounds relaunches to one after the death predicate'
assert_contains "$adversarial_text" 'launcher reports a terminal child' \
    'the skill prefers native launcher terminal state'
assert_contains "$adversarial_text" 'Without native launcher state, a validated canonical verdict is Completed' \
    'the skill permits detached canonical-verdict completion'
assert_not_contains "$skill_union_text" 'kill -0' \
    'the skill never recommends cross-cell PID probes'
assert_contains "$adversarial_text" 'bounded in both directions' \
    'the skill bounds the wait against both stalls and premature verdicts'
assert_not_contains "$skill_union_text" '>"$verdict_path"' \
    'the skill never streams directly into the final verdict path'
assert_not_contains "$skill_union_text" 'claude.result.json' \
    'the skill has no Claude-specific verdict path'
assert_not_contains "$skill_union_text" 'codex.result.json' \
    'the skill has no Codex-specific verdict path'


diff_pattern="git --no-pager diff.*\"\\\$diff_path\""
diff_line=$(grep -n "$diff_pattern" "$adversarial_ref" | head -1 | cut -d: -f1 || true)
probe_line=$(grep -n '^probe_rc=0$' "$adversarial_ref" | head -1 | cut -d: -f1 || true)
if ((diff_line < probe_line)); then
    _pass 'the shared diff is created before probe branching'
else
    _fail 'the shared diff is created before probe branching' \
        "diff line: $diff_line" "probe line: $probe_line"
fi

finish
