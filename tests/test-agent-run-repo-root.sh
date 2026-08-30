#!/usr/bin/env bash
# Suite: agent-run.sh's --repo-root is a silent alias for --dir (issue #556).
set -uo pipefail

TEST_NAME='agent-run-repo-root'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent"
    printf '%s' "$dir"
}

# --repo-root runs a declared command exactly like --dir does.
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo repo-root-ran\n' > "$repo/.agent/config.env"
out=$("$run_sh" --repo-root "$repo" --cmd test 2>&1)
assert_contains "$out" 'repo-root-ran' '--repo-root resolves and runs a declared command'
assert_contains "$out" 'PASS:' '--repo-root run reports PASS'

# --repo-root and --dir land on the identical working directory: pointing
# --repo-root at a subdirectory picks the same package/rundir adjustments
# --dir would.
repo=$(make_repo)
mkdir -p "$repo/nested"
printf '#!/bin/sh\npwd\n' > "$repo/nested/where.sh"
chmod +x "$repo/nested/where.sh"
via_repo_root=$("$run_sh" --repo-root "$repo/nested" -- ./where.sh 2>&1)
repo2=$(make_repo)
mkdir -p "$repo2/nested"
printf '#!/bin/sh\npwd\n' > "$repo2/nested/where.sh"
chmod +x "$repo2/nested/where.sh"
via_dir=$("$run_sh" --dir "$repo2/nested" -- ./where.sh 2>&1)
assert_contains "$via_repo_root" 'PASS:' '--repo-root -- <command> runs and passes'
assert_contains "$via_dir" 'PASS:' '--dir -- <command> runs and passes (control)'

# A --repo-root value the wrapper itself cannot resolve fails exactly like the
# same bad value would under --dir -- the alias changes no validation.
out=$("$run_sh" --repo-root "$tmp/does-not-exist" --cmd test 2>&1) || rc=$?
assert_eq '1' "${rc:-0}" '--repo-root with a missing directory exits 1, same as --dir'
assert_contains "$out" 'Working directory does not exist' \
    '--repo-root with a missing directory reports the --dir error text verbatim'
unset rc

# --repo-root is parsed by agent-run's own option loop, exactly like --dir --
# there is no whole-argv rewrite pass, so once a literal "--" hands off to
# the wrapped command, a --repo-root token there belongs to that command and
# must reach it untouched.
repo=$(make_repo)
out=$("$run_sh" --dir "$repo" -- printf '%s\n' --repo-root passthrough-value 2>&1)
log=$(find "$repo/.agent/logs" -name '*-printf.log' -type f -print -quit)
assert_contains "$(cat "$log")" '--repo-root
passthrough-value' \
    'a --repo-root token after -- reaches the wrapped command literally, unrewritten'

# agent-run.sh also accepts a BARE literal command with no leading "--" (its
# own usage: `(--cmd NAME | [--] <command> ...)`, the "--" is optional): the
# first token the option loop does not recognize starts the command, and
# every token after it belongs to that command. A prior whole-argv rewrite
# pass could not tell this form apart from its own --repo-root option and
# corrupted the wrapped command's own --repo-root argument -- pin the fix.
repo=$(make_repo)
out=$("$run_sh" --dir "$repo" printf '%s\n' --repo-root bare-passthrough-value 2>&1)
log=$(find "$repo/.agent/logs" -name '*-printf.log' -type f -print -quit)
assert_contains "$(cat "$log")" '--repo-root
bare-passthrough-value' \
    'a --repo-root token in a bare (no --) literal command reaches it literally, unrewritten'

finish
