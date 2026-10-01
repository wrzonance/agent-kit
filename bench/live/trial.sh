#!/usr/bin/env bash
# bench/live/trial.sh: one live trial of one kit against the ak-bench sandbox, scored into bench/results/live.jsonl.
#
#   bench/live/trial.sh --kit v1|v2 --ref GITREF [--issues "01 03 04"] [--model M] [--effort E]
#                       [--worker-model M] [--worker-effort E] [--timeout SECONDS] [--trial ID]
#
# Run it from a worktree, not the operator's checkout: the ledger row it appends is a tracked result to commit.
# Steps: reset the sandbox; install the kit at GITREF into a private CODEX_HOME (so the arm's plugin bytes
# are pinned); clone the sandbox; run the kit's one invocation headless with `codex exec`; score the root
# and child rollouts; run the hidden acceptance suites against every PR head; append one ledger row.
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bench=$(dirname -- "$here")
kit_repo=$(dirname -- "$bench")
state="$here/sandbox.json"

kit='' ref='' issues='01 03 04' model=gpt-6-luna effort=high worker_model=gpt-5.6-luna worker_effort=medium
timeout_s=5400 trial='' scenario=issues
while (($#)); do
    case $1 in
        --kit) kit=$2; shift 2 ;;
        --ref) ref=$2; shift 2 ;;
        --issues) issues=$2; shift 2 ;;
        --model) model=$2; shift 2 ;;
        --effort) effort=$2; shift 2 ;;
        --worker-model) worker_model=$2; shift 2 ;;
        --worker-effort) worker_effort=$2; shift 2 ;;
        --timeout) timeout_s=$2; shift 2 ;;
        --trial) trial=$2; shift 2 ;;
        --scenario) scenario=$2; shift 2 ;;
        *) printf 'trial: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ $kit == v1 || $kit == v2 ]] || { printf 'trial: --kit v1|v2 is required\n' >&2; exit 2; }
[[ -n $ref ]] || { printf 'trial: --ref is required\n' >&2; exit 2; }
[[ $scenario == issues || $scenario == prs ]] || { printf 'trial: --scenario issues|prs\n' >&2; exit 2; }
[[ -f $state ]] || { printf 'trial: no %s; run bench/live/sandbox.sh create\n' "$state" >&2; exit 2; }

sha=$(git -C "$kit_repo" rev-parse --verify "$ref^{commit}")
trial=${trial:-$(date -u +%Y%m%dT%H%M%SZ)-$kit-${sha:0:7}}
repo=$(jq -r .repo "$state")
dir="${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/$trial"
mkdir -p "$dir"
log() { printf 'trial %s: %s\n' "$trial" "$*" | tee -a "$dir/trial.log" >&2; }

# shellcheck disable=SC2016 # the $ is the skill sigil, not a shell expansion
case $kit in
    v1) plugin=agentkit
        prompt='$agentkit:parallel-issues --yolo --fast-mode --auto-serialize --auto-review' ;;
    v2) plugin=ak
        prompt='$ak:issues --yolo --serialize' ;;
esac

# GitHub's hourly GraphQL pool is shared by every tool on the account; a trial that starts dry fails in seconds.
budget() { gh api rate_limit --jq '"\(.resources.graphql.remaining) \(.resources.graphql.reset) \(.resources.core.remaining)"'; }
read -r gql_left gql_reset _ < <(budget)
while ((gql_left < ${AK_BENCH_MIN_GRAPHQL:-1500})); do
    log "GraphQL pool at $gql_left; waiting for reset at $(date -u -d "@$gql_reset" +%H:%M:%SZ)"
    sleep $((gql_reset - $(date +%s) + 30))
    read -r gql_left gql_reset _ < <(budget)
done

log "reset sandbox, open issues: $issues"
# A reset that fails is almost always GitHub throttling; wait it out once rather than burning the trial.
"$here/sandbox.sh" reset "$issues" 2>>"$dir/trial.log" || {
    log 'reset failed; waiting 15 minutes for GitHub throttling to clear'
    sleep 900
    "$here/sandbox.sh" reset "$issues" 2>>"$dir/trial.log"
}

# GitHub's project listing lags fresh items; a run that starts before they show sees a different board.
expect=$(wc -w <<<"$issues")
for _ in $(seq 1 30); do
    seen=$(gh project item-list "$(jq -r .board.number "$state")" --owner "${repo%%/*}" --format json --limit 100 |
        jq --argjson want "$(jq -c '[.[]]' "${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/current-issues.json")" \
            '[.items[] | select(.status == "Ready" and (.content.number as $n | $want | index($n)))] | length')
    ((seen >= expect)) && break
    sleep 10
done
((seen >= expect)) || { log "board never showed all $expect trial issues as Ready (saw $seen)"; exit 1; }

if [[ $scenario == prs ]]; then
    log "seed draft PRs for: $issues"
    pr_list=$("$here/sandbox.sh" seed-prs "$issues" 2>>"$dir/trial.log" | awk '{print $2}' | tr '\n' ' ')
    pr_list=${pr_list% }
    [[ -n $pr_list ]] || { log 'seeding PRs failed'; exit 1; }
    case $kit in
        v1) prompt="\$agentkit:pr-to-green --yolo --fast-mode --auto-review --auto-merge $pr_list" ;;
        v2) prompt="\$ak:pr --merge $pr_list" ;;
    esac
    log "seeded PRs: $pr_list"
fi

