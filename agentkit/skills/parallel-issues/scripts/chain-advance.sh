#!/usr/bin/env bash
# Resolve chain bases and prove a stacked PR is safe after retargeting.
set -euo pipefail

readonly PROGNAME=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'
readonly SHA_RE='^[0-9a-f]{40}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'

MODE=''
REF=''
PR=''
BASE=''
REPO=''
GH_BIN=${CHAIN_ADVANCE_GH:-gh}

usage() {
    cat <<EOF
Usage:
  $PROGNAME --resolve-base REF
  $PROGNAME --retarget --pr N --base B [--repo OWNER/REPO]

--resolve-base is read-only and prints the full commit SHA Git resolves for REF.
--retarget edits the PR base, then proves the new base, ancestry, CI, approval,
and closing-issue linkage before reporting success.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --resolve-base)
                require_value "$1" "${2-}"
                [[ -z $MODE ]] || die '--resolve-base cannot be combined with another mode'
                MODE=resolve
                REF=$2
                shift 2
                ;;
            --resolve-base=*)
                [[ -z $MODE ]] || die '--resolve-base cannot be combined with another mode'
                MODE=resolve
                REF=${1#*=}
                shift
                ;;
            --retarget)
                [[ -z $MODE ]] || die '--retarget cannot be combined with another mode'
                MODE=retarget
                shift
                ;;
            --pr)
                require_value "$1" "${2-}"
                PR=$2
                shift 2
                ;;
            --pr=*) PR=${1#*=}; shift ;;
            --base)
                require_value "$1" "${2-}"
                BASE=$2
                shift 2
                ;;
            --base=*) BASE=${1#*=}; shift ;;
            --repo)
                require_value "$1" "${2-}"
                REPO=$2
                shift 2
                ;;
            --repo=*) REPO=${1#*=}; shift ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die "unexpected argument: $1"
                ;;
            *) die "unexpected argument: $1" ;;
        esac
    done
}

