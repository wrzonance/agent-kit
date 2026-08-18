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

repo=''
repo_root=''
pr=''
authorization_file=''
rounds=4
interval=60
work_dir=''
plan_resolved=0
declare -a providers=()
declare -A modes=()
declare -A emitted=()

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
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

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
  ((.providers | type) == "array") and all(.providers[]; type == "string") and
  ((.queue | type) == "array") and
  ([.queue[] | select(.pr == $pr and .state == "RUNNABLE" and
    (.headSha | type) == "string" and (.headSha | test("^[0-9a-f]{40}$")) and
    (.base | type) == "string" and (.base | length) > 0)] | length) == 1
' "$authorization_file" >/dev/null 2>&1 ||
    die 'authorization does not confirm this repository, runnable PR, and ready transition'

mapfile -t authorized_providers < <(jq -r '.providers[]' "$authorization_file" | sort -u)
triggerable=()
for provider in "${providers[@]}"; do
    [[ ${modes[$provider]} != triggerable ]] || triggerable+=("$provider")
done
mapfile -t triggerable < <(printf '%s\n' "${triggerable[@]}" | sed '/^$/d' | sort -u)
if [[ $(printf '%s\n' "${authorized_providers[@]}" | sed '/^$/d') != \
      $(printf '%s\n' "${triggerable[@]}" | sed '/^$/d') ]]; then
    die 'authorization provider set does not match the trigger-capable plan'
fi

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
                printf 'provider=%s result=ALREADY_SPENT\n' "$provider"
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
            printf 'provider=%s result=TRIGGERED\n' "$provider"
            ;;
    esac
done
