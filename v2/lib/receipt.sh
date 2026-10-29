# shellcheck shell=bash
# ak receipt: waits for CI on the pushed head, then posts one PR comment with the reviewed head, reviewer, findings and
# CI state; writes .ak/result. A red of the branch's own prints ak ci's diagnostics and exits 1.
# shellcheck source=ship.sh
source "$AK_HOME/lib/ship.sh"
# shellcheck source=ci.sh
source "$AK_HOME/lib/ci.sh"
# shellcheck source=threads.sh
source "$AK_HOME/lib/threads.sh"

FINDING_RE='^ *(P[0-3]) *\| *([^|]*[^| ]) *\| *(fixed [0-9a-f]{7,40}|declined: .+)$'
REVIEW_FINDING_RE='^[[:space:]*-]*P[12]:'

# receipt_findings: reads finding lines on stdin and prints one "SEV | title | disposition" line per finding; refuses
# malformed lines.
receipt_findings() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n ${line//[[:space:]]/} && ${line,,} != none ]] || continue
        [[ $line =~ $FINDING_RE ]] ||
            die "malformed finding: $line" "write each line as 'P1|title|fixed <sha>' or 'P2|title|declined: reason'"
        printf '%s | %s | %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    done
}

# receipt_review_identity DIR: the findings content that a saved disposition set belongs to.
receipt_review_identity() {
    local dir=$1 findings
    if [[ -f $dir/review.md ]]; then
        findings=$(grep -E "$REVIEW_FINDING_RE" "$dir/review.md" | sed -E 's/^[[:space:]*-]*//' || true)
        if [[ -n $findings ]]; then
            printf 'findings\n%s\n' "$findings"
        elif grep -qx '[[:space:]]*NO FINDINGS[[:space:]]*' "$dir/review.md"; then
            printf 'no findings\n'
        else
            printf 'unparsed review\n%s\n' "$(cat -- "$dir/review.md")"
        fi
    elif [[ -f $dir/review.unavailable ]]; then
        printf 'unavailable\n'
    else
        printf 'no review\n'
    fi
}

# receipt_default DIR: the findings when none were given: the lines a receipt here wrote before (a merge-down runs the
# receipt again), else none when the review found nothing or could not run, else a refusal naming the flag. A review
# with findings never posts "none" by default (08c2516 bench: 8 of 12 workers spent a turn writing .ak/findings).
receipt_default() {
    local dir=$1 want=0 saved identity
    if [[ -f $dir/findings && ! -L $dir/findings ]]; then
        [[ -f $dir/findings-review && ! -L $dir/findings-review ]] ||
            die "saved findings have no review identity" "read $dir/review.md and pass each disposition with --finding"
        saved=$(<"$dir/findings-review")
        identity=$(receipt_review_identity "$dir")
        [[ $saved == "$identity" ]] ||
            die "saved findings do not match the current review" "read $dir/review.md and pass each disposition with --finding"
        cat -- "$dir/findings"
        return 0
    fi
    [[ ! -f $dir/review.md ]] || want=$(grep -cE "$REVIEW_FINDING_RE" "$dir/review.md" || true)
    ((want == 0)) || die "the review has $want findings and no dispositions were given" \
        "ak receipt --finding 'P1|title|fixed <sha>' --finding 'P2|title|declined: reason'"
    [[ ! -f $dir/review.md ]] || grep -qx '[[:space:]]*NO FINDINGS[[:space:]]*' "$dir/review.md" ||
        die "the review findings could not be parsed" "read $dir/review.md and pass each disposition with --finding"
    printf 'none\n'
}