validate_args() {
    [[ $MODE == resolve || $MODE == retarget ]] ||
        die 'choose exactly one mode: --resolve-base REF or --retarget'
    if [[ $MODE == resolve ]]; then
        [[ -n $REF && $REF != -* && $REF != *$'\n'* && $REF != *$'\r'* ]] ||
            die '--resolve-base requires a safe single-line ref'
        [[ -z $PR && -z $BASE && -z $REPO ]] ||
            die '--resolve-base does not accept --pr, --base, or --repo'
        return 0
    fi
    [[ $PR =~ $UINT_RE ]] || die '--pr must be a positive integer'
    [[ $BASE =~ ^[A-Za-z0-9._/-]+$ && $BASE != -* && $BASE != /* &&
        $BASE != */ && $BASE != *..* && $BASE != *//* && $BASE != *'@{'* ]] ||
        die '--base must be a safe branch ref'
    [[ -z $REPO || $REPO =~ $SLUG_RE ]] ||
        die '--repo must look like OWNER/REPO'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
    command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
}

resolve_base() {
    local resolved
    if ! resolved=$(git rev-parse --verify --end-of-options "${REF}^{commit}" 2>&1); then
        die "could not resolve base ref: $REF${resolved:+: $resolved}"
    fi
    [[ $resolved =~ $SHA_RE ]] || die "Git returned no single full SHA for base ref: $REF"
    printf '%s\n' "$resolved"
}

resolve_repo() {
    [[ -n $REPO ]] && return 0
    REPO=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) ||
        die 'could not derive OWNER/REPO; pass --repo OWNER/REPO'
    [[ $REPO =~ $SLUG_RE ]] || die 'gh repo view returned no usable OWNER/REPO'
}

fetch_pr() {
    "$GH_BIN" pr view "$PR" --repo "$REPO" \
        --json number,baseRefName,headRefName,headRefOid,statusCheckRollup,reviewDecision,reviews,closingIssuesReferences
}

# The retarget boundary, read from the forge's own clock rather than this
# machine's: every freshness comparison below is against provider timestamps, so
# a skewed local clock would silently decide the verdict.
retarget_boundary() {
    local headers date_line epoch
    headers=$("$GH_BIN" api --include /rate_limit 2>/dev/null) ||
        die 'could not read provider time for the retarget boundary; evidence provenance is unavailable'
    date_line=$(printf '%s\n' "$headers" |
        sed -nE 's/^[Dd]ate:[[:space:]]*(.+[^[:space:]])[[:space:]]*$/\1/p' | head -n 1)
    [[ -n $date_line ]] ||
        die 'provider response carried no Date header; evidence provenance is unavailable'
    epoch=$(date -u -d "$date_line" +%s 2> /dev/null) ||
        die 'provider Date header was unparseable; evidence provenance is unavailable'
    [[ $epoch =~ ^[0-9]+$ ]] ||
        die 'provider Date header did not yield an epoch; evidence provenance is unavailable'
    printf '%s\n' "$epoch"
}

iso_to_epoch() {
    local value=$1 epoch
    [[ -n $value && $value != null ]] || return 1
    epoch=$(date -u -d "$value" +%s 2> /dev/null) || return 1
    [[ $epoch =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$epoch"
}

# `gh pr edit --base` leaves headRefOid untouched, and both the check rollup and
# provider approvals hang off the head commit -- so evidence produced against the
# OLD base survives the retarget and satisfies a naive green/approved test. The
# workflow does not re-run on a base change either (`pull_request` defaults to
# opened/synchronize/reopened), so this cannot self-heal: it must fail closed
# until CI is actually re-run against the new base. chains.md is explicit that a
# stale digest is a stop signal, not a green result.
check_ci_fresh() {
    local pr_json=$1 boundary=$2 stale
    stale=$(jq -r --argjson boundary "$boundary" '
        [ .statusCheckRollup[]?
          | (.completedAt // .startedAt // .createdAt // "") as $ts
          | (.name // .context // "check") as $label
          | if ($ts | length) == 0 then $label
            else ($ts | fromdateiso8601) as $epoch
                 | if $epoch <= $boundary then $label else empty end
            end
        ] | join(", ")
    ' <<<"$pr_json") ||
        die 'check rollup timestamps were unreadable; CI provenance is unavailable'
    [[ -z $stale ]] ||
        die "CI evidence predates the retarget (stale: $stale); re-run CI against the new base -- a stale digest is a stop signal, not a green result"
}

check_approval_fresh() {
    local pr_json=$1 boundary=$2 fresh
    fresh=$(jq -r --argjson boundary "$boundary" '
        any(.reviews[]?;
            (.state == "APPROVED")
            and ((.submittedAt // .submitted_at // "") | length) > 0
            and (((.submittedAt // .submitted_at) | fromdateiso8601) > $boundary))
    ' <<<"$pr_json") ||
        die 'review timestamps were unreadable; approval provenance is unavailable'
    [[ $fresh == true ]] ||
        die 'approval predates the retarget; residual approval state after a base change remains a human judgment -- record the residue in the handoff and stop'
}

check_ancestry() {
    local head_sha=$1 compare_json behind status
    compare_json=$("$GH_BIN" api "repos/$REPO/compare/$BASE...$head_sha") ||
        die "base...head comparison failed for $BASE...$head_sha"
    behind=$(jq -r '.behind_by // empty' <<<"$compare_json") ||
        die "base...head comparison was not valid JSON for $BASE...$head_sha"
    [[ $behind =~ ^[0-9]+$ ]] ||
        die "base...head comparison omitted behind_by for $BASE...$head_sha"
    ((behind == 0)) || die "base...head is stale: $BASE...$head_sha behind_by=$behind"
    status=$(jq -r '.status // empty' <<<"$compare_json") ||
        die "base...head comparison could not report status for $BASE...$head_sha"
    [[ -z $status || $status == ahead || $status == identical ]] ||
        die "base...head is not an ancestor-safe comparison: status=$status"
}

check_ci() {
    local pr_json=$1 total pass pending failing
    IFS=$'\t' read -r total pass pending failing < <(
        jq -r '
            def bucket:
              if (has("status") or has("conclusion")) then
                if ((.status // "") | ascii_upcase) != "COMPLETED" then "pending"
                elif ((.conclusion // "") | ascii_upcase
                      | . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "pass"
                else "fail" end
              else
                if ((.state // "") | ascii_upcase) == "SUCCESS" then "pass"
                elif ((.state // "") | ascii_upcase
                      | . == "PENDING" or . == "EXPECTED" or . == "") then "pending"
                else "fail" end
              end;
            [ .statusCheckRollup[]? | bucket ] as $checks
            | [($checks | length),
               ([$checks[] | select(. == "pass")] | length),
               ([$checks[] | select(. == "pending")] | length),
               ([$checks[] | select(. == "fail")] | length)]
            | @tsv
        ' <<<"$pr_json"
    ) || die 'could not parse statusCheckRollup; CI evidence unavailable'
    [[ $total =~ ^[0-9]+$ && $pass =~ ^[0-9]+$ && $pending =~ ^[0-9]+$ &&
        $failing =~ ^[0-9]+$ ]] || die 'statusCheckRollup counts were malformed; CI evidence unavailable'
    ((total > 0)) || die 'statusCheckRollup is empty; CI evidence unavailable'
    ((pending == 0 && failing == 0)) ||
        die "CI is stale or not green: total=$total pass=$pass pending=$pending failing=$failing"
    printf '%s\t%s\n' "$total" "$pass"
}

check_approval() {
    local pr_json=$1 head_sha=$2 decision current
    decision=$(jq -r '.reviewDecision // empty' <<<"$pr_json") ||
        die 'reviewDecision was unreadable; approval evidence unavailable'
    [[ $decision == APPROVED ]] ||
        die "approval is not current: reviewDecision=${decision:-missing}; stale approval disposition remains human judgment"
    current=$(jq -r --arg head "$head_sha" '
        any(.reviews[]?;
            (.state == "APPROVED") and
            (((if (.commit | type) == "object" then .commit.oid
               elif (.commit | type) == "string" then .commit
               else .commitId end // "") | tostring) == $head))
    ' <<<"$pr_json") || die 'reviews were unreadable; approval evidence unavailable'
    [[ $current == true ]] ||
        die 'approval is stale or cannot be proven current; stale approval disposition remains human judgment'
}

closing_issue_count() {
    jq -r '
        (.closingIssuesReferences // []) as $references
        | (if ($references | type) == "array" then $references
           else ($references.nodes // []) end)
        | length
    ' <<<"$1"
}

retarget() {
    local pr_json actual_base head_ref head_sha ci_counts total pass closing_count boundary
    resolve_repo
    # Captured before the edit so anything produced against the old base sorts
    # strictly below it.
    boundary=$(retarget_boundary)
    "$GH_BIN" pr edit "$PR" --repo "$REPO" --base "$BASE" >/dev/null ||
        die "could not retarget PR #$PR to base $BASE"
    pr_json=$(fetch_pr) || die "could not re-read PR #$PR after retarget"
    actual_base=$(jq -r '.baseRefName // empty' <<<"$pr_json") ||
        die 'baseRefName was unreadable after retarget'
    [[ $actual_base == "$BASE" ]] ||
        die "baseRefName proof failed: requested=$BASE actual=${actual_base:-missing}"
    head_ref=$(jq -r '.headRefName // empty' <<<"$pr_json") ||
        die 'headRefName was unreadable after retarget'
    head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_json") ||
        die 'headRefOid was unreadable after retarget'
    [[ -n $head_ref && $head_sha =~ $SHA_RE ]] ||
        die 'head ref/SHA evidence was missing after retarget'
    check_ancestry "$head_sha"
    ci_counts=$(check_ci "$pr_json")
    IFS=$'\t' read -r total pass <<<"$ci_counts"
    check_ci_fresh "$pr_json" "$boundary"
    check_approval "$pr_json" "$head_sha"
    check_approval_fresh "$pr_json" "$boundary"
    closing_count=$(closing_issue_count "$pr_json") ||
        die 'closingIssuesReferences was unreadable after retarget'
    [[ $closing_count =~ ^[1-9][0-9]*$ ]] ||
        die 'closingIssuesReferences is empty after retarget; linkage evidence is missing'
    printf 'retargeted pr #%s base=%s head=%s sha=%s ci=%s/%s green:post-retarget approval=current:post-retarget ancestry=verified closing-issues=%s\n' \
        "$PR" "$BASE" "$head_ref" "$head_sha" "$pass" "$total" "$closing_count"
}

main() {
    parse_args "$@"
    validate_args
    if [[ $MODE == resolve ]]; then
        resolve_base
    else
        retarget
    fi
}

main "$@"
