#!/usr/bin/env bash
# Shared canonical PR-diff rendering for consent and adversarial review.

# Vendored trees excluded from every review payload regardless of declaration
# (issue #609); repository-specific generated paths come from the BASE
# revision's AGENT_GENERATED_PATHS, never from the checkout under review.
CANONICAL_DIFF_BUILTIN_EXCLUSIONS=(vendor third_party node_modules)

# canonical_diff_exclusions REV -- one `:(exclude,top)PREFIX` pathspec per line
# for REV's declared AGENT_GENERATED_PATHS plus the built-ins above. REV is
# `origin/<base>` or a full SHA; a REV without .agent/config.env yields only
# the built-ins.
canonical_diff_exclusions() {
    local rev=$1 resolver spec declared='' config_tmp
    local -a specs=("${CANONICAL_DIFF_BUILTIN_EXCLUSIONS[@]}") declared_items=()
    resolver=$(dirname -- "${BASH_SOURCE[0]}")/../repo-config.sh
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

# diff_touched_paths FILE -- sorted, unique, repository-relative paths a
# unified diff touches (issue #609 subset consent), read from its own
# `--- a/`/`+++ b/` file headers so a payload's granted paths and a later
# payload's paths are always derived the same way, whether FILE is a
# canonical rendering or a caller-supplied diff. `/dev/null` create/delete
# markers never match the `a/`/`b/` prefix, so they contribute nothing.
diff_touched_paths() {
    local file=$1
    grep -E '^(---|\+\+\+) (a|b)/' -- "$file" 2>/dev/null |
        sed -E 's#^(---|\+\+\+) (a|b)/##' |
        sort -u
}
