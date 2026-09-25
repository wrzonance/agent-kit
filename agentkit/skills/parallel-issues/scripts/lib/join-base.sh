#!/usr/bin/env bash
# Assemble a planned multi-predecessor base before an implementation worker starts.

JOIN_ENABLED=0
JOIN_START=''
JOIN_EXPECTED=()
JOIN_HEADS=()
JOIN_BRANCHES=()

join_fail() {
    worktree_setup_fail "$1"
    return 1
}

join_state() {
    "$JOIN_RUN_STATE" "$@" --run-id "$RUN_ID" --repo-root "$JOIN_ROOT"
}

join_record() {
    local status=$1 next=$2 head=$3 integration=$4 record
    record=$(jq -nc --argjson expected "$JOIN_EXPECTED_JSON" \
        --argjson heads "$JOIN_HEADS_JSON" --arg status "$status" \
        --argjson nextStep "$next" --arg headSha "$head" \
        --arg integrationBaseSha "$integration" \
        '{expectedPredecessors:$expected,initialHeads:$heads,status:$status,
          nextStep:$nextStep,headSha:(if ($headSha|length)>0 then $headSha else null end),
          integrationBaseSha:(if ($integrationBaseSha|length)>0 then $integrationBaseSha else null end)}') ||
        return 1
    join_state set --path "joins.$ISSUE" --json "$record" >/dev/null
}

join_load_publication() {
    local predecessor=$1 publication rc=0 branch head
    publication=$(join_state get --path "initialPublications.$predecessor" 2>/dev/null) || rc=$?
    if ((rc == 11)); then
        join_fail "missing initial publication for predecessor #$predecessor; keep issue #$ISSUE queued"
        return 1
    fi
    ((rc == 0)) || { join_fail "initial publication state unavailable for predecessor #$predecessor"; return 1; }
    jq -e 'type == "object" and (keys | sort) == (["attempt","branch","headSha"] | sort) and
        (.attempt | type) == "string" and (.attempt | length) > 0 and
        (.branch | type) == "string" and (.branch | test("^[A-Za-z0-9._/-]+$")) and
        (.headSha | type) == "string" and (.headSha | test("^[0-9a-f]{40}$"))' \
        <<<"$publication" >/dev/null 2>&1 || {
        join_fail "invalid initial publication for predecessor #$predecessor"
        return 1
    }
    branch=$(jq -r .branch <<<"$publication")
    head=$(jq -r .headSha <<<"$publication")
    git -C "$JOIN_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch" || {
        join_fail "published branch unavailable for predecessor #$predecessor: origin/$branch"
        return 1
    }
    git -C "$JOIN_ROOT" merge-base --is-ancestor "$head" "origin/$branch" || {
        join_fail "initial publication $head is not reachable from origin/$branch for predecessor #$predecessor"
        return 1
    }
    JOIN_BRANCHES+=("$branch")
    JOIN_HEADS+=("$head")
}

join_validate_prior_state() {
    local prior rc=0
    prior=$(join_state get --path "joins.$ISSUE" 2>/dev/null) || rc=$?
    ((rc == 11)) && return 0
    ((rc == 0)) || { join_fail "join progress state unavailable for issue #$ISSUE"; return 1; }
    jq -e --argjson expected "$JOIN_EXPECTED_JSON" --argjson heads "$JOIN_HEADS_JSON" '
        type == "object" and .expectedPredecessors == $expected and .initialHeads == $heads and
        (.status == "assembling" or .status == "conflict" or .status == "complete") and
        (.nextStep | type) == "number" and .nextStep >= 0 and (.nextStep | floor) == .nextStep
    ' <<<"$prior" >/dev/null 2>&1 || {
        join_fail "saved join progress disagrees with the planned predecessor order for issue #$ISSUE"
        return 1
    }
}

