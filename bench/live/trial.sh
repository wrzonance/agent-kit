#!/usr/bin/env bash
# bench/live/trial.sh: one live trial of one kit against the ak-bench sandbox, scored into bench/results/live.jsonl.
#
#   bench/live/trial.sh --kit v1|v2 --ref GITREF [--issues "01 03 04"] [--model M] [--effort E]
#                       [--worker-model M] [--worker-effort E] [--timeout SECONDS] [--trial ID]
#
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
timeout_s=5400 trial=''
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
        *) printf 'trial: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ $kit == v1 || $kit == v2 ]] || { printf 'trial: --kit v1|v2 is required\n' >&2; exit 2; }
[[ -n $ref ]] || { printf 'trial: --ref is required\n' >&2; exit 2; }
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

log "reset sandbox, open issues: $issues"
"$here/sandbox.sh" reset "$issues" 2>>"$dir/trial.log"

log "install $plugin@$sha into a private CODEX_HOME"
git -C "$kit_repo" worktree add -q --detach "$dir/kit" "$sha"
trap 'git -C "$kit_repo" worktree remove --force "$dir/kit" 2>/dev/null || true' EXIT
export CODEX_HOME="$dir/codex-home"
mkdir -p "$CODEX_HOME"
cp -- "${AK_BENCH_CODEX_AUTH:-$HOME/.codex/auth.json}" "$CODEX_HOME/auth.json"
cat >"$CODEX_HOME/config.toml" <<TOML
model = "$model"
model_reasoning_effort = "$effort"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[features]
multi_agent = true
TOML
codex plugin marketplace add "$dir/kit" >>"$dir/trial.log" 2>&1
codex plugin add "$plugin@agent-kit" >>"$dir/trial.log" 2>&1

log "clone $repo"
git clone -q "https://github.com/$repo.git" "$dir/repo"
mkdir -p "$dir/repo/.agent"
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

log "run: codex exec $prompt (model=$model effort=$effort timeout=${timeout_s}s)"
started=$(date -u +%s)
rc=0
# The trial must not inherit the operator's harness: a Claude Code session exports CLAUDE* into every child.
mapfile -t scrub < <(env | sed -n 's/^\(CLAUDE[A-Z_]*\|CODEX_THREAD_ID\|CODEX_SESSION_ID\|CODEX_CI\)=.*/-u\n\1/p')
env "${scrub[@]}" timeout --kill-after=30 "$timeout_s" codex exec --json --dangerously-bypass-approvals-and-sandbox \
    --dangerously-bypass-hook-trust --skip-git-repo-check -C "$dir/repo" -m "$model" \
    -c "model_reasoning_effort=\"$effort\"" "$prompt" >"$dir/exec.jsonl" 2>"$dir/exec.err" || rc=$?
ended=$(date -u +%s)
thread=$(jq -r 'select(.type=="thread.started") | .thread_id' "$dir/exec.jsonl" | head -n 1)
root=$(grep -rl --include='rollout-*.jsonl' "\"id\":\"$thread\"" "$CODEX_HOME/sessions" 2>/dev/null | head -n 1 || true)
log "exec rc=$rc thread=${thread:-none} elapsed=$((ended - started))s"

log 'score PR heads with the hidden acceptance suites'
outcome="$dir/outcome.json"
"$here/outcome.sh" "$repo" "$dir/repo" "$issues" "$rc" "$((ended - started))" >"$outcome" 2>>"$dir/trial.log"

row="$dir/row.json"
if [[ -n $root ]]; then
    "$here/score.py" "$root" --sessions "$CODEX_HOME/sessions" --outcome "$outcome" \
        --label kit="$kit" --label ref="$sha" --label fixture="ak-bench:$(jq -r .tag "$state"):$issues" \
        --label trial="$trial" --label model="$model" --label effort="$effort" \
        --label worker_model="$worker_model" --label worker_effort="$worker_effort" >"$row"
else
    jq -n --arg kit "$kit" --arg ref "$sha" --arg trial "$trial" --slurpfile o "$outcome" \
        '{kit:$kit, ref:$ref, trial:$trial, error:"no root rollout", outcome:$o[0]}' >"$row"
fi
cat -- "$row" >>"$bench/results/live.jsonl"
jq -c '{trial, kit, passed: .outcome.passed, prs: .outcome.prs, root_calls: .root.calls,
        root_tokens: .root.tokens.total_tokens, system_tokens, first_spawn: .root.first_spawn}' "$row"
