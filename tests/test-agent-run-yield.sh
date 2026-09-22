#!/usr/bin/env bash
# Suite: yielded agent-run calls remain observable and cannot be duplicated.
set -uo pipefail

TEST_NAME='agent-run-yield'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

help=$($run_sh --help)
assert_contains "$help" 'active duplicate exits 2' \
    'help documents the accepted duplicate-run exit status'
assert_contains "$help" 'unknown abandoned handle exits 75' \
    'help distinguishes abandoned verification evidence from a live duplicate'
assert_not_contains "$help" 'exit 2 is reserved' \
    'help no longer reserves duplicate-run status for interpreter errors'
assert_contains "$help" 'in-flight command is still refused with its log' \
    '--force documentation does not promise a duplicate-run bypass'

epoch_repo=$tmp/epoch-repo
git -C "$tmp" init -q epoch-repo
mkdir -p "$epoch_repo/.agent" "$epoch_repo/tools"
cat > "$epoch_repo/tools/check" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'started\n' > "${STARTED_FILE:?}"
sleep 1
EOF
chmod +x -- "$epoch_repo/tools/check"
printf 'AGENT_CMD_TEST=tools/check\n' > "$epoch_repo/.agent/config.env"
printf 'unset EPOCHSECONDS\n' > "$tmp/unset-epoch"
BASH_ENV=$tmp/unset-epoch STARTED_FILE=$tmp/epoch-started \
    "$run_sh" --dir "$epoch_repo" --cmd test > "$tmp/epoch.out" 2>&1 &
epoch_owner=$!
for ((attempt=0; attempt<100; attempt++)); do
    epoch_log=$(find "$epoch_repo/.agent/logs" -type f -name '*-test.log' -print -quit 2>/dev/null || true)
    [[ -n ${epoch_log:-} && -f $tmp/epoch-started ]] && break
    sleep 0.02
done
epoch_status=$(BASH_ENV=$tmp/unset-epoch "$run_sh" status "$epoch_log" 2>&1)
assert_contains "$epoch_status" 'running pid=' \
    'a live run remains observable when EPOCHSECONDS is unavailable'
wait "$epoch_owner"
assert_eq 0 "$?" 'a declared command runs when EPOCHSECONDS is unavailable'

repo=$tmp/repo
git -C "$tmp" init -q repo
mkdir -p "$repo/.agent" "$repo/tools"
cat > "$repo/tools/slow-check" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'started\n' > "${STARTED_FILE:?}"
sleep 2
printf 'finished\n'
EOF
chmod +x -- "$repo/tools/slow-check"
printf 'AGENT_CMD_TEST=tools/slow-check\n' > "$repo/.agent/config.env"

owner_out=$tmp/owner.out
STARTED_FILE=$tmp/started "$run_sh" --dir "$repo" --cmd test > "$owner_out" 2>&1 &
owner=$!
for ((attempt=0; attempt<100; attempt++)); do
    log=$(find "$repo/.agent/logs" -type f -name '*-test.log' -print -quit 2>/dev/null || true)
    [[ -n ${log:-} && -f $tmp/started ]] && break
    sleep 0.02
done

assert_contains "$(tail -n 1 -- "$owner_out")" 'resume this same call; never relaunch' \
    'the final pre-block line tells a yielded caller to resume the same call'
status=$($run_sh status "$log" 2>&1)
assert_contains "$status" 'running pid=' 'status identifies an unfinished live run'
assert_contains "$status" 'elapsed=' 'running status includes elapsed seconds'

duplicate=''
duplicate_rc=0
duplicate=$(STARTED_FILE=$tmp/duplicate "$run_sh" --dir "$repo" --cmd test 2>&1) || duplicate_rc=$?
assert_eq 2 "$duplicate_rc" 'an identical active launch is refused as usage'
assert_contains "$duplicate" "already running: $log" 'duplicate refusal names the original log'
assert_eq no "$([[ -e $tmp/duplicate ]] && printf yes || printf no)" \
    'the refused duplicate never starts the declared command'

wait "$owner"
assert_eq pass "$($run_sh status "$log")" 'status reports pass after the owner completes'

printf 'AGENT_CMD_TEST=false\n' > "$repo/.agent/config.env"
"$run_sh" --dir "$repo" --label failing --cmd test > /dev/null 2>&1 || true
fail_log=$(find "$repo/.agent/logs" -type f -name '*-failing.log' -print -quit)
assert_eq 'fail rc=1' "$($run_sh status "$fail_log")" 'status preserves a terminal failure code'

background_repo=$tmp/background-repo
git -C "$tmp" init -q background-repo
mkdir -p "$background_repo/.agent" "$background_repo/tools"
cat > "$background_repo/tools/check" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'run\n' >> "${COUNT_FILE:?}"
sleep 5 &
printf '%s\n' "$!" > "${DESCENDANT_FILE:?}"
EOF
chmod +x -- "$background_repo/tools/check"
printf 'AGENT_CMD_TEST=tools/check\n' > "$background_repo/.agent/config.env"
COUNT_FILE=$tmp/background-count DESCENDANT_FILE=$tmp/descendant \
    "$run_sh" --dir "$background_repo" --cmd test > /dev/null 2>&1
descendant=$(<"$tmp/descendant")
assert_eq yes "$([[ $descendant =~ ^[0-9]+$ ]] && kill -0 "$descendant" 2>/dev/null && printf yes || printf no)" \
    'fixture leaves a live background descendant after agent-run completes'
second_rc=0
COUNT_FILE=$tmp/background-count DESCENDANT_FILE=$tmp/descendant-2 \
    "$run_sh" --dir "$background_repo" --cmd test > /dev/null 2>&1 || second_rc=$?
assert_eq 0 "$second_rc" 'a completed command descendant does not retain the active-run lease'
assert_eq 2 "$(wc -l < "$tmp/background-count" | tr -d '[:space:]')" \
    'the identical command executes again after its prior wrapper completes'
kill "$descendant" 2>/dev/null || true
[[ ! -f $tmp/descendant-2 ]] || kill "$(<"$tmp/descendant-2")" 2>/dev/null || true

symlink_repo=$tmp/symlink-repo
symlink_agent=$tmp/symlink-agent
git -C "$tmp" init -q symlink-repo
mkdir -p "$symlink_agent"
ln -s "$symlink_agent" "$symlink_repo/.agent"
"$run_sh" --dir "$symlink_repo" -- true > /dev/null 2>&1
assert_eq no "$([[ -e $symlink_agent/run-records ]] && printf yes || printf no)" \
    'a symlinked .agent parent receives no active-run records'
assert_eq no "$([[ -e $symlink_agent/logs ]] && printf yes || printf no)" \
    'a symlinked .agent parent receives no command logs'

finish
