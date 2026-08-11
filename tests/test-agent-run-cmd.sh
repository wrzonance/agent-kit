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
# Approval reads a confirmation from the controlling terminal (defense-in-depth,
# not a human-only gate); the helper supplies that terminal so these
# resolution/logging cases can approve. See test-agent-run-approval-gate.sh for
# the boundary itself.
tty_approve="$here/lib/tty-approve"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export AGENT_TRUST_ROOT="$tmp/trust"

# Existing behavioral cases exercise commands after an explicit approval so the
# suite can stay focused on resolution, logging, and stamps. The trust-specific
# cases below call real_run_sh directly and prove that an unapproved or changed
# declaration never executes.
run_sh="$tmp/approved-agent-run.sh"
# shellcheck disable=SC2016  # the dollar expressions are literal script text.
printf '#!/bin/sh\n"%s" y -- "%s" --approve "$@" >/dev/null 2>&1\nexec "%s" "$@"\n' \
    "$tty_approve" "$real_run_sh" \
    "$real_run_sh" > "$run_sh"
chmod +x "$run_sh"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent"
    printf '%s' "$dir"
}

# --- repository command trust boundary ------------------------------------
repo=$(make_repo)
mkdir -p "$repo/tools"
printf '#!/bin/sh\ntouch "%s/payload-ran"\n' "$tmp" > "$repo/tools/payload"
chmod +x "$repo/tools/payload"
printf 'AGENT_CMD_TEST=tools/payload\n' > "$repo/.agent/config.env"
trust_root="$tmp/trust"
if ! out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" "$real_run_sh" --cmd test 2>&1); then
    : # The test asserts the expected refusal below.
fi
assert_contains "$out" 'refusing unapproved repository command' \
    'a repository command is denied before its first approval'
assert_not_contains "$out" 'payload-ran' \
    'the denied command never executes'
(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$real_run_sh" --approve --cmd test) > /dev/null 2>&1
assert_eq 'no' "$([[ -e $tmp/payload-ran ]] && echo yes || echo no)" \
    'approval does not execute the repository command'
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" "$real_run_sh" --cmd test 2>&1)
assert_contains "$out" 'PASS:' 'an explicitly approved command runs'
assert_eq 'yes' "$([[ -e $tmp/payload-ran ]] && echo yes || echo no)" \
    'the approved command executes only during the normal run'
printf '#!/bin/sh\ntouch "%s/changed-payload-ran"\n' "$tmp" > "$repo/tools/payload"
if ! out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" "$real_run_sh" --cmd test 2>&1); then
    : # The test asserts the expected refusal below.
fi
assert_contains "$out" 'refusing unapproved repository command' \
    'changing the repository executable requires fresh approval'
assert_eq 'no' "$([[ -e $tmp/changed-payload-ran ]] && echo yes || echo no)" \
    'a changed executable is not run under an old approval'

# --yolo must cover build definitions, not only literal argv paths. A command
# such as `make test` executes the repository's Makefile even though neither
# argv token names it.
repo=$(make_repo)
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
printf 'AGENT_CMD_TEST=make test\n' > "$repo/.agent/config.env"
printf 'test:\n\t@touch "%s/make-base-ran"\n' "$tmp" > "$repo/Makefile"
git -C "$repo" add -- .agent/config.env Makefile
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
printf 'test:\n\t@touch "%s/make-changed-ran"\n' "$tmp" > "$repo/Makefile"
# shellcheck disable=SC2015  # the || true captures expected refusal output
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1 || true)
assert_contains "$out" 'refusing --yolo' \
    'a changed build manifest blocks unattended command execution'
assert_eq 'no' "$([[ -e $tmp/make-changed-ran ]] && echo yes || echo no)" \
    'a changed build manifest is not executed under --yolo'

# Module-mode interpreters carry their repository payload in a token without a
# slash, so the gate must derive the module's .py and package paths explicitly.
repo=$(make_repo)
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
mkdir -p "$repo/tools"
touch "$repo/tools/__init__.py"
printf 'AGENT_CMD_TEST=python -m tools\n' > "$repo/.agent/config.env"
printf 'print("base")\n' > "$repo/tools/__main__.py"
git -C "$repo" add -- .agent/config.env tools
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
printf 'print("changed")\n' > "$repo/tools/__main__.py"
# shellcheck disable=SC2015  # the || true captures expected refusal output
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1 || true)
assert_contains "$out" 'refusing --yolo' \
    'a changed module payload blocks unattended command execution'

