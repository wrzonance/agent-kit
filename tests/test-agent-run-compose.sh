#!/usr/bin/env bash
# Suite: agent-run.sh isolates Compose projects and classifies startup collisions.
# shellcheck disable=SC2016  # generated fixture keeps the variable literal.
set -uo pipefail

TEST_NAME='agent-run-compose'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

real_run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tty_approve="$here/lib/tty-approve"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export AGENT_TRUST_ROOT="$tmp/trust"

run_sh="$tmp/approved-agent-run.sh"
printf '#!/usr/bin/env bash\n"%s" y -- "%s" --approve "$@" >/dev/null 2>&1\nexec "%s" "$@"\n' \
    "$tty_approve" "$real_run_sh" "$real_run_sh" > "$run_sh"
chmod +x "$run_sh"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent" "$dir/tools"
    printf '%s' "$dir"
}

make_emit_repo() {
    local dir=$1
    printf '#!/bin/sh\nprintf "%%s\\n" "${COMPOSE_PROJECT_NAME-}"\n' > "$dir/tools/emit-compose"
    chmod +x "$dir/tools/emit-compose"
    printf 'AGENT_CMD_TEST=tools/emit-compose\n' > "$dir/.agent/config.env"
}

latest_log() {
    find "$1/.agent/logs" -type f -name '*-test*.log' -print | sort | tail -n 1
}

# --- deterministic per-worktree identity -----------------------------------
repo_one=$(make_repo)
repo_two=$(make_repo)
make_emit_repo "$repo_one"
make_emit_repo "$repo_two"

out_one=$(cd "$repo_one" && "$run_sh" --cmd test 2>&1)
log_one=$(latest_log "$repo_one")
project_one=$(grep -v '^===' "$log_one" | tail -n 1)
cd "$repo_one" && "$run_sh" --cmd test >/dev/null 2>&1
log_one_repeat=$(latest_log "$repo_one")
project_one_repeat=$(grep -v '^===' "$log_one_repeat" | tail -n 1)
cd "$repo_two" && "$run_sh" --cmd test >/dev/null 2>&1
log_two=$(latest_log "$repo_two")
project_two=$(grep -v '^===' "$log_two" | tail -n 1)

assert_contains "$out_one" 'PASS:' 'a named command still runs with Compose isolation enabled'
assert_contains "$project_one" 'agentkit-' 'the command receives a deterministic Compose project name'
assert_eq "$project_one" "$project_one_repeat" 'the same worktree receives the same Compose project name'
assert_not_contains "$project_one" "$project_two" 'different worktrees receive different Compose project names'

# --- repository hardcodes are reported and overridden -----------------------
repo=$(make_repo)
make_emit_repo "$repo"
printf 'name: fixed-compose-project\nservices: {}\n' > "$repo/compose.yaml"
printf 'COMPOSE_PROJECT_NAME=another-fixed-project\n' > "$repo/.env"
hardcode_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
hardcode_log=$(latest_log "$repo")
hardcode_project=$(grep -v '^===' "$hardcode_log" | tail -n 1)
assert_contains "$hardcode_out" 'hardcodes a Compose project name' \
    'a repository hardcoded Compose name is reported'
assert_contains "$hardcode_out" 'compose.yaml' \
    'the hardcoded Compose file is named in the diagnostic'
assert_contains "$hardcode_out" '.env' \
    'the hardcoded environment file is named in the diagnostic'
assert_not_contains "$hardcode_project" 'fixed-compose-project' \
    'the deterministic worktree name overrides a Compose file hardcode'
assert_not_contains "$hardcode_project" 'another-fixed-project' \
    'the deterministic worktree name overrides an environment hardcode'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "%%s\\n" "${COMPOSE_PROJECT_NAME-}"\n' > "$repo/tools/docker"
chmod +x "$repo/tools/docker"
printf 'AGENT_CMD_TEST=tools/docker compose --project-name fixed-cli-project\n' \
    > "$repo/.agent/config.env"
cli_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
assert_contains "$cli_out" 'hardcodes a Compose project name' \
    'a declared CLI project name is reported'
assert_contains "$cli_out" 'fixed-cli-project' \
    'the CLI hardcode value is visible for remediation'

repo=$(make_repo)
make_emit_repo "$repo"
printf 'AGENT_CMD_TEST=tools/emit-compose -p no:cacheprovider\n' \
    > "$repo/.agent/config.env"
unrelated_flag_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
assert_not_contains "$unrelated_flag_out" 'hardcodes a Compose project name' \
    'an unrelated short -p flag is not treated as a Compose project name'

# --- Compose dependency-start collisions are retry-eligible findings --------
repo=$(make_repo)
printf '#!/bin/sh\nprintf "docker compose: dependency failed to start; container name is already in use\\n"\nexit 1\n' \
    > "$repo/tools/fail-compose"
chmod +x "$repo/tools/fail-compose"
printf 'AGENT_CMD_TEST=tools/fail-compose\n' > "$repo/.agent/config.env"
collision_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1 || true)
assert_contains "$collision_out" 'FAIL(rc=1)' \
    'a Compose collision preserves the wrapped command exit status'
assert_contains "$collision_out" 'environment-retry-eligible' \
    'a Compose dependency-start collision is retry-eligible'
assert_contains "$collision_out" 'not a code regression' \
    'the collision finding is distinct from a code regression'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "AssertionError: expected green result\\n"\nexit 1\n' \
    > "$repo/tools/fail-code"
chmod +x "$repo/tools/fail-code"
printf 'AGENT_CMD_TEST=tools/fail-code\n' > "$repo/.agent/config.env"
code_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1 || true)
assert_not_contains "$code_out" 'environment-retry-eligible' \
    'a normal command failure is not mislabeled as a Compose environment finding'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "composer: address already in use\\n"\nexit 1\n' \
    > "$repo/tools/fail-composer"
chmod +x "$repo/tools/fail-composer"
printf 'AGENT_CMD_TEST=tools/fail-composer\n' > "$repo/.agent/config.env"
composer_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1 || true)
assert_not_contains "$composer_out" 'environment-retry-eligible' \
    'a Composer-style failure is not treated as a Compose collision'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "docker compose: address already in use\\n"\nexit 1\n' \
    > "$repo/tools/fail-compose-address"
chmod +x "$repo/tools/fail-compose-address"
printf 'AGENT_CMD_TEST=tools/fail-compose-address\n' > "$repo/.agent/config.env"
compose_address_out=$(cd "$repo" && "$run_sh" --cmd test 2>&1 || true)
assert_not_contains "$compose_address_out" 'environment-retry-eligible' \
    'a bare address collision without dependency evidence is not retry-eligible'

finish
