#!/usr/bin/env bash
# Resolve chain bases and prove a stacked PR is safe after retargeting.
set -euo pipefail
umask 077

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
RETARGET_APPLIED=false
BOUNDARY_SOURCE=''
BOUNDARY_EPOCH=''

usage() {
    cat <<EOF
Usage:
  $PROGNAME --resolve-base REF
  $PROGNAME --retarget --pr N --base B [--repo OWNER/REPO]

--resolve-base is read-only and prints the full commit SHA Git resolves for REF.
--retarget first proves the intended base is not ahead of the current head. It
then edits the PR base and proves the new base, ancestry, CI, approval, and
closing-issue linkage before reporting success. Exit 1 means no base edit was
confirmed; exit 2 means the edit succeeded but a later proof failed.
EOF
}

die() {
    if [[ $RETARGET_APPLIED == true ]]; then
        printf '%s: retarget applied base=%s; %s\n' "$PROGNAME" "$BASE" "$*" >&2
        exit 2
    fi
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

iso_to_epoch() {
    local value=$1 epoch
    [[ -n $value && $value != null ]] || return 1
    epoch=$(date -u -d "$value" +%s 2> /dev/null) || return 1
    [[ $epoch =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$epoch"
}

# GitHub's timeline is the source of truth for a base edit. A local/provider
# clock read after the edit is not a boundary: it can make the proof impossible
# when CI started during the edit, and it changes on every retry.
timeline_boundary() {
    local timeline event_time epoch
    timeline=$("$GH_BIN" api --paginate "repos/$REPO/issues/$PR/timeline" 2>/dev/null) || return 1
    event_time=$(jq -r --arg base "$BASE" '
        def first_nonempty: first(.[] | select(type == "string" and length > 0)) // "";
        [ .[]?
          | select((.event // "") == "base_ref_changed")
          | ([.base_ref, .baseRefName, .base_ref_name] | first_nonempty) as $event_base
          | select($event_base == "" or $event_base == $base)
          | ([.created_at, .createdAt] | first_nonempty)
          | select(length > 0)
        ] | last // empty
    ' <<<"$timeline") || return 1
    [[ -n $event_time ]] || return 1
    epoch=$(iso_to_epoch "$event_time") || return 1
    printf '%s\n' "$epoch"
}

path_has_no_symlink() {
    local path=$1 current='' component
    local -a components
    [[ $path = /* ]] || return 1
    IFS=/ read -r -a components <<<"${path#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || return 1
        current+="/$component"
        [[ ! -L $current ]] || return 1
    done
}

boundary_file() {
    local git_dir safe_base
    git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
    [[ $git_dir = /* && -d $git_dir ]] || return 1
    path_has_no_symlink "$git_dir" || return 1
    safe_base=${BASE//\//-}
    printf '%s/chain-advance-evidence/chain-advance-pr-%s-base-%s.json\n' \
        "$git_dir" "$PR" "$safe_base"
}

persist_boundary() {
    local file dir tmp
    file=$(boundary_file) || return 1
    path_has_no_symlink "$file" || return 1
    dir=${file%/*}
    if [[ -e $dir ]]; then
        [[ -d $dir && ! -L $dir ]] || return 1
    else
        mkdir -p -- "$dir" || return 1
    fi
    path_has_no_symlink "$file" || return 1
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || return 1
    tmp=$(mktemp "$dir/.chain-advance-boundary.XXXXXX") || return 1
    if ! jq -n --argjson pr "$PR" --arg base "$BASE" --arg head "$1" \
        --argjson boundary "$2" '{pr:$pr,base:$base,headSha:$head,boundaryEpoch:$boundary}' >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

persisted_boundary() {
    local file value
    file=$(boundary_file) || return 1
    path_has_no_symlink "$file" || return 1
    [[ -f $file && ! -L $file ]] || return 1
    value=$(jq -r --argjson pr "$PR" --arg base "$BASE" --arg head "$1" '
        select(.pr == $pr and .base == $base and .headSha == $head)
        | .boundaryEpoch
        | select(type == "number" and floor == . and . > 0)
    ' "$file" 2>/dev/null) || return 1
    [[ $value =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$value"
}

boundary_for() {
    local head_sha=$1 boundary
    if boundary=$(timeline_boundary); then
        BOUNDARY_SOURCE=timeline
        BOUNDARY_EPOCH=$boundary
        # Keep persistence fail-closed: a timeline value can authorize this
        # proof, but silently dropping its retry provenance would make a later
        # run unable to distinguish a fresh boundary from an untrusted cache.
        persist_boundary "$head_sha" "$boundary" ||
            die 'could not persist the retarget boundary evidence'
    elif boundary=$(persisted_boundary "$head_sha"); then
        BOUNDARY_SOURCE=persisted
        BOUNDARY_EPOCH=$boundary
    else
        die 'could not read a base_ref_changed timeline event or persisted retarget boundary; evidence provenance is unavailable'
    fi
}

# `gh pr edit --base` leaves headRefOid untouched, and the check rollup may still
# be attached to that same head commit. Its timestamp must nevertheless postdate
# the forge timeline boundary: the workflow does not re-run on a base change
# (`pull_request` defaults to opened/synchronize/reopened), so a current-head
# digest alone cannot establish post-retarget CI provenance.
check_ci_fresh() {
    local pr_json=$1 boundary=$2 stale
    stale=$(jq -r --argjson boundary "$boundary" '
        def first_nonempty: first(.[] | select(type == "string" and length > 0)) // "";
        [ .statusCheckRollup[]?
          | ([.startedAt, .started_at, .createdAt, .created_at] | first_nonempty) as $ts
          | ([.name, .context] | first_nonempty) as $raw_label
          | (if $raw_label == "" then "unnamed check" else $raw_label end) as $label
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

# Approval is provider policy, not mechanical base safety (issue #455): a
# trigger/observe provider settles on the current head only after the
# ready/provider transition that follows this proof, and a disabled/none
# provider may never produce one at all. Blocking retarget on approval made
# both cases unsatisfiable, so this reports one of four tokens instead of
# dying: `current:post-retarget` (an APPROVED review both on the current head
# and submitted after the retarget boundary -- both conditions must hold for
# ONE review; splitting them across two existential checks would pass a PR
# carrying a stale approval of the current head plus a fresh approval of some
# older commit, where no single review is both), `residue:stale` (an APPROVED
# review exists but none satisfies both conditions -- pre-retarget residue,
# never counted as current), `none` (no APPROVED review at all), or `unknown`
# (review evidence was unreadable). The caller decides what, if anything, this
# token requires.
describe_approval() {
    local pr_json=$1 head_sha=$2 boundary=$3 result
    result=$(jq -r --arg head "$head_sha" --argjson boundary "$boundary" '
        def review_sha: (if (.commit | type) == "object" then .commit.oid
                          elif (.commit | type) == "string" then .commit
                          else .commitId end // "") | tostring;
        def review_ts: (.submittedAt // .submitted_at // "");
        (.reviews // []) as $reviews
        | (any($reviews[]; .state == "APPROVED")) as $any_approved
        | (any($reviews[]; (.state == "APPROVED") and (review_sha == $head)
                and ((review_ts | length) > 0)
                and ((review_ts | fromdateiso8601) > $boundary))) as $current_fresh
        | if $current_fresh then "current:post-retarget"
          elif $any_approved then "residue:stale"
          else "none" end
    ' <<<"$pr_json") || result=unknown
    [[ $result =~ ^(current:post-retarget|residue:stale|none)$ ]] || result=unknown
    printf '%s\n' "$result"
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

# A retry may observe a PR whose base was retargeted by an earlier invocation.
# Do not use the process-local RETARGET_APPLIED flag as the only refresh signal:
# stale or missing code-scanning evidence is the durable proof that a scan still
# needs a post-boundary trigger.
code_scanning_refresh_needed() {
    local pr_json=$1 boundary=$2 needed
    needed=$(jq -r --argjson boundary "$boundary" '
        def is_scan:
          (((.name // .context // "") | ascii_downcase)
           | test("codeql|code[ -]?scanning"));
        def first_nonempty:
          first(.[] | select(type == "string" and length > 0)) // "";
        [ .statusCheckRollup[]?
          | select(is_scan)
          | ([.startedAt, .started_at, .createdAt, .created_at] | first_nonempty)
        ] as $timestamps
        | if ($timestamps | length) == 0 then "no"
          elif any($timestamps[];
                   . == "" or (try (fromdateiso8601 <= $boundary) catch true))
          then "yes"
          else "no" end
    ' <<<"$pr_json") ||
        die 'code-scanning evidence was unreadable; refresh decision unavailable'
    [[ $needed == yes ]]
}

# Workflow/check names are forge-controlled text. Keep them readable in
# diagnostics while preventing newlines, tabs, and control bytes from becoming
# extra proof lines or terminal escapes. The proof record itself never includes
# these names; it remains one machine-readable line on stdout.
sanitize_label() {
    local value=${1:-}
    value=$(printf '%s' "$value" | LC_ALL=C tr '\r\n' '  ' | LC_ALL=C sed 's/[^[:print:]]/?/g') ||
        value='code-scanning'
    [[ -n $value ]] || value='code-scanning'
    printf '%s' "${value:0:120}"
}

# A base edit does not reliably emit a pull_request workflow event. Refresh
# only a code-scanning workflow named by the PR's check rollup: rerun a known
# head-associated run, or dispatch its workflow when the API accepts that
# capability. A missing dispatch is an operator handoff, never a reason to
# close and reopen a PR. This function intentionally does nothing when the PR
# has no code-scanning-labelled check, preserving the retarget proof contract
# for repositories without such a workflow.
refresh_code_scanning() {
    local pr_json=$1 head_sha=$2 head_ref=$3 names runs run_id run_name workflows workflow_id
    local safe_run_name safe_name
    names=$(jq -r '
        [.statusCheckRollup[]?
         | select(((.name // .context // "") | ascii_downcase)
                  | test("codeql|code[ -]?scanning"))
         | (.name // .context)] | unique | join("\n")
    ' <<<"$pr_json") || die 'could not identify code-scanning checks; refresh evidence unavailable'
    [[ -n $names ]] || return 0

    runs=$(
        "$GH_BIN" api "repos/$REPO/actions/runs?head_sha=$head_sha&per_page=100" 2>/dev/null
    ) || runs='{"workflow_runs":[]}'
    run_id=''
    run_name=''
    while IFS=$'\t' read -r candidate_id candidate_name; do
        [[ -n $candidate_id ]] || continue
        run_id=$candidate_id
        run_name=$candidate_name
        break
    done < <(jq -r --arg names "$names" '
        .workflow_runs[]?
        | select(((.name // .path // "") | ascii_downcase)
                 | test("codeql|code[ -]?scanning"))
        | [(.id // ""), (.name // .path // "code-scanning")] | @tsv
    ' <<<"$runs" 2>/dev/null || true)

    if [[ -n $run_id ]]; then
        if "$GH_BIN" api --method POST "repos/$REPO/actions/runs/$run_id/rerun" \
            >/dev/null 2>&1; then
            printf 'analysis-refresh=rerun workflow=%s run=%s\n' \
                "$(sanitize_label "$run_name")" "$run_id" >&2
            return 0
        fi
        safe_run_name=$(sanitize_label "$run_name")
        printf 'cannot-trigger: %s rerun unavailable; human action: open Actions, rerun the %s workflow for head %s\n' \
            "$safe_run_name" "$safe_run_name" "$head_sha" >&2
        return 1
    fi

    workflows=$(
        "$GH_BIN" api "repos/$REPO/actions/workflows?per_page=100" 2>/dev/null
    ) || workflows='{"workflows":[]}'
    workflow_id=$(jq -r '
        [.workflows[]?
         | select(((.name // .path // "") | ascii_downcase)
                  | test("codeql|code[ -]?scanning"))
         | .id] | first // empty
    ' <<<"$workflows" 2>/dev/null) || workflow_id=''
    if [[ $workflow_id =~ ^[1-9][0-9]*$ ]]; then
        if "$GH_BIN" api --method POST "repos/$REPO/actions/workflows/$workflow_id/dispatches" \
            -f "ref=$head_ref" >/dev/null 2>&1; then
            printf 'analysis-refresh=dispatch workflow=%s ref=%s\n' \
                "$(sanitize_label "${names%%$'\n'*}")" "$(sanitize_label "$head_ref")" >&2
            return 0
        fi
    fi
    safe_name=$(sanitize_label "${names%%$'\n'*}")
    printf 'cannot-trigger: %s has no dispatch; human action: open the CodeQL workflow and run it manually for %s, or update its path filter to include this PR\n' \
        "$safe_name" "$(sanitize_label "$head_ref")" >&2
    return 1
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
    local pr_json actual_base head_ref head_sha ci_counts total pass closing_count refreshed_head_sha
    resolve_repo
    pr_json=$(fetch_pr) || die "could not read PR #$PR before retarget"
    actual_base=$(jq -r '.baseRefName // empty' <<<"$pr_json") ||
        die 'baseRefName was unreadable before retarget'
    head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_json") ||
        die 'headRefOid was unreadable before retarget'
    [[ $head_sha =~ $SHA_RE ]] || die 'head SHA evidence was missing before retarget'
    if [[ $actual_base != "$BASE" ]]; then
        check_ancestry "$head_sha"
        if ! "$GH_BIN" pr edit "$PR" --repo "$REPO" --base "$BASE" >/dev/null; then
            pr_json=$(fetch_pr) ||
                die "could not retarget PR #$PR to base $BASE or re-read the live base"
            actual_base=$(jq -r '.baseRefName // empty' <<<"$pr_json") ||
                die 'baseRefName was unreadable after the retarget command failed'
            if [[ $actual_base == "$BASE" ]]; then
                RETARGET_APPLIED=true
                die 'retarget command failed after the requested base was applied'
            fi
            die "could not retarget PR #$PR to base $BASE; live base=${actual_base:-missing}"
        fi
        RETARGET_APPLIED=true
        pr_json=$(fetch_pr) || die "could not re-read PR #$PR after retarget"
    fi
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
    boundary_for "$head_sha"
    check_ancestry "$head_sha"
    ci_counts=$(check_ci "$pr_json")
    IFS=$'\t' read -r total pass <<<"$ci_counts"
    if [[ $RETARGET_APPLIED == true ]] ||
        code_scanning_refresh_needed "$pr_json" "$BOUNDARY_EPOCH"; then
        if ! refresh_code_scanning "$pr_json" "$head_sha" "$head_ref"; then
            die 'required code-scanning analysis could not be triggered'
        fi
        pr_json=$(fetch_pr) || die "could not re-read PR #$PR after analysis refresh"
        refreshed_head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_json") ||
            die 'headRefOid was unreadable after analysis refresh'
        [[ $refreshed_head_sha == "$head_sha" ]] ||
            die 'pull request head changed after analysis refresh; evidence is stale'
        ci_counts=$(check_ci "$pr_json")
        IFS=$'\t' read -r total pass <<<"$ci_counts"
    fi
    check_ci_fresh "$pr_json" "$BOUNDARY_EPOCH"
    approval_token=$(describe_approval "$pr_json" "$head_sha" "$BOUNDARY_EPOCH")
    closing_count=$(closing_issue_count "$pr_json") ||
        die 'closingIssuesReferences was unreadable after retarget'
    [[ $closing_count =~ ^[1-9][0-9]*$ ]] ||
        die 'closingIssuesReferences is empty after retarget; linkage evidence is missing'
    printf 'retargeted pr #%s base=%s head=%s sha=%s ci=%s/%s green:post-retarget approval=%s ancestry=verified boundarySource=%s closing-issues=%s\n' \
        "$PR" "$BASE" "$head_ref" "$head_sha" "$pass" "$total" "$approval_token" "$BOUNDARY_SOURCE" "$closing_count"
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
