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

readonly HELPERS='agent-run|worktree-commit|validate-handback|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment|claude-adversarial-review|codex-adversarial-review|apply-ledger|fence-untrusted-data|pick-issues|post-receipt|prepare-issue-artifacts|compose-worker-prompt|board-list'
readonly FULL_RESOLVER_MARK='agentkit=\$(sed -n "s/\^skills= path='
# Both halves of the guard are matched as complete TEST EXPRESSIONS on a single
# non-comment line, never as loose substrings. Substring matching is not enough:
# `${agentkit:-}/.shared/scripts` also appears inside a helper invocation path,
# and `${agentkit_provenance:-}` can appear in a comment, so a fence carrying a
# bare invocation plus a comment mentioning the sentinel would satisfy both
# marks while executing no guard at all -- the exact bypass this rule exists to
# close.
readonly GUARD_EXPR_DIR='[ -d "${agentkit:-}/.shared/scripts" ]'
# The directory check alone is satisfied by any stale or profile-inherited
# $agentkit that happens to point at a real tree, which is exactly the case the
# sentinel exists to reject. Requiring both is what makes the provenance
# boundary enforced rather than decorative.
readonly GUARD_EXPR_SENTINEL='[ "${agentkit_provenance:-}" = ok ]'
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
unreachable_guards=0

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

# Prints the code portion of a shell line, dropping a trailing comment.
# `${line%%#*}` is not good enough: bash only starts a comment at an UNQUOTED
# `#` that begins a word, so `: '#'; agent-run.sh` really does run the helper
# while a naive cut hides it -- a lint bypass for exactly the bare invocation
# this gate exists to catch. Tracks quote state and requires the `#` to start a
# word, which is bash's own rule.
strip_shell_comment() {
    local line=$1 out='' quote='' char prev='' i
    for ((i = 0; i < ${#line}; i++)); do
        char=${line:i:1}
        if [[ -n $quote ]]; then
            [[ $char == "$quote" ]] && quote=''
        elif [[ $char == "'" || $char == '"' ]]; then
            quote=$char
        elif [[ $char == '#' && ( -z $prev || $prev == [[:space:]] || $prev == ';' ) ]]; then
            break
        fi
        out+=$char
        prev=$char
    done
    printf '%s' "$out"
}

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
        # Only the text before the comment counts as code for this check.
        code_part=$(strip_shell_comment "$line")
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
            # Executed guard only: comment lines are skipped, and both halves
            # must appear as test expressions on the SAME line, which is how the
            # guard is actually written. A mention in prose or a comment proves
            # nothing about what runs.
            guard_dir=0
            guard_both=0
            # Reachability, not mere presence. A guard nested inside an if/else
            # protects only the path it sits on: review-remote-pr's Step 0a once
            # carried the guard inside the worktree-CREATION branch while calling
            # agent-preflight.sh after the `fi`, so the worktree-REUSE path -- the
            # common resume case -- reached the helper with $agentkit never
            # validated. Presence-only matching passed that fence. Track the
            # position of the guard, not just its depth. DEPTH ALONE IS NOT
            # ENOUGH: a helper on line 1 and the guard on line 2, both at depth
            # 0, compares equal and passes while the helper has already run
            # unguarded. The convention is "prepend the guard", so enforce
            # exactly that -- an effective guard sits at depth 0 AND ahead of
            # the first helper invocation in the fence.
            depth=0
            pos=0
            guard_pos=-1
            guard_depth=-1
            invoke_pos=-1
            invoke_depth=-1
            while IFS= read -r line; do
                stripped=$(strip_shell_comment "$line")
                trimmed=${stripped#"${stripped%%[![:space:]]*}"}
                [[ -z $trimmed ]] && continue
                pos=$((pos + 1))
                # Close before recording: `fi` belongs to the enclosing level.
                [[ $trimmed =~ ^(fi|done|esac)([[:space:]]|;|$) ]] && ((depth > 0)) && depth=$((depth - 1))
                if [[ $trimmed == *"$GUARD_EXPR_DIR"* ]]; then
                    guard_dir=1
                    # Record the first guard that is BOTH complete and at depth
                    # 0; a deeper or later one cannot retroactively protect an
                    # earlier call.
                    if [[ $trimmed == *"$GUARD_EXPR_SENTINEL"* ]]; then
                        guard_both=1
                        if [[ $guard_pos -lt 0 && $depth -eq 0 ]]; then
                            guard_pos=$pos
                            guard_depth=$depth
                        fi
                        [[ $guard_depth -lt 0 ]] && guard_depth=$depth
                    fi
                elif grep -qE "\"\\\$agentkit/[^\"]*($HELPERS)\.sh\"" <<< "$trimmed"; then
                    if [[ $invoke_pos -lt 0 ]]; then
                        invoke_pos=$pos
                        invoke_depth=$depth
                    fi
                fi
                if [[ $trimmed =~ ^(if|for|while|case)([[:space:]]|$) ]] ||
                   [[ $trimmed =~ \;[[:space:]]*(then|do)$ ]]; then
                    depth=$((depth + 1))
                fi
            done < "$fence"
            if ((guard_both)) && [[ $invoke_pos -ge 0 ]] &&
               [[ $guard_pos -lt 0 || $guard_pos -gt $invoke_pos ]]; then
                unreachable_guards=$((unreachable_guards + 1))
                if [[ $guard_pos -lt 0 ]]; then
                    printf 'GUARD NOT ON EVERY PATH in %s (fence %s): the only guard sits at block depth %s, inside a branch, while a helper runs at depth %s; hoist it to the top of the fence\n' \
                        "$skill_file" "$fence_name" "$guard_depth" "$invoke_depth" >&2
                else
                    printf 'GUARD AFTER HELPER in %s (fence %s): the guard is statement %s but a helper already ran at statement %s; the guard must precede every invocation it protects\n' \
                        "$skill_file" "$fence_name" "$guard_pos" "$invoke_pos" >&2
                fi
                continue
            fi
            ((guard_both)) && continue
            if ((guard_dir)); then
                sentinel_gaps=$((sentinel_gaps + 1))
                printf 'GUARD WITHOUT SENTINEL in %s (fence %s): a directory-only guard is satisfied by a stale inherited agentkit; require %s on the same line\n' \
                    "$skill_file" "$fence_name" "$GUARD_EXPR_SENTINEL" >&2
                continue
            fi
            no_resolver=$((no_resolver + 1))
            printf 'MISSING RESOLVER in %s (fence %s): a helper is invoked with neither the full resolver nor an executed guard\n' \
                "$skill_file" "$fence_name" >&2
        done
    fi
done

printf 'skill invocations: %d references, %d bare; %d contract reads, %d unguarded, %d fallback, %d missing-resolver, %d definition-count violations, %d resolver side effects, %d sentinel gaps, %d unreachable guards\n' \
    "$checked" "$bare" "$contract_reads" "$missing_contract_reads" "$fallbacks" "$no_resolver" "$def_count_violations" "$resolver_side_effects" "$sentinel_gaps" "$unreachable_guards"
[[ $bare -eq 0 && $unguarded -eq 0 && $missing_contract_reads -eq 0 && $fallbacks -eq 1 &&
   $no_resolver -eq 0 && $def_count_violations -eq 0 && $resolver_side_effects -eq 0 &&
   $sentinel_gaps -eq 0 && $unreachable_guards -eq 0 ]]
