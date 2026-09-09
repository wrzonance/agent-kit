#!/usr/bin/env bash
# Shared canonical PR-diff rendering for consent and adversarial review.

# Vendored trees excluded from every review payload regardless of declaration
# (issue #609); repository-specific generated paths come from the BASE
# revision's AGENT_GENERATED_PATHS, never from the checkout under review.
CANONICAL_DIFF_BUILTIN_EXCLUSIONS=(vendor third_party node_modules)

# Resolved once, at source time, before any caller changes directory: this
# file is always sourced via a path relative to the caller's own SCRIPT_DIR,
# and BASH_SOURCE keeps whatever form it was sourced with -- a relative path
# only resolves against the cwd at the moment it is interpreted. consent-
# record.sh's payload_command renders the canonical diff inside `(cd --
# "$WORKTREE" && ...)` subshells, so resolving the sibling repo-config.sh
# lazily inside canonical_diff_exclusions would silently miss it once the
# caller has cd'd elsewhere (issue #609 P2): every declared
# AGENT_GENERATED_PATHS exclusion then vanishes without warning, and the
# payload a reviewer sees mismatches adversarial-run.sh's own rendering.
if [[ -z ${CANONICAL_DIFF_LIB_DIR:-} ]]; then
    CANONICAL_DIFF_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) ||
        CANONICAL_DIFF_LIB_DIR=$(dirname -- "${BASH_SOURCE[0]}")
    readonly CANONICAL_DIFF_LIB_DIR
fi

# canonical_diff_exclusions REV -- one `:(exclude,top)PREFIX` pathspec per line
# for REV's declared AGENT_GENERATED_PATHS plus the built-ins above. REV is
# `origin/<base>` or a full SHA; a REV without .agent/config.env yields only
# the built-ins.
canonical_diff_exclusions() {
    local rev=$1 resolver spec declared='' config_tmp
    local -a specs=("${CANONICAL_DIFF_BUILTIN_EXCLUSIONS[@]}") declared_items=()
    resolver="$CANONICAL_DIFF_LIB_DIR/../repo-config.sh"
    if [[ -x $resolver ]] && config_tmp=$(mktemp) && git show "$rev:.agent/config.env" >"$config_tmp" 2>/dev/null; then
        declared=$("$resolver" --repo-root "$(git rev-parse --show-toplevel)" --config-file "$config_tmp" \
            --get AGENT_GENERATED_PATHS 2>/dev/null) || declared=''
    fi
    rm -f -- "${config_tmp:-}"
    IFS=, read -ra declared_items <<< "$declared"
    for spec in "${specs[@]}" "${declared_items[@]}"; do
        while [[ $spec == ./* ]]; do spec=${spec#./}; done
        while [[ $spec == */ ]]; do spec=${spec%/}; done
        [[ -n $spec && $spec != . ]] || continue
        printf ':(exclude,top)%s\n' "$spec"
    done
}

# canonical_diff_range RANGE REV -- the exact diff flags every renderer uses.
canonical_diff_range() {
    local -a pathspecs=()
    mapfile -t pathspecs < <(canonical_diff_exclusions "$2")
    # ':/' anchors the pathspec at the repository top: the payload is
    # repo-relative from any cwd (`.` would shrink it from a subdirectory).
    git --no-pager diff --find-renames --unified=25 "$1" -- ':/' "${pathspecs[@]}"
}

canonical_diff() {
    local base_ref=${1:-}
    [[ -n $base_ref ]] || return 1
    git check-ref-format --branch "$base_ref" >/dev/null 2>&1 || return 1
    canonical_diff_range "origin/$base_ref...HEAD" "origin/$base_ref"
}

# canonical_diff_token_estimate FILE -- bytes / 3.5, rounded down.
canonical_diff_token_estimate() {
    local bytes
    bytes=$(wc -c <"$1") || return 1
    printf '%s\n' $(( bytes * 2 / 7 ))
}