printf 'print("added")\n' > "$repo/tools/payload.py"
git -C "$repo" checkout -- tools/__main__.py
# shellcheck disable=SC2015  # the || true captures expected refusal output
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1 || true)
assert_contains "$out" 'refusing --yolo' \
    'an untracked module payload blocks unattended command execution'

# Repository-relative inputs beginning with `__` are ordinary paths, not
# sentinels. Track a directory passed through --require and refuse it only
# after its payload changes.
repo=$(make_repo)
mkdir -p "$repo/__tests__/unit" "$repo/tools"
printf 'base\n' > "$repo/__tests__/unit/payload"
printf '#!/bin/sh\ntouch "%s/valid-input-ran"\n' "$tmp" > "$repo/tools/runner"
chmod +x "$repo/tools/runner"
printf 'AGENT_CMD_TEST=tools/runner --require=__tests__/unit\n' > "$repo/.agent/config.env"
git -C "$repo" add -- .agent/config.env __tests__ tools
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD

rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1) || rc=$?
assert_eq '0' "$rc" 'an unchanged repo-relative __ path passes --yolo'
assert_eq 'yes' "$([[ -e $tmp/valid-input-ran ]] && echo yes || echo no)" \
    'the valid __ path reaches its command'

printf 'changed\n' > "$repo/__tests__/unit/payload"
rc=0
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1) || rc=$?
assert_eq '1' "$rc" 'a changed repo-relative __ path is refused under --yolo'
assert_contains "$out" 'refusing --yolo' 'the changed __ path is named as a trust failure'

# Deleting a declaration must be a change too. Keep a runner fallback so
# resolution reaches the yolo gate after the config disappears.
repo=$(make_repo)
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
mkdir -p "$repo/tools"
printf '#!/bin/sh\ntouch "%s/deleted-config-ran"\n' "$tmp" > "$repo/tools/runner"
chmod +x "$repo/tools/runner"
printf 'AGENT_CMD_TEST=true\n' > "$repo/.agent/config.env"
printf '%s/tools/runner\n' "$repo" > "$repo/.agent/runner"
git -C "$repo" add -- .agent/config.env .agent/runner tools/runner
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
rm -- "$repo/.agent/config.env"
# shellcheck disable=SC2015  # the || true captures expected refusal output
out=$(cd "$repo" && "$real_run_sh" --cmd test --yolo 2>&1 || true)
assert_contains "$out" 'refusing --yolo' \
    'a deleted declaration blocks unattended command execution'
assert_eq 'no' "$([[ -e $tmp/deleted-config-ran ]] && echo yes || echo no)" \
    'a deleted declaration does not fall through to execution'

# Approval persistence must fail loudly rather than claiming success when the
# temporary record cannot be written or atomically replaced. Both cases approve
# through the terminal helper; the write case additionally has the helper create
# a directory where the trust temp file (`<trust_file>.<pid>`) would be written,
# keyed to the approving process's own PID so the collision is deterministic.
repo=$(make_repo)
printf 'AGENT_CMD_TEST=true\n' > "$repo/.agent/config.env"
trust_id=$(printf '%s' "$repo\ntest" | sha256sum | awk '{print $1}')
rc=0
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" --mkdir-before "$trust_root/$trust_id.trust" y -- \
    "$real_run_sh" --approve --cmd test 2>&1) || rc=$?
assert_eq '1' "$rc" 'a failed temporary trust-file write exits nonzero'
assert_contains "$out" 'cannot write temporary trust file' \
    'a failed temporary trust-file write explains the persistence failure'
assert_not_contains "$out" 'approved test' \
    'a failed temporary trust-file write never reports approval'

