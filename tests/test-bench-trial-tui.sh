#!/usr/bin/env bash
# Suite: bench/live/trial-tui.sh --dry-run -- the interactive tmux arm for Codex and Claude. Stub tmux, codex,
# claude and gh on PATH record what the script does; no CLI, network or GitHub is touched.
set -uo pipefail

TEST_NAME='bench trial tui'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

trial_tui="$repo_root/bench/live/trial-tui.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/stubs"
cat >"$tmp/stubs/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
if [[ $1 == capture-pane ]]; then
    # Replay one scripted pane per call; once the script runs out the CLI shows its input prompt.
    if [[ -s ${STUB_PANES:-/nonexistent} ]]; then
        head -n 1 "$STUB_PANES"
        sed -i 1d "$STUB_PANES"
    else
        printf '❯ \n? for shortcuts › 90%% context left\n'
    fi
fi
env | grep -E '^(CLAUDE|CODEX_THREAD_ID|CODEX_SESSION_ID|CODEX_CI)' >>"$STUB_ENV" || true
STUB
cat >"$tmp/stubs/codex" <<'STUB'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >>"$STUB_LOG"
STUB
cat >"$tmp/stubs/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$STUB_LOG"
STUB
cat >"$tmp/stubs/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$STUB_LOG"
STUB
chmod +x "$tmp/stubs/"*

# shellcheck disable=SC2034 # RUN_OUT is kept for debugging a failed run
run_arm() {
    local harness=$1
    : >"$tmp/log" && : >"$tmp/env"
    RUN_OUT=$(STUB_LOG="$tmp/log" STUB_ENV="$tmp/env" PATH="$tmp/stubs:$PATH" AK_BENCH_WORK="$tmp/work" \
        AK_BENCH_CODEX_AUTH="$tmp/auth.json" AK_BENCH_TUI_READY_POLL=0 STUB_PANES="${PANES:-}" AK_BENCH_TUI_READY_TIMEOUT="${AK_BENCH_TUI_READY_TIMEOUT:-120}" \
        CLAUDE_CODE_LEAK=1 CODEX_THREAD_ID=leak \
        "$trial_tui" --harness "$harness" --ref HEAD --dry-run --trial "t-$harness" 2>&1)
    RUN_RC=$?
}


: >"$tmp/auth.json"
for harness in codex claude; do
    run_arm "$harness"
    assert_eq 0 "$RUN_RC" "$harness: dry-run exits 0"
    mapfile -t calls <"$tmp/log"
    tmux_calls=()
    for line in "${calls[@]}"; do [[ $line == codex* || $line == claude* || $line == gh* || $line == capture-pane* ]] || tmux_calls+=("$line"); done
    sends=$(printf '%s\n' "${tmux_calls[@]}" | grep -c '^send-keys' || true)
    assert_eq 1 "$sends" "$harness: exactly one send-keys in a dry run"
    assert_contains "${tmux_calls[0]}" 'kill-session' "$harness: a stale session is cleared first"
    assert_contains "${tmux_calls[1]}" 'new-session -d' "$harness: the CLI starts in a detached session"
    assert_contains "${tmux_calls[2]}" 'send-keys' "$harness: the invocation is sent right after the session starts"
    assert_contains "${tmux_calls[3]}" 'kill-session' "$harness: nothing is typed after the invocation, then the session is dropped"
    assert_eq 4 "${#tmux_calls[@]}" "$harness: no other tmux command runs"
    assert_eq '' "$(cat "$tmp/env")" "$harness: tmux does not inherit CLAUDE* or CODEX_THREAD_ID"
    assert_contains "${tmux_calls[1]}" '-u CLAUDE_CODE_LEAK' "$harness: the CLI command line unsets the leaked variable"
    assert_contains "${tmux_calls[1]}" '-u CODEX_THREAD_ID' "$harness: the CLI command line unsets CODEX_THREAD_ID"
done