# diff_touched_paths_from_range RANGE REV DIFF_FILE -- the sorted, unique,
# repository-relative paths RANGE touches, using REV's declared exclusions
# (mirrors canonical_diff_range's own pathspecs exactly) and derived from
# git's own `--raw -z` records rather than parsed diff text (issue #609 P1,
# preferred over diff_touched_paths whenever the range/rev are known): `-z`
# never C-quotes a path (so a non-ASCII or special-character filename cannot
# hide outside the recovered set), a rename contributes both its old and new
# path, and every file record is counted whether or not it carries a hunk (a
# mode-only change, a rename with no content change, a binary file). Cross-
# checked against DIFF_FILE's own `diff --git` record count so a DIFF_FILE
# that was not actually rendered from RANGE/REV -- or is not a git diff at
# all -- fails closed (rc 1) instead of silently under-reporting.
diff_touched_paths_from_range() {
    local range=$1 rev=$2 diff_file=$3 raw_tmp meta status diff_git_count
    local -a pathspecs=() fields=() out=()
    mapfile -t pathspecs < <(canonical_diff_exclusions "$rev")
    raw_tmp=$(mktemp) || return 1
    if ! git diff --find-renames --raw -z "$range" -- ':/' "${pathspecs[@]}" >"$raw_tmp"; then
        rm -f -- "$raw_tmp"
        return 1
    fi
    mapfile -d '' -t fields <"$raw_tmp"
    rm -f -- "$raw_tmp"
    local i=0 n=${#fields[@]} records=0
    while (( i < n )); do
        meta=${fields[i]}
        if [[ -z $meta ]]; then
            i=$((i + 1))
            continue
        fi
        [[ $meta == :* ]] || return 1
        status=${meta##* }
        i=$((i + 1))
        records=$((records + 1))
        if [[ $status == R* || $status == C* ]]; then
            (( i + 1 < n )) || return 1
            out+=("${fields[i]}" "${fields[i + 1]}")
            i=$((i + 2))
        else
            (( i < n )) || return 1
            out+=("${fields[i]}")
            i=$((i + 1))
        fi
    done
    diff_git_count=$(grep -c -E '^diff --git ' -- "$diff_file" 2>/dev/null) || diff_git_count=0
    (( records == diff_git_count )) || return 1
    # `-z` never quotes a path, so a literal newline byte inside a path
    # survives into $out verbatim (issue #609 P1, round 3): joining $out with
    # `\n` below would then split that single path across two output lines
    # and silently defeat the subset gate. Every consumer of this set (the
    # persisted paths file, its hash, and the comm(1) comparison in
    # consent-record.sh) is itself newline-delimited, so there is no safe way
    # to emit such a path here -- fail closed instead of corrupting the set.
    local p
    for p in "${out[@]}"; do
        [[ $p != *$'\n'* ]] || return 1
    done
    printf '%s\n' "${out[@]}" | sort -u
}

# diff_touched_paths FILE -- sorted, unique, repository-relative paths a
# unified diff touches (issue #609 subset consent), read from its own
# `--- a/`/`+++ b/` file headers so a payload's granted paths and a later
# payload's paths are always derived the same way, whether FILE is a
# canonical rendering or a caller-supplied diff. `/dev/null` create/delete
# markers never match the `a/`/`b/` prefix, so they contribute nothing.
#
# This text-only parser is the fallback for when the range/rev that produced
# FILE are not known to the caller (prefer diff_touched_paths_from_range
# whenever they are, e.g. any canonical --base-ref/--base-sha rendering) --
# it cannot safely unescape a git-quoted path, so it refuses (rc 1) rather
# than guess whenever it sees one, and it refuses whenever its recovered
# `---`/`+++` pair count does not match FILE's own `diff --git` record
# count, which also catches a rename-without-hunks, a mode-only change, or a
# binary file that a plain header grep would silently drop from the set
# (issue #609 P1).
diff_touched_paths() {
    local file=$1 diff_git_count pair_count
    grep -qE '^(---|\+\+\+) "' -- "$file" 2>/dev/null && return 1
    diff_git_count=$(grep -c -E '^diff --git ' -- "$file" 2>/dev/null) || diff_git_count=0
    if (( diff_git_count > 0 )); then
        # A deleted file renders `+++ /dev/null` (an added file `--- /dev/null`
        # with a normal `+++ b/`), so counting only `(a|b)/`-prefixed `+++`
        # lines under-counts every deletion and wrongly refuses an otherwise
        # well-formed diff (issue #609 P2, round 3); accept `/dev/null` on
        # the `+++` side as an equally complete record.
        pair_count=$(grep -c -E '^\+\+\+ ((a|b)/|/dev/null)' -- "$file" 2>/dev/null) || pair_count=0
        (( pair_count == diff_git_count )) || return 1
    fi
    grep -E '^(---|\+\+\+) (a|b)/' -- "$file" 2>/dev/null |
        sed -E 's#^(---|\+\+\+) (a|b)/##' |
        sort -u
}
