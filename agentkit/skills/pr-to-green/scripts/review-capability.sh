#!/usr/bin/env bash
# Classify a review-only exception from explicit capability and live policy.
set -euo pipefail
umask 077
repo='' pr='' head='' base='' capability=''
GH_BIN=${REVIEW_CAPABILITY_GH:-gh}
while (($#)); do
    case $1 in
        --) shift; (($# == 0)) || exit 2; break ;;
        --repo|--pr|--head-sha|--base|--capability-file)
            (($# >= 2)) || exit 2
            case $1 in
                --repo) repo=$2 ;; --pr) pr=$2 ;; --head-sha) head=$2 ;;
                --base) base=$2 ;; --capability-file) capability=$2 ;;
            esac
            shift 2 ;;
        *) exit 2 ;;
    esac
done
[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && $pr =~ ^[1-9][0-9]*$ &&
   $head =~ ^[0-9a-f]{40}$ && -n $base && $base != *[[:space:]]* ]] || exit 2
result() {
    printf 'review=%s repo=%s pr=%s sha=%s base=%s reason=%s\n' "$1" "$repo" "$pr" "$head" "$base" "$2"
    [[ $1 == unsatisfiable ]] && exit 0
    exit 1
}
[[ -f $capability && ! -L $capability && -O $capability ]] || result unknown capability-untrusted
mode=$(stat -c %a -- "$capability" 2>/dev/null) || mode=$(stat -f %Lp -- "$capability" 2>/dev/null) || result unknown capability-permissions
if [[ ! $mode =~ ^[0-7]+$ ]] || (( (8#$mode & 0022) != 0 )); then result unknown capability-writable; fi
jq -e --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg base "$base" '
  .version == 1 and .repository == $repo and .source == "operator-confirmed" and
  (.queue | type) == "array" and
  ([.queue[] | select(.pr == $pr)] | length) == 1 and
  any(.queue[]; .pr == $pr and .headSha == $head and .base == $base and
      .humanReviewers == "none" and .reviewProvider == "disabled")
' "$capability" >/dev/null 2>&1 || result unknown capability-unbound-or-reviewer-available
tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-capability.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
"$GH_BIN" pr view "$pr" --repo "$repo" --json reviewDecision,headRefOid,baseRefName,reviewRequests \
    >"$tmp/pr" 2>"$tmp/error" || result unknown review-decision-unreadable
jq -e --arg head "$head" --arg base "$base" '
  .headRefOid == $head and .baseRefName == $base and (.reviewRequests | type) == "array"
' "$tmp/pr" >/dev/null 2>&1 || result unknown live-binding-unreadable
[[ $(jq -r .reviewDecision "$tmp/pr") == REVIEW_REQUIRED ]] || result unknown review-not-required
[[ $(jq '.reviewRequests | length' "$tmp/pr") == 0 ]] || result satisfiable reviewer-requested
encoded_base=$(jq -rn --arg base "$base" '$base | @uri')
"$GH_BIN" api "repos/$repo/rules/branches/$encoded_base?per_page=100" --paginate --slurp \
    >"$tmp/rules" 2>"$tmp/error" || result unknown rules-unreadable
# Rules are paginated. No success on page one can hide a later restriction.
jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end' \
    "$tmp/rules" >"$tmp/flat" 2>/dev/null || result unknown rules-malformed
jq -e '
  type == "array" and length > 0 and all(.[];
    .type == "pull_request" and (.parameters | type) == "object" and
    (.parameters.required_approving_review_count | type) == "number" and
    .parameters.required_approving_review_count > 0 and
    (.parameters.required_approving_review_count | floor) == .parameters.required_approving_review_count and
    (.parameters | keys - ["required_approving_review_count", "dismiss_stale_reviews_on_push",
      "require_code_owner_review", "require_last_push_approval", "required_review_thread_resolution", "allowed_merge_methods"] | length) == 0 and
    (if .parameters | has("allowed_merge_methods") then
       (.parameters.allowed_merge_methods | sort) == ["merge","rebase","squash"] else true end) and
    all(.parameters | to_entries[] | select(.key != "required_approving_review_count" and .key != "allowed_merge_methods");
      .value | type == "boolean") and
    (.parameters.required_review_thread_resolution // false) == false)
' "$tmp/flat" >/dev/null 2>&1 || result unknown additional-or-unknown-rules
# Classic protection can coexist with rulesets. Only its specific absence
# response permits this narrow exception; a generic 404/403 is not absence.
if "$GH_BIN" api "repos/$repo/branches/$encoded_base/protection" >"$tmp/protection" 2>"$tmp/error"; then
    result unknown classic-protection-present
fi
jq -e '(.status | tostring) == "404" and .message == "Branch not protected"' \
    "$tmp/protection" >/dev/null 2>&1 || result unknown classic-protection-unreadable
result unsatisfiable review-only-rule-and-explicit-capability
