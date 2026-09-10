#!/usr/bin/env bash
# Helper scripts are the largest token surface an agent can be made to read,
# and until this gate they were the only one without a ratchet: the 2026-09
# size waves cut them by ~16K tokens and the next two fix waves grew them back
# by ~19K without any check noticing. This mirrors lint-skill-size.sh for every
# *.sh under skills/ and hooks/ -- a per-file cap, an explicit allowlist for
# the files already over it, and a tree-total ceiling so growth spread across
# many under-cap files still fails.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/token-estimate.sh
source "$here/lib/token-estimate.sh"

plugin_dir=${1:?usage: lint-helper-size.sh PLUGIN_DIR}

# Keys are paths relative to PLUGIN_DIR. Values are LINES:TOKENS:TARGET --
# the file's measured size when the entry was written (hard caps in both
# dimensions) and the line count to work back down to. Remove the entry the
# moment the file is back under the standard budget; the ratchet check below
# fails a stale one. A deliberate growth raises the crossed ceiling in the
# same PR, so every raise is a reviewed line in the diff, never a drift.
declare -A KNOWN_OVERSIZE=(
    # LINES:TOKENS:TARGET
    [hooks/lib/guard-lib.sh]="2298:25215:800"
    [skills/.shared/scripts/agent-preflight.sh]="1333:15916:800"
    [skills/.shared/scripts/agent-run.sh]="1627:17340:800"
    [skills/.shared/scripts/bootstrap-repo.sh]="818:10354:800"
    [skills/.shared/scripts/repo-config.sh]="1123:11566:800"
    [skills/.shared/scripts/worktree-commit.sh]="816:8485:800"
    [skills/parallel-issues/scripts/chain-advance.sh]="1076:12966:800"
    [skills/parallel-issues/scripts/compose-worker-prompt.sh]="1276:16733:800"
    [skills/parallel-issues/scripts/move-github-project-item.sh]="993:11129:800"
    [skills/parallel-issues/scripts/write-merge-plan.sh]="1066:13055:800"
    # Issue #706: preserve selected invalid model provenance through the result.
    [skills/review-remote-pr/scripts/adversarial-run.sh]="1007:12670:800"
    [skills/review-remote-pr/scripts/gh-pr-state.sh]="1193:14442:800"
    [skills/review-remote-pr/scripts/post-receipt.sh]="968:10889:800"
)

# 800 lines is code.md's hard cap for any file; 10,000 tokens is what ~800
# lines of shell measure under bytes/4.
readonly MAX_HELPER_LINES=800
readonly MAX_HELPER_TOKENS=10000
# The whole tree's estimated tokens as of this ceiling being written. Raise it
# only in the PR that needs the room, and say why in that PR.
# Issue #706: runner and receipt provenance; measured tree, no spare allowance.
readonly MAX_TREE_TOKENS=396294

violations=0
checked=0
tree_bytes=0

report() {
    printf 'VIOLATION %s: %s\n' "$1" "$2" >&2
    violations=$((violations + 1))
}

# NR counts an unterminated final line; `wc -l` would not.
count_lines() {
    awk 'END { print NR }' "$1"
}

check_allowlisted() {
    local file=$1 rel=$2 lines=$3 tokens=$4 over=$5
    local entry=${KNOWN_OVERSIZE[$rel]} line_ceiling token_ceiling target field
    IFS=: read -r line_ceiling token_ceiling target <<< "$entry"
    # Non-numeric fields abort arithmetic under `set -u`; `08` is an invalid
    # octal literal; `1+1` silently evaluates. Name the entry instead.
    for field in "$line_ceiling" "$token_ceiling" "$target"; do
        if [[ ! $field =~ ^(0|[1-9][0-9]*)$ ]]; then
            report "$file" \
                "malformed KNOWN_OVERSIZE entry for '$rel' ('$entry') -- expected LINES:TOKENS:TARGET, each a decimal integer without leading zeros"
            return 0
        fi
    done
    if ((over == 0)); then
        report "$file" \
            "allowlisted helper '$rel' is now within budget ($lines lines, ~$tokens tokens) -- remove the stale KNOWN_OVERSIZE entry (target <=$target lines)"
        return 0
    fi
    if ((lines > line_ceiling)); then
        report "$file" \
            "allowlisted helper '$rel' grew to $lines lines, past its ratcheted ceiling of $line_ceiling lines -- either shrink it back or, for a deliberate change, raise LINES in this file's KNOWN_OVERSIZE entry in the same PR (target <=$target)"
    fi
    if ((tokens > token_ceiling)); then
        report "$file" \
            "allowlisted helper '$rel' grew to ~$tokens estimated tokens, past its ratcheted ceiling of $token_ceiling tokens -- either shrink it back or, for a deliberate change, raise TOKENS in this file's KNOWN_OVERSIZE entry in the same PR"
    fi
    return 0
}

