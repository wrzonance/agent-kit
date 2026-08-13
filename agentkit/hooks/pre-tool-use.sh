#!/usr/bin/env bash
# PreToolUse -> two denials, and nothing else.
#
#   1. Commands that destroy work. Refused every time, because for these the
#      second attempt is exactly the one that must also be refused.
#   2. A bare helper name, which cannot succeed at all -- nothing here is on
#      PATH. Refused once per session, and the message says the retry is allowed.
#
# Everything else is taught by PostToolUse AFTER the command has run and returned
# real data (see post-tool-use.sh). A measured runtime fact makes that possible:
# PostToolUse additionalContext reaches the model. So a guard no longer has to
# choose between teaching a lesson and letting the work proceed.
#
# That matters most where nobody is watching. A blocked main session has a human
# who can rephrase; a blocked worker is a dead branch, silently. This hook is
# therefore silent on every rule that has an alternative, which makes it
# structurally unable to halt autonomous work.
#
# Never exit 2 and never updatedInput: exit 2 halts the agent instead of
# informing it, and a rewrite hides the lesson a reason teaches.
set -uo pipefail

# Allow == say nothing. VERIFIED AGAINST THE RUNTIME, NOT THE SCHEMA: the JSON
# Schema embedded in the codex binary lists permissionDecision as
# ["allow","deny","ask"], but codex 0.147 rejects the allow value outright --
# `PreToolUse hook returned unsupported permissionDecision:allow` -- on EVERY
# tool call. An empty object is the correct way to express "no opinion".
#
# The schema fixtures verify output SHAPE; they are not a statement of what the
# runtime accepts. Only an interactive session proved this.
allow() { printf '{}\n'; exit 0; }
GUARD_HOOK_NAME=pre-tool-use
trap 'guard_log_error $? 2>/dev/null || true; allow' ERR

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.

# Loading the guard library is part of the security boundary. A partial
# installation must not turn every guard into an implicit allow.
deny() {
    jq -nc --arg r "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:$r}}'
    exit 0
}

# shellcheck source=lib/guard-lib.sh
guard_lib_status=0
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || guard_lib_status=$?
if (( guard_lib_status != 0 )); then
    deny "PreToolUse guard library is unavailable (load status $guard_lib_status); refusing this tool call."
fi

# Advisory only: this deliberately emits no permission decision, so a worker
# can always continue after learning that a command reads outside its scope.
advise() {
    ADVISORY_CONTEXT=$1
}

input=$(cat 2> /dev/null || true)
command_line=$(jq -r '.tool_input.command // empty' <<< "$input" 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
session=$(jq -r '.session_id // empty' <<< "$input" 2> /dev/null || true)
ADVISORY_CONTEXT=''

# Files that decide whether other checks run. This hook used to see shell
# commands only, so an agent could edit a CI workflow -- or the hook config
# itself -- entirely unobserved.
guard_resolve_roots "$cwd" "$command_line"
guard_resolve_scope_roots "$cwd"
protect_root=$(guard_state_root)
# Both channels: the paths an edit tool declares, and the paths a shell command
# is about to write. The second exists because a redirect or `sed -i` arrives as
# a Bash call, so the edit-tool guard cannot see it -- the gap that let a CI
# workflow be rewritten straight past this rule.
while IFS= read -r target; do
    [[ -n $target ]] || continue
    classification_result=$(guard_classify_target_result "$target" "$cwd" "$command_line")
    target_classification=${classification_result%%$'\n'*}
    target_root=${classification_result#*$'\n'}
    [[ $target_root == "$classification_result" ]] && target_root=''
    case $target_classification in
        fixture) continue;;
    esac
    [[ -n $target_root ]] || target_root=$protect_root
    policy_root=$protect_root
    [[ $target_classification == workspace && -n $policy_root ]] || policy_root=$target_root
    matched=$(guard_protected_match "$target" "${policy_root:-$protect_root}") || continue
    if guard_should_deny "$protect_root" "$session" "protected-path"; then
        reason="Refused once -- $target is under $matched (classification: $target_classification;
repository target: ${target_root:-unresolved}), which decides whether other
checks run. Editing one is ordinary work sometimes and quietly loosening a gate
other times, and the diff alone does not say which.

If this edit is part of the task, make the same call again and it will be
allowed. If you are changing it to make a failing check pass, fix the check."
        [[ $target_classification != unresolved ]] || reason+=$'\nThe target classification is ambiguous; retry if this is an ephemeral fixture, after confirming its resolved git root.'
        deny "$reason"
    fi
done < <(
    guard_target_paths "$input"
    [[ -z $command_line ]] || guard_shell_write_targets "$command_line"
)

[[ -n $command_line ]] || allow

# Work-destroying commands. Denied every time, deliberately: unlike every other
# rule here, the second attempt is exactly the one that must also be refused.
if reason=$(guard_destructive_reason "$command_line"); then
    deny "Refused -- $reason
This denial does not lift on a retry. If it is genuinely what the task needs,
the user should run it themselves."
fi

