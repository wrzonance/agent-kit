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
#
# A skill split into a dispatcher body plus references/*.md carries the
# definition in the body only -- reference bash fences apply the identical
# guard convention, never a second full-resolver definition. Both are scanned
# below so a helper invocation moved into a reference file keeps the same
# provenance bar it had in the body.
#
# .shared/*.md policy files (six-step-loop.md, spawn-contract.md,
# wait-discipline.md, github-body-policy.md, ...) are pasted verbatim into
# worker prompts by both split skills -- they are never an entry point of
# their own, so they hold the same bar as a reference file: any bash fence
# that invokes a helper carries the two-line guard, and the full resolver
# definition never appears there.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-invocations.sh SKILLS_DIR}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment|claude-adversarial-review|codex-adversarial-review|apply-ledger|fence-untrusted-data|pick-issues|post-receipt|prepare-issue-artifacts|board-list'
readonly FULL_RESOLVER_MARK='agentkit=\$(sed -n "s/\^skills= path='
readonly GUARD_MARK='${agentkit:-}/.shared/scripts'
# The directory check alone is satisfied by any stale or profile-inherited
# $agentkit that happens to point at a real tree, which is exactly the case the
# sentinel exists to reject. Requiring both is what makes the provenance
# boundary enforced rather than decorative.
readonly SENTINEL_MARK='${agentkit_provenance:-}'
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
resolver_side_effects=0
sentinel_gaps=0

# Every SKILL.md, every references/*.md beneath it, and every .shared/*.md
# policy file -- a split skill's reference files and the shared policy files
# both carry bash fences too, and they inherit the same resolver/guard
# obligations as the body they were extracted from.
mapfile -t md_files < <(find "$skills_dir" -maxdepth 3 \
    \( -name SKILL.md -o -path '*/references/*.md' -o -path '*/.shared/*.md' \) \
    -not -path '*/.system/*' | sort)

fallback_matches=$(grep -Hn '^[[:space:]]*agentkit=\$(find ' "${md_files[@]}" 2>/dev/null || true)
fallbacks=$(printf '%s\n' "$fallback_matches" | grep -c . || true)
if [[ $fallbacks -ne 1 ]]; then
    printf 'EXPECTED exactly one contract-absent fallback resolver, found %s\n' "$fallbacks" >&2
    unguarded=$((unguarded + 1))
fi
if [[ $fallbacks -eq 1 ]] && ! grep -q '/onboard-repo/SKILL\.md:' <<< "$fallback_matches"; then
    printf 'EXPECTED the contract-absent fallback only in onboard-repo bootstrap\n' >&2
    unguarded=$((unguarded + 1))
fi

pinned_paths=$(grep -HnE \
    'plugins/cache/[^[:space:]"`$}]*/agentkit/[0-9]+(\.[0-9]+)*' "${md_files[@]}" 2>/dev/null || true)
if [[ -n $pinned_paths ]]; then
    printf 'PINNED plugin-cache path in skill text:\n%s\n' "$pinned_paths" >&2
    unguarded=$((unguarded + 1))
fi

