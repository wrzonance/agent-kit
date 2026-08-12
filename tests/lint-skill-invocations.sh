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
#
# Single-source convention (review-remote-pr, parallel-issues): shell state
# does not persist between an agent's tool calls, so the full resolver (the
# `skills= path=` read plus its untracked/non-symlink/owned provenance checks)
# is defined exactly once, in each skill's earliest setup step, boxed under
# "### The resolver (prepend to EVERY shell call)" / "#### The resolver
# (prepend to EVERY shell call)". Every OTHER bash block that touches
# `$agentkit` carries the two-line guard instead of a second copy:
#   # >>> prepend THE RESOLVER (defined once in Step 0) <<<
#   [ -d "${agentkit:-}/.shared/scripts" ] || { printf ...; exit 1; }
# onboard-repo keeps its own bootstrap resolver (with the `find` fallback)
# as the sole contract-absent case and is not held to the single-definition
# rule below -- it never had a second copy to begin with.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-invocations.sh SKILLS_DIR}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment|claude-adversarial-review|codex-adversarial-review|apply-ledger|fence-untrusted-data|pick-issues'
readonly FULL_RESOLVER_MARK='agentkit=\$(sed -n "s/\^skills= path='
readonly GUARD_MARK='${agentkit:-}/.shared/scripts'
# Skills whose earliest setup step keeps the single boxed resolver definition;
# every other bash block in these two files must carry the guard instead.
readonly SINGLE_SOURCE_SKILLS='review-remote-pr parallel-issues'

checked=0
bare=0
unguarded=0
contract_reads=0
missing_contract_reads=0
fallbacks=0
no_resolver=0
def_count_violations=0

fallback_matches=$(grep -R -n --include='SKILL.md' '^[[:space:]]*agentkit=\$(find ' "$skills_dir" || true)
fallbacks=$(printf '%s\n' "$fallback_matches" | grep -c . || true)
if [[ $fallbacks -ne 1 ]]; then
    printf 'EXPECTED exactly one contract-absent fallback resolver, found %s\n' "$fallbacks" >&2
    unguarded=$((unguarded + 1))
fi
if [[ $fallbacks -eq 1 ]] && ! grep -q '/onboard-repo/SKILL\.md:' <<< "$fallback_matches"; then
    printf 'EXPECTED the contract-absent fallback only in onboard-repo bootstrap\n' >&2
    unguarded=$((unguarded + 1))
fi

pinned_paths=$(grep -R -nE --include='SKILL.md' \
    'plugins/cache/[^[:space:]"`$}]*/agentkit/[0-9]+(\.[0-9]+)*' "$skills_dir" || true)
if [[ -n $pinned_paths ]]; then
    printf 'PINNED plugin-cache path in skill text:\n%s\n' "$pinned_paths" >&2
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

    # Single-source convention: the full resolver definition appears exactly
    # once in each of these two skills, and only there.
    if [[ " $SINGLE_SOURCE_SKILLS " == *" $name "* ]]; then
        def_count=$(grep -c "$FULL_RESOLVER_MARK" "$block" || true)
        if [[ $def_count -ne 1 ]]; then
            def_count_violations=$((def_count_violations + 1))
            printf 'EXPECTED exactly one full resolver definition in %s, found %s\n' \
                "$skill_file" "$def_count" >&2
        fi
    fi

    while IFS= read -r -u 3 lineno; do
        contract_reads=$((contract_reads + 1))
        if ! sed -n "$((lineno + 1)),$((lineno + 10))p" "$block" |
            grep -q '\[ -d "\$agentkit/\.shared/scripts" \]'; then
            missing_contract_reads=$((missing_contract_reads + 1))
            printf 'UNGUARDED CONTRACT in %s (block line %s): invalid path would be silent\n' \
                "$skill_file" "$lineno" >&2
        fi
    done 3< <(grep -n "$FULL_RESOLVER_MARK" "$block" | cut -d: -f1)

    while IFS= read -r line; do
        grep -qE "($HELPERS)\.sh" <<< "$line" || continue
        checked=$((checked + 1))
        [[ $line =~ ^[[:space:]]*# ]] && continue
        grep -qE "(printf|echo)" <<< "$line" && continue
        grep -qE "/($HELPERS)\.sh" <<< "$line" && continue
        bare=$((bare + 1))
        printf 'BARE INVOCATION in %s: %s\n' "$skill_file" "$line" >&2
    done < "$block"

    # Every INDIVIDUAL fence that invokes a helper must carry either the full
    # resolver definition or the two-line guard -- not just the file as a
    # whole. Split back into per-fence files to check at that granularity.
    # Scoped to the two skills that adopted the single-source convention;
    # onboard-repo's bootstrap block resolves `$agentkit`/`$shared` once and
    # its later fences are documented as running in the same continued
    # session, so it was never a copy-per-block skill to begin with.
    if [[ " $SINGLE_SOURCE_SKILLS " == *" $name "* ]]; then
        fence_dir="$work/$name-fences"
        mkdir -p "$fence_dir"
        awk -v dir="$fence_dir" '
            /^```bash$/ { inblock = 1; n++; file = dir "/" n; next }
            /^```$/     { inblock = 0; next }
            inblock     { print > file }
        ' "$skill_file"
        for fence in "$fence_dir"/*; do
            [[ -f $fence ]] || continue
            grep -qE "($HELPERS)\.sh" "$fence" || continue
            grep -q "$FULL_RESOLVER_MARK" "$fence" && continue
            grep -qF "$GUARD_MARK" "$fence" && continue
            no_resolver=$((no_resolver + 1))
            printf 'MISSING RESOLVER in %s (fence %s): a helper is invoked with neither the full resolver nor the guard\n' \
                "$skill_file" "$(basename "$fence")" >&2
        done
    fi
done < <(find "$skills_dir" -maxdepth 2 -name SKILL.md -not -path '*/.system/*' | sort)

printf 'skill invocations: %d references, %d bare; %d contract reads, %d unguarded, %d fallback, %d missing-resolver, %d definition-count violations\n' \
    "$checked" "$bare" "$contract_reads" "$missing_contract_reads" "$fallbacks" "$no_resolver" "$def_count_violations"
[[ $bare -eq 0 && $unguarded -eq 0 && $missing_contract_reads -eq 0 && $fallbacks -eq 1 &&
   $no_resolver -eq 0 && $def_count_violations -eq 0 ]]
