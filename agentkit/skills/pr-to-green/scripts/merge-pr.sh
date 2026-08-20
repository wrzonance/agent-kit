#!/usr/bin/env bash
# Perform exactly one confirmed, evidence-green merge for --auto-merge.
# The guard lives here, at the point of mutation, not just in the calling
# order: an owner-only authorization record must confirm this exact
# repository/PR/head/base/method/delete-branch as an --auto-merge confirmed
# RUNNABLE queue member, and a gate-result record must show merge-gate.sh
# reported gate=PASS for this same PR and head -- both re-checked here rather
# than trusted from an earlier step, the same freshness argument this script
# already applies to the head SHA. Re-verifies head/base/mergeable itself as
# a second, independent check before mutating. A branch-protection refusal
# from the forge is reported verbatim and is a named stop, never a bypass.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
GH_BIN=${MERGE_PR_GH:-gh}
readonly SHA_RE='^[0-9a-f]{40}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly BRANCH_RE='^[A-Za-z0-9._/-]+$'

repo=''
pr=''
head_sha=''
base=''
method=''
delete_branch=0
authorization_file=''
gate_result_file=''
work_dir=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO --pr N --head-sha SHA40 --base REF
       --merge-method squash|merge|rebase --authorization-file FILE
       --gate-result FILE [--delete-branch]
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --pr) (($# >= 2)) || usage; pr=$2; shift 2 ;;
        --head-sha) (($# >= 2)) || usage; head_sha=$2; shift 2 ;;
        --base) (($# >= 2)) || usage; base=$2; shift 2 ;;
        --merge-method) (($# >= 2)) || usage; method=$2; shift 2 ;;
        --authorization-file) (($# >= 2)) || usage; authorization_file=$2; shift 2 ;;
        --gate-result) (($# >= 2)) || usage; gate_result_file=$2; shift 2 ;;
        --delete-branch) delete_branch=1; shift ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ $repo =~ $SLUG_RE ]] || die '--repo must have the form OWNER/REPO'
[[ $pr =~ ^[1-9][0-9]*$ ]] || die '--pr must be a positive integer'
[[ $head_sha =~ $SHA_RE ]] || die '--head-sha must be a full 40-character SHA'
[[ -n $base ]] || die '--base is required'
case $method in squash|merge|rebase) ;; *) die '--merge-method must be squash, merge, or rebase' ;; esac
[[ -n $authorization_file ]] || die '--authorization-file is required'
[[ -n $gate_result_file ]] || die '--gate-result is required'
command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
command -v jq >/dev/null 2>&1 || die 'jq is required; merge evidence unavailable'

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/merge-pr.XXXXXX") || die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM

# --- Authorization: this exact merge, for this exact confirmed queue item ---
[[ -f $authorization_file && ! -L $authorization_file && -O $authorization_file ]] ||
    die 'authorization file must be an owned regular file, not a symlink'
delete_branch_json=false
((delete_branch == 0)) || delete_branch_json=true
jq -e --arg repo "$repo" --argjson pr "$pr" --arg sha "$head_sha" --arg base "$base" \
    --arg method "$method" --argjson deleteBranch "$delete_branch_json" '
  type == "object" and .repository == $repo and .autoMerge == true and
  .mergeMethod == $method and .deleteBranch == $deleteBranch and
  ((.queue | type) == "array") and
  ([.queue[] | select(.pr == $pr and .state == "RUNNABLE" and
    .headSha == $sha and .base == $base)] | length) == 1
' "$authorization_file" >/dev/null 2>&1 ||
    die 'authorization does not confirm this repository, PR, head, base, merge method, and delete-branch setting as a --auto-merge confirmed RUNNABLE queue member'

# --- Gate: a fresh merge-gate.sh PASS bound to this same PR and head ---
[[ -f $gate_result_file && ! -L $gate_result_file && -O $gate_result_file ]] ||
    die 'gate-result file must be an owned regular file, not a symlink'
grep -qF "gate=PASS pr=$pr sha=$head_sha" "$gate_result_file" ||
    die 'merge is not authorized by a passed review-completion gate for this PR and head'

"$GH_BIN" api "repos/$repo/pulls/$pr" >"$work_dir/pr.json" 2>"$work_dir/api.err" ||
    die "pull request metadata unavailable: $(head -n 1 "$work_dir/api.err")"
jq -e --argjson pr "$pr" '
  .number == $pr and (.state | type) == "string" and (.draft | type) == "boolean" and
  ((.head.sha | type) == "string" and (.head.sha | test("^[0-9a-f]{40}$"))) and
  ((.head.ref | type) == "string" and (.head.ref | length) > 0) and
  ((.base.ref | type) == "string") and
  ((.mergeable == null) or ((.mergeable | type) == "boolean"))
' "$work_dir/pr.json" >/dev/null 2>&1 || die 'pull request metadata was malformed'

[[ $(jq -r '.state' "$work_dir/pr.json") == open ]] || die 'pull request is not open'
[[ $(jq -r '.draft' "$work_dir/pr.json") == false ]] || die 'pull request is still a draft'
[[ $(jq -r '.head.sha' "$work_dir/pr.json") == "$head_sha" ]] ||
    die 'pull request head changed since the merge was authorized (stale evidence)'
[[ $(jq -r '.base.ref' "$work_dir/pr.json") == "$base" ]] ||
    die 'pull request base changed since the merge was authorized (stale evidence)'
[[ $(jq -r '.mergeable' "$work_dir/pr.json") == true ]] || die 'pull request is not mergeable'

allow_field="allow_${method}_merge"
[[ $method != merge ]] || allow_field='allow_merge_commit'
"$GH_BIN" api "repos/$repo" >"$work_dir/repo.json" 2>"$work_dir/api.err" ||
    die "repository metadata unavailable: $(head -n 1 "$work_dir/api.err")"
[[ $(jq -r --arg f "$allow_field" '.[$f] // false' "$work_dir/repo.json") == true ]] ||
    die "repository does not allow the configured merge method: $method"

head_ref=$(jq -r '.head.ref' "$work_dir/pr.json")
head_repo_full=$(jq -r '.head.repo.full_name // ""' "$work_dir/pr.json")

merge_body_file="$work_dir/merge-body.json"
jq -n --arg method "$method" --arg sha "$head_sha" \
    '{merge_method:$method, sha:$sha}' >"$merge_body_file"

if ! "$GH_BIN" api -X PUT "repos/$repo/pulls/$pr/merge" --input "$merge_body_file" \
    >"$work_dir/merge.json" 2>"$work_dir/merge.err"; then
    die "merge refused by the forge (branch protection, stale sha, or not mergeable): $(head -n 1 "$work_dir/merge.err")"
fi
jq -e '.merged == true' "$work_dir/merge.json" >/dev/null 2>&1 ||
    die "merge did not report success: $(jq -r '.message // "no message"' "$work_dir/merge.json")"

merge_sha=$(jq -r '.sha // empty' "$work_dir/merge.json")
printf 'pr=%s merged=true method=%s merge_sha=%s\n' "$pr" "$method" "${merge_sha:-unknown}"

if ((delete_branch)); then
    if [[ ! $head_ref =~ $BRANCH_RE ]]; then
        printf 'branch_delete=failed reason=unsafe-branch-name\n'
    elif [[ $head_repo_full != "$repo" ]]; then
        # A fork PR's head branch lives in the fork, not this repository --
        # deleting "$repo/heads/$head_ref" by name would risk deleting an
        # unrelated same-named branch in the target repository instead.
        printf 'branch_delete=skipped ref=%s reason=head-repository-is-not-the-target-repository\n' "$head_ref"
    elif ! "$GH_BIN" api "repos/$repo/git/refs/heads/$head_ref" \
        >"$work_dir/ref-check.json" 2>"$work_dir/ref-check.err"; then
        printf 'branch_delete=failed ref=%s reason=%s\n' "$head_ref" \
            "$(head -n 1 "$work_dir/ref-check.err")"
    elif [[ $(jq -r '.object.sha // empty' "$work_dir/ref-check.json") != "$head_sha" ]]; then
        # The branch no longer points at the head this merge was authorized
        # for -- new work may have landed on it since the merge. Never
        # delete a branch tip we did not just verify and merge.
        printf 'branch_delete=skipped ref=%s reason=branch-no-longer-points-at-the-merged-head\n' "$head_ref"
    elif "$GH_BIN" api -X DELETE "repos/$repo/git/refs/heads/$head_ref" \
        >"$work_dir/delete.out" 2>"$work_dir/delete.err"; then
        printf 'branch_delete=ok ref=%s\n' "$head_ref"
    else
        printf 'branch_delete=failed reason=%s\n' "$(head -n 1 "$work_dir/delete.err")"
    fi
else
    printf 'branch_delete=skipped ref=%s\n' "$head_ref"
fi
