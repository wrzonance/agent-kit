#!/usr/bin/env bash
# bench/live/trial-tui.sh: one live trial of the ak kit driven through the INTERACTIVE CLI in a detached tmux
# session, for Codex or Claude Code, scored into bench/results/live.jsonl with "mode": "tui".
#
#   bench/live/trial-tui.sh --harness codex|claude --ref GITREF [--issues "11 12 13 14"] [--model M]
#                           [--effort E] [--timeout SECONDS] [--trial ID] [--dry-run]
#
# Steps: reset the sandbox; pin the kit bytes at GITREF (a git archive, loaded through a private CODEX_HOME or
# `claude --plugin-dir`); start the CLI with one initial prompt in tmux; poll GitHub (REST)
# until every fixture issue has an open PR carrying an ak receipt comment, or the timeout; exit the CLI; score
# the root transcript and every PR head; append one ledger row. --dry-run builds everything locally (no
# GitHub, no ledger row) so the tmux sequence and the environment can be tested with stub CLIs.
#
# The Claude arm keeps the default Claude config dir (it holds the login) and loads only project and local
# settings, so the operator's user-level hooks do not run. Run it from a worktree: the ledger row is tracked.
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bench=$(dirname -- "$here")
kit_repo=$(dirname -- "$bench")
state="$here/sandbox.json"
# shellcheck source=trial-lib.sh
source "$here/trial-lib.sh"

harness='' ref='' issues='11 12 13 14' model='' effort='' timeout_s=5400 trial='' dry=0
worker_model='' worker_effort=high
while (($#)); do
    case $1 in
        --harness) harness=$2; shift 2 ;;
        --ref) ref=$2; shift 2 ;;
        --issues) issues=$2; shift 2 ;;
        --model) model=$2; shift 2 ;;
        --effort) effort=$2; shift 2 ;;
        --timeout) timeout_s=$2; shift 2 ;;
        --trial) trial=$2; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) printf 'trial-tui: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ $harness == codex || $harness == claude ]] || { printf 'trial-tui: --harness codex|claude is required\n' >&2; exit 2; }
[[ -n $ref ]] || { printf 'trial-tui: --ref is required\n' >&2; exit 2; }
# The fixture variant (AK_BENCH_VERIFY_SLEEP) is checked before the sandbox is reset, and labels every row.
variant=$(fixture_variant) || exit 2
# Workers use a model of the arm's own harness: AGENT_WORKER_MODELS names it for the kit, and Codex also reads it
# from its config.
if [[ $harness == codex ]]; then
    model=${model:-gpt-6-luna} effort=${effort:-high} worker_model=gpt-6-luna
else
    model=${model:-claude-sonnet-5-5} effort=${effort:-high} worker_model=sonnet
fi
if ((dry)); then repo=dry/run; else
    [[ -f $state ]] || { printf 'trial-tui: no %s; run bench/live/sandbox.sh create\n' "$state" >&2; exit 2; }
    repo=$(jq -r .repo "$state")
fi

sha=$(git -C "$kit_repo" rev-parse --verify "$ref^{commit}")
trial=${trial:-$(date -u +%Y%m%dT%H%M%SZ)-tui-$harness-${sha:0:7}}
dir="${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/$trial"
mkdir -p "$dir"
log() { printf 'trial %s: %s\n' "$trial" "$*" | tee -a "$dir/trial.log" >&2; }

# shellcheck disable=SC2016 # the $ is the Codex skill sigil, not a shell expansion
case $harness in
    codex) invocation='$ak:issues --serialize --yolo --limit 4' ;;
    claude) invocation='/ak:issues --serialize --yolo --limit 4' ;;
esac
session="akbench-${trial//[^A-Za-z0-9_-]/_}"

if ((dry)); then
    git init -q "$dir/repo"
else
    wait_graphql_budget
    reset_sandbox_ready "$issues"
fi

log "pin ak@$sha"
mkdir -p "$dir/kit"
git -C "$kit_repo" archive "$sha" | tar -x -C "$dir/kit"
if [[ $harness == codex ]]; then
    export CODEX_HOME="$dir/codex-home"
    mkdir -p "$CODEX_HOME"
    if ((dry)); then : >"$CODEX_HOME/auth.json"; else cp -- "${AK_BENCH_CODEX_AUTH:-$HOME/.codex/auth.json}" "$CODEX_HOME/auth.json"; fi
    write_codex_config
    codex plugin marketplace add "$dir/kit" >>"$dir/trial.log" 2>&1
    codex plugin add ak@agent-kit >>"$dir/trial.log" 2>&1
