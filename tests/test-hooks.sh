#!/usr/bin/env bash
# Suite: hook dispatchers. Every hook exits 0 and emits schema-valid JSON --
# exit 2 from a hook halts the agent instead of informing it.
set -uo pipefail

TEST_NAME='hooks'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The hooks resolve their helpers as <plugin-root>/skills/.shared/scripts/, the
# layout build-plugin.sh produces. plugin-src/skills is a symlink onto the skill
# tree so that resolution is the one under test, rather than a test-only shim.
#
# Whenever a hook reaches agent-preflight.sh, the stub shadows gh: a unit suite
# must not depend on a live forge account.
stub_path="$here/stub:$PATH"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent/cache"
    printf '%s' "$dir"
}

session_input() {
    jq -nc --arg cwd "$1" --arg src "${2:-startup}" \
        '{cwd:$cwd,hook_event_name:"SessionStart",model:"m",permission_mode:"default",
          session_id:"s1",source:$src,transcript_path:null}'
}

# --- SessionStart emits the contract --------------------------------------
repo=$(make_repo)
printf 'repo=example-org/example-repo\nbranch=main\nbase=main source=x\n' \
    > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | "$hooks/session-start.sh" 2>/dev/null)
rc=0; session_input "$repo" | "$hooks/session-start.sh" >/dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'SessionStart exits 0'
assert_hook_output "$out" session-start 'SessionStart emits schema-valid JSON'
assert_contains "$out" 'example-org/example-repo' 'and carries the contract'
assert_contains "$out" 'SessionStart' 'tagged with its event name'

# --- an un-onboarded repository is told how to onboard --------------------
# The failure mode this covers is SILENCE: with no .agent/config.env every
# evidence-gated guard correctly no-ops, which is indistinguishable from the
# tooling being broken. A live session ran ten turns past it.
repo=$(make_repo)
printf 'repo=example-org/example-repo\n' > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | "$hooks/session-start.sh" 2>/dev/null)
assert_hook_output "$out" session-start 'the onboarding notice is schema-valid'
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
assert_contains "$ctx" 'not onboarded' 'an un-onboarded repo is told so'
assert_contains "$ctx" 'bootstrap-repo.sh' 'and which script to run'
assert_contains "$ctx" '.agent/config.env' 'and which files must exist'
assert_contains "$ctx" '.agent/board.json' 'including the board cache'
assert_contains "$ctx" 'README' 'and where to read more'
assert_contains "$ctx" 'example-org/example-repo' 'without displacing the contract'
assert_contains "$ctx" 'plugins/cache' 'and it teaches the resolver, not a fixed path'

# Onboarded repositories must never see it again.
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$repo/.agent/config.env"
out=$(session_input "$repo" | "$hooks/session-start.sh" 2>/dev/null)
assert_not_contains "$out" 'not onboarded' 'an onboarded repo is not nagged'

# No contract AND no config is still worth speaking up for -- it is precisely
# the un-onboarded case, and emitting nothing is how it stays invisible. Built
# with a PATH that has git but no gh, so the probe genuinely fails rather than
# being stubbed into failing.
nogh="$tmp/nogh"
mkdir -p "$nogh"
# bash and env included deliberately: `#!/usr/bin/env bash` resolves the
# interpreter ON this PATH, so omitting them makes the hook exit 127 before it
# runs and the assertion passes for the wrong reason.
for b in bash env git jq cat find sort tail sed grep mktemp touch; do
    if p=$(command -v "$b" 2> /dev/null); then ln -sf "$p" "$nogh/$b"; fi
done
bare_repo=$(make_repo)
out=$(session_input "$bare_repo" | env PATH="$nogh" "$hooks/session-start.sh" 2>/dev/null)
assert_contains "$out" 'bootstrap-repo.sh' 'no contract still yields the notice'
assert_not_contains "$out" 'Environment contract' 'and claims no contract it does not have'

