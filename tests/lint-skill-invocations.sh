#!/usr/bin/env bash
# Every helper script invoked from a SKILL.md bash block must be reached through
# a resolved path, never bare.
# shellcheck disable=SC2016  # resolver text is intentionally literal
#
# Nothing in this tree is on PATH, so a bare `agent-run.sh` is a guaranteed
# "command not found" that the agent then has to recover from by guessing a
# location -- exactly the failed-tool-call waste the skills exist to avoid. The
# established convention is to read the absolute `skills= path=` line from the
# preflight contract, then invoke helpers below that directory.
#
# A reference passes when it is part of a path (preceded by /), sits in a
# comment, or appears inside a printf/echo message.
#
# The contract is produced by agent-preflight.sh. A contract-absent fallback is
# deliberately kept in one onboarding block; all other blocks must fail loudly
# and tell the agent to run preflight rather than reintroduce a resolver copy.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-invocations.sh SKILLS_DIR}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment|claude-adversarial-review|codex-adversarial-review'

checked=0
bare=0
unguarded=0
contract_reads=0
missing_contract_reads=0
fallbacks=0

fallback_matches=$(grep -R -n --include='SKILL.md' '^[[:space:]]*agentkit=\$(find ' "$skills_dir" || true)
fallbacks=$(printf '%s\n' "$fallback_matches" | grep -c . || true)
if [[ $fallbacks -ne 1 ]]; then
    printf 'EXPECTED exactly one contract-absent fallback resolver, found %s\n' "$fallbacks" >&2
    unguarded=$((unguarded + 1))
fi

while IFS= read -r skill_file; do
    name=$(basename "$(dirname "$skill_file")")
    block="$work/$name.sh"
    awk -v out="$block" '
        /^```bash$/ { inblock = 1; next }
        /^```$/     { inblock = 0; next }
        inblock     { print > out }
    ' "$skill_file"
    [[ -f $block ]] || continue

    while IFS= read -r -u 3 lineno; do
        contract_reads=$((contract_reads + 1))
        if ! sed -n "$((lineno + 1)),$((lineno + 10))p" "$block" |
            grep -q '\[ -d "\$agentkit/\.shared/scripts" \]'; then
            missing_contract_reads=$((missing_contract_reads + 1))
            printf 'UNGUARDED CONTRACT in %s (block line %s): invalid path would be silent\n' \
                "$skill_file" "$lineno" >&2
        fi
    done 3< <(grep -n 'agentkit=\$(sed -n "s/\^skills= path=' "$block" | cut -d: -f1)

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

printf 'skill invocations: %d references, %d bare; %d contract reads, %d unguarded, %d fallback\n' \
    "$checked" "$bare" "$contract_reads" "$missing_contract_reads" "$fallbacks"
[[ $bare -eq 0 && $unguarded -eq 0 && $missing_contract_reads -eq 0 && $fallbacks -eq 1 ]]