fi

if ((dry)); then :; else
    log "clone $repo"
    git clone -q "https://github.com/$repo.git" "$dir/repo"
fi
write_bench_config "$dir/repo"
# Codex records folder trust per project in its config; Claude's trust dialog is answered below when it shows.
if [[ $harness == codex ]]; then
    printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$(cd -- "$dir/repo" && pwd -P)" >>"$CODEX_HOME/config.toml"
fi

mkdir -p "$dir/bin"
ln -sf "$here/gh-shim" "$dir/bin/gh"
real_gh=$(command -v gh)
log_gh="$dir/gh-calls.log"
: >"$log_gh"

# The CLI starts inside the tmux server's environment, not this script's, so the scrub and the bench variables
# travel on the command line itself.
scrub_args
case $harness in
    codex) cli=(codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust
        -C "$dir/repo" -m "$model" -c "model_reasoning_effort=\"$effort\"") ;;
    claude) cli=(claude --plugin-dir "$dir/kit/v2" --setting-sources "project,local" --dangerously-skip-permissions
        --model "$model" --effort "$effort") ;;
esac
cli+=("$invocation")
[[ $harness == codex ]] && envs=("CODEX_HOME=$CODEX_HOME") || envs=()
envs+=("PATH=$dir/bin:$PATH" "AK_BENCH_REAL_GH=$real_gh" "AK_BENCH_GH_LOG=$log_gh")
printf -v command_line '%q ' env "${scrub[@]}" "${envs[@]}" "${cli[@]}"

tmux_run() { env "${scrub[@]}" tmux "$@"; }

# A visible composer does not prove submission. Both CLIs accept an initial prompt; wait for a root turn
# in its transcript, and retain that path so a newer worker transcript cannot become the scored root.
root=''
if [[ $harness == codex ]]; then
    sessions="$CODEX_HOME/sessions"; glob='rollout-*.jsonl'