for skill_file in "${md_files[@]}"; do
    # references/*.md belongs to the skill directory one level above
    # "references"; SKILL.md belongs to its own parent directory; .shared/*.md
    # belongs to no skill at all -- it is shared policy content pasted into
    # more than one skill's worker prompts, held to the reference-file bar.
    parent_dir=$(dirname "$skill_file")
    is_shared=0
    if [[ $(basename "$parent_dir") == references ]]; then
        name=$(basename "$(dirname "$parent_dir")")
        is_reference=1
    elif [[ $(basename "$parent_dir") == .shared ]]; then
        name=.shared
        is_reference=1
        is_shared=1
    else
        name=$(basename "$parent_dir")
        is_reference=0
    fi
    rel=${skill_file#"$skills_dir"/}
    block="$work/${rel//\//__}.sh"
    awk -v out="$block" '
        /^```bash$/ { inblock = 1; next }
        /^```$/     { inblock = 0; next }
        inblock     { print > out }
    ' "$skill_file"
    [[ -f $block ]] || continue

    # Single-source convention: the full resolver definition appears exactly
    # once, in the body, and never again in a reference file split out of it
    # or in a .shared policy file pasted into more than one skill's prompts.
    if [[ " $SINGLE_SOURCE_SKILLS " == *" $name "* || $is_shared -eq 1 ]]; then
        def_count=$(grep -c "$FULL_RESOLVER_MARK" "$block" || true)
        if [[ $is_reference -eq 0 ]]; then
            if [[ $def_count -ne 1 ]]; then
                def_count_violations=$((def_count_violations + 1))
                printf 'EXPECTED exactly one full resolver definition in %s, found %s\n' \
                    "$skill_file" "$def_count" >&2
            fi
        elif [[ $def_count -ne 0 ]]; then
            def_count_violations=$((def_count_violations + 1))
            printf 'EXPECTED zero full resolver definitions in reference file %s, found %s -- the definition belongs in the body only\n' \
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
        # Exempt when the reference sits entirely inside a comment -- not just
        # a LEADING comment (`^#`), but also a trailing one on an otherwise
        # code-bearing line (e.g. a `case` arm's `# helper.sh did X` note).
        # Only the text before the first `#` counts as code for this check.
        code_part=${line%%#*}
        grep -qE "($HELPERS)\.sh" <<< "$code_part" || continue
        grep -qE "(printf|echo)" <<< "$line" && continue
        grep -qE "/($HELPERS)\.sh" <<< "$line" && continue
        bare=$((bare + 1))
        printf 'BARE INVOCATION in %s: %s\n' "$skill_file" "$line" >&2
    done < "$block"

    # Every INDIVIDUAL fence that invokes a helper must carry either the full
    # resolver definition or the two-line guard -- not just the file as a
    # whole. Split back into per-fence files to check at that granularity.
    # Scoped to the two skills that adopted the single-source convention, and
    # to .shared/*.md (pasted into both skills' prompts under that same
    # convention); onboard-repo's bootstrap block resolves `$agentkit`/`$shared`
    # once and its later fences are documented as running in the same
    # continued session, so it was never a copy-per-block skill to begin with.
    if [[ " $SINGLE_SOURCE_SKILLS " == *" $name "* || $is_shared -eq 1 ]]; then
        fence_dir="$work/${rel//\//__}-fences"
        mkdir -p "$fence_dir"
        awk -v dir="$fence_dir" '
            /^```bash$/ { inblock = 1; n++; file = dir "/" n; next }
            /^```$/     { inblock = 0; next }
            inblock     { print > file }
        ' "$skill_file"
        for fence in "$fence_dir"/*; do
            [[ -f $fence ]] || continue
            # The boxed resolver is prepended to EVERY later shell call, so any
            # run-once work left inside it runs once per call. agent-preflight.sh
            # is the sharp case: it rewrites .agent/env-contract.txt and prints
            # the whole contract, so a copy inside the resolver re-probes the
            # environment on every command -- letting one transient gh/network
            # failure overwrite a good contract (preflight reports rather than
            # blocks, so the degradation is silent) and prefixing every later
            # command's stdout with the contract block. The resolver fence
            # resolves and validates $agentkit; nothing else.
            fence_name=$(basename "$fence")
            if grep -q "$FULL_RESOLVER_MARK" "$fence"; then
                while IFS= read -r line; do
                    grep -qE "($HELPERS)\.sh" <<< "$line" || continue
                    [[ $line =~ ^[[:space:]]*# ]] && continue
                    grep -qE "(printf|echo)" <<< "$line" && continue
                    resolver_side_effects=$((resolver_side_effects + 1))
                    printf 'RUN-ONCE WORK IN RESOLVER in %s (fence %s): %s\n' \
                        "$skill_file" "$fence_name" "$line" >&2
                done < "$fence"
                continue
            fi
            grep -qE "($HELPERS)\.sh" "$fence" || continue
            if grep -qF "$GUARD_MARK" "$fence"; then
                grep -qF "$SENTINEL_MARK" "$fence" && continue
                sentinel_gaps=$((sentinel_gaps + 1))
                printf 'GUARD WITHOUT SENTINEL in %s (fence %s): a directory-only guard is satisfied by a stale inherited agentkit; require [ "${agentkit_provenance:-}" = ok ] too\n' \
                    "$skill_file" "$fence_name" >&2
                continue
            fi
            no_resolver=$((no_resolver + 1))
            printf 'MISSING RESOLVER in %s (fence %s): a helper is invoked with neither the full resolver nor the guard\n' \
                "$skill_file" "$fence_name" >&2
        done
    fi
done

printf 'skill invocations: %d references, %d bare; %d contract reads, %d unguarded, %d fallback, %d missing-resolver, %d definition-count violations, %d resolver side effects, %d sentinel gaps\n' \
    "$checked" "$bare" "$contract_reads" "$missing_contract_reads" "$fallbacks" "$no_resolver" "$def_count_violations" "$resolver_side_effects" "$sentinel_gaps"
[[ $bare -eq 0 && $unguarded -eq 0 && $missing_contract_reads -eq 0 && $fallbacks -eq 1 &&
   $no_resolver -eq 0 && $def_count_violations -eq 0 && $resolver_side_effects -eq 0 &&
   $sentinel_gaps -eq 0 ]]
