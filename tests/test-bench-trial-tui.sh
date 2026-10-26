#!/usr/bin/env bash
# Dry-run contracts: initial prompt, trust dialogs, pinned kit, worker config and environment isolation.
set -uo pipefail
TEST_NAME='bench trial tui'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
tmp=$(mktemp -d)
cleanup() {
    if [[ -f $tmp/claude-projects ]]; then
        while IFS= read -r project; do rm -rf -- "$project"; done <"$tmp/claude-projects"
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
cp "$here/fixtures/bench-tui/command.py" "$tmp/bin/command.py"
chmod +x "$tmp/bin/command.py"
for command in tmux codex claude gh sleep; do ln -s command.py "$tmp/bin/$command"; done
export TUI_FIXTURE="$tmp"
counter=0
run_arm() {
    local harness=$1 mode=${2:-normal}
    counter=$((counter + 1))
    trial="dry-$harness-$counter"
    dir="$tmp/work/$trial"
    : >"$tmp/calls"; : >"$tmp/invocations"; : >"$tmp/inherited"
    RUN_OUT=$(TUI_MODE="$mode" PATH="$tmp/bin:$PATH" AK_BENCH_WORK="$tmp/work" \
        AK_BENCH_TUI_READY_POLL=0 AK_BENCH_TUI_READY_TIMEOUT=2 CLAUDE_CODE_LEAK=1 CODEX_THREAD_ID=leak \
        "$repo_root/bench/live/trial-tui.sh" --harness "$harness" --ref HEAD --dry-run --trial "$trial" 2>&1)
    RUN_RC=$?
    newsession=$(jq -r 'select(.[0:2] == ["tmux","new-session"]) | .[-1]' "$tmp/calls")
}

for harness in codex claude; do
    run_arm "$harness"
    assert_eq 0 "$RUN_RC" "$harness: dry-run exits 0"
    assert_contains "$RUN_OUT" 'root turn started' "$harness: a transcript confirms startup"
    assert_eq 1 "$(wc -l <"$tmp/invocations")" "$harness: one initial invocation reaches the CLI"
    assert_eq 0 "$(jq -s '[.[] | select(.[0:2] == ["tmux","send-keys"])] | length' "$tmp/calls")" "$harness: no composer keys are needed"
    assert_eq 1 "$(jq -s '[.[] | select(.[0:2] == ["tmux","new-session"])] | length' "$tmp/calls")" "$harness: one detached CLI starts"
    assert_eq no "$([[ -e $tmp/alive ]] && echo yes || echo no)" "$harness: dry-run cleans up its session"
    assert_eq '' "$(cat "$tmp/inherited")" "$harness: tmux and CLI do not inherit session variables"
    assert_contains "$newsession" '-u CLAUDE_CODE_LEAK' "$harness: CLI launch unsets leaked Claude variable"
    assert_contains "$newsession" '-u CODEX_THREAD_ID' "$harness: CLI launch unsets inherited Codex thread"
done

run_arm codex
assert_contains "$(cat "$dir/repo/.agent/config.env")" 'AGENT_WORKER_MODELS=gpt-6-luna' 'codex: kit workers use gpt-6-luna'
assert_contains "$(cat "$dir/codex-home/config.toml")" 'default_subagent_model = "gpt-6-luna"' 'codex: sub-agents use gpt-6-luna'
assert_contains "$(cat "$dir/codex-home/config.toml")" 'multi_agent = true' 'codex: spawning is enabled'
assert_not_contains "$(cat "$dir/codex-home/config.toml")" 'multi_agent = false' 'codex: spawning is never disabled'
assert_contains "$(cat "$dir/codex-home/config.toml")" 'trust_level = "trusted"' 'codex: clone is pre-trusted'
assert_not_contains "$(cat "$dir/repo/.agent/config.env")" 'gpt-5.6' 'codex: no retired model id'
assert_contains "$newsession" "CODEX_HOME=$dir/codex-home" 'codex: private home travels on the command line'
assert_contains "$(cat "$tmp/calls")" '"codex", "plugin", "add", "ak@agent-kit"' 'codex: pinned plugin is installed'
# shellcheck disable=SC2016 # the dollar is the Codex skill sigil
assert_eq '$ak:issues --serialize --yolo --limit 4' "$(cat "$tmp/invocations")" 'codex: literal dollar-sigil invocation arrives intact'

run_arm claude
assert_contains "$(cat "$dir/repo/.agent/config.env")" 'AGENT_WORKER_MODELS=sonnet' 'claude: workers use sonnet'
assert_contains "$(cat "$dir/repo/.agent/config.env")" 'AGENT_WORKER_EFFORT=high' 'claude: worker effort is high'
assert_not_contains "$(cat "$dir/repo/.agent/config.env")" 'gpt' 'claude: no Codex model in the Claude arm'
assert_contains "$newsession" "--plugin-dir $dir/kit/v2" 'claude: kit loaded from pinned archive'
assert_contains "$newsession" '--setting-sources project\,local' 'claude: user-level settings are not loaded'
assert_not_contains "$newsession" 'CODEX_HOME' 'claude: no Codex home in the Claude arm'
assert_eq '/ak:issues --serialize --yolo --limit 4' "$(cat "$tmp/invocations")" 'claude: slash invocation arrives intact'

printf 'loading\nDo you trust the files in this folder?\n' >"$tmp/panes"
run_arm claude
assert_eq 0 "$RUN_RC" 'claude: startup succeeds after trust dialog'
assert_eq '["Enter"]' "$(jq -c 'select(.[0:2] == ["tmux","send-keys"]) | .[4:]' "$tmp/calls")" 'claude: only the trust dialog receives a key'
assert_eq 1 "$(wc -l <"$tmp/invocations")" 'claude: trust dialog does not duplicate the invocation'
printf 'Bypass Permissions mode\n' >"$tmp/panes"
run_arm claude
assert_eq 0 "$RUN_RC" 'claude: startup succeeds after bypass dialog'
assert_eq '["2","Enter"]' "$(jq -c 'select(.[0:2] == ["tmux","send-keys"]) | .[4:]' "$tmp/calls")" 'claude: documented bypass choice is sent'
rm "$tmp/panes"
run_arm claude no-start
assert_eq 1 "$RUN_RC" 'claude: composer and user transcript alone are not a started turn'
assert_contains "$RUN_OUT" 'no agent turn' 'claude: bounded startup failure has a useful diagnostic'
assert_eq 1 "$(wc -l <"$tmp/invocations")" 'claude: failed startup is never resubmitted'
finish
