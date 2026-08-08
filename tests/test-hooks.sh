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
skills_root="$root/agentkit/skills"
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

# The notice must reach the PERSON, not only the model. Handed it and asked to
# run ls, a live agent ran ls and said nothing about it -- a reasonable reading
# of context that is not addressed to the user. systemMessage is the channel the
# TUI shows, so the notice goes to both.
assert_contains "$out" 'systemMessage' 'the onboarding notice also reaches the operator'
human=$(jq -r '.systemMessage // ""' <<< "$out")
assert_contains "$human" 'not onboarded' 'and says what is wrong'
assert_contains "$human" 'bootstrap-repo.sh' 'and how to fix it'
# The agent-facing copy must be an instruction, not a description, or the model
# has no reason to raise it at all.
assert_contains "$ctx" 'ACTION REQUIRED' 'and the agent is told to raise it'

# Onboarded repositories must never see it again.
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$repo/.agent/config.env"
out=$(session_input "$repo" | "$hooks/session-start.sh" 2>/dev/null)
assert_not_contains "$out" 'not onboarded' 'an onboarded repo is not nagged'
assert_not_contains "$out" 'systemMessage' 'and the operator is not nagged either'

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

# --- a contract from the OTHER CLI is stale, however fresh ----------------
# Observed live: a contract written by one CLI at 13:26 was reused two minutes
# later by the other, which then reported itself as its peer. Every commit in
# that session would have credited the wrong agent. The harness= line is SESSION
# identity; the file is shared by every CLI that opens the repository.
foreign=$(make_repo)
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$foreign/.agent/config.env"
printf 'repo=example-org/example-repo\nharness= name=someone-else trailer="X <x@example.invalid>" other=nobody\n' \
    > "$foreign/.agent/env-contract.txt"
out=$(session_input "$foreign" | PATH="$stub_path" "$hooks/session-start.sh" 2>/dev/null)
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
assert_not_contains "$ctx" 'someone-else' 'a contract from another CLI is not served'
assert_contains "$ctx" 'harness=' 'and is replaced by a fresh probe'

# The same file, written by THIS harness, is still reused -- the check must not
# throw away every cache and re-probe gh on every single session.
mine=$(make_repo)
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$mine/.agent/config.env"
me=$("$skills_root/.shared/scripts/harness-id.sh" --name)
printf 'repo=cached/value\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' "$me" \
    > "$mine/.agent/env-contract.txt"
out=$(session_input "$mine" | PATH="$stub_path" "$hooks/session-start.sh" 2>/dev/null)
assert_contains "$out" 'cached/value' 'a contract from this harness is still reused'

# A worker must not inherit the other CLI's identity either; it has no way to
# notice, and nobody is watching it.
printf 'repo=example-org/example-repo\nharness= name=someone-else trailer="X <x@example.invalid>" other=nobody\n' \
    > "$foreign/.agent/env-contract.txt"
out=$(printf '%s' "$(jq -nc --arg cwd "$foreign" \
    '{cwd:$cwd,hook_event_name:"SubagentStart",model:"m",session_id:"s1",
      agent_id:"a1",agent_type:"worker",transcript_path:null}')" \
    | "$hooks/subagent-start.sh" 2>/dev/null)
assert_not_contains "$out" 'someone-else' 'a worker is not handed the other CLI identity'

# --- Layer 0: the tooling contract, at zero cost --------------------------
# The cheapest defence against re-learning: it arrives before the first mistake
# and costs no tool call at all.
onboarded=$(make_repo)
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$onboarded/.agent/config.env"
printf 'repo=example-org/example-repo\n' > "$onboarded/.agent/env-contract.txt"
out=$(session_input "$onboarded" | "$hooks/session-start.sh" 2>/dev/null)
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
assert_contains "$ctx" 'triage-issues.sh' 'an onboarded repo is told what helpers exist'
assert_contains "$ctx" 'move-github-project-item.sh' 'including the board mover'
assert_contains "$ctx" 'plugins/cache' 'and how to resolve them'
assert_contains "$ctx" 'example-org/example-repo' 'without displacing the contract'
assert_not_contains "$ctx" 'not onboarded' 'and is not also told to bootstrap'