check_size() {
    local file=$1 rel=$2 lines bytes tokens over=0
    lines=$(count_lines "$file")
    bytes=$(wc -c < "$file")
    tokens=$(estimate_tokens "$bytes")
    tree_bytes=$((tree_bytes + bytes))
    if ((lines > MAX_HELPER_LINES || tokens > MAX_HELPER_TOKENS)); then
        over=1
    fi
    # `-v arr[$key]` re-expands $key as a subscript on Bash 5.1+, so a helper
    # path containing a command substitution would execute it during linting.
    # The `+present}` parameter-expansion form does not re-evaluate the
    # subscript and is the safe membership check.
    if [[ ${KNOWN_OVERSIZE[$rel]+present} ]]; then
        check_allowlisted "$file" "$rel" "$lines" "$tokens" "$over"
        return 0
    fi
    if ((over)); then
        report "$file" \
            "body is $lines lines / ~$tokens estimated tokens (budget: $MAX_HELPER_LINES lines, $MAX_HELPER_TOKENS tokens)"
    fi
    return 0
}

# Scan only the roots that exist: a missing hooks/ in a fixture is not an
# error, but a `find` on it would print one and hide real failures behind it.
scan_roots=()
for sub in skills hooks; do
    [[ -d $plugin_dir/$sub ]] && scan_roots+=("$plugin_dir/$sub")
done
if ((${#scan_roots[@]})); then
    # Captured into a variable rather than piped through `< <(...)` process
    # substitution: a process substitution's exit status is never checked, so
    # a `find` failure (e.g. an unreadable subtree) would be silently
    # discarded and the lint would exit 0 having scanned only part of the
    # tree. `set -o pipefail` (on via the file-level `set -euo pipefail`)
    # makes this assignment fail if either `find` or `sort` does.
    files_list=''
    if ! files_list=$(find "${scan_roots[@]}" -name '*.sh' -not -path '*/.system/*' | sort); then
        report "$plugin_dir" \
            "helper scan failed: find or sort exited non-zero -- the tree may be incompletely scanned (check for an unreadable subtree)"
    fi
    if [[ -n $files_list ]]; then
        while IFS= read -r file; do
            checked=$((checked + 1))
            rel=${file#"$plugin_dir"/}
            check_size "$file" "$rel"
        done <<< "$files_list"
    fi
fi

tree_tokens=$(estimate_tokens "$tree_bytes")
if ((tree_tokens > MAX_TREE_TOKENS)); then
    report "$plugin_dir" \
        "helper tree total is ~$tree_tokens estimated tokens, past the tree total ceiling of $MAX_TREE_TOKENS -- shrink something, or raise MAX_TREE_TOKENS in this file in the same PR and say why"
fi

printf 'helper size: %d helpers checked, %d violations (tree ~%d tokens, ceiling %d)\n' \
    "$checked" "$violations" "$tree_tokens" "$MAX_TREE_TOKENS"
if ((checked == 0)); then
    printf 'VIOLATION %s: no helper scripts found -- lint ran against nothing\n' "$plugin_dir" >&2
    violations=$((violations + 1))
fi
[[ $violations -eq 0 ]]
