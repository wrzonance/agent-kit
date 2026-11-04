#!/usr/bin/env bash
# bench/live/trial-lib.sh: setup steps shared by trial.sh (headless) and trial-tui.sh (interactive tmux).
# Source it after defining: state (path of sandbox.json), here (bench/live), log (a one-argument logger),
# and for the config writers the globals named in each function.
# shellcheck shell=bash disable=SC2154,SC2034 # globals come from the sourcing script; scrub is read by it

# budget: "REMAINING RESET_EPOCH" for the GraphQL pool, read through GraphQL itself. The REST rate_limit view
# reported 4999 left while GraphQL's own rateLimit said 20, and two sandbox resets died on the throttle. A query that
# is itself throttled counts as an empty pool and waits for the REST-reported reset.
budget() {
    local out
    if out=$(gh api graphql -f query='query { rateLimit { remaining resetAt } }' \
        --jq '"\(.data.rateLimit.remaining) \(.data.rateLimit.resetAt | fromdateiso8601)"' 2>/dev/null); then
        printf '%s\n' "$out"
    else
        printf '0 %s\n' "$(gh api rate_limit --jq .resources.graphql.reset)"
    fi
}

# wait_graphql_budget: GitHub's hourly GraphQL pool is shared by every tool on the account; a trial that
# starts dry fails in seconds.
wait_graphql_budget() {
    local gql_left gql_reset wait_s
    read -r gql_left gql_reset < <(budget)
    while ((gql_left < ${AK_BENCH_MIN_GRAPHQL:-1500})); do
        log "GraphQL pool at $gql_left; waiting for reset at $(date -u -d "@$gql_reset" +%H:%M:%SZ)"
        wait_s=$((gql_reset - $(date +%s) + 30))
        sleep $((wait_s > 60 ? wait_s : 60))
        read -r gql_left gql_reset < <(budget)
    done
}

# ready_count "11 12 13 14": how many of these issues the reset puts in Ready; a `status: Backlog` issue
# (a blocked wave-fixture dependent) waits in Backlog, so the board wait does not count it.
ready_count() {
    local id file status n=0
    for id in $1; do
        file=$(ls "$bench"/issues/"$id"-*.md)
        status=$(sed -n 's/^status: *//p' "$file" | head -n 1)
        [[ ${status:-Ready} != Ready ]] || n=$((n + 1))
    done
    printf '%s\n' "$n"
}

# reset_sandbox_ready "01 03": reset the sandbox with these issues, then wait until the board shows them Ready.
# Needs: repo, dir (the trial's work dir, for trial.log).
reset_sandbox_ready() {
    local issues=$1 expect seen=0 _
    log "reset sandbox, open issues: $issues"
    # A reset that fails is almost always GitHub throttling; wait it out once rather than burning the trial.
    "$here/sandbox.sh" reset "$issues" 2>>"$dir/trial.log" || {
        log 'reset failed; waiting 15 minutes for GitHub throttling to clear'
        sleep 900
        "$here/sandbox.sh" reset "$issues" 2>>"$dir/trial.log"
    }
    # GitHub's project listing lags fresh items; a run that starts before they show sees a different board.
    expect=$(ready_count "$issues")
    for _ in $(seq 1 30); do
        seen=$(gh project item-list "$(jq -r .board.number "$state")" --owner "${repo%%/*}" --format json --limit 100 |
            jq --argjson want "$(jq -c '[.[]]' "${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/current-issues.json")" \
                '[.items[] | select(.status == "Ready" and (.content.number as $n | $want | index($n)))] | length')
        ((seen >= expect)) && break
        sleep 10
    done
    ((seen >= expect)) || { log "board never showed all $expect trial issues as Ready (saw $seen)"; return 1; }
}

# write_codex_config: a private CODEX_HOME/config.toml mirroring the field machine's config (2026-09-30), so a
# trial runs the setup the field repository runs. Needs: CODEX_HOME, model, effort, worker_model, worker_effort.
write_codex_config() {
    cat >"$CODEX_HOME/config.toml" <<TOML
model = "$model"
model_reasoning_effort = "$effort"
service_tier = "default"
approvals_reviewer = "auto_review"
default_permissions = ":danger-full-access"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[agents]
max_concurrent_threads_per_session = 20
default_subagent_model = "$worker_model"
default_subagent_reasoning_effort = "$worker_effort"

[features]
hooks = true
multi_agent = true
TOML
}

# fixture_variant: the fixture variant this trial runs, as a label suffix. AK_BENCH_VERIFY_SLEEP=S makes the bench
# verify sleep S seconds first ("+verifySs"): field verifies ran for minutes and workers polled them 17 to 92 times,
# while the plain fixture's verify ends inside one 30 s shell slice, so that wait was never measured.
fixture_variant() {
    local s=${AK_BENCH_VERIFY_SLEEP:-}
    [[ -n $s ]] || return 0
    [[ $s =~ ^[0-9]+$ ]] || { printf 'trial: AK_BENCH_VERIFY_SLEEP must be whole seconds, got: %s\n' "$s" >&2; return 2; }
    printf '+verify%ss\n' "$s"
}

# write_bench_config CLONE: the shared bench .agent/config.env, so every arm reads identical settings.
# Needs: repo, state, worker_model, worker_effort.
write_bench_config() {
    local variant verify='node test/smoke.mjs'
    variant=$(fixture_variant) || return 2
    [[ -z $variant ]] || verify="sleep $AK_BENCH_VERIFY_SLEEP && $verify"
    mkdir -p "$1/.agent"
    cat >"$1/.agent/config.env" <<ENV
AGENT_REPO_SLUG=$repo
AGENT_BASE_BRANCH=main
AGENT_WORKTREE_ROOT=.worktrees
AGENT_PROJECT_OWNER=${repo%%/*}
AGENT_PROJECT_NUMBER=$(jq -r .board.number "$state")
AGENT_STATUS_VOCAB=Backlog,Ready,In progress,In review,Done
AGENT_CMD_TEST="$verify"
AGENT_CMD_VERIFY="$verify"
AGENT_WORKER_MODELS=$worker_model
AGENT_WORKER_EFFORT=$worker_effort
AGENT_LABEL_TYPES=bug,enhancement
AGENT_LABEL_AREAS=render,store
AGENT_LABEL_PRIORITIES=p1,p2
ENV
}

# scrub_args: fills the global array scrub with `-u NAME` pairs for env(1). The trial must not inherit the
# operator's harness: a Claude Code session exports CLAUDE* into every child.
scrub_args() {
    mapfile -t scrub < <(env | sed -n 's/^\(CLAUDE[A-Z_]*\|CODEX_THREAD_ID\|CODEX_SESSION_ID\|CODEX_CI\)=.*/-u\n\1/p')
}