log "install $plugin@$sha into a private CODEX_HOME"
git -C "$kit_repo" worktree add -q --detach "$dir/kit" "$sha"
trap 'git -C "$kit_repo" worktree remove --force "$dir/kit" 2>/dev/null || true' EXIT
export CODEX_HOME="$dir/codex-home"
mkdir -p "$CODEX_HOME"
cp -- "${AK_BENCH_CODEX_AUTH:-$HOME/.codex/auth.json}" "$CODEX_HOME/auth.json"
# Mirrors the field machine's config (2026-09-30) so a trial runs the setup the field repository runs.
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
js_repl = false
multi_agent = false
TOML
codex plugin marketplace add "$dir/kit" >>"$dir/trial.log" 2>&1
codex plugin add "$plugin@agent-kit" >>"$dir/trial.log" 2>&1

log "clone $repo"
git clone -q "https://github.com/$repo.git" "$dir/repo"
mkdir -p "$dir/repo/.agent"
# A real v1 repository is onboarded once: bootstrap-repo.sh writes .agent/board.json (and a config.env that
# the shared bench config below replaces, so both kits read identical settings). Setup is not measured.
if [[ $kit == v1 ]]; then
    "$dir/kit/agentkit/skills/.shared/scripts/bootstrap-repo.sh" --repo-root "$dir/repo" \
        --project "$(jq -r .board.number "$state")" --owner "${repo%%/*}" --force >>"$dir/trial.log" 2>&1 ||
        { log 'v1 onboarding (bootstrap-repo.sh) failed; see trial.log'; exit 1; }
fi
cat >"$dir/repo/.agent/config.env" <<ENV
AGENT_REPO_SLUG=$repo
AGENT_BASE_BRANCH=main
AGENT_WORKTREE_ROOT=.worktrees
AGENT_PROJECT_OWNER=${repo%%/*}
AGENT_PROJECT_NUMBER=$(jq -r .board.number "$state")
AGENT_STATUS_VOCAB=Backlog,Ready,In progress,In review,Done
AGENT_CMD_TEST="node test/smoke.mjs"
AGENT_CMD_VERIFY="node test/smoke.mjs"
AGENT_WORKER_MODELS=$worker_model
AGENT_WORKER_EFFORT=$worker_effort
AGENT_LABEL_TYPES=bug,enhancement
AGENT_LABEL_AREAS=render,store
AGENT_LABEL_PRIORITIES=p1,p2
ENV

# Every gh call during the run goes through a counting shim, so API use is exact, not a shared-pool delta.
mkdir -p "$dir/bin"
ln -sf "$here/gh-shim" "$dir/bin/gh"
AK_BENCH_REAL_GH=$(command -v gh)
export AK_BENCH_REAL_GH AK_BENCH_GH_LOG="$dir/gh-calls.log"
: >"$AK_BENCH_GH_LOG"
export PATH="$dir/bin:$PATH"
log "run: codex exec $prompt (model=$model effort=$effort timeout=${timeout_s}s)"
started=$(date -u +%s)
rc=0
# The trial must not inherit the operator's harness: a Claude Code session exports CLAUDE* into every child.
mapfile -t scrub < <(env | sed -n 's/^\(CLAUDE[A-Z_]*\|CODEX_THREAD_ID\|CODEX_SESSION_ID\|CODEX_CI\)=.*/-u\n\1/p')
env "${scrub[@]}" timeout --kill-after=30 "$timeout_s" codex exec --json --dangerously-bypass-approvals-and-sandbox \
    --dangerously-bypass-hook-trust --skip-git-repo-check -C "$dir/repo" -m "$model" \
    -c "model_reasoning_effort=\"$effort\"" "$prompt" >"$dir/exec.jsonl" 2>"$dir/exec.err" || rc=$?
ended=$(date -u +%s)
export PATH=${PATH#"$dir/bin:"}
thread=$(jq -r 'select(.type=="thread.started") | .thread_id' "$dir/exec.jsonl" | head -n 1)
root=$(grep -rl --include='rollout-*.jsonl' "\"id\":\"$thread\"" "$CODEX_HOME/sessions" 2>/dev/null | head -n 1 || true)
log "exec rc=$rc thread=${thread:-none} elapsed=$((ended - started))s"

log 'score PR heads with the hidden acceptance suites'
outcome="$dir/outcome.json"
outcome_sh="$here/outcome.sh"
[[ $scenario == issues ]] || outcome_sh="$here/outcome-prs.sh"
"$outcome_sh" "$repo" "$dir/repo" "$issues" "$rc" "$((ended - started))" 2>>"$dir/trial.log" |
    jq --argjson calls "$("$here/gh-calls.py" "$AK_BENCH_GH_LOG")" '. + {github: $calls}' >"$outcome"

row="$dir/row.json"
fixture_label="ak-bench:$(jq -r .tag "$state"):$issues"
[[ $scenario == issues ]] || fixture_label="ak-bench-prs:$(jq -r .tag "$state"):pr-v2:$issues"
if [[ -n $root ]]; then
    "$here/score.py" "$root" --sessions "$CODEX_HOME/sessions" --outcome "$outcome" \
        --label kit="$kit" --label ref="$sha" --label fixture="$fixture_label" \
        --label trial="$trial" --label model="$model" --label effort="$effort" \
        --label worker_model="$worker_model" --label worker_effort="$worker_effort" >"$row"
else
    jq -n --arg kit "$kit" --arg ref "$sha" --arg trial "$trial" --slurpfile o "$outcome" \
        '{kit:$kit, ref:$ref, trial:$trial, error:"no root rollout", outcome:$o[0]}' >"$row"
fi
cat -- "$row" >>"$bench/results/live.jsonl"
jq -c '{trial, kit, passed: .outcome.passed, prs: .outcome.prs, root_calls: .root.calls,
        root_tokens: .root.tokens.total_tokens, system_tokens, first_spawn: .root.first_spawn}' "$row"
