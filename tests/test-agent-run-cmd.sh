#!/usr/bin/env bash
# Suite: agent-run.sh --cmd resolves commands by NAME, never by ecosystem.
set -uo pipefail

TEST_NAME='agent-run-cmd'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

real_run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
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

# Ordinary resolution preserves repo-config's established warn/drop/fall-through
# contract: unrelated malformed, unknown, and invalid declarations do not stop a
# valid command from resolving and executing.
repo=$(make_repo)
cat >"$repo/.agent/config.env" <<'CFG'
AGENT_CMD_TEST=echo survives-unrelated-config-errors
AGENT_UNKNOWN=ignored
malformed declaration
AGENT_BASE_BRANCH=bad branch
CFG
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
assert_contains "$out" 'survives-unrelated-config-errors' \
    'a valid command executes despite unrelated malformed declarations'

# A misbased command that is not the requested command may warn during the
# resolver's whole-file audit, but it must not make the valid requested command
# fatal. The refusal must remain scoped to the key being run.
repo=$(make_repo)
mkdir -p "$repo/dashboard" "$repo/tools"
printf '#!/bin/sh\nprintf valid-requested\n' > "$repo/tools/requested"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/root-only"
chmod +x "$repo/tools/requested" "$repo/tools/root-only"
printf 'AGENT_CMD_TEST=tools/requested\nAGENT_CMD_BAD=tools/root-only\nAGENT_RUNDIR_BAD=dashboard\n' \
    > "$repo/.agent/config.env"
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
requested_log=$(find "$repo/.agent/logs" -name '*-test.log' -type f -print -quit)
assert_contains "$(cat "$requested_log")" 'valid-requested' \
    'a valid requested command runs despite an unrelated misbased declaration'
assert_not_contains "$out" 'cannot run AGENT_CMD_TEST' \
    'an unrelated misbased declaration does not refuse the requested key'

# --- declared command wins -------------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo declared-test-ran\n' > "$repo/.agent/config.env"
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
assert_contains "$out" 'declared-test-ran' 'runs the declared AGENT_CMD_TEST'

# Quoted argv survives the resolver and reaches the executable as the same
# tokens, including a repository path and an argument containing spaces.
repo=$(make_repo)
mkdir -p "$repo/My Project/tools"
printf '#!/bin/sh\nprintf "<%%s>\\n" "$@" > "%s/space-argv"\n' "$tmp" \
    > "$repo/My Project/tools/check"
chmod +x "$repo/My Project/tools/check"
printf 'AGENT_CMD_TEST="My Project/tools/check" --input "My Project/input file"\n' \
    > "$repo/.agent/config.env"
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
assert_contains "$out" 'PASS:' 'runs a command whose executable path contains a space'
assert_contains "$(cat "$tmp/space-argv")" '<--input>' \
    'preserves an ordinary argument after the spaced executable'
assert_contains "$(cat "$tmp/space-argv")" '<My Project/input file>' \
    'preserves a spaced argument as one argv token'

# A literal slash command prefers the execution directory and falls back to
# the repository toplevel only when that candidate is absent. Plain names still
# use PATH lookup.
repo=$(make_repo)
mkdir -p "$repo/tools" "$repo/nested/tools"
printf '#!/bin/sh\nprintf toplevel-slash\n' > "$repo/tools/toplevel-command"
chmod +x "$repo/tools/toplevel-command"
out=$(cd "$repo" && "$real_run_sh" --dir nested -- "$repo/tools/toplevel-command" 2>&1)
assert_contains "$(cat "$repo"/.agent/logs/*-toplevel-command.log)" 'toplevel-slash' \
    'an absolute literal executable remains runnable from a nested directory'
printf '#!/bin/sh\nprintf nested-slash\n' > "$repo/nested/tools/toplevel-command"
chmod +x "$repo/nested/tools/toplevel-command"
out=$(cd "$repo" && "$real_run_sh" --dir nested -- ./tools/toplevel-command 2>&1)
assert_contains "$(grep -R -h 'nested-slash' "$repo"/.agent/logs)" 'nested-slash' \
    'a relative slash executable resolves from the execution directory first'
