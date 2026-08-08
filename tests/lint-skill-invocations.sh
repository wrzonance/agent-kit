#!/usr/bin/env bash
# Every helper script invoked from a SKILL.md bash block must be reached through
# a resolved path, never bare.
#
# Nothing in this tree is on PATH, so a bare `agent-run.sh` is a guaranteed
# "command not found" that the agent then has to recover from by guessing a
# location -- exactly the failed-tool-call waste the skills exist to avoid. The
# established convention is:
#
#     codex_home=${CODEX_HOME:-$HOME/.codex}
#     "$codex_home/skills/.shared/scripts/agent-run.sh" ...
#
# A reference passes when it is part of a path (preceded by /), sits in a
# comment, or appears inside a printf/echo message.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-invocations.sh SKILLS_DIR}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment|claude-adversarial-review|codex-adversarial-review'

checked=0
bare=0

while IFS= read -r skill_file; do
    name=$(basename "$(dirname "$skill_file")")
    block="$work/$name.sh"
    awk -v out="$block" '
        /^```bash$/ { inblock = 1; next }
        /^```$/     { inblock = 0; next }
        inblock     { print > out }
    ' "$skill_file"
    [[ -f $block ]] || continue

    while IFS= read -r line; do
        grep -qE "($HELPERS)\.sh" <<< "$line" || continue
        checked=$((checked + 1))
        [[ $line =~ ^[[:space:]]*# ]] && continue
        grep -qE "(printf|echo)" <<< "$line" && continue
        grep -qE "/($HELPERS)\.sh" <<< "$line" && continue
        bare=$((bare + 1))
        printf 'BARE INVOCATION in %s: %s\n' "$skill_file" "$line" >&2
    done < "$block"
done < <(find "$skills_dir" -maxdepth 2 -name SKILL.md -not -path '*/.system/*' | sort)

printf 'skill invocations: %d references, %d bare\n' "$checked" "$bare"
[[ $bare -eq 0 ]]