# receipt_all_decided DIR FINDINGS: every finding the review printed has a disposition (PR bench 2026-10-01: a
# worker ran ak review, got a P1, and posted a receipt saying "none" four seconds later).
receipt_all_decided() {
    local review=$1/review.md want got titles
    [[ -f $review ]] || return 0
    want=$(grep -cE "$REVIEW_FINDING_RE" "$review" || true)
    got=$(grep -c . <<<"$2" || true)
    ((got >= want)) && return 0
    titles=$(grep -E "$REVIEW_FINDING_RE" "$review" | sed -E 's/^[[:space:]*-]*//; s/ — .*//' |
        cut -c1-80 | head -n 3 | paste -sd';' -)
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

# receipt_part_of PR: a PR that covers part of its issue must not close it on merge. A field PR for task 1 of a
# seven-task issue said "Closes #N"; merging it would have closed the issue with six tasks undone.
receipt_part_of() {
    local pr=$1 n body dir ref
    n=$(issue_number)
    dir=$(ak_dir)
    # Not being able to read the body is not "nothing to rewrite": the receipt stops rather than leave a closing line.
    body=$(gh api "repos/$(slug)/pulls/$pr" --jq '.body // ""') ||
        die "could not read the body of PR #$pr to keep it from closing #$n" "gh auth status"
    ref=$(closing_ref "$n") || exit 1
    grep -qiE "(^|[^[:alnum:]])($(closing_words))$ref([^0-9]|\$)" <<<"$body" || return 0
    # Groups: 1 the character before, 2-3 the keyword, 4 the reference (5 inside it), 6 the character after.
    sed -E "s~(^|[^[:alnum:]])($(closing_words))$ref([^0-9]|\$)~\\1Part of \\4\\6~Ig" <<<"$body" >"$dir/pr-body.md"
    gh api -X PATCH "repos/$(slug)/pulls/$pr" -F "body=@$dir/pr-body.md" >/dev/null ||
        die "could not change \"Closes #$n\" to \"Part of #$n\" on PR #$pr" "gh auth status"
}

# receipt_post PR FILE HEAD: post the comment, or update the receipt this PR already carries for HEAD. A second
# receipt on one head used to add a second comment (a field PR carried two, 32 s apart), and one run again after CI
# concluded left the earlier ci=pending receipt standing. Only a comment that opens as a receipt for this head and
# was written by this account counts: a quote of one is never edited, and a look-alike someone else posted is never
# taken over (a token with admin rights could edit it, and its author could then rewrite the receipt). A failed
# lookup or a refused update posts a new comment, as before.
receipt_post() {
    local pr=$1 file=$2 mark found id='' me body
    mark="$BANNER"$'\n\n'"**ak receipt** for head \`$3\`"
    found=$(gh api --paginate "repos/$(slug)/issues/$pr/comments?per_page=100" 2>/dev/null |
        jq -rs --arg mark "$mark" '.[][] | select((.body // "") | startswith($mark)) | "\(.id) \(.user.login // "")"' 2>/dev/null) || found=''
    # The account is asked for only when a candidate exists.
    if [[ -n $found ]] && me=$(gh api user --jq .login 2>/dev/null) && [[ -n $me ]]; then
        id=$(awk -v me="$me" '$2 == me { id = $1 } END { print id }' <<<"$found")
    fi
    if [[ $id =~ ^[0-9]+$ ]] && body=$(gh api -X PATCH "repos/$(slug)/issues/comments/$id" -F "body=@$file" 2>/dev/null); then
        printf '%s\n' "$body"
        return 0
    fi
    gh api -X POST "repos/$(slug)/issues/$pr/comments" -F "body=@$file"
}

# receipt_red_round DIR HEAD: how many distinct heads this worktree's receipts have seen red of their own, HEAD counted.
receipt_red_round() {
    local file=$1/red-heads
    [[ ! -L $file ]] || rm -f -- "$file"
    grep -qxF -- "$2" "$file" 2>/dev/null || printf '%s\n' "$2" >>"$file"
    LC_ALL=C sort -u -- "$file" | grep -c .
}

cmd_main() {
    local file="" lines="" remaining="" findings_given=0 dir head pr runs ci summary review findings note body url fixed declined count open inherited base identity own diag round
    local usage='usage: ak receipt [--finding LINE]... [--findings F] [--remaining TEXT]'
    while (($#)); do
        case $1 in
            --finding) findings_given=1; lines+="${2:-}"$'\n'; shift 2 || usage_die "$usage" ;;
            --findings) findings_given=1; file=${2:-}; shift 2 || usage_die "$usage" ;;
            --remaining) remaining=${2:-}; shift 2 || usage_die "$usage" ;;
            *) usage_die "$usage" ;;
        esac
    done
    [[ -z $file || -f $file ]] || die "findings file not found: $file" "ak receipt --finding 'P1|title|fixed <sha>'"
    [[ -z $file ]] || lines+=$(<"$file")$'\n'
    cd -- "$(worktree_root)" || exit 1
    dir=$(ak_dir)
    ((!findings_given)) || [[ -n ${lines//[[:space:]]/} ]] ||
        die "findings input is empty" "pass 'none' or one disposition per review finding"
    [[ -n ${lines//[[:space:]]/} ]] || lines=$(receipt_default "$dir") || exit 1
    findings=$(receipt_findings <<<"$lines") || exit 1
    head=$(ci_head)
    pr=$(ship_pr_find)
    [[ -n $pr ]] || die "no open PR for $(git branch --show-current)" "ak ship --message '<conventional commit>'"
    # The receipt waits for CI the way ak ci does, so a worker spends no turn on ak ci first (bench 2026-10-27).
    ci_blocked
    runs=$(ci_wait "$head" 1800 0) || exit 1
    # A parent may have merged during the wait, leaving the PR conflicted with its checks unchanged.
    ci_blocked
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
    if [[ -n $open ]]; then
        threads_print "$open"
        die "PR #${pr%% *} has $(grep -c . <<<"$open") unresolved review threads ($(threads_summary "$open"))" \
            "fix or decline each thread, resolve it with ak threads --resolve ID --note '<fixed in sha: what now happens | declined: reason>', then ak receipt again"
    fi
    [[ -z $remaining ]] || receipt_part_of "${pr%% *}"
    # The decided lines stay for a later receipt here (a merge-down), written fresh, never through a link.
    rm -f -- "$dir/findings"
    if [[ -n $findings ]]; then grep -v '^[[:space:]]*$' <<<"$lines" >"$dir/findings"; else printf 'none\n' >"$dir/findings"; fi
    identity=$(receipt_review_identity "$dir") || exit 1
    printf '%s\n' "$identity" >"$dir/findings-review"
    # A red prints what ak ci prints; a failure of the branch's own exits 1 after the receipt so the worker fixes it.
    inherited='' own='' diag=''
    if [[ $ci == red ]]; then
        inherited=$(ci_inherited "$runs")
        own=$(ci_only "$runs" "$inherited")
        diag=$(printf '%s\n' "$summary" "$inherited" "$own" | grep -v '^$'; ci_print_failures "$runs" || true)
    fi
    receipt_body "$head" "$(receipt_reviewer "$dir")" "$review" "CI: $ci (${summary#* })" "$findings" "$remaining" >"$dir/receipt.md"
    body=$(receipt_post "${pr%% *}" "$dir/receipt.md" "$head") ||
        die "could not post the receipt comment" "gh auth status"
    url=$(jq -r '.html_url' <<<"$body")
    count=$(grep -c . <<<"$findings" || true)
    fixed=$(grep -c ' | fixed ' <<<"$findings" || true)
    declined=$(grep -c ' | declined: ' <<<"$findings" || true)
    note="findings=$count fixed=$fixed declined=$declined"
    [[ -z $remaining ]] || note+="; remaining: ${remaining//$'\n'/ }"
    # Red checks the base branch fails too: the collect line then shows the operator that the base is red, not this PR.
    # The base name is on its way to a line the root reads, so it is reduced to ref-name characters, never dropped.
    if [[ $inherited =~ ^inherited=(.+)\ from=([^ ]+)\ note= ]]; then
        base=${BASH_REMATCH[2]//[^A-Za-z0-9._\/+@-]/}
        note+="; base-red: ${BASH_REMATCH[1]} (also red on ${base:-the base branch})"
    fi
    # Checks that only CI caught on this PR: the operator reads them on the collect line and can add a local suite.
    ! ci_only_trusted "$dir/ci-only" ||
        note+="; ci-only: $(LC_ALL=C tr -cd 'A-Za-z0-9 _.()/\n-' <"$dir/ci-only" | cut -c1-60 | head -n 20 | paste -sd, -)"
    printf 'receipt=%s\n' "$url"
    # A red of the branch's own below the third round writes no result: ak wait reads a result as the worker's end,
    # and this worker is about to fix and ship again. The third red head is recorded, and the worker ends.
    round=0
    [[ -z $own ]] || round=$(receipt_red_round "$dir" "$head")
    if ((round > 0 && round < 3)); then
        [[ -z $diag ]] || printf '%s\n' "$diag"
        printf 'red round %s of 3: fix what the diagnostics name, ak ship, then ak receipt again\n' "$round"
        return 1
    fi
    printf 'pr=%s\nci=%s\nreview=%s\nhead=%s\nnote=%s\n' "${pr#* }" "$ci" "$review" "$head" "$note" >"$dir/result"
    paste -sd' ' "$dir/result"
    [[ -z $diag ]] || printf '%s\n' "$diag"
    ((round == 0)) || printf 'red round %s of 3: recorded as red; end with the result line\n' "$round"
}
