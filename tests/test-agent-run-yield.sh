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

finish