# Worker models belong to the arm's own harness.
run_arm codex
assert_contains "$(cat "$tmp/work/t-codex/repo/.agent/config.env")" 'AGENT_WORKER_MODELS=gpt-6-luna' 'codex: kit workers use gpt-6-luna'
assert_contains "$(cat "$tmp/work/t-codex/codex-home/config.toml")" 'default_subagent_model = "gpt-6-luna"' 'codex: Codex sub-agents use gpt-6-luna'
assert_contains "$(cat "$tmp/work/t-codex/codex-home/config.toml")" 'multi_agent = true' 'codex: spawn_agent is enabled, the wave needs workers'
assert_not_contains "$(cat "$tmp/work/t-codex/codex-home/config.toml")" 'multi_agent = false' 'codex: multi-agent is never switched off'
assert_contains "$(cat "$tmp/work/t-codex/codex-home/config.toml")" 'trust_level = "trusted"' 'codex: the clone dir is pre-trusted in the private home'
assert_not_contains "$(cat "$tmp/work/t-codex/repo/.agent/config.env")" 'gpt-5.6' 'codex: no retired model id'
run_arm claude
assert_contains "$(cat "$tmp/work/t-claude/repo/.agent/config.env")" 'AGENT_WORKER_MODELS=sonnet' 'claude: kit workers use sonnet'
assert_contains "$(cat "$tmp/work/t-claude/repo/.agent/config.env")" 'AGENT_WORKER_EFFORT=high' 'claude: worker effort is high'
assert_not_contains "$(cat "$tmp/work/t-claude/repo/.agent/config.env")" 'gpt' 'claude: no Codex model in the Claude arm'

# Readiness: the pane is read until the prompt shows; a trust dialog is answered with its accept key first,
# and the invocation is the only thing typed after that.
PANES="$tmp/panes"
printf 'loading\nDo you trust the files in this folder?\n' >"$PANES"
run_arm claude
mapfile -t calls <"$tmp/log"
seq=$(printf '%s\n' "${calls[@]}" | grep -E '^(capture-pane|send-keys)' | cut -d' ' -f1 | tr '\n' ' ')
assert_eq 'capture-pane capture-pane send-keys capture-pane send-keys ' "$seq" 'claude: read, read the trust dialog, accept it, read the prompt, then type the invocation'
assert_contains "$(grep '^send-keys' "$tmp/log" | head -n 1)" 'Enter' 'claude: the trust dialog is accepted with Enter'
assert_contains "$(grep '^send-keys' "$tmp/log" | tail -n 1)" '/ak:issues' 'claude: the invocation is typed last'
printf 'booting\nbooting\nbooting\nbooting\nbooting\n' >"$PANES"
AK_BENCH_TUI_READY_TIMEOUT=3 run_arm claude
assert_eq 1 "$RUN_RC" 'a CLI that never shows a prompt fails the trial'
assert_eq 0 "$(grep -c '^send-keys' "$tmp/log")" 'nothing is typed when the prompt never appears'
PANES=''

run_arm codex
# shellcheck disable=SC2016 # the dollar is the Codex skill sigil
assert_contains "$(grep '^send-keys' "$tmp/log")" '$ak:issues --serialize --yolo --limit 4 Enter' 'codex: sends the dollar-sigil invocation'
assert_contains "$(grep new-session "$tmp/log")" "CODEX_HOME=$tmp/work/t-codex/codex-home" 'codex: private CODEX_HOME on the command line'
assert_eq yes "$([[ -f $tmp/work/t-codex/codex-home/config.toml ]] && echo yes || echo no)" 'codex: private CODEX_HOME holds a config'
assert_contains "$(cat "$tmp/log")" 'codex plugin add ak@agent-kit' 'codex: ak plugin installed into the private home'

run_arm claude
assert_contains "$(grep '^send-keys' "$tmp/log")" '/ak:issues --serialize --yolo --limit 4 Enter' 'claude: sends the slash invocation'
newsession=$(grep new-session "$tmp/log")
assert_contains "$newsession" "--plugin-dir $tmp/work/t-claude/kit/v2" 'claude: kit loaded from the pinned archive'
assert_contains "$newsession" '--setting-sources project\,local' 'claude: user-level settings are not loaded'
assert_not_contains "$newsession" 'CODEX_HOME' 'claude: no Codex home in the Claude arm'

finish