# Every helper named must EXIST. A curriculum naming a missing script teaches a
# broken path -- the same failure the deny messages had after packaging moved
# the tree. Extracted from the emitted text, not restated here, so this cannot
# drift from what agents are actually told.
# shellcheck disable=SC2016  # $agentkit is the literal text being matched in the
# emitted curriculum, not a variable to expand here.
while read -r rel; do
    [[ -n $rel ]] || continue
    assert_eq 'yes' "$([[ -e $skills_root/$rel ]] && echo yes || echo no)" \
        "the curriculum names a helper that exists: $rel"
done < <(grep -oE '\$agentkit/[^[:space:]]+\.sh' <<< "$ctx" | sed 's|^\$agentkit/||' | sort -u)

# A worker gets it too, and this is the only channel that can reach it.
sub_in=$(jq -nc --arg cwd "$onboarded" \
    '{cwd:$cwd,hook_event_name:"SubagentStart",model:"m",session_id:"s1",
      agent_id:"a1",agent_type:"worker",transcript_path:null}')
out=$(printf '%s' "$sub_in" | "$hooks/subagent-start.sh" 2>/dev/null)
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
assert_contains "$ctx" 'triage-issues.sh' 'a spawned worker inherits the tooling contract'
assert_contains "$ctx" 'example-org/example-repo' 'alongside the environment contract'

# --- compaction re-arms the lessons ---------------------------------------
# Compaction is precisely when an injected lesson was summarised away, so the
# once-per-session claims must not outlive it.
claim_dir="$onboarded/.agent/cache/brief/s1"
mkdir -p "$claim_dir/board-read"
session_input "$onboarded" compact | PATH="$stub_path" "$hooks/session-start.sh" >/dev/null 2>&1
assert_eq 'no' "$([[ -d $claim_dir/board-read ]] && echo yes || echo no)" \
    'compaction clears this session claims so the lessons are taught again'

mkdir -p "$claim_dir/board-read"
session_input "$onboarded" | "$hooks/session-start.sh" >/dev/null 2>&1
assert_eq 'yes' "$([[ -d $claim_dir/board-read ]] && echo yes || echo no)" \
    'an ordinary start leaves them alone'

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

# --- PreToolUse: one denial, once, and never a halt -----------------------
# Every other rule moved to PostToolUse, where the command runs first and the
# lesson lands afterwards. What survives here is the bare helper path, which
# cannot succeed at all -- so nothing is being withheld by refusing it.
# Counter kept on disk, not in a variable. These are called from inside command
# substitution, so a shell variable would increment in a subshell and every
# "fresh" session id would come back identical -- which silently collapsed all of
# the once-per-session assertions into one session.
sid_file="$tmp/sid-counter"
printf '0' > "$sid_file"
fresh_sid() {
    local n
    n=$(($(cat "$sid_file" 2> /dev/null || echo 0) + 1))
    printf '%s' "$n" > "$sid_file"
    printf 's%03d' "$n"
}

pre_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" --arg sid "${3:-$(fresh_sid)}" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:$sid,tool_name:"Bash",tool_use_id:"t",transcript_path:null,
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
# The override sentence is load-bearing, not decorative. Denied once WITHOUT it,
# a live agent answered "It was not run" and stopped rather than adapting.
assert_contains "$out" 'run it again' 'and states that the retry is permitted'