printf '#!/bin/sh\nprintf root-fallback\n' > "$repo/tools/root-only-command"
chmod +x "$repo/tools/root-only-command"
out=$(cd "$repo" && "$real_run_sh" --dir nested -- ./tools/root-only-command 2>&1)
assert_contains "$(grep -R -h 'root-fallback' "$repo"/.agent/logs)" 'root-fallback' \
    'a relative slash executable falls back to the repository toplevel'
printf '#!/bin/sh\nprintf path-lookup\n' > "$tmp/path-command"
chmod +x "$tmp/path-command"
out=$(cd "$repo" && PATH="$tmp:$PATH" "$real_run_sh" --dir nested -- path-command 2>&1)
assert_contains "$(cat "$repo"/.agent/logs/*-path-command.log)" 'path-lookup' \
    'a plain executable name keeps PATH lookup from the execution directory'
out=$(cd "$repo" && "$real_run_sh" --dir nested -- ./missing-command 2>&1 || true)
assert_contains "$out" 'cwd=' \
    'a missing slash executable reports the execution cwd'
assert_contains "$out" 'toplevel' \
    'a missing slash executable reports its toplevel resolution status'

# --- argv, not a shell string ---------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo one;touch %s/PWNED\n' "$tmp" > "$repo/.agent/config.env"
(cd "$repo" && "$real_run_sh" --cmd test) > /dev/null 2>&1 || true
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
printf 'AGENT_CMD_TEST=echo declared-query-ran\n' > "$repo/.agent/config.env"
query_out=''
query_rc=0
query_out=$(cd "$repo" && "$real_run_sh" --resolve test 2>&1) || query_rc=$?
assert_eq '0' "$query_rc" 'the query returns the declared-command status'
assert_eq 'declared' "$query_out" 'the query reports a declared command'
assert_eq 'no' "$([[ -e $repo/.agent/logs ]] && echo yes || echo no)" \
    'the resolution query does not create execution logs'
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
assert_contains "$out" 'declared-query-ran' \
    'a command reported as declared executes through the normal path'

repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$1" belongs to the generated stub, not to us.
printf '#!/bin/sh\nprintf "runner-got:%%s\\n" "$1"\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf 'AGENT_REPO_RUNNER=tools/verify\n' > "$repo/.agent/config.env"
query_out=''
query_rc=0
query_out=$(cd "$repo" && "$real_run_sh" --resolve test 2>&1) || query_rc=$?
assert_eq '4' "$query_rc" 'the query returns the repository-runner status'
assert_eq 'runner' "$query_out" 'the query reports a repository runner'
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
# shellcheck disable=SC2016  # backticks inside an assertion MESSAGE, quoting the
# `runner <name>` convention for a human reader.
assert_contains "$out" 'runner-got:test' 'falls back to the runner as `runner <name>`'

# Exit 2 belongs to the fatal interpreter guard, not to a successful runner
# resolution. Invoke the helper explicitly with zsh so the guard is exercised
# before any repository resolution can emit its normal stdout status.
if command -v zsh >/dev/null 2>&1; then
    guard_out=''
    guard_rc=0
    guard_out=$(cd "$repo" && zsh "$real_run_sh" --resolve test 2>&1) || guard_rc=$?
    assert_eq '2' "$guard_rc" 'the unsupported interpreter guard keeps exit 2'
    assert_contains "$guard_out" 'requires Bash >= 4' \
        'the exit-2 guard explains the unsupported interpreter'
else
    printf '  skip unsupported-interpreter guard (zsh is not installed)\n'
fi

repo=$(make_repo)
: > "$repo/.agent/config.env"
query_out=''
query_rc=0
query_out=$(cd "$repo" && "$real_run_sh" --resolve test 2>&1) || query_rc=$?
assert_eq '3' "$query_rc" 'the query returns the unresolved status'
assert_eq 'unresolved' "$query_out" 'the query reports an unresolved command'
run_out=''
run_rc=0
run_out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1) || run_rc=$?
assert_eq '1' "$run_rc" 'execution refuses a command reported unresolved'
assert_contains "$run_out" 'no command named' \
    'the unresolved execution still explains the missing declaration'

