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
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

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
    # Not a lexical sort: two runs inside one second produce `<stamp>-test.log`
    # and `<stamp>-test.<pid>.log`, and `l` sorts after any digit, so `sort |
    # tail -1` returns the FIRST file and the repeat-invocation assertion below
    # silently re-reads the original log instead of the second run's.
    find "$1/.agent/logs" -type f -name '*-test*.log' -printf '%T@\t%p\n' |
        sort -n | tail -n 1 | cut -f2-
}

# --- deterministic per-worktree identity -----------------------------------
repo_one=$(make_repo)
repo_two=$(make_repo)
make_emit_repo "$repo_one"
make_emit_repo "$repo_two"

out_one=$(cd "$repo_one" && "$real_run_sh" --cmd test 2>&1)
log_one=$(latest_log "$repo_one")
project_one=$(grep -v '^===' "$log_one" | tail -n 1)
cd "$repo_one" && "$real_run_sh" --cmd test >/dev/null 2>&1
log_one_repeat=$(latest_log "$repo_one")
project_one_repeat=$(grep -v '^===' "$log_one_repeat" | tail -n 1)
cd "$repo_two" && "$real_run_sh" --cmd test >/dev/null 2>&1
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
hardcode_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
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
set +e
cli_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
cli_rc=$?
set -e
assert_contains "$cli_out" 'hardcodes a Compose project name' \
    'a declared CLI project name is reported'
assert_contains "$cli_out" 'fixed-cli-project' \
    'the CLI hardcode value is visible for remediation'
# A declared -p/--project-name outranks the exported name, so isolation cannot be
# established at all. Warning and running anyway is the collision this gate
# exists to prevent, so the run must fail closed instead of proceeding.
assert_eq '5' "$cli_rc" 'a declared CLI project name fails closed instead of running unisolated'
assert_contains "$cli_out" 'ISOLATION-IMPOSSIBLE' \
    'the refusal is greppable by a dispatcher'
assert_contains "$cli_out" 'serialize full-suite verification' \
    'the refusal names serialization as the remedy'
assert_not_contains "$cli_out" 'PASS:' \
    'the declared command never runs when isolation is impossible'

# The dispatcher asserts it has serialized; the same command then proceeds.
set +e
cli_serialized_out=$(cd "$repo" && AGENT_COMPOSE_SERIALIZED=1 "$real_run_sh" --cmd test 2>&1)
cli_serialized_rc=$?
set -e
assert_eq '0' "$cli_serialized_rc" \
    'AGENT_COMPOSE_SERIALIZED=1 lets the serialized run proceed'
assert_contains "$cli_serialized_out" 'isolation-impossible accepted' \
    'the serialized run records the assertion it proceeded under'

