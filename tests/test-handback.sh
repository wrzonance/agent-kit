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

attacker_helper_dir="$tmp/attacker/bin"
attacker_helper="$attacker_helper_dir/worktree-commit.sh"
mkdir -p "$attacker_helper_dir"
printf '#!/usr/bin/env bash\n' >"$attacker_helper"
chmod +x "$attacker_helper"
expect_invalid attacker-helper \
    "\"$attacker_helper\" --message 'feat(skills): attacker helper' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt"

outside="$tmp/outside.txt"
printf 'outside\n' >"$outside"
expect_invalid outside-path \
    "\"$helper\" --message 'feat(skills): outside' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- ../outside.txt"

missing_rc=0
"$script" --worktree "$tmp/missing" --handback-file "$valid_handback" >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_rc=$?
assert_eq '2' "$missing_rc" 'missing worktree reports unavailable evidence'

# argv[0] is emitted as the canonical shipped helper, never as the spelling the
# worker submitted. Resolving the submitted path only proves what it pointed at
# during validation; a symlink retargeted before root executes would otherwise
# hand root a worker-controlled program.
helper_symlink="$tmp/attacker/worktree-commit.sh"
ln -sf "$helper" "$helper_symlink"
symlink_handback="$tmp/symlink.handback"
cat >"$symlink_handback" <<EOF
"$helper_symlink" --message 'feat(skills): symlink helper' --trailer 'Co-Authored-By: Codex gpt-5.6-luna <noreply@openai.com>' -- src/tracked.txt
EOF
symlink_output="$tmp/symlink.argv"
symlink_rc=0
"$script" --worktree "$repo" --handback-file "$symlink_handback" >"$symlink_output" 2>"$tmp/symlink.err" || symlink_rc=$?
assert_eq '0' "$symlink_rc" 'a symlink that resolves to the shipped helper is accepted'
assert_eq "$helper" "$(tr '\0' '\n' <"$symlink_output" | head -1)" \
    'the emitted argv names the canonical helper, not the submitted symlink'

# worktree-commit.sh commits the whole index, and its own staged-protected guard
# only fires during an active merge. A path staged but left out of the operands
# would otherwise be published without ever reaching the protected check.
git -C "$repo" add -- secrets/config.txt
staged_protected_rc=0
"$script" --worktree "$repo" --handback-file "$valid_handback" \
    >"$tmp/staged-protected.out" 2>"$tmp/staged-protected.err" || staged_protected_rc=$?
assert_eq '1' "$staged_protected_rc" 'a staged protected path is refused even when undeclared'
assert_contains "$(cat -- "$tmp/staged-protected.err")" 'secrets/config.txt' \
    'the refusal names the staged protected path'
git -C "$repo" reset -q -- secrets/config.txt

printf 'plain\n' >"$repo/src/staged-only.txt"
git -C "$repo" add -- src/staged-only.txt
staged_undeclared_rc=0
"$script" --worktree "$repo" --handback-file "$valid_handback" \
    >"$tmp/staged-undeclared.out" 2>"$tmp/staged-undeclared.err" || staged_undeclared_rc=$?
assert_eq '1' "$staged_undeclared_rc" 'a staged but undeclared path is refused'
assert_contains "$(cat -- "$tmp/staged-undeclared.err")" 'staged path is not declared' \
    'the refusal names the undeclared staged path'
git -C "$repo" reset -q -- src/staged-only.txt
rm -f -- "$repo/src/staged-only.txt"

printf 'AGENT_WORKER_MODEL= \t  \nAGENT_PROTECTED_PATHS=secrets/\n' >"$repo/.agent/config.env"
blank_model_rc=0
"$script" --worktree "$repo" --handback-file "$valid_handback" >"$tmp/blank-model.out" 2>"$tmp/blank-model.err" || blank_model_rc=$?
assert_eq '2' "$blank_model_rc" 'blank worker model reports unavailable evidence'
assert_not_contains "$(cat -- "$tmp/blank-model.err")" 'Traceback' \
    'blank worker model has no Python traceback'

finish