# --- .agent/runner file is equally honored --------------------------------
repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$1" belongs to the generated stub, not to us.
printf '#!/bin/sh\nprintf "runner-got:%%s\\n" "$1"\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf '%s/tools/verify\n' "$repo" > "$repo/.agent/runner"
query_out=''
query_rc=0
query_out=$(cd "$repo" && "$real_run_sh" --resolve lint 2>&1) || query_rc=$?
assert_eq '4' "$query_rc" 'the query recognizes the .agent/runner convention'
assert_eq 'runner' "$query_out" 'the query reports the .agent/runner as a repository runner'
out=$(cd "$repo" && "$real_run_sh" --cmd lint 2>&1)
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
out=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1)
assert_contains "$out" 'declared-wins' 'a declared command outranks the runner'

# --- nothing declared -> usage error naming the key -----------------------
repo=$(make_repo)
: > "$repo/.agent/config.env"
# shellcheck disable=SC2015  # the || true is the point: capture output, never fail
err=$(cd "$repo" && "$real_run_sh" --cmd test 2>&1 || true)
rc=0
(cd "$repo" && "$real_run_sh" --cmd test > /dev/null 2>&1) || rc=$?
assert_eq '1' "$rc" 'nothing declared is a usage error (this script exits 1)'
assert_contains "$err" 'AGENT_CMD_TEST' 'and the error names the exact key to add'

# --- name validation -------------------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo ok\n' > "$repo/.agent/config.env"
for badname in 'te st' '../x' 'te;st' ''; do
    rc=0
    (cd "$repo" && "$real_run_sh" --cmd "$badname" > /dev/null 2>&1) || rc=$?
    assert_eq '1' "$rc" "rejects the command name: '$badname'"
done

# --- --cmd and a literal command are mutually exclusive -------------------
rc=0
(cd "$repo" && "$real_run_sh" --cmd test -- echo hi > /dev/null 2>&1) || rc=$?
assert_eq '1' "$rc" '--cmd with a literal command is a usage error'

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
    (cd "$repo" && "$real_run_sh" --cmd test) > /dev/null 2>&1 || true
done
assert_eq 'no' "$([[ -e $tmp/outside/EXECUTED ]] && echo yes || echo no)" \
    'and the out-of-repo executable never ran'

# --- a named command may declare the directory it runs in ------------------
# Values are argv run from the repository root, which suits one component and
# breaks a monorepo. Asked to declare a dashboard test command, an agent
# produced the only root-runnable form -- and it globbed into node_modules and
# began running a DEPENDENCY's test suite. The command was right; the working
# directory was not expressible.
repo=$(make_repo)
mkdir -p "$repo/dashboard"
printf 'AGENT_CMD_DASH=pwd\nAGENT_RUNDIR_DASH=dashboard\nAGENT_CMD_ROOT=pwd\n' \
    > "$repo/.agent/config.env"

(cd "$repo" && "$real_run_sh" --cmd dash > /dev/null 2>&1)
# The log is bracketed by "=== agent-run" markers; the command's own output is
# what is being asserted here.
assert_eq "$repo/dashboard" "$(grep -v '^=== ' "$repo"/.agent/logs/*-dash.log)" \
    'a declared rundir is where the command runs'

(cd "$repo" && "$real_run_sh" --cmd root > /dev/null 2>&1)
assert_contains "$(cat "$repo"/.agent/logs/*-root.log)" "$repo" \
    'and without one it still runs at the repository root'

# A rundir naming nothing is a declaration error, reported before the command
# runs somewhere unintended rather than after.
printf 'AGENT_CMD_GONE=pwd\nAGENT_RUNDIR_GONE=nope\n' > "$repo/.agent/config.env"
out=$( (cd "$repo" && "$real_run_sh" --cmd gone 2>&1) || true)
assert_contains "$out" 'missing directory' 'a rundir that does not exist is refused'

# It cannot point outside the repository: the file is committed, and anyone who
# can open a pull request can edit it.
printf 'AGENT_CMD_ESC=pwd\nAGENT_RUNDIR_ESC=../../etc\n' > "$repo/.agent/config.env"
out=$( (cd "$repo" && "$real_run_sh" --cmd esc 2>&1) || true)
assert_not_contains "$out" '/etc' 'a rundir cannot escape the repository'