# A commit landing on the trunk branch. Deny-once: committing to trunk is
# ordinary in some repositories and a mistake in every repository that reviews
# by pull request, and the command alone does not say which -- so one refusal
# turns the default into a choice.
target_root=$(guard_command_repository_root "$cwd" "$command_line" 2> /dev/null || true)
if [[ -n $target_root ]]; then
    classification_result=$(guard_classify_root_result "$target_root")
    target_classification=${classification_result%%$'\n'*}
else
    target_classification=unresolved
fi
if [[ $target_classification != fixture && $target_classification != foreign ]] &&
    branch=$(guard_trunk_commit_reason "$command_line" "${target_root:-$protect_root}"); then
    if guard_should_deny "$protect_root" "$session" trunk-commit; then
        if guard_commit_has_explicit_worktree "$command_line"; then
            provenance="An explicit git -C worktree pin identifies the landing worktree."
        else
            provenance="Because this repository has one worktree, those observations identify the inferred landing branch."
        fi
        reason="Refused once -- this commit would land on $branch, the inferred landing
branch. The hook observed repository root: ${target_root:-$protect_root}
and observed HEAD branch: $branch. $provenance This is the trunk branch this
repository declares. Work that is reviewed before it merges needs a branch:

  git checkout -b <type>/<short-name>

If committing to $branch is genuinely right here, make the same call again and
it will be allowed.

Target classification: $target_classification; repository target: ${target_root:-$protect_root}."
        [[ $target_classification != unresolved ]] || reason+=$'\nThe target classification is ambiguous; retry if this is an ephemeral fixture, after confirming its resolved git root.'
        deny "$reason"
    fi
fi

# A bare helper invocation. Nothing in the tree is on PATH, so this is a
# guaranteed "command not found" that the agent then recovers from by guessing a
# location. Letting it run would teach the same lesson one call later, so the
# denial is the cheaper path -- and unlike the rules that moved to PostToolUse,
# there is no result being withheld, because there would not have been one.
#
# Matched in COMMAND POSITION only -- start of line or after a separator,
# allowing an interpreter prefix, because `bash agent-run.sh` fails the same way.
# Any whitespace used to qualify, which denied ARGUMENT-position mentions too:
# `find ... -name agent-run.sh`, `command -v agent-run.sh`, `grep -rn
# agent-run.sh` -- the very commands that LOCATE the helper, and the shape this
# rule's own message invites. A live session burned two calls on it and then
# abandoned the shell entirely.
#
# This deliberately under-blocks (`x=$(agent-run.sh)` slips through). A false
# deny costs a call and teaches the wrong lesson; a missed deny costs one
# "command not found" that the agent corrects unaided.
# The denial fires ONCE per session, and the message says so. Without that
# promise -- and without the code that keeps it -- a two-stage guard collapses
# into a halt: denied once, a live agent answered "It was not run" and stopped
# rather than adapting.
if grep -qE "(^|[;&|])[[:space:]]*((sudo|bash|sh|env)[[:space:]]+)*($HELPERS)\.sh([[:space:]]|$)" \
    <<< "$command_line"; then
    guard_resolve_roots "$cwd" "$command_line"
    if guard_should_deny "$(guard_state_root)" "$session" helper-path; then
        # shellcheck disable=SC2016  # literal text, see deny()
        deny "Helper scripts are not on PATH, and the tree MOVES when installed as a
plugin. Resolve it first:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/<script>.sh\" ...
If this exact command is what the task needs, run it again -- it will be allowed."
    fi
fi

# A broad filesystem walker is useful inside the declared working set, but a
# home/sibling/harness sweep is usually a mistaken environment probe. The
# command still runs; this is a once-per-session lesson, never a denial. Keep
# this after every hard-denial path so a denied command cannot consume a lesson
# that was never emitted.
if scope_target=$(guard_out_of_scope_target "$command_line" "$cwd"); then
    if guard_should_advise "$protect_root" "$session" filesystem-scope; then
        # shellcheck disable=SC2016  # literal text for the agent, see deny()
        advise "This command reads outside the workspace ($scope_target; classification: ${GUARD_SCOPE_CLASSIFICATION:-foreign}). The contract and shipped helpers answer environment questions; files outside the worktree and contract skills tree are out of scope and untrusted. Keep filesystem walkers/readers inside the current worktree, contract skills= tree, /tmp, contract cache directories, or explicitly provided paths. Finding nothing in scope is an answer."
    fi
fi

# Inline gh mutation bodies are advisory only. The command still runs, while
# the exact file-backed policy arrives before the next tool call.
if gh_body_reason=$(guard_gh_inline_body_reason "$command_line"); then
    if guard_should_advise "$protect_root" "$session" gh-inline-body; then
        advise "$gh_body_reason"
    fi
fi

if [[ -n $ADVISORY_CONTEXT ]]; then
    jq -nc --arg ctx "$ADVISORY_CONTEXT" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
    exit 0
fi

allow