# A plain directory is not a repository; bootstrapping cannot succeed there.
# It gets the OTHER notice instead -- silently degrading is the thing to avoid,
# since the contract then describes a directory the work may never touch.
plain="$tmp/not-a-repo"
mkdir -p "$plain"
out=$(session_input "$plain" | PATH="$stub_path" "$hooks/session-start.sh" 2>/dev/null)
assert_not_contains "$out" 'bootstrap-repo.sh' 'a non-repository is never told to bootstrap'
ctx=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$out")
assert_contains "$ctx" 'did not start inside a git repository' 'it is told where it is'
assert_contains "$ctx" 'stays inert' 'and which guard is not watching'

# --- fails open when nothing on the PATH resolves -------------------------
# "No usable environment" means no jq, no git, no coreutils -- not "no bash".
# `#!/usr/bin/env bash` resolves bash ON the PATH, so emptying the PATH makes env
# exit 127 before a single line of the hook runs, which no script can defend
# against. Hand the interpreter over by absolute path and strip everything else.
repo=$(make_repo)
bash_bin=$(command -v bash)
for h in session-start subagent-start; do
    rc=0
    out=$(session_input "$repo" | env PATH=/nonexistent "$bash_bin" "$hooks/$h.sh" 2>/dev/null) || rc=$?
    assert_eq '0' "$rc" "$h exits 0 with no usable environment"
    assert_eq '{}' "$out" "and $h fails open with empty context"
done

# --- a stale contract is refreshed, a fresh one reused --------------------
repo=$(make_repo)
printf 'repo=cached/value\n' > "$repo/.agent/env-contract.txt"
touch -d '2 hours ago' "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2>/dev/null)
assert_hook_output "$out" session-start 'a stale contract still yields valid output'
assert_contains "$out" 'sandbox=' 'and is replaced by a fresh probe'
assert_not_contains "$out" 'cached/value' 'so the stale value is not served'

# --- compact always re-emits ----------------------------------------------
repo=$(make_repo)
printf 'repo=example-org/example-repo\n' > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" compact | PATH="$stub_path" "$hooks/session-start.sh" 2>/dev/null)
assert_contains "$out" 'additionalContext' 'source=compact re-emits the context'
assert_not_contains "$out" 'example-org/example-repo' 'from a fresh probe, not the cache'

# --- SubagentStart injects the same contract ------------------------------
repo=$(make_repo)
printf 'repo=example-org/example-repo\nbranch=feat/x\n' > "$repo/.agent/env-contract.txt"
sub=$(jq -nc --arg cwd "$repo" \
    '{cwd:$cwd,hook_event_name:"SubagentStart",model:"m",session_id:"s1",
      agent_id:"a1",agent_type:"worker",transcript_path:null}')
out=$(printf '%s' "$sub" | "$hooks/subagent-start.sh" 2>/dev/null)
rc=0; printf '%s' "$sub" | "$hooks/subagent-start.sh" >/dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'SubagentStart exits 0'
assert_hook_output "$out" subagent-start 'SubagentStart emits schema-valid JSON'
assert_contains "$out" 'example-org/example-repo' 'and injects the contract into the worker'

# --- no contract, no context, still fine ----------------------------------
repo=$(make_repo)
out=$(printf '%s' "$(jq -nc --arg cwd "$repo" \
    '{cwd:$cwd,hook_event_name:"SubagentStart",model:"m",session_id:"s",
      agent_id:"a",agent_type:"worker",transcript_path:null}')" \
    | "$hooks/subagent-start.sh" 2>/dev/null)
assert_hook_output "$out" subagent-start 'a repo with no contract still emits valid JSON'

# --- garbage input never crashes a hook -----------------------------------
for h in session-start subagent-start; do
    rc=0
    printf 'not json at all' | "$hooks/$h.sh" > /dev/null 2>&1 || rc=$?
    assert_eq '0' "$rc" "$h survives malformed input"
done

# --- PreToolUse: deny with a reason, never exit 2 -------------------------
pre_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:"s",tool_name:"Bash",tool_use_id:"t",transcript_path:null,
          tool_input:{command:$cmd}}'
}
decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$1"; }

repo=$(make_repo)
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$repo/.agent/config.env"
printf '{"schemaVersion":1,"project":{"id":"PVT_x","number":7}}\n' > "$repo/.agent/board.json"

