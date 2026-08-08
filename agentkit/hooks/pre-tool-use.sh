#!/usr/bin/env bash
# PreToolUse -> deny with a reason naming the correct command, or allow.
#
# Deny-with-reason, never exit 2 and never updatedInput: exit 2 halts the agent
# instead of informing it, and a rewrite hides the lesson a reason teaches.
#
# Guards fail closed in the sense that a rule only fires on positive evidence;
# anything this cannot parse or does not recognise is ALLOWED. A repository with
# no .agent/ directory receives no denial from the evidence-gated rules at all.
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
trap 'allow' ERR

# Every reason below is single-quoted deliberately, and each call is annotated as
# such. The "$agentkit/..." form inside is literal text for the agent to read
# and type; expanding it here would resolve it against the hook's own environment
# and hand back a path instead of the lesson.
deny() {
    jq -nc --arg r "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:$r}}'
    exit 0
}

# The exact snippet the skills use. Defined once so a deny message can never
# teach a path that does not resolve -- which is precisely what these messages
# did after packaging moved the tree.
# shellcheck disable=SC2016  # every $ here is literal text the AGENT reads and
# retypes. Expanding it would bake this machine's paths into the advice.
readonly RESOLVE_HINT='  agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -maxdepth 4 \
    -type d -path "*/agentkit/*/skills" 2>/dev/null | sort | tail -1)
  [ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"'

readonly HELPERS='agent-run|worktree-commit|gh-pr-state|agent-preflight|repo-config|triage-issues|move-github-project-item|gh-comment'

input=$(cat 2> /dev/null || true)
command_line=$(jq -r '.tool_input.command // empty' <<< "$input" 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
[[ -n $command_line ]] || allow

# Every repository this command might act on -- not just the one the session
# started in. An agent launched in $HOME and told "commit my work in <repo>"
# reaches it with `cd <repo> && ...` or `git -C <repo> ...`, and anchoring
# evidence to the session cwd alone made the board and triage guards inert for
# exactly that session, with no sign they had switched off.
roots=()
add_root() {
    local resolved existing
    resolved=$(git -C "$1" rev-parse --show-toplevel 2> /dev/null) || return 0
    for existing in ${roots[@]+"${roots[@]}"}; do
        [[ $existing != "$resolved" ]] || return 0
    done
    roots+=("$resolved")
}

if [[ -n $cwd && -d $cwd ]]; then
    add_root "$cwd"
fi

# Paths the command itself names. Read as text and never evaluated: this runs on
# an untrusted command line, so a substitution here would execute it.
while IFS= read -r candidate; do
    [[ -n $candidate ]] || continue
    candidate=${candidate/#\~/$HOME}
    if [[ -d $candidate ]]; then
        add_root "$candidate"
    fi
done < <(grep -oE '(^|[;&|])[[:space:]]*cd[[:space:]]+[^[:space:];&|]+|-C[[:space:]]+[^[:space:];&|]+' \
    <<< "$command_line" 2> /dev/null | sed -E 's/.*(cd|-C)[[:space:]]+//' || true)

# True when ANY candidate repository carries the file. A guard keyed to a
# repository's own declaration should fire on the repository being touched.
has_evidence() {
    local r
    for r in ${roots[@]+"${roots[@]}"}; do
        [[ ! -r "$r/$1" ]] || return 0
    done
    return 1
}

# 1. A bare helper invocation. Nothing here is on PATH, so this is a guaranteed
#    "command not found" the agent then recovers from by guessing a location.
#
#    Matched in COMMAND POSITION only -- start of line or after a separator,
#    allowing an interpreter prefix, because `bash agent-run.sh` fails the same
#    way. Any whitespace used to qualify, which denied every ARGUMENT-position
#    mention too: `find ... -name agent-run.sh`, `command -v agent-run.sh`,
#    `grep -rn agent-run.sh` -- the very commands that LOCATE the helper, and the
#    shape this rule's own message invites. A live session burned two calls on it
#    and then abandoned the shell entirely.
#
#    This deliberately under-blocks (`x=$(agent-run.sh)` slips through). A false
#    deny costs a call and teaches the wrong lesson; a missed deny costs one
#    "command not found" that the agent corrects unaided.
if grep -qE "(^|[;&|])[[:space:]]*((sudo|bash|sh|env)[[:space:]]+)*($HELPERS)\.sh([[:space:]]|$)" \
    <<< "$command_line"; then
    # shellcheck disable=SC2016  # literal text, see deny()
    deny "Helper scripts are not on PATH, and the tree MOVES when installed as a
plugin. Resolve it first:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/<script>.sh\" ..."
fi

# 2. Blanket staging sweeps up .agent/, which is untracked working state.
#
#    Global git options are stripped before matching, because they sit BETWEEN
#    `git` and `add` and so defeated a `git[[:space:]]+add` pattern outright:
#    `git -C . add -A` and `git --no-pager add -A` both walked straight through.
#    Stripping a bounded list of known globals is deliberate -- a pattern loose
#    enough to skip arbitrary text would also match `git log --grep "add -A"`.
staging_line=$(sed -E '
    s/[[:space:]]+-(C|c)[[:space:]]+[^[:space:]]+//g
    s/[[:space:]]+--(git-dir|work-tree|namespace|exec-path)=[^[:space:]]+//g
    s/[[:space:]]+--(no-pager|paginate|bare|no-replace-objects|literal-pathspecs)([[:space:]]|$)/ /g
    s/[[:space:]]+-P([[:space:]]|$)/ /g
' <<< "$command_line" 2> /dev/null || printf '%s' "$command_line")

if grep -qE '(^|[[:space:];&|])git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$)' \
    <<< "$staging_line"; then
    # shellcheck disable=SC2016  # literal text, see deny()
    deny "git add -A stages .agent/ working state. Stage explicit paths, or use
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/worktree-commit.sh\""
fi

((${#roots[@]})) || allow

# 3. Board discovery when the board is already cached: seven calls become one.
#
#    Both helpers are named. Naming only the mover answered a question nobody
#    asked: a live agent denied here was trying to READ the board, found only a
#    move-status tool on offer, and hand-rolled its own GraphQL query instead.
if has_evidence .agent/board.json &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+project[[:space:]]+(list|item-list|field-list)' \
        <<< "$command_line"; then
    # shellcheck disable=SC2016  # literal text, see deny()
    deny "This repository declares its board in .agent/board.json. Use
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/triage-issues.sh\"          # to READ the board
  \"\$agentkit/parallel-issues/scripts/move-github-project-item.sh\"  # to move an item
Both resolve the ids from that file in a single call."
fi

# 4. Per-issue triage calls that one GraphQL query already covers.
if has_evidence .agent/config.env &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+(api[[:space:]]+[^[:space:]]*/timeline|issue[[:space:]]+view)' \
        <<< "$command_line"; then
    # shellcheck disable=SC2016  # literal text, see deny()
    deny "Per-issue triage calls are replaced by one query. Use
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/triage-issues.sh\"
which returns board status and cross-referenced pull requests together."
fi

allow
