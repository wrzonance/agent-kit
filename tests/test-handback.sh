#!/usr/bin/env bash
# Suite: validate-handback.sh checks a root publication command without running it.
set -euo pipefail

TEST_NAME='validate-handback'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(dirname -- "$here")
script="$root/agentkit/skills/.shared/scripts/validate-handback.sh"
source "$here/lib/assert.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/validate-handback-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/.agent" "$repo/src" "$repo/secrets"
cat >"$repo/.agent/config.env" <<'EOF'
AGENT_WORKER_MODEL=gpt-5.6-luna
AGENT_PROTECTED_PATHS=secrets/
EOF
git init -q -b feature "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
printf 'base\n' >"$repo/src/tracked.txt"
git -C "$repo" add -- .
git -C "$repo" commit -qm base
printf 'changed\n' >"$repo/src/tracked.txt"
printf 'new\n' >"$repo/src/untracked.txt"
printf 'workflow\n' >"$repo/secrets/config.txt"

helper="$root/agentkit/skills/.shared/scripts/worktree-commit.sh"
valid_handback="$tmp/valid.handback"
cat >"$valid_handback" <<EOF
"$helper" --message 'feat(skills): validate handbacks' --body 'Checks the publication boundary.' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt src/untracked.txt
EOF

valid_output="$tmp/valid.argv"
valid_rc=0
"$script" --worktree "$repo" --handback-file "$valid_handback" >"$valid_output" 2>"$tmp/valid.err" || valid_rc=$?
assert_eq '0' "$valid_rc" 'valid handback passes'
assert_eq "$helper
--message
feat(skills): validate handbacks
--body
Checks the publication boundary.
--trailer
Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>
--
src/tracked.txt
src/untracked.txt" "$(tr '\0' '\n' <"$valid_output")" \
    'valid handback returns the parsed argv NUL-delimited'
assert_eq '' "$(cat -- "$tmp/valid.err")" 'valid handback keeps diagnostics off stdout and stderr'

expect_invalid() {
    local name=$1 contents=$2
    local handback="$tmp/$name.handback" marker="$tmp/$name.marker" rc=0
    printf '%s\n' "$contents" >"$handback"
    "$script" --worktree "$repo" --handback-file "$handback" >"$tmp/$name.out" 2>"$tmp/$name.err" || rc=$?
    assert_eq '1' "$rc" "$name is invalid"
    assert_not_contains "$(cat -- "$tmp/$name.err")" 'Traceback' "$name has no Python traceback"
    assert_eq 'absent' "$([[ -e $marker ]] && printf present || printf absent)" \
        "$name did not execute shell syntax"
}

expect_invalid bad-trailer \
    "\"$helper\" --message 'feat(skills): bad trailer' --trailer 'Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"
expect_invalid wrong-model \
    "\"$helper\" --message 'feat(skills): wrong model' --trailer 'Co-Authored-By: Codex gpt-5.6-terra <noreply@openai.com>' -- src/tracked.txt"
expect_invalid bad-subject \
    "\"$helper\" --message 'not conventional' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"
expect_invalid shell-syntax \
    "\"$helper\" --message 'feat(skills): reject syntax' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt && touch $tmp/shell-syntax.marker"
expect_invalid unchanged-file \
    "\"$helper\" --message 'feat(skills): unchanged' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- .agent/config.env"
expect_invalid protected-file \
    "\"$helper\" --message 'feat(skills): protected' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- secrets/config.txt"
expect_invalid wrong-helper \
    "\"$root/agentkit/skills/.shared/scripts/agent-run.sh\" --message 'feat(skills): wrong helper' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"

outside="$tmp/outside.txt"
printf 'outside\n' >"$outside"
expect_invalid outside-path \
    "\"$helper\" --message 'feat(skills): outside' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- ../outside.txt"

missing_rc=0
"$script" --worktree "$tmp/missing" --handback-file "$valid_handback" >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_rc=$?
assert_eq '2' "$missing_rc" 'missing worktree reports unavailable evidence'

finish
