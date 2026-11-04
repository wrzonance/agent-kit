#!/usr/bin/env bash
# The one Claude hook: it holds agent notices only while this session's ak wait is alive, and fails open otherwise.
TEST_NAME=v2-hook
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

hook="$REPO/v2/hooks/wave-barrier.sh"
repo=$(fixture_repo)
mkdir -p "$repo/.ak" "$repo/src"
marker="$repo/.ak/wave.open"

sleep 300 &
watcher=$!
trap 'kill "$watcher" 2>/dev/null; rm -rf -- "$WORK"' EXIT
start=$(awk '{ sub(/^.*\) /, ""); split($0, f, " "); print f[20] }' "/proc/$watcher/stat")

# write_marker PID START SESSION: the marker ak wait writes (cwd only when the session is empty).
write_marker() {
    printf 'pid=%s\nstart=%s\nsession=%s\n' "$1" "$2" "$3" >"$marker"
    [[ -n $3 ]] || printf 'cwd=%s\n' "$repo/src" >>"$marker"
}
# notice SUMMARY: the hook stdin for a task notice, shaped like the recorded S1 samples.
notice() {
    printf '{"session_id":"sess-1","transcript_path":"/t.jsonl","cwd":"%s","prompt_id":"p","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\\n<task-id>a1</task-id>\\n<output-file>/tmp/o</output-file>\\n<status>completed</status>\\n<summary>%s</summary>\\n</task-notification>"}' "$repo/src" "$1"
}
agent_final='Agent \"w\" finished'
agent_interim='Agent \"w\" is waiting on its own background work'
blocked='{"decision":"block","reason":"ak wait is open for this wave; its exit notice is the one wake."}'
run_hook() { bash "$hook"; }

write_marker "$watcher" "$start" sess-1
assert_eq "$blocked" "$(notice "$agent_final" | run_hook)" 'final agent notice, live marker, same session: blocked'
assert_eq "$blocked" "$(notice "$agent_interim" | run_hook)" 'interim agent notice: blocked'

plugin_space="$WORK/plugin root"
cp -r "$REPO/v2" "$plugin_space"
hook_command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$plugin_space/hooks/hooks.json")
assert_eq "$blocked" "$(notice "$agent_final" | CLAUDE_PLUGIN_ROOT="$plugin_space" bash -c "$hook_command")" 'the manifest runs the hook when the plugin root contains spaces'

assert_eq '' "$(notice 'Background command \"ak wait\" completed (exit code 0)' | run_hook)" 'bash-task notice passes'
human=$(printf '{"session_id":"sess-1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"Agent finished, what now?"}' "$repo/src")
assert_eq '' "$(run_hook <<<"$human")" 'human prompt passes'
quoting=$(printf '{"session_id":"sess-1","cwd":"%s","prompt":"see <summary>Agent \\"w\\" finished</summary>"}' "$repo/src")
assert_eq '' "$(run_hook <<<"$quoting")" 'a human prompt quoting a summary passes'

write_marker "$watcher" "$start" sess-2
assert_eq '' "$(notice "$agent_final" | run_hook)" 'different session passes'
write_marker "$watcher" "$start" ''
assert_eq "$blocked" "$(notice "$agent_final" | run_hook)" 'empty session, same cwd: blocked'
printf 'pid=%s\nstart=%s\nsession=\ncwd=/elsewhere\n' "$watcher" "$start" >"$marker"
assert_eq '' "$(notice "$agent_final" | run_hook)" 'empty session, other cwd passes'

write_marker "$watcher" "$start-x" sess-1
assert_eq '' "$(notice "$agent_final" | run_hook)" 'live pid with the wrong start passes'
dead=$(bash -c 'echo $$')
write_marker "$dead" "$start" sess-1
assert_eq '' "$(notice "$agent_final" | run_hook)" 'dead pid passes'
rm -f "$marker"
assert_eq '' "$(notice "$agent_final" | run_hook)" 'no marker passes'