mv_fail_bin="$tmp/mv-fail-bin"
mkdir -p "$mv_fail_bin"
printf '%s\n' '#!/bin/sh' 'exit 42' > "$mv_fail_bin/mv"
chmod +x "$mv_fail_bin/mv"
rc=0
out=$(cd "$repo" && PATH="$mv_fail_bin:$PATH" AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$real_run_sh" --approve --cmd test 2>&1) || rc=$?
assert_eq '1' "$rc" 'a failed atomic trust-file replacement exits nonzero'
assert_contains "$out" 'cannot atomically replace trust file' \
    'a failed atomic trust-file replacement explains the persistence failure'
assert_not_contains "$out" 'approved test' \
    'a failed atomic trust-file replacement never reports approval'

(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$real_run_sh" --approve --cmd test) > /dev/null 2>&1
trust_file="$trust_root/$trust_id.trust"
assert_eq '600' "$(stat -c '%a' "$trust_file")" \
    'successful trust persistence keeps the approval record owner-only'

# --- declared command wins -------------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo declared-test-ran\n' > "$repo/.agent/config.env"
out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
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
out=$(cd "$repo" && "$run_sh" --cmd test 2>&1)
assert_contains "$out" 'PASS:' 'runs a command whose executable path contains a space'
assert_contains "$(cat "$tmp/space-argv")" '<--input>' \
    'preserves an ordinary argument after the spaced executable'
assert_contains "$(cat "$tmp/space-argv")" '<My Project/input file>' \
    'preserves a spaced argument as one argv token'

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
# shellcheck disable=SC2015  # the || true is the point: capture output, never fail
err=$(cd "$repo" && "$run_sh" --cmd test 2>&1 || true)
rc=0
(cd "$repo" && "$run_sh" --cmd test > /dev/null 2>&1) || rc=$?
assert_eq '1' "$rc" 'nothing declared is a usage error (this script exits 1)'
assert_contains "$err" 'AGENT_CMD_TEST' 'and the error names the exact key to add'

# --- name validation -------------------------------------------------------
repo=$(make_repo)
printf 'AGENT_CMD_TEST=echo ok\n' > "$repo/.agent/config.env"
for badname in 'te st' '../x' 'te;st' ''; do
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

(cd "$repo" && "$run_sh" --cmd dash > /dev/null 2>&1)
# The log is bracketed by "=== agent-run" markers; the command's own output is
# what is being asserted here.
assert_eq "$repo/dashboard" "$(grep -v '^=== ' "$repo"/.agent/logs/*-dash.log)" \
    'a declared rundir is where the command runs'

(cd "$repo" && "$run_sh" --cmd root > /dev/null 2>&1)
assert_contains "$(cat "$repo"/.agent/logs/*-root.log)" "$repo" \
    'and without one it still runs at the repository root'

# A rundir naming nothing is a declaration error, reported before the command
# runs somewhere unintended rather than after.
printf 'AGENT_CMD_GONE=pwd\nAGENT_RUNDIR_GONE=nope\n' > "$repo/.agent/config.env"
out=$( (cd "$repo" && "$run_sh" --cmd gone 2>&1) || true)
assert_contains "$out" 'missing directory' 'a rundir that does not exist is refused'

# It cannot point outside the repository: the file is committed, and anyone who
# can open a pull request can edit it.
printf 'AGENT_CMD_ESC=pwd\nAGENT_RUNDIR_ESC=../../etc\n' > "$repo/.agent/config.env"
out=$( (cd "$repo" && "$run_sh" --cmd esc 2>&1) || true)
assert_not_contains "$out" '/etc' 'a rundir cannot escape the repository'

# --- option and module payloads invalidate approval when they change --------
repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$1" and ${1#*=} belong to the generated runner.
printf '#!/bin/sh\ncase "$1" in --require=*) . "${1#*=}" ;; esac\n' \
    > "$repo/tools/require-runner"
printf '#!/bin/sh\ntouch "%s/option-original-ran"\n' "$tmp" \
    > "$repo/tools/hook.sh"
chmod +x "$repo/tools/require-runner" "$repo/tools/hook.sh"
printf 'AGENT_CMD_OPTION=tools/require-runner --require=tools/hook.sh\n' \
    > "$repo/.agent/config.env"
(cd "$repo" && "$tty_approve" y -- "$real_run_sh" --approve --cmd option) \
    > /dev/null 2>&1
printf '#!/bin/sh\ntouch "%s/option-changed-ran"\n' "$tmp" \
    > "$repo/tools/hook.sh"
out=$( (cd "$repo" && "$real_run_sh" --cmd option 2>&1) || true)
assert_contains "$out" 'refusing unapproved repository command' \
    'a changed --require payload requires fresh approval'
assert_eq 'no' "$([[ -e $tmp/option-changed-ran ]] && echo yes || echo no)" \
    'a changed --require payload is not executed under old approval'

repo=$(make_repo)
mkdir -p "$repo/tools"
# shellcheck disable=SC2016  # "$2" and $module belong to the generated runner.
printf '#!/bin/sh\nmodule=$(printf "%%s" "$2" | tr . /)\n. "$module.py"\n' \
    > "$repo/tools/module-runner"
printf '#!/bin/sh\ntouch "%s/module-original-ran"\n' "$tmp" \
    > "$repo/tools/verify.py"
chmod +x "$repo/tools/module-runner" "$repo/tools/verify.py"
printf 'AGENT_CMD_MODULE=tools/module-runner -m tools.verify\n' \
    > "$repo/.agent/config.env"
(cd "$repo" && "$tty_approve" y -- "$real_run_sh" --approve --cmd module) \
    > /dev/null 2>&1
printf '#!/bin/sh\ntouch "%s/module-changed-ran"\n' "$tmp" \
    > "$repo/tools/verify.py"
out=$( (cd "$repo" && "$real_run_sh" --cmd module 2>&1) || true)
assert_contains "$out" 'refusing unapproved repository command' \
    'a changed module payload requires fresh approval'
assert_eq 'no' "$([[ -e $tmp/module-changed-ran ]] && echo yes || echo no)" \
    'a changed module payload is not executed under old approval'

# --- an OPTIONAL command must not be a hard failure ------------------------
# A review workflow hardcoded --cmd lint and errored on a repository whose gate
# is declared as verify. The contract never promised that name, so the skill was
# wrong to assume it -- but the failure landed on the repository.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"

out=$( (cd "$repo" && "$run_sh" --cmd lint --if-declared 2>&1) ); rc=$?
assert_eq '0' "$rc" 'an undeclared optional command exits 0'
assert_contains "$out" 'skipping' 'and says it skipped rather than passing silently'

out=$( (cd "$repo" && "$run_sh" --cmd lint 2>&1) || true)
assert_contains "$out" 'no command named' 'while a REQUIRED one still fails loudly'

out=$( (cd "$repo" && "$run_sh" --cmd verify --if-declared 2>&1) ); rc=$?
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

out=$(cd "$repo" && "$run_sh" --cmd check-node-pin 2>&1)
assert_contains "$out" 'pinned' 'the canonical dashed name resolves'

out=$(cd "$repo" && "$run_sh" --cmd check_node_pin 2>&1)
assert_contains "$out" 'pinned' 'and the underscored declaration key resolves to the same command'

out=$(cd "$repo" && "$run_sh" --cmd CHECK_NODE_PIN 2>&1)
assert_contains "$out" 'pinned' 'as does the key exactly as config.env spells it'

# Canonicalisation must reach the log label too, or the same command produces
# two differently-named logs depending on how it was spelled.
out=$(cd "$repo" && "$run_sh" --cmd check_node_pin 2>&1)
assert_contains "$out" '-check-node-pin.' 'the log label is canonicalised, not echoed back'
assert_not_contains "$out" 'check_node_pin' 'so one command cannot produce two log names'

# Relaxing the spelling must not relax what a NAME is: anything a shell would
# interpret is still refused, and that is what the restriction was ever for.
out=$(cd "$repo" && "$run_sh" --cmd 'pnpm lint' 2>&1)
assert_contains "$out" 'must be letters, digits, dashes or underscores' 'a name with a space is still refused'
out=$(cd "$repo" && "$run_sh" --cmd 'te;st' 2>&1)
assert_contains "$out" 'must be letters, digits, dashes or underscores' 'and so is one carrying a shell metacharacter'
out=$(cd "$repo" && "$run_sh" --cmd '../x' 2>&1)
assert_contains "$out" 'must be letters, digits, dashes or underscores' 'and so is a path traversal'


# --- the log says whether it finished ---------------------------------------
# The log used to hold the command's output and nothing else, so a log that
# stopped mid-stream was indistinguishable from one still being written, and
# from one whose process had died. A session that launched several commands at
# once read two logs ending after their package manager's preamble, could not
# tell a hang from a failure, and went to `ps` to find out.
repo=$(make_repo)
printf 'AGENT_CMD_OK=echo hello\nAGENT_CMD_BAD=false\n' > "$repo/.agent/config.env"

out=$(cd "$repo" && "$run_sh" --cmd ok 2>&1)
log=$(cat "$repo"/.agent/logs/*-ok.log)
assert_contains "$log" '=== agent-run echo hello' 'the log names the command it is running'
assert_contains "$log" '=== started' 'and when it started'
assert_contains "$log" '=== agent-run exited rc=0' 'and terminates with the verdict'
assert_contains "$out" 'has NOT finished' 'and the caller is told what an unterminated log means'

# The suppressed-line count must report the command output, not the markers.
assert_contains "$out" '(1 lines suppressed' 'the line count excludes the log bookkeeping'

(cd "$repo" && "$run_sh" --cmd bad > /dev/null 2>&1) || true
log=$(cat "$repo"/.agent/logs/*-bad.log)
assert_contains "$log" '=== agent-run exited rc=1' 'a failing command records its exit code too'

finish
