#!/usr/bin/env bash
# Suite: agent-run.sh --cmd resolves commands by NAME, never by ecosystem.
set -uo pipefail

TEST_NAME='agent-run-cmd'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
rc_sh="$root/agentkit/skills/.shared/scripts/repo-config.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent"
    printf '%s' "$dir"
}

# --- declared command wins -------------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo declared-test-ran\n' > "$repo/.agent/config.env"
out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
assert_contains "$out" 'declared-test-ran' 'runs the declared AGENT_CMD_TEST'

# --- argv, not a shell string ---------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo one;touch %s/PWNED\n' "$tmp" > "$repo/.agent/config.env"
(cd "$repo" && "$run_sh" --cmd test) > /dev/null 2>&1 || true
assert_eq 'no' "$([[ -e $tmp/PWNED ]] && echo yes || echo no)" \
    'a semicolon is rejected, never interpreted by a shell'

# shellcheck disable=SC2016  # THE ENTIRE POINT: these are metacharacter payloads
# that safe_argv must reject as data. Expanding them here would test nothing.
for bad in 'echo a|tee b' 'echo `id`' 'echo $(id)' 'echo a>b' 'echo a&b'; do
    repo=$(make_repo)
    printf 'AGENT_CMD_TEST=%s\n' "$bad" > "$repo/.agent/config.env"
    listed=$("$rc_sh" --repo-root "$repo" --list 2> /dev/null)
    assert_not_contains "$listed" 'AGENT_CMD_TEST=' "rejects metacharacters in: $bad"
done

# --- runner fallback -------------------------------------------------------
repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$1" belongs to the generated stub, not to us.
printf '#!/bin/sh\nprintf "runner-got:%%s\\n" "$1"\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf 'AGENT_REPO_RUNNER=tools/verify\n' > "$repo/.agent/config.env"
out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
# shellcheck disable=SC2016  # backticks inside an assertion MESSAGE, quoting the
# `runner <name>` convention for a human reader.
assert_contains "$out" 'runner-got:test' 'falls back to the runner as `runner <name>`'

# --- .agent/runner file is equally honored --------------------------------
repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$1" belongs to the generated stub, not to us.
printf '#!/bin/sh\nprintf "runner-got:%%s\\n" "$1"\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf '%s/tools/verify\n' "$repo" > "$repo/.agent/runner"
out=$(cd "$repo" && "$run_sh" --cmd lint 2>&1)
assert_contains "$out" 'runner-got:lint' 'the .agent/runner convention still works'

# --- declared command beats the runner ------------------------------------
repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$1" is written into a stub script, to be
# expanded when that stub runs -- not by the shell writing it.
printf '#!/bin/sh\nprintf "runner-got:%%s\\n" "$1"\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf 'AGENT_REPO_RUNNER=tools/verify\nAGENT_CMD_TEST=echo declared-wins\n' \
    > "$repo/.agent/config.env"
out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
assert_contains "$out" 'declared-wins' 'a declared command outranks the runner'

# --- nothing declared -> usage error naming the key -----------------------
repo=$(make_repo)
: > "$repo/.agent/config.env"
err=$(cd "$repo" && "$run_sh" --cmd test 2>&1 || true)
rc=0
(cd "$repo" && "$run_sh" --cmd test > /dev/null 2>&1) || rc=$?
assert_eq '1' "$rc" 'nothing declared is a usage error (this script exits 1)'
assert_contains "$err" 'AGENT_CMD_TEST' 'and the error names the exact key to add'

# --- name validation -------------------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo ok\n' > "$repo/.agent/config.env"
for badname in 'TEST' 'te st' '../x' 'te;st' ''; do
    rc=0
    (cd "$repo" && "$run_sh" --cmd "$badname" > /dev/null 2>&1) || rc=$?
    assert_eq '1' "$rc" "rejects the command name: '$badname'"
done

# --- --cmd and a literal command are mutually exclusive -------------------
rc=0
(cd "$repo" && "$run_sh" --cmd test -- echo hi > /dev/null 2>&1) || rc=$?
assert_eq '1' "$rc" '--cmd with a literal command is a usage error'

# --- the command stamp -----------------------------------------------------
# The Stop hook blocks on changes the stamp for the command it asks for does not
# cover, so what may write one is the whole contract: a SUCCESSFUL run of a
# command the repository NAMED, stamped under THAT name.
stamped() { [[ -e $1/.agent/cache/stamp-$2 ]] && printf 'yes' || printf 'no'; }

repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo ok\n' > "$repo/.agent/config.env"
(cd "$repo" && "$run_sh" --cmd test) > /dev/null 2>&1
assert_eq 'yes' "$(stamped "$repo" test)" 'a successful --cmd run stamps that command'

repo=$(make_repo)
: > "$repo/.agent/config.env"
(cd "$repo" && "$run_sh" -- echo ok) > /dev/null 2>&1
assert_eq 'no' "$(stamped "$repo" echo)" 'a literal command never stamps'

repo=$(make_repo)
printf 'AGENT_CMD_TEST=false\n' > "$repo/.agent/config.env"
(cd "$repo" && "$run_sh" --cmd test) > /dev/null 2>&1 || true
assert_eq 'no' "$(stamped "$repo" test)" 'a failing --cmd run never stamps'

# A stamp names what it attests to. One shared flag would let a trivial command
# declared under any name clear a gate that asked for the failing one -- and
# `AGENT_CMD_LINT=true` in a pull request would be a one-line disarm.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=false\nAGENT_CMD_LINT=true\n' > "$repo/.agent/config.env"
(cd "$repo" && "$run_sh" --cmd verify) > /dev/null 2>&1 || true
(cd "$repo" && "$run_sh" --cmd lint) > /dev/null 2>&1
assert_eq 'yes' "$(stamped "$repo" lint)" 'a passing lint stamps lint'
assert_eq 'no' "$(stamped "$repo" verify)" 'and never stamps the verify it did not run'

# --- an out-of-repo executable is not reachable through AGENT_CMD_* --------
# AGENT_REPO_RUNNER is contained; the same capability through a command key was
# not, so `tools/../../outside/payload` exec'd whatever it pointed at.
repo=$(make_repo)
mkdir -p "$tmp/outside" "$repo/tools"
printf '#!/bin/sh\ntouch %s/outside/EXECUTED\n' "$tmp" > "$tmp/outside/payload"
chmod +x "$tmp/outside/payload"
ln -sfn "$tmp/outside/payload" "$repo/tools/link-outside"
for escape in 'tools/../../outside/payload' '../outside/payload' 'tools/link-outside'; do
    printf 'AGENT_CMD_TEST=%s\n' "$escape" > "$repo/.agent/config.env"
    listed=$("$rc_sh" --repo-root "$repo" --list 2> /dev/null)
    assert_not_contains "$listed" 'AGENT_CMD_TEST=' "rejects an out-of-repo command: $escape"
    (cd "$repo" && "$run_sh" --cmd test) > /dev/null 2>&1 || true
done
assert_eq 'no' "$([[ -e $tmp/outside/EXECUTED ]] && echo yes || echo no)" \
    'and the out-of-repo executable never ran'

finish