write_marker "$watcher" "$start" sess-1
bad_input() { printf 'not json {' | bash "$hook"; }
assert_rc 0 'malformed stdin exits 0' -- bad_input
run_hook <<<'not json {' >"$WORK/out"
assert_eq '' "$(<"$WORK/out")" 'malformed stdin prints nothing'
assert_eq '' "$(printf '' | run_hook)" 'empty stdin prints nothing'

# Real recorded samples: the agent notices block, the bash-task notice and the human prompts pass.
samples="$REPO/tests/v2/fixtures/transcripts/claude/notices/hook-stdin-session1.jsonl"
printf 'pid=%s\nstart=%s\nsession=7d0884ba-b7aa-4a06-a83e-e8a37132cb18\n' "$watcher" "$start" >"$marker"
sed "s#\"cwd\":\"[^\"]*\"#\"cwd\":\"$repo/src\"#" "$samples" >"$WORK/samples"
held=0 passed=0
while IFS= read -r line; do
    if [[ -n $(run_hook <<<"$line") ]]; then held=$((held + 1)); else passed=$((passed + 1)); fi
done <"$WORK/samples"
agents=$(grep -c '<summary>Agent \\"' "$samples")
assert_eq "$agents" "$held" 'recorded samples: exactly the agent notices are held'

# The hook runs on every prompt, so its cost is the processes it forks. Count them with logging shims instead of
# timing it: a wall-clock budget fails under host load, while a new subprocess or network call always shows here.
shims="$WORK/shims"
mkdir -p "$shims"
for tool in git dirname sed awk grep cat ps date sleep curl wget jq tr cut head; do
    cat >"$shims/$tool" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$SHIM_LOG"
PATH=${PATH#"$SHIM_DIR:"} exec "${0##*/}" "$@"
SHIM
    chmod +x "$shims/$tool"
done
# forks INPUT: how many external processes the hook spawns for that stdin.
forks() {
    : >"$WORK/shim.log"
    printf '%s' "$1" | SHIM_DIR="$shims" SHIM_LOG="$WORK/shim.log" PATH="$shims:$PATH" bash "$hook" >/dev/null
    wc -l <"$WORK/shim.log" | tr -d ' '
}
human_prompt='{"session_id":"sess-1","cwd":"/x","prompt":"hello"}'
assert_eq 1 "$(forks "$human_prompt")" 'an ordinary prompt forks only the stdin read'
assert_eq 3 "$(forks "$(notice "$agent_final")")" 'a live-marker agent notice forks only stdin, git and dirname'

# The gate: the tree as shipped passes; a second event, a second command, or an extra file fails it.
lint="$V2_TESTS/lint-budget.sh"
copy="$WORK/v2copy"
cp -r "$REPO/v2" "$copy"
gate() { V2_ROOT=$copy bash "$lint"; }
assert_rc 0 'gate passes the shipped hook' -- gate
jq '.hooks.Stop = [{"hooks":[{"type":"command","command":"x/wave-barrier.sh"}]}]' "$copy/hooks/hooks.json" >"$WORK/h" && cp "$WORK/h" "$copy/hooks/hooks.json"
assert_rc 1 'gate fails a second event' -- gate
cp "$REPO/v2/hooks/hooks.json" "$copy/hooks/hooks.json"
jq '.hooks.UserPromptSubmit[0].hooks += [{"type":"command","command":"x/other.sh"}]' "$copy/hooks/hooks.json" >"$WORK/h" && cp "$WORK/h" "$copy/hooks/hooks.json"
assert_rc 1 'gate fails a second command' -- gate
cp "$REPO/v2/hooks/hooks.json" "$copy/hooks/hooks.json"
: >"$copy/hooks/extra.sh"
assert_rc 1 'gate fails an extra file' -- gate
rm "$copy/hooks/extra.sh"
jq '. + {hooks: "./hooks/hooks.json"}' "$copy/.claude-plugin/plugin.json" >"$WORK/h" && cp "$WORK/h" "$copy/.claude-plugin/plugin.json"
assert_rc 1 'gate fails a manifest hooks entry' -- gate

finish