join_plan_load() {
    local matches expected predecessor integration
    JOIN_ROOT=$1
    JOIN_RUN_STATE=$2
    JOIN_PLAN=$DISPATCH_PLAN
    # shellcheck disable=SC2034  # consumed by the sourcing setup script
    JOIN_START=${CHAIN_BASE:-origin/$BASE}
    [[ -n $JOIN_PLAN || -n $RUN_ID ]] || return 0
    [[ -n $JOIN_PLAN && -n $RUN_ID ]] || {
        join_fail '--dispatch-plan and --run-id must be given together'
        return 1
    }
    [[ -f $JOIN_PLAN && ! -L $JOIN_PLAN && -O $JOIN_PLAN ]] || {
        join_fail "dispatch plan must be an owned regular file: $JOIN_PLAN"
        return 1
    }
    matches=$(jq -c --argjson issue "$ISSUE" '[.entries[] | select(.issue == $issue)]' \
        "$JOIN_PLAN" 2>/dev/null) || { join_fail 'dispatch plan is unreadable'; return 1; }
    [[ $(jq -r length <<<"$matches") == 1 ]] || {
        join_fail "dispatch plan must identify issue #$ISSUE exactly once"
        return 1
    }
    expected=$(jq -c '.[0].expectedPredecessors // []' <<<"$matches")
    jq -e 'type == "array" and all(.[]; type == "number" and . > 0 and floor == .) and
        (unique | length) == length' <<<"$expected" >/dev/null 2>&1 || {
        join_fail "dispatch plan has invalid expectedPredecessors for issue #$ISSUE"
        return 1
    }
    (($(jq -r length <<<"$expected"))) || return 0
    integration=$(jq -r '.[0].integrationBaseSha // empty' <<<"$matches")
    [[ -z $integration || $integration =~ ^[0-9a-f]{40}$ ]] || {
        join_fail "dispatch plan has invalid integrationBaseSha for issue #$ISSUE"
        return 1
    }
    JOIN_ENABLED=1
    JOIN_EXPECTED_JSON=$expected
    mapfile -t JOIN_EXPECTED < <(jq -r '.[]' <<<"$expected")
    for predecessor in "${JOIN_EXPECTED[@]}"; do
        [[ $predecessor != "$ISSUE" ]] || { join_fail "issue #$ISSUE cannot be its own predecessor"; return 1; }
        join_load_publication "$predecessor" || return 1
    done
    JOIN_HEADS_JSON=$(printf '%s\n' "${JOIN_HEADS[@]}" | jq -Rsc 'split("\n")[:-1]')
    JOIN_RECORDED_BASE=$integration
    join_validate_prior_state || return 1
}

