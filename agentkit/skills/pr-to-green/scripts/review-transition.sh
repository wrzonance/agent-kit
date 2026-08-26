#!/usr/bin/env bash
# Apply a confirmed ready transition and provider capability plan exactly once.
set -euo pipefail
umask 077

# Empty-array "${arr[@]}" expansions under `set -u` (used throughout below)
# error before Bash 4.4, not just before 4.
if [[ -z ${BASH_VERSION:-} ]] ||
    ! { (( ${BASH_VERSINFO[0]:-0} > 4 )) ||
        { (( ${BASH_VERSINFO[0]:-0} == 4 )) && (( ${BASH_VERSINFO[1]:-0} >= 4 )); }; }; then
    printf '%s: requires Bash >= 4.4\n' "${0##*/}" >&2
    exit 2
fi

readonly PROGRAM=${0##*/}
GH_BIN=${REVIEW_TRANSITION_GH:-gh}

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
SHARED_DIR=$(cd -- "$SCRIPT_DIR/../../.shared/scripts" && pwd -P)
PROVIDER_CONFIG=${REVIEW_TRANSITION_PROVIDER_CONFIG:-$SHARED_DIR/review-provider-config.sh}
COMMENT_HELPER=${REVIEW_TRANSITION_COMMENT:-$SCRIPT_DIR/../../review-remote-pr/scripts/gh-comment.sh}
# shellcheck source=../../.shared/scripts/lib/review-provider-catalog.sh
source "$SHARED_DIR/lib/review-provider-catalog.sh"
# shellcheck source=../../.shared/scripts/lib/provider-identity.sh
source "$SHARED_DIR/lib/provider-identity.sh"

repo=''
repo_root=''
pr=''
authorization_file=''
rounds=4
interval=60
work_dir=''
plan_resolved=0
observe=0
since=''
ledger_comments=''
REVIEW_LEDGER_SCRIPT=${REVIEW_TRANSITION_REVIEW_LEDGER:-$SCRIPT_DIR/../../review-remote-pr/scripts/review-ledger.sh}
declare -a providers=()
declare -A modes=()
declare -A emitted=()
declare -A provider_action=()
declare -A provider_source=()

die() {
    if ((plan_resolved)); then
        local blocked_provider
        for blocked_provider in "${providers[@]}"; do
            [[ -z ${emitted[$blocked_provider]+set} ]] ||
                continue
            printf 'provider=%s result=BLOCKED\n' "$blocked_provider"
        done
    fi
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO --repo-root DIR --pr N
       --authorization-file FILE [--rounds 1-60] [--interval 1-3600]
       [--ledger-comments FILE]
       $PROGRAM --observe --repo OWNER/REPO --pr N --since TIMESTAMP

--ledger-comments FILE (issue #477): before polling a triggerable provider,
consults the sibling review-ledger.sh's status for this PR's already-fetched
comments artifact. A covered-head bot entry for that provider short-circuits
straight to "provider=NAME result=ALREADY_SPENT source=ledger" without
burning any polling rounds or REST budget. Any other verdict (stale, absent,
or a blocked/malformed ledger) polls exactly as it does without this flag.

--observe is a lightweight, read-only companion query: after a --trigger run
prints TRIGGERED/ALREADY_SPENT with a since=TIMESTAMP, poll with --observe
--since that TIMESTAMP until it reports LANDED (a terminal CodeRabbit review
submitted after TIMESTAMP, for the PR's OWN CURRENT head SHA -- fetched
fresh, never trusted from a caller) instead of re-running the full
ready-transition and provider-spend flow. Prints "provider=coderabbit
result=LANDED state=STATE threads=N since=TIMESTAMP", or
"provider=coderabbit result=STALE_HEAD state=STATE commit=SHA" for a
terminal review that postdates TIMESTAMP but targets a head the PR has since
moved past, or "provider=coderabbit result=PENDING" otherwise. Always exits
0 -- neither PENDING nor STALE_HEAD is a failure, only "not landed for this
head yet".
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --repo-root) (($# >= 2)) || usage; repo_root=$2; shift 2 ;;
        --pr) (($# >= 2)) || usage; pr=$2; shift 2 ;;
        --authorization-file) (($# >= 2)) || usage; authorization_file=$2; shift 2 ;;
        --rounds) (($# >= 2)) || usage; rounds=$2; shift 2 ;;
        --interval) (($# >= 2)) || usage; interval=$2; shift 2 ;;
        --observe) observe=1; shift ;;
        --since) (($# >= 2)) || usage; since=$2; shift 2 ;;
        --ledger-comments) (($# >= 2)) || usage; ledger_comments=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

if ((observe)); then
    [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die '--repo must have the form OWNER/REPO'
    [[ $pr =~ ^[1-9][0-9]*$ ]] || die '--pr must be a positive integer'
    [[ -n $since ]] || die '--since is required with --observe'
    command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
    command -v jq >/dev/null 2>&1 || die 'jq is required; observe evidence unavailable'

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/review-transition-observe.XXXXXX") ||
        die 'could not create work directory'
    chmod 700 "$work_dir"
    trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

    fetch_slurped() {
        local endpoint=$1 out=$2 label=$3
        "$GH_BIN" api "$endpoint" --paginate --slurp >"$work_dir/$label.raw" ||
            die "$label evidence unavailable"
        jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end' \
            "$work_dir/$label.raw" >"$out" || die "$label evidence returned malformed JSON"
        jq -e 'type == "array"' "$out" >/dev/null 2>&1 || die "$label evidence returned malformed JSON"
    }
    # The live head SHA, fetched fresh rather than trusted from any caller
    # input: the PR can advance between the trigger and this observe call, and
    # a review submitted for the OLD head can still postdate $since and read
    # as current if commit_id is never checked (agent-kit#395 follow-up).
    "$GH_BIN" api "repos/$repo/pulls/$pr" >"$work_dir/pr.json" || die 'pull request metadata unavailable'
    head_sha=$(jq -r '.head.sha // empty' "$work_dir/pr.json") || head_sha=''
    [[ $head_sha =~ ^[0-9a-f]{40}$ ]] || die 'pull request metadata carries no full head SHA'

    fetch_slurped "repos/$repo/pulls/$pr/reviews?per_page=100" "$work_dir/reviews.json" reviews
    fetch_slurped "repos/$repo/pulls/$pr/comments?per_page=100" "$work_dir/comments.json" comments

    # Same terminal-state/tie-break rule as gh-pr-state.sh's provider_state:
    # only a genuinely submitted review (APPROVED/CHANGES_REQUESTED/COMMENTED)
    # postdating the trigger counts at all, and only one whose OWN commit_id
    # matches the just-fetched live head counts as LANDED. A terminal,
    # post-trigger review that targets a different (older) commit is reported
    # as STALE_HEAD -- distinct from PENDING, so the root does not read a
    # real-but-stale review as "nothing happened yet" and does not read it as
    # LANDED either, which would let a review of different code authorize
    # this head's merge.
    info=$(jq -r "$PROVIDER_IDENTITY_JQ"'
        [ .[] | select(((.user.login // "") | ascii_downcase) | is_coderabbit_login)
               | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "COMMENTED")
               | select((.submitted_at // "") > $since) ] as $terminal
        | ($terminal | map(select((.commit_id // "") == $head))
            | sort_by([(.submitted_at // ""), (.id // 0)]) | last) as $current
        | ($terminal | sort_by([(.submitted_at // ""), (.id // 0)]) | last) as $latest
        | if $current != null then
            ["current", $current.state, ($current.submitted_at // ""), (($current.id // 0) | tostring)] | @tsv
          elif $latest != null then
            ["stale", $latest.state, ($latest.commit_id // ""), ""] | @tsv
          else empty end' --arg since "$since" --arg head "$head_sha" <"$work_dir/reviews.json") || info=""
    if [[ -n $info ]]; then
        kind='' state_or_commit='' info_b='' review_id=''
        IFS=$'\t' read -r kind state_or_commit info_b review_id <<< "$info"
        if [[ $kind == current ]]; then
            threads=$(jq -r --argjson rid "${review_id:-0}" \
                '[.[] | select((.pull_request_review_id // -1) == $rid)] | length' \
                <"$work_dir/comments.json")
            printf 'provider=coderabbit result=LANDED state=%s threads=%s since=%s\n' \
                "$state_or_commit" "$threads" "${info_b:-unknown}"
            exit 0
        fi
        printf 'provider=coderabbit result=STALE_HEAD state=%s commit=%s\n' \
            "$state_or_commit" "${info_b:-unknown}"
        exit 0
    fi
    printf 'provider=coderabbit result=PENDING\n'
    exit 0
fi

[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die '--repo must have the form OWNER/REPO'
[[ $pr =~ ^[1-9][0-9]*$ ]] || die '--pr must be a positive integer'
[[ -d $repo_root ]] || die '--repo-root must be a directory'
repo_root=$(cd -- "$repo_root" && pwd -P) || die 'could not resolve --repo-root'
[[ $rounds =~ ^[1-9][0-9]*$ && $rounds -le 60 ]] || die '--rounds must be 1-60'
[[ $interval =~ ^[1-9][0-9]*$ && $interval -le 3600 ]] || die '--interval must be 1-3600'
command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
command -v jq >/dev/null 2>&1 || die 'jq is required; transition evidence unavailable'
[[ -x $PROVIDER_CONFIG ]] || die "provider resolver is not executable: $PROVIDER_CONFIG"
[[ -x $COMMENT_HELPER ]] || die "comment transport is not executable: $COMMENT_HELPER"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/review-transition.XXXXXX") ||
    die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM

# This is deliberately the first external action. A missing/invalid declaration
# resolves to effective none inside the resolver and can never reach posting.
"$PROVIDER_CONFIG" --repo-root "$repo_root" >"$work_dir/providers.txt" ||
    die 'provider capability resolution failed'
[[ -s $work_dir/providers.txt ]] || die 'provider capability resolver returned an empty plan'

while IFS= read -r line; do
    if [[ $line =~ ^provider=([a-z0-9-]+)[[:space:]]mode=([a-z-]+)[[:space:]]source=([a-z]+)$ ]]; then
        provider=${BASH_REMATCH[1]}
        mode=${BASH_REMATCH[2]}
    else
        die 'provider capability resolver returned a malformed record'
    fi
    [[ -z ${modes[$provider]+set} ]] || die "provider capability plan duplicates $provider"
    expected_mode=$(review_provider_mode "$provider" 2>/dev/null) ||
        die "provider capability plan contains unsupported provider: $provider"
    [[ $mode == "$expected_mode" ]] ||
        die "provider capability plan contains unsupported capability: $provider:$mode"
    providers+=("$provider")
    modes[$provider]=$mode
done <"$work_dir/providers.txt"
plan_resolved=1

[[ -f $authorization_file && ! -L $authorization_file && -O $authorization_file ]] ||
    die 'authorization file must be an owned regular file, not a symlink'
jq -e --arg repo "$repo" --argjson pr "$pr" '
  type == "object" and .repository == $repo and .readyTransition == true and
  ((.providers | type) == "array") and
  all(.providers[]; type == "object" and
    ((.name | type) == "string" and (.name | length) > 0) and
    (.action == "trigger" or .action == "observe" or .action == "disabled") and
    ((.source | type) == "string" and (.source | length) > 0)) and
  ((.providers | map(.name) | unique | length) == (.providers | length)) and
  ((.queue | type) == "array") and
  ([.queue[] | select(.pr == $pr and .state == "RUNNABLE" and
    (.headSha | type) == "string" and (.headSha | test("^[0-9a-f]{40}$")) and
    (.base | type) == "string" and (.base | length) > 0)] | length) == 1
' "$authorization_file" >/dev/null 2>&1 ||
    die 'authorization does not confirm this repository, runnable PR, and ready transition'

mapfile -t authorized_providers < <(jq -r '.providers[].name' "$authorization_file" | sort -u)
triggerable=()
for provider in "${providers[@]}"; do
    [[ ${modes[$provider]} != triggerable ]] || triggerable+=("$provider")
done
mapfile -t triggerable < <(printf '%s\n' "${triggerable[@]}" | sed '/^$/d' | sort -u)
if [[ $(printf '%s\n' "${authorized_providers[@]}" | sed '/^$/d') != \
      $(printf '%s\n' "${triggerable[@]}" | sed '/^$/d') ]]; then
    die 'authorization provider set does not match the trigger-capable plan'
fi

# Every trigger-capable provider carries a per-run action decision: the
# operator's queue confirmation authorizes trigger (the capability default)
# or explicitly opts a provider out to observe/disabled without a ping --
# the path a "declared triggerable, operator says no" instruction takes.
while IFS=$'\t' read -r auth_name auth_action auth_source; do
    provider_action[$auth_name]=$auth_action
    provider_source[$auth_name]=$auth_source
done < <(jq -r '.providers[] | [.name, .action, .source] | @tsv' "$authorization_file")

"$GH_BIN" api "repos/$repo/pulls/$pr" >"$work_dir/pr.json" ||
    die 'pull request metadata unavailable'
jq -e --argjson pr "$pr" '
  .number == $pr and .state == "open" and
  ((.draft | type) == "boolean") and
  ((.node_id | type) == "string" and (.node_id | length) > 0) and
  ((.head.sha | type) == "string" and (.head.sha | test("^[0-9a-f]{40}$")))
' "$work_dir/pr.json" >/dev/null 2>&1 || die 'pull request is not open or metadata is malformed'
head_sha=$(jq -r '.head.sha' "$work_dir/pr.json")
authorized_head=$(jq -r --argjson pr "$pr" '.queue[] | select(.pr == $pr) | .headSha' \
    "$authorization_file")
[[ $head_sha == "$authorized_head" ]] || die 'pull request head changed after queue confirmation'

live_base=$(jq -r '.base.ref' "$work_dir/pr.json")
authorized_base=$(jq -r --argjson pr "$pr" '.queue[] | select(.pr == $pr) | .base' \
    "$authorization_file")
[[ $live_base == "$authorized_base" ]] || die 'pull request base changed after queue confirmation'

if [[ $(jq -r '.draft' "$work_dir/pr.json") == true ]]; then
    node_id=$(jq -r '.node_id' "$work_dir/pr.json")
    # shellcheck disable=SC2016 # GraphQL variables are literal API syntax.
    query='mutation($pullRequestId:ID!){markPullRequestReadyForReview(input:{pullRequestId:$pullRequestId}){pullRequest{isDraft}}}'
    "$GH_BIN" api graphql -F "pullRequestId=$node_id" -f "query=$query" \
        >"$work_dir/ready.json" || die 'ready transition failed'
    jq -e '.data.markPullRequestReadyForReview.pullRequest.isDraft == false' \
        "$work_dir/ready.json" >/dev/null 2>&1 || die 'ready transition was not verified'
    printf 'pr=%s ready=transitioned\n' "$pr"
else
    printf 'pr=%s ready=resumed\n' "$pr"
fi

fetch_provider_evidence() {
    local label endpoint
    for label in reviews comments issue-comments; do
        case $label in
            reviews) endpoint="repos/$repo/pulls/$pr/reviews?per_page=100" ;;
            comments) endpoint="repos/$repo/pulls/$pr/comments?per_page=100" ;;
            issue-comments) endpoint="repos/$repo/issues/$pr/comments?per_page=100" ;;
        esac
        "$GH_BIN" api "$endpoint" --paginate --slurp >"$work_dir/$label.raw" ||
            die "$label provider evidence unavailable"
        jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end' \
            "$work_dir/$label.raw" >"$work_dir/$label.json" ||
            die "$label provider evidence returned malformed JSON"
    done
    jq -e 'type == "array"' "$work_dir/reviews.json" "$work_dir/comments.json" \
        "$work_dir/issue-comments.json" >/dev/null 2>&1 ||
        die 'provider evidence returned malformed JSON'
}

provider_current_activity() {
    local provider=$1 login
    login=$(review_provider_login "$provider") || return 1
    jq -e --arg sha "$head_sha" --arg login "$login" '
      any(.[];
        (((.user.login // "") | ascii_downcase) == $login or
         ((.user.login // "") | ascii_downcase) == ($login + "[bot]")) and
        (.commit_id // "") == $sha)
    ' "$work_dir/reviews.json" >/dev/null ||
    jq -e --arg sha "$head_sha" --arg login "$login" '
      any(.[];
        (((.user.login // "") | ascii_downcase) == $login or
         ((.user.login // "") | ascii_downcase) == ($login + "[bot]")) and
        (.commit_id // "") == $sha)
    ' "$work_dir/comments.json" >/dev/null
}

workflow_login=''
fetch_workflow_login() {
    [[ -z $workflow_login ]] || return 0
    "$GH_BIN" api user >"$work_dir/user.json" 2>"$work_dir/api.err" ||
        die "authenticated workflow identity unavailable: $(head -n 1 "$work_dir/api.err")"
    workflow_login=$(jq -er '.login | select(type == "string" and length > 0)' \
        "$work_dir/user.json" 2>/dev/null) ||
        die 'authenticated workflow identity response was malformed'
}

# A marker alone is forgeable by any commenter; only a marker posted by the
# authenticated workflow account proves the request was already spent.
provider_spent() {
    local marker
    marker=$(review_provider_request_marker "$1") || return 1
    fetch_workflow_login
    jq -e --arg marker "$marker" --arg login "$workflow_login" '
      any(.[];
        ((.body // "") | contains($marker)) and
        (((.user.login // "") | ascii_downcase) == ($login | ascii_downcase)))
    ' "$work_dir/issue-comments.json" >/dev/null
}

# The spent marker's own creation time, for callers that want to hand it to
# --observe --since as the trigger boundary. Empty when the comment evidence
# carries no created_at (never treated as a failure -- the caller degrades to
# printing no since= field).
provider_spent_at() {
    local marker
    marker=$(review_provider_request_marker "$1") || return 1
    fetch_workflow_login
    jq -r --arg marker "$marker" --arg login "$workflow_login" '
      [ .[] | select(((.body // "") | contains($marker)) and
          (((.user.login // "") | ascii_downcase) == ($login | ascii_downcase))) ]
      | sort_by(.created_at // "") | last | (.created_at // empty)
    ' "$work_dir/issue-comments.json"
}

for provider in "${providers[@]}"; do
    case ${modes[$provider]} in
        disabled)
            emitted[$provider]=1
            printf 'provider=%s result=DISABLED\n' "$provider"
            ;;
        observe-only)
            emitted[$provider]=1
            printf 'provider=%s result=OBSERVE_ONLY\n' "$provider"
            ;;
        triggerable)
            action=${provider_action[$provider]-}
            [[ -n $action ]] ||
                die "authorization carries no action for trigger-capable provider: $provider"
            case $action in
                disabled)
                    emitted[$provider]=1
                    printf 'provider=%s result=DISABLED source=%s\n' \
                        "$provider" "${provider_source[$provider]}"
                    ;;
                observe)
                    emitted[$provider]=1
                    printf 'provider=%s result=OBSERVE_ONLY source=%s\n' \
                        "$provider" "${provider_source[$provider]}"
                    ;;
                trigger)
                    # issue #477: consult the durable review ledger, from the
                    # already-fetched --ledger-comments artifact (zero network
                    # calls), BEFORE the first live fetch below. A covered-head
                    # ledger entry for this provider at the current head means
                    # this exact tree was already reviewed -- short-circuit
                    # straight to ALREADY_SPENT and skip fetch_provider_evidence,
                    # provider_spent, and every polling round entirely.
                    if [[ -n $ledger_comments && -x $REVIEW_LEDGER_SCRIPT ]]; then
                        ledger_verdict=''
                        ledger_rc=0
                        ledger_verdict=$("$REVIEW_LEDGER_SCRIPT" status --repo "$repo" --pr "$pr" \
                            --comments "$ledger_comments" --head "$head_sha" \
                            --kind bot --provider "$provider" \
                            --repo-root "$repo_root" 2>/dev/null) || ledger_rc=$?
                        if ((ledger_rc == 0)) &&
                            [[ $ledger_verdict == covered-head || $ledger_verdict == covered-diff ]]; then
                            emitted[$provider]=1
                            printf 'provider=%s result=ALREADY_SPENT source=ledger\n' "$provider"
                            continue
                        fi
                    fi
                    request_marker=$(review_provider_request_marker "$provider") ||
                        die "triggerable provider has no request marker: $provider"
                    request_body=$(review_provider_request "$provider") ||
                        die "triggerable provider has no request body: $provider"
                    # Checked against the first fetch, before any bounded wait: a
                    # provider whose budget is already spent has nothing left to poll
                    # for, so this must not burn rounds*interval finding that out.
                    fetch_provider_evidence
                    if provider_spent "$provider"; then
                        emitted[$provider]=1
                        spent_since=$(provider_spent_at "$provider") || spent_since=''
                        if [[ -n $spent_since ]]; then
                            printf 'provider=%s result=ALREADY_SPENT since=%s\n' "$provider" "$spent_since"
                        else
                            printf 'provider=%s result=ALREADY_SPENT\n' "$provider"
                        fi
                        continue
                    fi
                    saw_activity=0
                    for ((round = 1; round <= rounds; round++)); do
                        ((round == 1)) || fetch_provider_evidence
                        if provider_current_activity "$provider"; then
                            saw_activity=1
                            break
                        fi
                        ((round == rounds)) || sleep "$interval"
                    done
                    if ((saw_activity)); then
                        emitted[$provider]=1
                        printf 'provider=%s result=AUTO_REVIEW\n' "$provider"
                        continue
                    fi
                    body_file=$work_dir/provider-request.md
                    {
                        printf '%s\n' 'This was written agentically; verify its assertions:'
                        printf '%s\n' "$request_marker"
                        printf '%s\n' "$request_body"
                    } >"$body_file"
                    post_output=$(bash "$COMMENT_HELPER" --pr "$pr" --repo "$repo" \
                        --body-file "$body_file") || die 'provider request posting failed'
                    [[ $post_output == *'verified=exact'* ]] ||
                        die 'provider request returned no exact readback proof'
                    emitted[$provider]=1
                    # The posted comment's own created_at is the trigger boundary a
                    # later --observe --since call needs; a readback failure here
                    # degrades to the plain TRIGGERED line rather than dying -- the
                    # trigger itself already succeeded and must still be reported.
                    trigger_id=$(sed -nE 's/.*\bid=([0-9]+).*/\1/p' <<< "$post_output" | head -n 1)
                    trigger_since=''
                    if [[ -n $trigger_id ]]; then
                        if "$GH_BIN" api "repos/$repo/issues/comments/$trigger_id" \
                            >"$work_dir/trigger-comment.json" 2>/dev/null; then
                            trigger_since=$(jq -r '.created_at // empty' \
                                "$work_dir/trigger-comment.json" 2>/dev/null) || trigger_since=''
                        fi
                    fi
                    if [[ -n $trigger_since ]]; then
                        printf 'provider=%s result=TRIGGERED since=%s\n' "$provider" "$trigger_since"
                    else
                        printf 'provider=%s result=TRIGGERED\n' "$provider"
                    fi
                    ;;
            esac
            ;;
    esac
done
