# shellcheck shell=bash
# ak receipt: one PR comment with the reviewed head, reviewer, findings and CI state; writes .ak/result.
# shellcheck source=ship.sh
source "$AK_HOME/lib/ship.sh"
# shellcheck source=ci.sh
source "$AK_HOME/lib/ci.sh"
# shellcheck source=threads.sh
source "$AK_HOME/lib/threads.sh"

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

# receipt_all_decided DIR FINDINGS: every finding the review printed has a disposition (PR bench 2026-10-01: a
# worker ran ak review, got a P1, and posted a receipt saying "none" four seconds later).
receipt_all_decided() {
    local review=$1/review.md want got titles
    [[ -f $review ]] || return 0
    want=$(grep -cE '^P[12]:' "$review" || true)
    got=$(grep -c . <<<"$2" || true)
    ((got >= want)) && return 0
    titles=$(grep -E '^P[12]:' "$review" | sed 's/ — .*//' | cut -c1-80 | head -n 3 | paste -sd';' -)
    die "the review has $want findings but the findings file decides $got: $titles" \
        "write one line per finding: P1|title|fixed <sha> or P2|title|declined: reason"
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
    [[ -z ${6:-} ]] || printf -- '- Remaining: %s\n' "$6"
    printf '\n'
    attribution
}

cmd_main() {
    local file="" remaining="" dir head pr runs ci summary review findings note body url fixed declined count open
    while (($#)); do
        case $1 in
            --findings) file=${2:-}; shift 2 || usage_die "usage: ak receipt --findings F [--remaining TEXT]" ;;
            --remaining) remaining=${2:-}; shift 2 || usage_die "usage: ak receipt --findings F [--remaining TEXT]" ;;
            *) usage_die "usage: ak receipt --findings F [--remaining TEXT]" ;;
        esac
    done
    [[ -n $file ]] || usage_die "usage: ak receipt --findings F [--remaining TEXT]"
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
    # A receipt before the review hides the review's findings (PR bench 2026-10-01: a worker posted its receipt,
    # then ran ak review and found the bug too late).
    [[ $review != skipped ]] || die "no review of this branch yet" "ak review"
    receipt_all_decided "$dir" "$findings"
    # Comments on the PR from review bots and people are findings too; each is resolved or declined before the receipt.
    open=$(threads_open "$(slug)" "${pr%% *}") || die "cannot read the review threads on PR #${pr%% *}" "gh auth status"
    [[ -z $open ]] || die "PR #${pr%% *} has $(grep -c . <<<"$open") unresolved review threads ($(threads_summary "$open"))" "ak threads"
    receipt_body "$head" "$(receipt_reviewer "$dir")" "$review" "CI: $ci (${summary#* })" "$findings" "$remaining" >"$dir/receipt.md"
    body=$(gh api -X POST "repos/$(slug)/issues/${pr%% *}/comments" -F "body=@$dir/receipt.md") ||
        die "could not post the receipt comment" "gh auth status"
    url=$(jq -r '.html_url' <<<"$body")
    count=$(grep -c . <<<"$findings" || true)
    fixed=$(grep -c ' | fixed ' <<<"$findings" || true)
    declined=$(grep -c ' | declined: ' <<<"$findings" || true)
    note="findings=$count fixed=$fixed declined=$declined"
    [[ -z $remaining ]] || note+="; remaining: ${remaining//$'\n'/ }"
    # Checks that only CI caught on this PR: the operator reads them on the collect line and can add a local suite.
    [[ ! -s $dir/ci-only || -L $dir/ci-only ]] ||
        note+="; ci-only: $(LC_ALL=C tr -cd 'A-Za-z0-9 _.()/\n-' <"$dir/ci-only" | cut -c1-60 | head -n 20 | paste -sd, -)"
    printf 'pr=%s\nci=%s\nreview=%s\nhead=%s\nnote=%s\n' "${pr#* }" "$ci" "$review" "$head" "$note" >"$dir/result"
    printf 'receipt=%s\n' "$url"
    paste -sd' ' "$dir/result"
}
