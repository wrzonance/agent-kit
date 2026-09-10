#!/usr/bin/env bash
# Read-only observed check-set comparison. No workflow/trigger inference.
# stacked_ci_snapshot GH REPO HOST PR_JSON [CHECK_RUN_PAGES] [STATUS_PAGES]
# Optional pages reuse the caller's current-head REST evidence. Reference selection
# examines at most five recent default-target PRs, pinned by PR number/head SHA.
# A matching set is not proof of requiredness, success, or future trigger behavior.

stacked_ci_snapshot() (
    local gh_bin=$1 repo=$2 host=$3 pr_json=$4 runs=${5-} statuses=${6-}
    local base default_branch head current status_count candidates candidate reference ref_runs
    local -a api=(api)
    [[ -z $host ]] || api+=(--hostname "$host")
    # Every incomplete read returns explicit unknown evidence, never an empty set.
    unknown() { jq -nc --arg reason "$1" '{state:"unknown",reason:$reason}'; }
    if ! base=$(jq -er '.base.ref | select(type=="string" and length>0)' <<<"$pr_json"); then
        unknown 'base metadata unavailable'; return;
    fi
    # create-issue-worktree.sh owns this convention; other targets keep ordinary CI.
    if [[ ! $base =~ ^feat/issue-[1-9][0-9]*$ ]]; then printf '%s\n' '{"state":"not-stacked"}'; return; fi
    if ! default_branch=$(jq -er '.base.repo.default_branch | select(type=="string" and length>0)' <<<"$pr_json"); then
        unknown 'default-branch metadata unavailable'; return;
    fi
    if [[ $base == "$default_branch" ]]; then printf '%s\n' '{"state":"not-stacked"}'; return; fi
    head=$(jq -er '.head.sha | select(type=="string" and test("^[0-9a-f]{7,40}$"))' <<<"$pr_json") || {
        unknown 'current head unavailable'; return;
    }
    [[ -n $runs ]] || runs=$("$gh_bin" "${api[@]}" "repos/$repo/commits/$head/check-runs?per_page=100" --paginate) || {
        unknown 'current check runs unavailable'; return;
    }
    [[ -n $statuses ]] || statuses=$("$gh_bin" "${api[@]}" "repos/$repo/commits/$head/status?per_page=100" --paginate) || {
        unknown 'current status contexts unavailable'; return;
    }
    if ! current=$(stacked_ci_identities <<<"$runs") ||
        ! status_count=$(jq -se 'select(length>0 and all(.[]; (.statuses | type)=="array")) | [.[].statuses[]] | length' <<<"$statuses"); then
        unknown 'current check evidence malformed'; return;
    fi
    if [[ $current == '[]' && $status_count == 0 ]]; then
        printf '%s\n' '{"state":"no-ci-on-stacked-base","missing":[]}'
        return
    fi
    local encoded
    encoded=$(jq -nr --arg branch "$default_branch" '$branch|@uri')
    if ! candidates=$("$gh_bin" "${api[@]}" "repos/$repo/pulls?state=all&base=$encoded&sort=updated&direction=desc&per_page=5") ||
        ! candidates=$(jq -ce --arg base "$default_branch" 'select(type=="array") | .[:5]
            | map(select(.base.ref==$base and (.number|type)=="number" and .number>0
                and (.head.sha|type)=="string" and (.head.sha|test("^[0-9a-f]{40}$"))))' <<<"$candidates"); then
        unknown 'default-target PR reference unavailable'; return;
    fi
    while IFS= read -r candidate; do
        reference=$(jq -c '{pr:.number,sha:.head.sha,base:.base.ref}' <<<"$candidate")
        head=$(jq -r .sha <<<"$reference")
        if ! ref_runs=$("$gh_bin" "${api[@]}" "repos/$repo/commits/$head/check-runs?per_page=100" --paginate); then
            unknown 'reference check runs unavailable'; return;
        fi
        # A newly updated reference may still have only its first check registered.
        # Skip in-flight candidates rather than declaring their subset sufficient.
        jq -se 'length>0 and all(.[]; (.check_runs|type)=="array"
            and all(.check_runs[]; .status=="completed" and .conclusion!=null))' <<<"$ref_runs" >/dev/null || continue
        if ! ref_runs=$(stacked_ci_identities <<<"$ref_runs"); then
            unknown 'reference check runs unavailable or malformed'; return;
        fi
        [[ $ref_runs != '[]' ]] || continue
        jq -nc --argjson current "$current" --argjson expected "$ref_runs" --argjson reference "$reference" '
            ($expected - $current) as $missing
            | {state:(if ($missing|length)>0 then "partial-ci-on-stacked-base" else "reference-checks-present" end),
               reference:$reference, missing:$missing}'
        return
    done < <(jq -c '.[]' <<<"$candidates")
    unknown 'no settled nonempty default-target PR reference in five recent candidates'
)

# Paginated check runs only: legacy statuses and same-named different apps cannot
# satisfy a check identity. Retain every provider, including GitHub Code Quality.
stacked_ci_identities() {
    jq -sce 'select(length>0 and all(.[]; (.check_runs|type)=="array"))
        | [.[].check_runs[]]
        | select(all(.[]; (.name|type)=="string" and (.name|length)>0
            and (.app.id|type)=="number" and .app.id>0))
        | map({app_id:.app.id,name:.name}) | unique_by([.app_id,.name])'
}

stacked_ci_lines() {
    jq -r 'select(.state!="not-stacked")
        | "verification=\(.state)",
          (if .state=="no-ci-on-stacked-base" then "ci: not-triggered-on-stacked-base"
           elif .state=="partial-ci-on-stacked-base" then "ci: partial-on-stacked-base"
           elif .state=="unknown" then "ci: unknown-on-stacked-base" else empty end),
          (if .reference then "ci-reference: pr=\(.reference.pr) sha=\(.reference.sha) base=\(.reference.base)" else empty end),
          (if (.missing|length)>0 then "ci-missing: \(.missing|tojson)" else empty end),
          (if .state=="reference-checks-present" then empty else "ready-eligible=no reason=ci-coverage-unverified" end)' <<<"$1"
}