out=$(pre_input "$repo" 'agent-run.sh --cmd test' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_hook_output "$out" pre-tool-use 'PreToolUse emits schema-valid JSON'
assert_eq 'deny' "$(decision "$out")" 'denies a bare helper invocation'
# The message must teach a path that RESOLVES. It named the pre-plugin location
# for a while, which a live deny caught: the agent obediently retyped a path to
# nothing.
assert_contains "$out" 'agentkit' 'and names the resolver, not a pre-plugin path'
assert_contains "$out" 'plugins/cache' 'including the plugin location'
assert_not_contains "$out" 'codex_home' 'never the path that no longer resolves'

out=$(pre_input "$repo" 'git add -A' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'denies git add -A'
assert_contains "$out" 'worktree-commit.sh' 'and names the correct helper'

# Global git options sit BETWEEN `git` and `add`, so a `git[[:space:]]+add`
# pattern misses every one of them. All four of these walked through untouched.
for sweep in 'git -C . add -A' 'git -C /some/repo add --all' \
    'git --no-pager add -A' 'git -c core.pager=cat add .' \
    'git --git-dir=/r/.git add -A'; do
    out=$(pre_input "$repo" "$sweep" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "denies through a global option: $sweep"
done

# Stripping globals must not become "skip arbitrary text": a search whose QUERY
# happens to contain the pattern is not a staging sweep.
out=$(pre_input "$repo" 'git log --grep "add -A"' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(decision "$out")" 'a search mentioning the pattern is not a sweep'

out=$(pre_input "$repo" 'gh project item-list 7 --owner x' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'denies board discovery when board.json exists'
assert_contains "$out" 'move-github-project-item.sh' 'and names the one-call helper'

out=$(pre_input "$repo" 'gh api repos/o/r/issues/5/timeline --paginate' \
    | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'denies the per-issue timeline call'
assert_contains "$out" 'triage-issues.sh' 'and names the single-query helper'

# Command position is what makes a helper mention wrong. An interpreter prefix
# still counts -- `bash agent-run.sh` is the same guaranteed failure.
for bad in 'agent-run.sh --cmd test' '  agent-run.sh' 'cd /tmp; agent-run.sh' \
    'git status && agent-run.sh --cmd verify' 'bash agent-run.sh' \
    'triage-issues.sh --state open'; do
    out=$(pre_input "$repo" "$bad" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "denies in command position: $bad"
done

# ARGUMENT position is how an agent FINDS the helper. Denying it left a live
# session unable to look for the script the deny message told it to look for --
# it spent two calls, then abandoned the shell for the search tool. Every shape
# below appeared in, or directly caused, that transcript.
# shellcheck disable=SC2016  # the literals ARE the fixtures: these assert which
# text is allowed, so they must stay unexpanded.
for ok in 'ls -la' 'git status' 'gh pr view 5' 'echo hi' \
    '"$codex_home/skills/.shared/scripts/agent-run.sh" --cmd test' \
    'git add src/main.c' \
    'find "$HOME/.codex/plugins/cache" -name agent-run.sh' \
    'command -v agent-run.sh' \
    'grep -rn agent-run.sh docs/' \
    'ls -l /some/path/skills/.shared/scripts/agent-run.sh' \
    'test -x "$agentkit/.shared/scripts/triage-issues.sh" && echo yes'; do
    out=$(pre_input "$repo" "$ok" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "allows: $ok"
done

# --- the allow path must express NO decision -------------------------------
# codex 0.147 rejects permissionDecision:"allow" at runtime even though the
# schema embedded in its own binary lists it as legal. Emitting it produced
# `PreToolUse hook returned unsupported permissionDecision:allow` on every
# single tool call. Approval is the absence of an opinion.
out=$(pre_input "$repo" 'ls -la' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_not_contains "$out" 'permissionDecision' 'the allow path emits no permissionDecision at all'
assert_not_contains "$out" 'allow' 'and never the literal the runtime rejects'
assert_eq '{}' "$(jq -c . <<< "$out")" 'the allow path is an empty object'

# --- guards follow the repository the COMMAND names ------------------------
# Launching outside the target repo is an ordinary mistake ("I meant to start in
# the project"). Anchoring evidence to the session cwd alone made the board and
# triage guards inert for that whole session while the text-only rules kept
# firing -- partial protection that looks identical to full protection.
outside="$tmp/outside"
mkdir -p "$outside"
for cmd in "cd $repo && gh project item-list 7 --owner x" \
    "gh issue view 442; cd $repo" \
    "git -C $repo add -A"; do
    out=$(pre_input "$outside" "$cmd" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "follows the named repository: $cmd"
done

# Naming no repository from outside one still allows: no evidence, no denial.
out=$(pre_input "$outside" 'gh project item-list 7 --owner x' \
    | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(decision "$out")" 'outside a repo, naming none, still allows'

# A read of the board must be offered a way to READ it. Denied here with only a
# status-mover on offer, a live agent hand-rolled its own GraphQL query.
out=$(pre_input "$repo" 'gh project item-list 7 --owner x' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_contains "$out" 'triage-issues.sh' 'the board deny offers a way to read the board'
assert_contains "$out" 'move-github-project-item.sh' 'as well as a way to move an item'

# --- no evidence, no denial ------------------------------------------------
bare=$(make_repo)
rm -rf "$bare/.agent"
for cmd in 'gh project item-list 7 --owner x' 'gh api repos/o/r/issues/5/timeline'; do
    out=$(pre_input "$bare" "$cmd" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "allows without .agent/ evidence: $cmd"
done

# --- a guard that cannot decide allows ------------------------------------
rc=0
printf 'not json' | "$hooks/pre-tool-use.sh" > /dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'PreToolUse survives malformed input'
out=$(printf 'not json' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(decision "$out")" 'and allows when it cannot parse'

# --- Stop: declaring a verify command is the opt-in -----------------------
stop_input() {
    jq -nc --arg cwd "$1" \
        '{cwd:$cwd,hook_event_name:"Stop",model:"m",session_id:"s",transcript_path:null}'
}
verdict() { jq -r '.decision // "allow"' <<< "$1"; }

# No verify command declared -> never blocks.
repo=$(make_repo)
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$repo/.agent/config.env"
printf 'dirty\n' > "$repo/untracked.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_hook_output "$out" stop 'Stop emits schema-valid JSON'
assert_eq 'allow' "$(verdict "$out")" 'no declared verify command means never blocking'

# Declared, changes present, no stamp -> block.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=echo ok\n' > "$repo/.agent/config.env"
printf 'x\n' > "$repo/changed.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'block' "$(verdict "$out")" 'declared command plus changes plus no stamp blocks'
assert_contains "$out" '--cmd verify' 'and the reason names the command to run'

# A stamp for a DIFFERENT command does not clear this one: the check asks for
# verify, so only verify's own stamp answers it. Otherwise a repository could
# disarm the gate with one line declaring a trivial command under another name.
touch "$repo/.agent/cache/stamp-lint"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'block' "$(verdict "$out")" "another command's stamp does not clear the verify gate"

# Stamp newer than the change -> allow.
touch "$repo/.agent/cache/stamp-verify"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'allow' "$(verdict "$out")" 'a stamp newer than every change allows'

# Change newer than the stamp -> block.
touch -d '1 minute' "$repo/changed.txt" 2>/dev/null || touch "$repo/changed.txt"
sleep 1; touch "$repo/changed.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'block' "$(verdict "$out")" 'an edit after the stamp blocks again'

# The agent's own working state is not a change. agent-preflight.sh rewrites
# .agent/env-contract.txt on every session start, so counting .agent/ would
# invalidate a stamp that had just covered the whole tree.
#
# The three mtimes are set explicitly rather than by write order: this
# filesystem's clock ticks about once a millisecond, so consecutive writes land
# on the same tick and `-nt` -- which is strictly greater -- would not fire.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=echo ok\n' > "$repo/.agent/config.env"
printf 'x\n' > "$repo/changed.txt"
touch -d '20 seconds ago' "$repo/changed.txt"
touch -d '10 seconds ago' "$repo/.agent/cache/stamp-verify"
printf 'repo=example-org/example-repo\n' > "$repo/.agent/env-contract.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'allow' "$(verdict "$out")" '.agent/ churn after the stamp is not a change'

# No changes at all -> allow.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=echo ok\n' > "$repo/.agent/config.env"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'allow' "$(verdict "$out")" 'a clean tree allows'

# --- the block terminates ---------------------------------------------------
# stop_hook_active marks the Stop that follows a block. Only a PASSING run clears
# the block, so a repository whose declared command genuinely fails could never
# produce one: without this guard the agent can never end its turn -- the same
# harm as exiting 2, reached through decision:block.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=false\n' > "$repo/.agent/config.env"
printf 'x\n' > "$repo/changed.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'block' "$(verdict "$out")" 'the first Stop still blocks'

active=$(jq -nc --arg cwd "$repo" \
    '{cwd:$cwd,hook_event_name:"Stop",model:"m",session_id:"s",transcript_path:null,
      stop_hook_active:true}')
out=$(printf '%s' "$active" | "$hooks/stop.sh" 2>/dev/null)
assert_hook_output "$out" stop 'the re-entered Stop emits schema-valid JSON'
assert_eq 'allow' "$(verdict "$out")" 'and never blocks twice, so the turn can end'

# --- the stamp attests to the command that was actually run ----------------
# End to end through the real writer: a declared verify that fails leaves no
# stamp, and a passing command under another name must not stand in for it.
run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=false\nAGENT_CMD_LINT=true\n' > "$repo/.agent/config.env"
printf 'x\n' > "$repo/changed.txt"
(cd "$repo" && "$run_sh" --cmd verify) > /dev/null 2>&1 || true
(cd "$repo" && "$run_sh" --cmd lint) > /dev/null 2>&1
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'block' "$(verdict "$out")" 'a passing lint does not satisfy a failing verify'

printf 'AGENT_CMD_VERIFY=true\nAGENT_CMD_LINT=true\n' > "$repo/.agent/config.env"
(cd "$repo" && "$run_sh" --cmd verify) > /dev/null 2>&1
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'allow' "$(verdict "$out")" 'and the verify that passes does'

rc=0
printf 'not json' | "$hooks/stop.sh" > /dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'Stop survives malformed input'

# --- the property that matters most ---------------------------------------
# A hook that exits non-zero halts the agent instead of informing it, so every
# dispatcher is swept over the payload shapes that break a naive parser -- each
# one twice, the second time on a PATH where nothing but bash resolves. Reported
# as one assertion per hook, naming every payload that got through.
sweep_hook() {
    local hook=$1 payload rc bad=''
    for payload in '' 'not json' '{}' '[]' '{"cwd":"/nonexistent"}' \
        '{"cwd":null,"tool_input":{"command":null}}' '{"tool_input":"scalar"}'; do
        rc=0
        printf '%s' "$payload" | "$hook" > /dev/null 2>&1 || rc=$?
        [[ $rc -eq 0 ]] || bad+=" [${payload:-<empty>} -> rc=$rc]"
        rc=0
        printf '%s' "$payload" | env PATH=/nonexistent "$bash_bin" "$hook" > /dev/null 2>&1 || rc=$?
        [[ $rc -eq 0 ]] || bad+=" [no PATH, ${payload:-<empty>} -> rc=$rc]"
    done
    printf '%s' "$bad"
}

for h in "$hooks"/*.sh; do
    assert_eq '' "$(sweep_hook "$h")" "$(basename -- "$h" .sh) never exits non-zero"
done

# --- what the harness actually runs ---------------------------------------
# Every assertion above invokes a hook by absolute path. The harness never does:
# it runs the command string out of hooks.json, in the SESSION's cwd. A relative
# './hooks/x.sh' therefore resolves nowhere -- exit 127, empty stdout, on every
# event -- while each script stays individually perfect and nothing notices. So
# build the plugin, export the variable the harness exports, and run each command
# verbatim from a directory that is not the plugin root.
built=$(mktemp -d "$tmp/plugin.XXXXXX")
"$here/build-plugin.sh" "$built" > /dev/null
plugin_root="$built/agentkit"

# A hook file nothing points at is a hook file nothing reads.
assert_eq './hooks.json' \
    "$(jq -r '.hooks // empty' < "$plugin_root/.codex-plugin/plugin.json")" \
    'the built manifest registers the hook file'

# The contract is deliberately stale, so SessionStart has to reach its helper --
# proving hooks and skills resolve as siblings in the BUILT layout, not just in
# the source tree. The gh stub keeps that probe off any live forge.
repo=$(make_repo)
printf 'repo=cached/value\n' > "$repo/.agent/env-contract.txt"
touch -d '2 hours ago' "$repo/.agent/env-contract.txt"

# CamelCase event name -> the kebab-case hook and schema fixture of the same name.
# shellcheck disable=SC2001  # a capture-group substitution; ${x//a/b} has no
    # backreferences, so the suggested rewrite cannot express this.
slug_of() { sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' <<< "$1" | tr '[:upper:]' '[:lower:]'; }

while IFS=$'\t' read -r event command; do
    # shellcheck disable=SC2016  # literal: the variable the harness expands, not this shell
    assert_contains "$command" '${CLAUDE_PLUGIN_ROOT}' "$event resolves against the plugin root"
    payload=$(jq -nc --arg cwd "$repo" --arg e "$event" \
        '{cwd:$cwd,hook_event_name:$e,model:"m",permission_mode:"default",session_id:"s",
          transcript_path:null,tool_name:"Bash",tool_use_id:"t",tool_input:{command:"ls -la"}}')
    rc=0
    out=$(cd "$tmp" && printf '%s' "$payload" |
        env CLAUDE_PLUGIN_ROOT="$plugin_root" PATH="$stub_path" sh -c "$command" 2> /dev/null) || rc=$?
    assert_eq '0' "$rc" "$event dispatches from an unrelated cwd"
    assert_hook_output "$out" "$(slug_of "$event")" "$event emits schema-valid JSON as dispatched"
    if [[ $event == SessionStart ]]; then
        assert_contains "$out" 'additionalContext' \
            'and SessionStart finds its helper beside it in the built plugin'
    fi
done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[] | [$e, .command] | @tsv' \
    < "$plugin_root/hooks.json")

# --- regressions from the first full interactive run -----------------------
# Each of these cost a real agent real turns. None were catchable by a unit test
# written from the design; all three came from watching one session work.

# Stop's reason must be COPY-PASTEABLE. Saying "resolve $agentkit first" without
# showing how made the agent guess the plugin root, miss the /skills segment,
# and burn three commands finding its way.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=echo ok\n' > "$repo/.agent/config.env"
printf 'x\n' > "$repo/real.txt"
git -C "$repo" add real.txt
out=$(printf '{"cwd":"%s","hook_event_name":"Stop","model":"m","session_id":"s","transcript_path":null}' \
    "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'block' "$(jq -r '.decision // "allow"' <<< "$out")" 'Stop blocks unverified work'
reason=$(jq -r '.reason' <<< "$out")
assert_contains "$reason" 'plugins/cache' 'the Stop reason spells the resolver out'
# shellcheck disable=SC2016  # the needle is the literal text of the resolver the
# hook must print; expanding it would search for this shell's output instead.
assert_contains "$reason" 'agentkit=$(find' 'and gives a runnable command, not an allusion'
assert_contains "$reason" '/skills' 'including the /skills segment the agent guessed wrong'

# .agent/ is the agent's own working state. agent-preflight.sh writes
# env-contract.txt there, so counting it as unverified work made Stop block on
# every single turn for the whole session.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=echo ok\n' > "$repo/.agent/config.env"
printf 'y\n' > "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
printf 'contract\n' > "$repo/.agent/env-contract.txt"
out=$(printf '{"cwd":"%s","hook_event_name":"Stop","model":"m","session_id":"s","transcript_path":null}' \
    "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq 'allow' "$(jq -r '.decision // "allow"' <<< "$out")" \
    'a change confined to .agent/ never blocks'

finish