# If an ad-hoc path-shaped argv[0] only exists at the repository root, but the
# command runs from a different base and exits 127, the failure must name both
# bases and say to repair the declaration rather than route around approval.
repo=$(make_repo)
mkdir -p "$repo/dashboard" "$repo/tools"
printf '#!/bin/sh\nexit 127\n' > "$repo/tools/root-only"
chmod +x "$repo/tools/root-only"
rc=0
out=$(cd "$repo" && "$real_run_sh" --dir "$repo/dashboard" -- ./tools/root-only 2>&1) || rc=$?
assert_eq '127' "$rc" 'a missing interpreter produces the rc=127 mismatch case'
assert_contains "$out" 'rc=127' 'reports the command failure status'
assert_contains "$out" 'execution cwd' 'rc=127 mismatch names the execution base'
assert_contains "$out" 'repository root' 'rc=127 mismatch names the repository-root base'
assert_contains "$out" 'fix the declaration' \
    'rc=127 mismatch says to fix the declaration'
assert_contains "$out" 'literal twin' \
    'rc=127 mismatch rejects a literal twin workaround'

# --- an OPTIONAL command must not be a hard failure ------------------------
# A review workflow hardcoded --cmd lint and errored on a repository whose gate
# is declared as verify. The contract never promised that name, so the skill was
# wrong to assume it -- but the failure landed on the repository.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"

out=$( (cd "$repo" && "$real_run_sh" --cmd lint --if-declared 2>&1) ); rc=$?
assert_eq '0' "$rc" 'an undeclared optional command exits 0'
assert_contains "$out" 'skipping' 'and says it skipped rather than passing silently'

out=$( (cd "$repo" && "$real_run_sh" --cmd lint 2>&1) || true)
assert_contains "$out" 'no command named' 'while a REQUIRED one still fails loudly'

out=$( (cd "$repo" && "$real_run_sh" --cmd verify --if-declared 2>&1) ); rc=$?
assert_eq '0' "$rc" 'and a declared command still runs under the flag'
assert_contains "$out" 'PASS' 'producing its real verdict'

# --- the underscore/dash boundary -------------------------------------------
# AGENT_CMD_CHECK_NODE_PIN is the declaration; --cmd check-node-pin is the
# invocation. Reading the contract and typing its key back is the obvious move.
#
# Naming the right spelling in an error was not enough: the next session made
# the same three mistakes and recovered from each, which is three wasted calls
# per session on every repository with multi-word command names. Both spellings
# fold to the same key with no ambiguity, so both are accepted.
repo=$(make_repo)
printf 'AGENT_CMD_CHECK_NODE_PIN=echo pinned\n' > "$repo/.agent/config.env"

out=$(cd "$repo" && "$real_run_sh" --cmd check-node-pin 2>&1)
assert_contains "$out" 'pinned' 'the canonical dashed name resolves'

out=$(cd "$repo" && "$real_run_sh" --cmd check_node_pin 2>&1)
assert_contains "$out" 'pinned' 'and the underscored declaration key resolves to the same command'

out=$(cd "$repo" && "$real_run_sh" --cmd CHECK_NODE_PIN 2>&1)
assert_contains "$out" 'pinned' 'as does the key exactly as config.env spells it'

# Canonicalisation must reach the log label too, or the same command produces
# two differently-named logs depending on how it was spelled.
out=$(cd "$repo" && "$real_run_sh" --cmd check_node_pin 2>&1)
assert_contains "$out" '-check-node-pin.' 'the log label is canonicalised, not echoed back'
assert_not_contains "$out" 'check_node_pin' 'so one command cannot produce two log names'

