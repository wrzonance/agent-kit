#!/usr/bin/env bash
# Suite: gh mutation bodies stay byte-stable by going through files.
set -uo pipefail

TEST_NAME='gh-body-advisory'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent/cache"
    printf '%s' "$dir"
}

pre_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" --arg sid "${3:-$RANDOM}" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:$sid,tool_name:"Bash",tool_use_id:"t",transcript_path:null,
          tool_input:{command:$cmd}}'
}
context() { jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$1"; }

repo=$(make_repo)

# Every body-taking operation accepts inline text, but the guard must remain
# advice-only so the command is still allowed to proceed.
for command in \
    'gh pr create --body "body"' \
    'gh pr edit 1 -b body' \
    'gh pr edit 1 --body=body' \
    'gh pr comment 1 --body body' \
    'gh issue create --body body' \
    'gh issue edit 1 -b body' \
    'gh issue comment 1 --body body' \
    'gh api repos/o/r/issues -f body=body' \
    'gh api repos/o/r/issues --raw-field body=body' \
    'gh api repos/o/r/issues --field body=body' \
    'gh api repos/o/r/issues -F body=text'; do
    out=$(pre_input "$repo" "$command" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$out")" \
        "inline body remains non-blocking: $command"
    assert_contains "$(context "$out")" 'file-backed' \
        "advises file-backed form: $command"
done

# File-backed forms are already safe and stay quiet.
for command in \
    'gh pr create --body-file body.md' \
    'gh issue edit 1 --input body.json' \
    'gh api repos/o/r/issues --input body.json' \
    'gh api repos/o/r/issues -F body=@body.md'; do
    out=$(pre_input "$repo" "$command" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq '' "$(context "$out")" "file-backed body stays quiet: $command"
done

# Only a command-position gh is inspected; text passed to another command is
# data, even when it contains a complete gh recipe.
for command in \
    'echo "gh pr create --body body"' \
    'grep -n "gh issue edit 1 --body body" notes.txt' \
    'printf %s "gh api repos/o/r/issues -f body=body"' \
    'git commit -m "gh pr create --body body"' \
    '"gh pr create --body body"'; do
    out=$(pre_input "$repo" "$command" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq '' "$(context "$out")" "quoted or argument-position gh stays quiet: $command"
done
for command in \
    'true; gh pr create --body body' \
    'printf ready | gh issue comment 1 --body body'; do
    out=$(pre_input "$repo" "$command" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_contains "$(context "$out")" 'file-backed' "separator exposes command-position gh: $command"
done

# A literal backslash-n survives shell quoting as two posted characters, so
# the diagnosis must say that it renders as backslash-n rather than a newline.
out=$(pre_input "$repo" 'gh pr create --body "line\nnext"' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_contains "$(context "$out")" 'renders as backslash-n' \
    'literal backslash-n gets its specific diagnosis'

# Comments have a dedicated byte-verifying transport helper.
out=$(pre_input "$repo" 'gh pr comment 1 --body body' "comment-$RANDOM" |
    "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_contains "$(context "$out")" 'gh-comment.sh' \
    'comment advice names the byte-verifying helper'

# Advisories are emitted once per session and never turn into a denial.
sid="once-$RANDOM"
out=$(pre_input "$repo" 'gh pr create --body body' "$sid" |
    "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$out")" \
    'inline body advice does not deny the command'
out=$(pre_input "$repo" 'gh pr create --body body' "$sid" |
    "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq '' "$(context "$out")" 'inline body advice speaks once per session'

finish
