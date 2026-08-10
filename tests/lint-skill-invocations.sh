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
#
# The same blocks must also FAIL LOUDLY when resolution comes back empty. Under
# `set -euo pipefail` an unresolved path exits silently, and a live session
# answered that silence by pasting an absolute plugin path -- version directory
# included -- and using it for the rest of the session. So every resolver copy
# has to be followed by a check that names the problem.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-invocations.sh SKILLS_DIR}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment|claude-adversarial-review|codex-adversarial-review'

checked=0
bare=0
resolvers=0
unguarded=0

while IFS= read -r skill_file; do
    name=$(basename "$(dirname "$skill_file")")
    block="$work/$name.sh"
    awk -v out="$block" '
        /^```bash$/ { inblock = 1; next }
        /^```$/     { inblock = 0; next }
        inblock     { print > out }
    ' "$skill_file"
    [[ -f $block ]] || continue

    # shellcheck disable=SC2016  # the $ is a literal being searched for, not expanded
    # Every fallback assignment must be followed by a check that the tree is
    # actually there. 25 copies of this snippet exist across the skills; a gate
    # is the only thing that keeps the 26th from omitting it.
    while IFS= read -r -u 3 lineno; do
        resolvers=$((resolvers + 1))
        if ! sed -n "$((lineno + 1)),$((lineno + 12))p" "$block" |
            grep -q '\[ -d "\$agentkit/\.shared/scripts" \]'; then
            unguarded=$((unguarded + 1))
            printf 'UNGUARDED RESOLVER in %s (block line %s): resolution failure would be silent\n' \
                "$skill_file" "$lineno" >&2
        fi
    done 3< <(grep -n '^\[ -n "\$agentkit" \] || agentkit=' "$block" | cut -d: -f1)

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

printf 'skill invocations: %d references, %d bare; %d resolvers, %d unguarded\n' \
    "$checked" "$bare" "$resolvers" "$unguarded"
[[ $bare -eq 0 && $unguarded -eq 0 ]]