else
    slug=${dir//[^A-Za-z0-9]/-}-repo
    sessions="$HOME/.claude/projects/$slug"; glob='*.jsonl'
fi
find_started_root() {
    local file
    while IFS= read -r -d '' file; do
        if jq -se --arg harness "$harness" --arg cwd "$dir/repo" '
            if $harness == "codex" then
                any(.[]; .type == "session_meta" and .payload.cwd == $cwd
                    and (.payload.parent_thread_id // "") == "")
                and any(.[]; .type == "event_msg" and .payload.type == "task_started")
            else any(.[]; .type == "assistant" and .cwd == $cwd) end
        ' "$file" >/dev/null 2>&1; then root=$file; return 0; fi
    done < <(find "$sessions" -maxdepth 6 -name "$glob" -not -path '*/subagents/*' \
        -newer "$dir/started" -print0 2>/dev/null)
    return 1
}

# Return 1 only for a vanished session; connection/permission errors are failures, not completion evidence.
session_exists() {
    local error
    if error=$(tmux_run has-session -t "$session" 2>&1); then return 0; fi
    case $error in
        *"can't find session:"*|*"no server running"*|*"No such file or directory"*) return 1 ;;
        *) log "tmux session check failed: $error"; return 2 ;;
    esac
}
tmux_if_present() {
    local command=$1 error status
    shift
    if session_exists; then :; else status=$?; ((status == 1)); return; fi
    if error=$(tmux_run "$command" -t "$session" "$@" 2>&1); then return 0; fi
    if session_exists; then :; else status=$?; ((status == 1)) && return 0; fi
    log "tmux cleanup failed: $error"
    return 1
}
stop_session() {
    local status=0
    if ((!dry)); then
        tmux_if_present send-keys C-c || status=1
        sleep 2
        tmux_if_present send-keys C-c || status=1
        sleep 5
    fi
    tmux_if_present kill-session || status=1
    return "$status"
}
wait_for_start() {
    local pane deadline=$((SECONDS + ${AK_BENCH_TUI_READY_TIMEOUT:-120})) trust_re bypass_re
    trust_re='[Dd]o you trust|trust the (files|contents)|trust this (folder|directory)'
    bypass_re='Bypass Permissions mode|Yes, I accept'
    while :; do
        find_started_root && { log 'root turn started'; return 0; }
        ((SECONDS < deadline)) || break
        session_exists || break
        pane=$(tmux_run capture-pane -p -t "$session" 2>/dev/null || true)
        printf '%s\n' "$pane" >"$dir/startup-pane.txt"
        if grep -Eq "$trust_re" <<<"$pane"; then
            tmux_run send-keys -t "$session" Enter || break
        elif grep -Eq "$bypass_re" <<<"$pane"; then
            tmux_run send-keys -t "$session" 2 Enter || break
        fi
        sleep "${AK_BENCH_TUI_READY_POLL:-1}"
    done
    log "no agent turn within ${AK_BENCH_TUI_READY_TIMEOUT:-120}s or CLI exited; inspect $dir/startup-pane.txt and $sessions; invocation was not resent"
    return 1
}

tmux_run kill-session -t "$session" 2>/dev/null || true
log "start $harness in tmux session $session (model=$model effort=$effort timeout=${timeout_s}s)"
started=$(date -u +%s)
: >"$dir/started"
tmux_run new-session -d -s "$session" -x 220 -y 50 -c "$dir/repo" "$command_line"
rc=0
wait_for_start || rc=1

# receipts_ready: every fixture issue has an open PR whose comments carry an ak receipt (REST only).
receipts_ready() {
    local number pr need=0 have=0
    for number in $(jq -r '.[]' "${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/current-issues.json"); do
        need=$((need + 1))
        pr=$(gh api "repos/$repo/pulls?state=open&per_page=100" --jq \
            "[.[] | select(((.body // \"\") | test(\"#$number([^0-9]|\$)\")) or (.head.ref | test(\"(^|[^0-9])$number\$\")))] | .[0].number // empty")
        [[ -n $pr ]] || continue
        gh api "repos/$repo/issues/$pr/comments?per_page=100" --jq '.[].body' | grep -q 'ak receipt' && have=$((have + 1))
    done
    ((need > 0 && have == need))
}

if ((dry)); then
    log 'dry-run: not polling GitHub'
elif ((rc == 0)); then
    export AK_BENCH_REAL_GH="$real_gh"
    while :; do
        receipts_ready && break
        if ! session_exists; then log 'CLI exited before all receipts arrived'; rc=1; break; fi
        if (($(date -u +%s) - started >= timeout_s)); then rc=124; break; fi
        sleep "${AK_BENCH_TUI_POLL:-60}"
    done
fi
stop_session || rc=1
ended=$(date -u +%s)
log "run rc=$rc elapsed=$((ended - started))s"
if ((dry)); then log 'dry-run: done'; exit "$rc"; fi

log 'score PR heads with the hidden acceptance suites'
outcome="$dir/outcome.json"
"$here/outcome.sh" "$repo" "$dir/repo" "$issues" "$rc" "$((ended - started))" 2>>"$dir/trial.log" |
    jq --argjson calls "$("$here/gh-calls.py" "$log_gh")" '. + {github: $calls}' >"$outcome"

row="$dir/row.json"
fixture_label="tally-waves-v1$variant:$(jq -r .tag "$state"):$issues"
if [[ -n $root ]]; then
    "$here/score.py" "$root" --sessions "$sessions" --harness "$harness" --outcome "$outcome" \
        --label kit=v2 --label mode=tui --label harness="$harness" --label ref="$sha" --label fixture="$fixture_label" \
        --label plugin_sha="$sha" --label fixture_version="$fixture_label" \
        --label trial="$trial" --label model="$model" --label effort="$effort" >"$row"
else
    jq -n --arg harness "$harness" --arg ref "$sha" --arg fixture "$fixture_label" --arg trial "$trial" --slurpfile o "$outcome" \
        '{kit:"v2", mode:"tui", harness:$harness, ref:$ref, fixture:$fixture, plugin_sha:$ref, fixture_version:$fixture,
          trial:$trial, error:"no root transcript", outcome:$o[0]}' >"$row"
fi
cat -- "$row" >>"$bench/results/live.jsonl"
jq -c '{trial, harness, mode, passed: .outcome.passed, prs: .outcome.prs, root_tokens: .root.tokens.total_tokens, wakes: .root.wakes.total}' "$row"
exit "$rc"