# --- work-destroying commands are refused, every time ---------------------
# The one place a hard, repeatable denial is right. Every other rule here lets
# the command run because a cheaper alternative can be taught afterwards; there
# is no teach-after-the-fact for a force-push that already landed.
for danger in 'git push --force origin main' 'git push -f' \
    'git push --force-with-lease origin feat/x' \
    'git reset --hard HEAD~3' 'git clean -fdx' \
    'git branch -D main' 'gh pr merge 42 --squash' \
    'git commit --no-verify -m x' 'rm -rf ~'; do
    out=$(pre_input "$repo" "$danger" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "refuses: $danger"
    assert_contains "$out" 'does not lift on a retry' "and says so: $danger"
done

# A flag hidden inside a substitution read as ordinary text to every pattern:
# `git push $(echo --force)` matched nothing. The model refused it on its own
# judgement, which is not a guard.
# shellcheck disable=SC2016  # the UNEXPANDED substitution is the fixture: these
# assert what the guard sees, so expanding them would test nothing.
for hidden in 'git push $(echo --force)' 'git push `echo --force`' \
    'git reset $(printf -- --hard) HEAD~1'; do
    out=$(pre_input "$repo" "$hidden" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "sees through the substitution: $hidden"
    assert_contains "$out" 'inside a substitution' 'and says why it could not be read as written'
done

# Substitution is NOT itself suspicious. Flattening leaves a legitimate dynamic
# value as harmless words, so the ordinary uses survive -- banning them outright
# is how a guard starts getting routed around.
# shellcheck disable=SC2016  # same: the literal text is what is under test.
for dynamic in 'git push origin $(git branch --show-current)' \
    'git commit -m "$(date)"' 'git log --oneline -n $(echo 5)' \
    'git reset --soft HEAD~1' 'git clean -n -- notes.f' \
    'git clean $(echo -n)'; do
    out=$(pre_input "$repo" "$dynamic" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "leaves ordinary substitution alone: $dynamic"
done

# It must NOT catch the ordinary forms of the same verbs. A guard that cries
# wolf on `git push` is one an agent learns to route around.
for safe in 'git push' 'git push origin main' 'git reset HEAD~1' \
    'git clean -n' 'git branch -D feat/old' 'gh pr view 42' \
    'git commit -m x' 'rm -rf ./build' 'rm -rf node_modules'; do
    out=$(pre_input "$repo" "$safe" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "allows the ordinary form: $safe"
done

# A destructive command is refused on the SECOND attempt too -- the opposite of
# the once-per-session rule that governs every other denial here.
same_sid=$(fresh_sid)
for attempt in 1 2 3; do
    out=$(pre_input "$repo" 'git push --force' "$same_sid" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "still refused on attempt $attempt"
done

# --- files that decide whether other checks run ---------------------------
# This hook saw shell commands only, so an agent could edit a CI workflow -- or
# the hook configuration itself -- entirely unobserved. Deny-once, not outright:
# editing one is ordinary work sometimes and quietly loosening a gate other
# times, and the diff alone does not distinguish them.
edit_input() {
    jq -nc --arg cwd "$1" --arg path "$2" --arg sid "${3:-$(fresh_sid)}" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:$sid,tool_name:"Edit",tool_use_id:"t",transcript_path:null,
          tool_input:{file_path:$path}}'
}

for guarded in '.github/workflows/ci.yml' '.githooks/pre-commit' \
    '.pre-commit-config.yaml' 'Jenkinsfile' '.circleci/config.yml' \
    '.claude/settings.json' '.codex/config.toml'; do
    out=$(edit_input "$repo" "$guarded" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "guards the gate file: $guarded"
done
assert_contains "$out" 'fix the check' 'and names the failure mode it exists for'

# Ordinary source must be untouched, or the guard is just friction.
for ordinary in 'src/main.ts' 'README.md' 'server/app/models.py' \
    'docs/.github-notes.md' 'workflows/ci.yml'; do
    out=$(edit_input "$repo" "$ordinary" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "leaves ordinary files alone: $ordinary"
done

# Same path, absolute rather than relative: one rule, both forms.
out=$(edit_input "$repo" "$repo/.github/workflows/ci.yml" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'an absolute path is compared repo-relative'

# Once per session, then the deliberate second attempt proceeds.
psid=$(fresh_sid)
out=$(edit_input "$repo" '.github/workflows/ci.yml' "$psid" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'the first protected edit is refused'
out=$(edit_input "$repo" '.github/workflows/release.yml' "$psid" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(decision "$out")" 'and the deliberate retry proceeds'

# A repository may EXTEND the set. It must not be able to shrink it: the file is
# committed, and anyone who can open a pull request can edit it.
ext=$(make_repo)
printf 'AGENT_REPO_SLUG=e/e\nAGENT_PROTECTED_PATHS=migrations/,docs/decisions.md\n' \
    > "$ext/.agent/config.env"
out=$(edit_input "$ext" 'migrations/001_init.sql' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'a repository-declared path is protected too'
out=$(edit_input "$ext" '.github/workflows/ci.yml' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'and declaring paths does not replace the defaults'

# The patch format carries its paths inside the payload text, not in a field.
patch=$(jq -nc --arg cwd "$repo" --arg sid "$(fresh_sid)" \
    '{cwd:$cwd,hook_event_name:"PreToolUse",session_id:$sid,tool_name:"apply_patch",
      tool_input:{input:"*** Begin Patch\n*** Update File: .github/workflows/ci.yml\n@@\n-x\n+y\n*** End Patch"}}')
out=$(printf '%s' "$patch" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'a path inside a patch payload is seen'

# --- the promise the message makes must be kept ---------------------------
same=$(fresh_sid)
out=$(pre_input "$repo" 'agent-run.sh --cmd test' "$same" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'first call in a session is denied'
out=$(pre_input "$repo" 'agent-run.sh --cmd test' "$same" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(decision "$out")" 'and the retry it invited is allowed'
out=$(pre_input "$repo" 'triage-issues.sh --state open' "$same" | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'allow' "$(decision "$out")" 'the whole rule opens, not just that one command'
out=$(pre_input "$repo" 'agent-run.sh --cmd test' | "$hooks/pre-tool-use.sh" 2>/dev/null)
assert_eq 'deny' "$(decision "$out")" 'a new session is taught again'

# --- cannot record, do not deny -------------------------------------------
# THE inviolable rule. A denial issued on state that could not be persisted
# denies the retry identically, and the one after that: an unrecoverable loop,
# with no human in the loop for a worker.
locked=$(make_repo)
chmod -w "$locked/.agent/cache" 2>/dev/null || true
if [[ -w $locked/.agent/cache ]]; then
    printf '  skip unwritable-state check: cache still writable (running as root?)\n'
else
    for attempt in 1 2 3; do
        out=$(pre_input "$locked" 'agent-run.sh --cmd test' "sLOCK" | "$hooks/pre-tool-use.sh" 2>/dev/null)
        assert_eq 'allow' "$(decision "$out")" "unrecordable state never denies (attempt $attempt)"
    done
fi
chmod +w "$locked/.agent/cache" 2>/dev/null || true

# Command position is what makes a helper mention wrong. An interpreter prefix
# still counts -- `bash agent-run.sh` is the same guaranteed failure. Each gets a
# fresh session, since the rule now opens after one denial.
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

# --- the rules that moved must NOT block any more -------------------------
# This is the autonomy guarantee. Each of these was a permanent denial; a worker
# meeting one had no way past it. They now run and are taught afterwards.
for freed in 'git add -A' 'git -C . add -A' 'gh project item-list 7 --owner x' \
    'gh api repos/o/r/issues/5/timeline --paginate' 'gh issue view 442'; do
    out=$(pre_input "$repo" "$freed" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "no longer blocked: $freed"
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

# --- PostToolUse: teach after the fact ------------------------------------
# Rests on a MEASURED fact: additionalContext here reaches the model. A live
# agent, given a code word through this channel and then barred from using any
# tool, repeated it exactly.
post_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" --arg sid "${3:-$(fresh_sid)}" \
        '{cwd:$cwd,hook_event_name:"PostToolUse",model:"m",permission_mode:"default",
          session_id:$sid,tool_name:"Bash",tool_use_id:"t",transcript_path:null,
          tool_input:{command:$cmd},tool_response:{stdout:"",exit_code:0}}'
}
ctx_of() { jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$1"; }

out=$(post_input "$repo" 'gh project item-list 7 --owner x' | "$hooks/post-tool-use.sh" 2>/dev/null)
assert_hook_output "$out" post-tool-use 'PostToolUse emits schema-valid JSON'
ctx=$(ctx_of "$out")
assert_contains "$ctx" 'triage-issues.sh' 'board advice offers a way to READ the board'
assert_contains "$ctx" 'move-github-project-item.sh' 'and a way to move an item'
assert_contains "$ctx" 'plugins/cache' 'and teaches the resolver'

# It must be structurally unable to block. Not "unlikely to" -- unable.
for shape in 'gh project item-list 7 --owner x' 'gh issue view 442' 'git add -A' 'ls -la'; do
    out=$(post_input "$repo" "$shape" | "$hooks/post-tool-use.sh" 2>/dev/null)
    assert_not_contains "$out" 'permissionDecision' "never decides a permission: $shape"
    assert_not_contains "$out" '"decision"' "and never blocks: $shape"
done

# Once per rule, per session. An advisory on every call is noise, and noise is
# how the environment contract stops being read.
s=$(fresh_sid)
out=$(post_input "$repo" 'gh issue view 442' "$s" | "$hooks/post-tool-use.sh" 2>/dev/null)
assert_contains "$(ctx_of "$out")" 'triage-issues.sh' 'the first per-issue call is taught'
out=$(post_input "$repo" 'gh issue view 443' "$s" | "$hooks/post-tool-use.sh" 2>/dev/null)
assert_eq '' "$(ctx_of "$out")" 'the second is not repeated'
# Keyed by RULE, not by command: hashing the command would make 442, 443, 444
# three separate lessons and teach twelve times where one was intended.
out=$(post_input "$repo" 'git add -A' "$s" | "$hooks/post-tool-use.sh" 2>/dev/null)
assert_contains "$(ctx_of "$out")" 'worktree-commit.sh' 'a different rule still speaks in that session'
out=$(post_input "$repo" 'gh issue view 444' | "$hooks/post-tool-use.sh" 2>/dev/null)
assert_contains "$(ctx_of "$out")" 'triage-issues.sh' 'and a new session is taught again'

# Reading ONE issue body stays legitimate; the digest deliberately omits bodies.
out=$(post_input "$repo" 'gh issue view 442' | "$hooks/post-tool-use.sh" 2>/dev/null)
assert_contains "$(ctx_of "$out")" 'does not carry bodies' 'the advice does not forbid reading a body'

# Unrecordable state SPEAKS -- the inverse of the denial rule. A repeated
# sentence is noise; silence would lose the lesson, and nothing here can block.
locked2=$(make_repo)
printf 'AGENT_REPO_SLUG=e/e\n' > "$locked2/.agent/config.env"
chmod -w "$locked2/.agent/cache" 2>/dev/null || true
if [[ ! -w $locked2/.agent/cache ]]; then
    for attempt in 1 2; do
        out=$(post_input "$locked2" 'gh issue view 1' "sLOCK2" | "$hooks/post-tool-use.sh" 2>/dev/null)
        assert_contains "$(ctx_of "$out")" 'triage-issues.sh' "unrecordable state still teaches (attempt $attempt)"
    done
fi
chmod +w "$locked2/.agent/cache" 2>/dev/null || true

# --- advice follows the repository the COMMAND names ----------------------
# Launching outside the target repo is an ordinary mistake. Anchoring evidence to
# the session cwd alone made these rules inert for that whole session.
outside="$tmp/outside"
mkdir -p "$outside"
for cmd in "cd $repo && gh project item-list 7 --owner x" \
    "gh issue view 442; cd $repo"; do
    out=$(post_input "$outside" "$cmd" | "$hooks/post-tool-use.sh" 2>/dev/null)
    assert_contains "$(ctx_of "$out")" 'triage-issues.sh' "follows the named repository: $cmd"
done

# --- no evidence, nothing to say ------------------------------------------
bare=$(make_repo)
rm -rf "$bare/.agent"
for cmd in 'gh project item-list 7 --owner x' 'gh api repos/o/r/issues/5/timeline'; do
    out=$(post_input "$bare" "$cmd" | "$hooks/post-tool-use.sh" 2>/dev/null)
    assert_eq '' "$(ctx_of "$out")" "silent without .agent/ evidence: $cmd"
done

rc=0
printf 'not json' | "$hooks/post-tool-use.sh" > /dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'PostToolUse survives malformed input'

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

# A hook file nothing points at is a hook file nothing reads. It lives inside
# hooks/ because that is where BOTH harnesses look: one declares the path, the
# other auto-discovers it there.
assert_eq './hooks/hooks.json' \
    "$(jq -r '.hooks // empty' < "$plugin_root/.codex-plugin/plugin.json")" \
    'the built manifest registers the hook file'
assert_eq 'yes' "$([[ -f $plugin_root/hooks/hooks.json ]] && echo yes || echo no)" \
    'and it is where the other harness auto-discovers it'

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
    < "$plugin_root/hooks/hooks.json")

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
