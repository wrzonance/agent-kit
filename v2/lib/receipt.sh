# shellcheck shell=bash
# ak receipt: one PR comment with the reviewed head, reviewer, findings and CI state; writes .ak/result.
# shellcheck source=ship.sh
source "$AK_HOME/lib/ship.sh"
# shellcheck source=ci.sh
source "$AK_HOME/lib/ci.sh"

FINDING_RE='^ *(P[0-3]) *\| *([^|]*[^| ]) *\| *(fixed [0-9a-f]{7,40}|declined: .+)$'

# receipt_findings FILE: prints one "SEV | title | disposition" line per finding; refuses malformed lines.
receipt_findings() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n ${line//[[:space:]]/} && ${line,,} != none ]] || continue
        [[ $line =~ $FINDING_RE ]] ||
            die "malformed finding: $line" "write each line as 'P1|title|fixed <sha>' or 'P2|title|declined: reason'"
        printf '%s | %s | %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    done <"$1"
}

receipt_review() {
    local dir=$1
    if [[ -f $dir/review.md ]]; then
        printf 'done\n'
    elif [[ -f $dir/review.unavailable ]]; then
        printf 'unavailable\n'
    else
        printf 'skipped\n'
    fi
}

# The reviewer model from review.md's first line: its model=X token, or the line itself.
receipt_reviewer() {
    local line
    [[ -f $1/review.md ]] || { printf 'none\n'; return 0; }
    line=$(head -n 1 -- "$1/review.md")
    if [[ $line =~ model=([^[:space:]]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        line=${line#\# }
        printf '%s\n' "${line:0:80}"
    fi
}

# receipt_body HEAD REVIEWER REVIEW CI FINDINGS: the comment markdown.
receipt_body() {
    printf '%s\n\n**ak receipt** for head %s\n\n' "$BANNER" "\`$1\`"
    printf -- '- Reviewer: %s (review=%s)\n- %s\n' "$2" "$3" "$4"
    if [[ -z $5 ]]; then
        printf -- '- Findings: none\n'
    else
        printf -- '- Findings:\n'
        printf '  - %s\n' "${5//$'\n'/$'\n'  - }"
    fi
    printf '\n'
    attribution
}

cmd_main() {
    local file="" dir head pr runs ci summary review findings note body url fixed declined count
    [[ ${1:-} == --findings && -n ${2:-} && $# == 2 ]] || usage_die "usage: ak receipt --findings F"
    file=$2
    [[ -f $file ]] || die "findings file not found: $file" "printf 'none\\n' >$file"
    file="$(cd -- "$(dirname -- "$file")" && pwd)/$(basename -- "$file")"
    cd -- "$(worktree_root)" || exit 1
    dir=$(ak_dir)
    findings=$(receipt_findings "$file") || exit 1
    head=$(ci_head)
    pr=$(ship_pr_find)
    [[ -n $pr ]] || die "no open PR for $(git branch --show-current)" "ak ship --message '<conventional commit>'"
    runs=$(ci_runs "$head") || exit 1
    summary=$(ci_summary "$runs")
    ci=${summary%% *}
    ci=${ci#ci=}
    review=$(receipt_review "$dir")
    receipt_body "$head" "$(receipt_reviewer "$dir")" "$review" "CI: $ci (${summary#* })" "$findings" >"$dir/receipt.md"
    body=$(gh api -X POST "repos/$(slug)/issues/${pr%% *}/comments" -F "body=@$dir/receipt.md") ||
        die "could not post the receipt comment" "gh auth status"
    url=$(jq -r '.html_url' <<<"$body")
    count=$(grep -c . <<<"$findings" || true)
    fixed=$(grep -c ' | fixed ' <<<"$findings" || true)
    declined=$(grep -c ' | declined: ' <<<"$findings" || true)
    note="findings=$count fixed=$fixed declined=$declined"
    printf 'pr=%s\nci=%s\nreview=%s\nhead=%s\nnote=%s\n' "${pr#* }" "$ci" "$review" "$head" "$note" >"$dir/result"
    printf 'receipt=%s\n' "$url"
    paste -sd' ' "$dir/result"
}
