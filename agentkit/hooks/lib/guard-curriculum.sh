#!/usr/bin/env bash
# SubagentStart is context-only. Unknown roles never acquire root interfaces.
guard_subagent_curriculum() {
    local skills=$1 role=${2:-} helper
    case $role in
        worker|implementation-worker|issue-lead|pr-fix-batch|fix-batch) ;;
        *) return 0 ;;
    esac
    [[ -d $skills ]] || return 1
    printf '%s\n' \
        'Role: implementation-worker (leaf), even when nesting is supported.' \
        'No dispatch/delegation, other-agent review, CI polling or PR/board management; root owns them.' \
        'Scope-limited investigation, correction and authorized commit/push remain allowed.' \
        'Use the absolute worktree, branch, owned paths and required instructions in your dispatch.' \
        'Read its .agent/env-contract.txt; never infer worker paths from the hook cwd or refresh configuration.' \
        'Run declared verification with agent-run.sh; preserve errors and return blockers with the exact remaining action.' \
        'Preserve model attribution, pushed history, and the supplied result schema; do not invent evidence.' \
        'SubagentStart enforcement=prompt-only; this context does not remove tools.' \
        'Use these interfaces through the absolute skills path supplied in your dispatch:'
    for helper in contract-read.sh repo-config.sh agent-run.sh worktree-commit.sh worker-result.sh; do
        [[ -x $skills/.shared/scripts/$helper ]] || continue
        printf '  .shared/scripts/%s\n' "$helper"
    done
}

# The tooling contract: what exists here and the one question each answers. Only
# helpers that resolve ON DISK are named (a curriculum naming a missing script
# teaches a broken path); one line each, since it competes with the contract for
# attention.
guard_curriculum() {
    local skills=$1 entry rel desc out=''
    local -a entries=(
        ".shared/scripts/board-list.sh|board columns; --issue N for one item"
        ".shared/scripts/ci-gap.sh|undeclared CI gates"
        ".shared/scripts/triage-issues.sh|issues, board status and PRs"
        "parallel-issues/scripts/move-github-project-item.sh|set board Status"
        ".shared/scripts/agent-run.sh --cmd NAME|run declared command"
        ".shared/scripts/worktree-commit.sh|commit explicit paths"
        "review-remote-pr/scripts/gh-pr-state.sh|PR CI and review state"
        ".shared/scripts/bootstrap-repo.sh|re-declare facts; see onboard-repo"
        ".shared/scripts/onboard-refresh.sh|onboarding drift (read-only)"
        ".shared/scripts/onboard-state.sh --report --repo-root DIR|next onboarding stage"
        ".shared/scripts/repo-config.sh --resolve KEY1 --resolve KEY2|batch reads; --list for all; --list-adversarial-efforts for supported efforts"
        # References under hidden .shared/ otherwise disappear from enumeration.
        "references.md|reference paths and purposes"
    )

    [[ -d $skills ]] || return 1
    for entry in "${entries[@]}"; do
        rel=${entry%%|*}
        desc=${entry#*|}
        [[ -e "$skills/${rel%% *}" ]] || continue
        # shellcheck disable=SC2016  # $agentkit is literal text the agent retypes
        out+='  $agentkit/'"$rel  -- $desc"$'\n'
    done
    [[ -n $out ]] || return 1

    printf 'Deterministic helpers available here -- prefer them over ad-hoc calls.\nResolve the tree once, then use the paths below:\n%s\n%s' \
        "$RESOLVE_HINT" "$out"
}