# Relaxing the spelling must not relax what a NAME is: anything a shell would
# interpret is still refused, and that is what the restriction was ever for.
out=$(cd "$repo" && "$real_run_sh" --cmd 'pnpm lint' 2>&1)
assert_contains "$out" 'must be letters, digits, dashes or underscores' 'a name with a space is still refused'
out=$(cd "$repo" && "$real_run_sh" --cmd 'te;st' 2>&1)
assert_contains "$out" 'must be letters, digits, dashes or underscores' 'and so is one carrying a shell metacharacter'
out=$(cd "$repo" && "$real_run_sh" --cmd '../x' 2>&1)
assert_contains "$out" 'must be letters, digits, dashes or underscores' 'and so is a path traversal'

# --- the log says whether it finished ---------------------------------------
# The log used to hold the command's output and nothing else, so a log that
# stopped mid-stream was indistinguishable from one still being written, and
# from one whose process had died. A session that launched several commands at
# once read two logs ending after their package manager's preamble, could not
# tell a hang from a failure, and went to `ps` to find out.
repo=$(make_repo)
printf 'AGENT_CMD_OK=echo hello\nAGENT_CMD_BAD=false\n' > "$repo/.agent/config.env"

out=$(cd "$repo" && "$real_run_sh" --cmd ok 2>&1)
log=$(cat "$repo"/.agent/logs/*-ok.log)
assert_contains "$log" '=== agent-run echo hello' 'the log names the command it is running'
assert_contains "$log" '=== started' 'and when it started'
assert_contains "$log" 'concurrent-suites=1' 'the log records the active full-suite count'
assert_contains "$log" '=== agent-run exited rc=0' 'and terminates with the verdict'
assert_contains "$out" 'has NOT finished' 'and the caller is told what an unterminated log means'

# The suppressed-line count must report the command output, not the markers.
assert_contains "$out" '(1 lines suppressed' 'the line count excludes the log bookkeeping'

(cd "$repo" && "$real_run_sh" --cmd bad > /dev/null 2>&1) || true
log=$(cat "$repo"/.agent/logs/*-bad.log)
assert_contains "$log" '=== agent-run exited rc=1' 'a failing command records its exit code too'

# --- load-flake retry acceptance -------------------------------------------
# An explicit scale is the deterministic seam for the live concurrent-suite
# marker count. The fixture makes the first probe invocation fail and the
# second succeed, then keeps both invocations failing to pin the red outcome.
retry_repo=$(make_repo)
mkdir -p "$retry_repo/tools"
cat >"$retry_repo/tools/probe-result" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
count=0
[[ -f ${COUNT_FILE:?} ]] && count=$(<"$COUNT_FILE")
count=$((count + 1))
printf '%s' "$count" >"$COUNT_FILE"
if [[ ${MODE:-} == always || $count == 1 ]]; then
    printf 'FAIL: probe did not finish within 10s\n' >&2
    exit 1
fi
printf 'probe recovered\n'
EOF
chmod +x -- "$retry_repo/tools/probe-result"
printf 'AGENT_CMD_TEST=tools/probe-result\n' >"$retry_repo/.agent/config.env"
retry_count=$tmp/retry-count
retry_out=''
retry_rc=0
retry_out=$(cd "$retry_repo" && MODE=flaky COUNT_FILE="$retry_count" AGENT_TEST_TIMEOUT_SCALE=2 \
    "$real_run_sh" --force --cmd test 2>&1) || retry_rc=$?
assert_eq '0' "$retry_rc" 'a timeout under concurrent load retries and turns green'
assert_contains "$retry_out" 'load-flake' 'a recovered timeout is classified as load-flake'
assert_contains "$retry_out" 'retried 1/1' 'the recovered timeout uses exactly one retry'

: >"$retry_count"
genuine_out=''
genuine_rc=0
genuine_out=$(cd "$retry_repo" && MODE=always COUNT_FILE="$retry_count" AGENT_TEST_TIMEOUT_SCALE=2 \
    "$real_run_sh" --force --cmd test 2>&1) || genuine_rc=$?
assert_eq '1' "$genuine_rc" 'a genuine probe timeout remains red after one retry'
assert_contains "$genuine_out" 'load-flake' 'the persistent timeout retains load-flake classification'
assert_contains "$genuine_out" 'one retry was exhausted' 'the persistent timeout reports exhaustion'
assert_eq '2' "$(<"$retry_count")" 'the persistent timeout is attempted exactly twice'

finish