join_commit_active_merge() {
    local predecessor=$1 head=$2 path
    local -a paths=()
    while IFS= read -r -d '' path; do paths+=("$path"); done < <(
        git -C "$JOIN_WORKTREE" diff --cached --name-only --no-renames -z)
    ((${#paths[@]})) || { join_fail "merge for predecessor #$predecessor staged no paths"; return 1; }
    (cd "$JOIN_WORKTREE" && "$JOIN_COMMIT" --include-staged \
        --message "chore(chains): integrate issue $predecessor" \
        --allow-base-inherited "$head" --yolo -- "${paths[@]}") >/dev/null || {
        join_fail "could not commit predecessor #$predecessor; preserve the active merge for the sole writer"
        return 1
    }
}

join_record_integration_base() {
    local head=$1 target_dir staged
    target_dir=$(dirname -- "$JOIN_PLAN")
    staged=$(mktemp "$target_dir/.dispatch-plan.XXXXXX") || return 1
    jq --argjson issue "$ISSUE" --arg head "$head" \
        '(.entries[] | select(.issue == $issue) | .integrationBaseSha) = $head' \
        "$JOIN_PLAN" >"$staged" || { rm -f -- "$staged"; return 1; }
    chmod --reference="$JOIN_PLAN" "$staged" 2>/dev/null || chmod 600 "$staged"
    mv -- "$staged" "$JOIN_PLAN"
}

join_prove_complete() {
    local integration=$1 predecessor_head remote
    git -C "$JOIN_WORKTREE" rev-parse --verify "$integration^{commit}" >/dev/null 2>&1 || return 1
    for predecessor_head in "${JOIN_HEADS[@]}"; do
        git -C "$JOIN_WORKTREE" merge-base --is-ancestor "$predecessor_head" "$integration" || return 1
    done
    remote=$(git -C "$JOIN_WORKTREE" ls-remote --refs origin "refs/heads/$JOIN_BRANCH" | awk 'NR == 1 {print $1}')
    [[ $remote == "$integration" ]] || return 1
}

join_assemble() {
    local worktree=$1 branch=$2 index predecessor head current remote
    JOIN_WORKTREE=$worktree
    JOIN_BRANCH=$branch
    JOIN_COMMIT=$SCRIPT_DIR/../../.shared/scripts/worktree-commit.sh
    ((JOIN_ENABLED)) || return 0
    if [[ -n $JOIN_RECORDED_BASE ]]; then
        join_prove_complete "$JOIN_RECORDED_BASE" || {
            join_fail "recorded integration base $JOIN_RECORDED_BASE lacks complete published join evidence"
            return 1
        }
        printf 'join-base=%s predecessors=%s\n' "$JOIN_RECORDED_BASE" "$(IFS=,; printf '%s' "${JOIN_EXPECTED[*]}")"
        return 0
    fi
    current=$(git -C "$worktree" rev-parse HEAD)
    join_record assembling 0 "$current" '' || return 1
    for index in "${!JOIN_EXPECTED[@]}"; do
        predecessor=${JOIN_EXPECTED[$index]}
        head=${JOIN_HEADS[$index]}
        if git -C "$worktree" merge-base --is-ancestor "$head" HEAD; then
            current=$(git -C "$worktree" rev-parse HEAD)
            join_record assembling "$((index + 1))" "$current" '' || return 1
            continue
        fi
        if git -C "$worktree" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
            [[ $(git -C "$worktree" rev-parse MERGE_HEAD) == "$head" ]] || {
                join_fail 'active merge does not match the next planned predecessor'
                return 1
            }
        else
            git -C "$worktree" merge --no-ff --no-commit "$head" >/dev/null 2>&1 || true
        fi
        if git -C "$worktree" diff --name-only --diff-filter=U | grep -q .; then
            join_record conflict "$index" "$(git -C "$worktree" rev-parse HEAD)" '' || return 1
            printf 'join-conflict issue=%s predecessor=%s head=%s worktree=%s next=resolution-worker-then-resume\n' \
                "$ISSUE" "$predecessor" "$head" "$worktree" >&2
            return 3
        fi
        git -C "$worktree" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || {
            join_fail "merge of predecessor #$predecessor did not produce an active merge"
            return 1
        }
        join_commit_active_merge "$predecessor" "$head" || return 1
        current=$(git -C "$worktree" rev-parse HEAD)
        join_record assembling "$((index + 1))" "$current" '' || return 1
    done
    current=$(git -C "$worktree" rev-parse HEAD)
    git -C "$worktree" push --set-upstream origin "$branch" >/dev/null || {
        join_fail "could not publish complete join branch origin/$branch"
        return 1
    }
    remote=$(git -C "$worktree" ls-remote --refs origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')
    [[ $remote == "$current" ]] || { join_fail 'published join branch does not equal the assembled head'; return 1; }
    join_prove_complete "$current" || { join_fail 'published join does not contain every planned predecessor'; return 1; }
    join_record_integration_base "$current" || { join_fail 'could not record integrationBaseSha in the saved plan'; return 1; }
    join_record complete "${#JOIN_EXPECTED[@]}" "$current" "$current" || return 1
    printf 'join-base=%s predecessors=%s\n' "$current" "$(IFS=,; printf '%s' "${JOIN_EXPECTED[*]}")"
}