# --- the engine subcommand behind global options ---------------------------
# `docker --context ci compose ...` is still a Compose invocation, but matching
# only the token immediately before `compose` saw `ci` and missed it entirely:
# no hardcode diagnostic and no fallback, while --project-name still took effect.
# One case per engine, since each spells its global option differently.
for engine_case in 'docker:--context' 'podman:--connection'; do
    engine=${engine_case%%:*}
    global_opt=${engine_case##*:}
    repo=$(make_repo)
    printf '#!/bin/sh\nprintf "%%s\\n" "${COMPOSE_PROJECT_NAME-}"\n' > "$repo/tools/$engine"
    chmod +x "$repo/tools/$engine"
    printf 'AGENT_CMD_TEST=tools/%s %s ci compose --project-name fixed-%s-global\n' \
        "$engine" "$global_opt" "$engine" > "$repo/.agent/config.env"
    set +e
    global_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
    global_rc=$?
    set -e
    assert_contains "$global_out" 'hardcodes a Compose project name' \
        "a $engine global option before compose still reports the hardcode"
    assert_contains "$global_out" "fixed-$engine-global" \
        "the $engine global-option hardcode value is visible for remediation"
    assert_eq '5' "$global_rc" \
        "a $engine global option before compose still fails closed"
    assert_contains "$global_out" 'ISOLATION-IMPOSSIBLE' \
        "the $engine global-option refusal is greppable by a dispatcher"
done

repo=$(make_repo)
make_emit_repo "$repo"
printf 'AGENT_CMD_TEST=tools/emit-compose -p no:cacheprovider\n' \
    > "$repo/.agent/config.env"
unrelated_flag_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
assert_not_contains "$unrelated_flag_out" 'hardcodes a Compose project name' \
    'an unrelated short -p flag is not treated as a Compose project name'

# --- Compose dependency-start collisions are retry-eligible findings --------
# Positive evidence path 1: the declared command's resolved argv is itself a
# Compose invocation (compose_argv already answers this).
repo=$(make_repo)
printf '#!/bin/sh\nprintf "dependency failed to start; container name is already in use\\n"\nexit 1\n' \
    > "$repo/tools/docker"
chmod +x "$repo/tools/docker"
printf 'AGENT_CMD_TEST=tools/docker compose\n' > "$repo/.agent/config.env"
collision_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
assert_contains "$collision_out" 'FAIL(rc=1)' \
    'a Compose collision preserves the wrapped command exit status'
assert_contains "$collision_out" 'environment-retry-eligible' \
    'a Compose dependency-start collision is retry-eligible when the declared command is a Compose invocation'
assert_contains "$collision_out" 'not a code regression' \
    'the collision finding is distinct from a code regression'

# Positive evidence path 2: the repository actually contains a Compose file,
# even though the declared command itself is not a Compose invocation.
repo=$(make_repo)
printf 'services: {}\n' > "$repo/compose.yaml"
printf '#!/bin/sh\nprintf "dependency failed to start; port is already allocated\\n"\nexit 1\n' \
    > "$repo/tools/fail-compose-file"
chmod +x "$repo/tools/fail-compose-file"
printf 'AGENT_CMD_TEST=tools/fail-compose-file\n' > "$repo/.agent/config.env"
compose_file_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
assert_contains "$compose_file_out" 'environment-retry-eligible' \
    'a Compose dependency-start collision is retry-eligible when the repository contains a Compose file'

# The defect this issue fixes: signature 1 used to be satisfied by ANY log
# line mentioning "docker compose" or "docker-compose" -- including a test
# name that merely describes Compose behaviour -- with no evidence the
# declared command or repository actually used Compose. A repository with no
# Compose file, running a declared command that is not itself a Compose
# invocation, must never classify -- even when its log contains both the old
# substring signature and a genuine collision signature.
repo=$(make_repo)
printf '#!/bin/sh\nprintf "ok a declared docker compose test command brings the Compose-isolation prose\\n"\nprintf "FAIL: expected port 8080 free, but port is already allocated\\n"\nexit 1\n' \
    > "$repo/tools/fail-compose-mention"
chmod +x "$repo/tools/fail-compose-mention"
printf 'AGENT_CMD_TEST=tools/fail-compose-mention\n' > "$repo/.agent/config.env"
mention_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
assert_contains "$mention_out" 'FAIL(rc=1)' \
    'a mislabelled misfire fixture still preserves the wrapped command exit status'
assert_not_contains "$mention_out" 'environment-retry-eligible' \
    'a log mentioning "docker compose" only in test/assertion text is not retry-eligible without positive Compose evidence'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "AssertionError: expected green result\\n"\nexit 1\n' \
    > "$repo/tools/fail-code"
chmod +x "$repo/tools/fail-code"
printf 'AGENT_CMD_TEST=tools/fail-code\n' > "$repo/.agent/config.env"
code_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
assert_not_contains "$code_out" 'environment-retry-eligible' \
    'a normal command failure is not mislabeled as a Compose environment finding'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "composer: address already in use\\n"\nexit 1\n' \
    > "$repo/tools/fail-composer"
chmod +x "$repo/tools/fail-composer"
printf 'AGENT_CMD_TEST=tools/fail-composer\n' > "$repo/.agent/config.env"
composer_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
assert_not_contains "$composer_out" 'environment-retry-eligible' \
    'a Composer-style failure is not treated as a Compose collision'

repo=$(make_repo)
printf '#!/bin/sh\nprintf "docker compose: address already in use\\n"\nexit 1\n' \
    > "$repo/tools/fail-compose-address"
chmod +x "$repo/tools/fail-compose-address"
printf 'AGENT_CMD_TEST=tools/fail-compose-address\n' > "$repo/.agent/config.env"
compose_address_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
assert_not_contains "$compose_address_out" 'environment-retry-eligible' \
    'a bare address collision without dependency evidence is not retry-eligible'

finish
