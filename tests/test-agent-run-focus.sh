#!/usr/bin/env bash
# Suite: agent-run.sh focused-test declaration, forwarding, and cache identity.
set -uo pipefail

TEST_NAME='agent-run-focus'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir=$1 origin=$tmp/origin
    git init -q -b main "$dir"
    git -C "$dir" config user.name test
    git -C "$dir" config user.email test@example.invalid
    mkdir -p "$dir/.agent" "$dir/tools"
    cat >"$dir/tools/full" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$FULL_COUNT" 2>/dev/null || printf '0')
printf '%s' "$((count + 1))" >"$FULL_COUNT"
printf 'full suite\n'
EOF
    cat >"$dir/tools/focused" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$FOCUS_COUNT" 2>/dev/null || printf '0')
printf '%s' "$((count + 1))" >"$FOCUS_COUNT"
printf 'focused args: %s\n' "$*"
EOF
    chmod +x "$dir/tools/full" "$dir/tools/focused"
    printf 'AGENT_CMD_TEST=tools/full\nAGENT_CMD_TEST_FOCUS=tools/focused --only %%s\n' \
        >"$dir/.agent/config.env"
    printf '.agent/*\n!.agent/config.env\n' >"$dir/.gitignore"
    git -C "$dir" add -- .agent/config.env .gitignore tools
    git -C "$dir" commit -qm base
    git init -q --bare "$origin"
    git -C "$dir" remote add origin "$origin"
    git -C "$dir" push -q origin HEAD:main
    git -C "$dir" fetch -q origin
}

make_runner_focus_repo() {
    local dir=$1 origin=$tmp/runner-origin
    git init -q -b main "$dir"
    git -C "$dir" config user.name test
    git -C "$dir" config user.email test@example.invalid
    mkdir -p "$dir/.agent" "$dir/tools"
    cat >"$dir/tools/focused" <<'EOF'
#!/usr/bin/env bash
printf 'direct-focused:%s\n' "$*"
EOF
    cat >"$dir/tools/runner" <<'EOF'
#!/usr/bin/env bash
printf 'runner-received:%s\n' "$*"
exit 99
EOF
    chmod +x "$dir/tools/focused" "$dir/tools/runner"
    printf 'AGENT_REPO_RUNNER=tools/runner\nAGENT_CMD_TEST_FOCUS=tools/focused --only %%s\n' \
        >"$dir/.agent/config.env"
    git -C "$dir" add -- .agent/config.env tools
    git -C "$dir" commit -qm base
    git init -q --bare "$origin"
    git -C "$dir" remote add origin "$origin"
    git -C "$dir" push -q origin HEAD:main
    git -C "$dir" fetch -q origin
}

repo=$tmp/repo
make_repo "$repo"
full_count=$tmp/full-count
focus_count=$tmp/focus-count

run_test() {
    (cd "$repo" && FULL_COUNT="$full_count" FOCUS_COUNT="$focus_count" \
        "$run_sh" --cmd test --yolo "$@" 2>&1)
}

out=$(run_test)
assert_contains "$out" 'PASS: tools/full' 'the full declaration still runs without focus'
assert_eq '1' "$(cat "$full_count")" 'the full declaration executes once'

out=$(run_test --only unit,smoke)
assert_contains "$out" 'PASS: tools/focused --only unit,smoke' \
    'the focused declaration receives the selected names'
assert_eq '1' "$(cat "$focus_count")" 'the focused declaration executes once'
assert_contains "$(<"$repo/.agent/verification-cache")" 'focus=unit,smoke' \
    'focused evidence records the focus set in its cache identity'
assert_not_contains "$out" 'verification current:' 'a focused green run does not reuse full evidence'

out=$(run_test --only unit,smoke)
assert_contains "$out" 'verification current:' 'an unchanged focused run may reuse focused evidence'
assert_eq '1' "$(cat "$focus_count")" 'a focused cache hit does not execute again'

out=$(run_test)
assert_contains "$out" 'verification current:' 'focused evidence does not replace full-suite evidence'
assert_eq '1' "$(cat "$full_count")" 'the unchanged full run remains cached independently'

# A repository without the opt-in focus declaration must fail before running
# its ordinary test command.
missing=$tmp/missing
git init -q -b main "$missing"
git -C "$missing" config user.name test
git -C "$missing" config user.email test@example.invalid
mkdir -p "$missing/.agent" "$missing/tools"
printf '#!/usr/bin/env bash\nexit 0\n' >"$missing/tools/full"
chmod +x "$missing/tools/full"
printf 'AGENT_CMD_TEST=tools/full\n' >"$missing/.agent/config.env"
git -C "$missing" add -- .agent/config.env tools/full
git -C "$missing" commit -qm base
rc=0
out=$(cd "$missing" && "$run_sh" --cmd test --only unit --yolo 2>&1) || rc=$?
assert_eq '1' "$rc" 'focus is usage-invalid without its declaration'
assert_contains "$out" 'AGENT_CMD_TEST_FOCUS' 'the usage error names the missing declaration'

# Focus may be the repository's only test declaration when a generic runner is
# present; it must execute the focused argv directly rather than delegating the
# declaration argv back to the runner as a subcommand.
runner_repo=$tmp/runner-repo
make_runner_focus_repo "$runner_repo"
rc=0
out=$(cd "$runner_repo" && "$run_sh" --cmd test --only unit --yolo 2>&1) || rc=$?
assert_eq '0' "$rc" 'focus declaration executes directly with a repository runner'
assert_contains "$out" 'PASS: tools/focused --only unit' \
    'runner fallback does not receive the focused declaration as a subcommand'
assert_not_contains "$out" 'runner-received:' 'focused declaration bypasses the generic runner'

# Focus and full approvals are separate records and remain usable independently.
trust_root=$tmp/trust
tty_approve="$here/lib/tty-approve"
(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$run_sh" --approve --cmd test) > /dev/null 2>&1
(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$run_sh" --approve --cmd test --only unit,smoke) > /dev/null 2>&1
assert_eq '2' "$(find "$trust_root" -type f -name '*.trust' | wc -l | tr -d ' ')" \
    'full and focused approvals persist as separate trust records'
out=$(cd "$repo" && FULL_COUNT="$full_count" FOCUS_COUNT="$focus_count" \
    AGENT_TRUST_ROOT="$trust_root" "$run_sh" --force --cmd test 2>&1)
assert_contains "$out" 'PASS: tools/full' 'the approved full command remains executable'
out=$(cd "$repo" && FULL_COUNT="$full_count" FOCUS_COUNT="$focus_count" \
    AGENT_TRUST_ROOT="$trust_root" "$run_sh" --force --cmd test --only unit,smoke 2>&1)
assert_contains "$out" 'PASS: tools/focused --only unit,smoke' \
    'the approved focused command remains executable'

# --only is a named-command option, not a literal-command option, and an empty
# selector must fail before trust, cache, or execution.
rc=0
out=$(cd "$repo" && "$run_sh" --only unit -- echo literal 2>&1) || rc=$?
assert_eq '1' "$rc" 'literal commands reject --only'
assert_contains "$out" '--only requires --cmd test' 'literal focus usage names its contract'
rc=0
out=$(cd "$repo" && "$run_sh" --only '' --cmd test --yolo 2>&1) || rc=$?
assert_eq '1' "$rc" 'empty --only is rejected'
assert_contains "$out" 'non-empty' 'empty focus usage explains the required value'

finish
