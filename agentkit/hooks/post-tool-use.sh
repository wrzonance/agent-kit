#!/usr/bin/env bash
# PostToolUse -> teach after the fact. Structurally incapable of blocking.
#
# The command has already run and returned real data by the time this fires, so
# the agent pays for the call it wanted once and knows the cheaper route before
# the second. That is the whole design: no guard has to choose between teaching a
# lesson and letting the work proceed.
#
# Rests on one MEASURED fact: PostToolUse additionalContext reaches the model.
# Given a code word through this channel and then asked for it while forbidden
# from using any tool, a live agent returned it exactly. The runtime keeps this
# field distinct from systemMessage, which was not shown to reach the model and
# is not used here.
#
# NEVER exits non-zero, and never emits a decision of any kind.
set -uo pipefail

emit_empty() { printf '{}\n'; exit 0; }
GUARD_HOOK_NAME=post-tool-use
trap 'guard_log_error $? 2>/dev/null || true; emit_empty' ERR

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || emit_empty

# The literal "$agentkit/..." in every lesson is text for the agent to read and
# retype. Expanding it would resolve against this hook's environment and hand
# back a path instead of the resolver.
teach() {
    jq -nc --arg ctx "$1" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
    exit 0
}

# Reconstruct command text with heredoc BODY LINES removed, keeping everything
# else -- including the << token and the delimiter word -- so a match outside a
# heredoc is unaffected. Reuses guard_gh_command_segments' quote/heredoc state
# machine (sourced above from guard-lib.sh) instead of re-deriving one, so the
# two can never disagree on what counts as "inside a heredoc" (issue #299).
guard_strip_heredoc_bodies() {
    local segment out=''
    while IFS= read -r segment; do
        out+="$segment"$'\n'
    done < <(guard_gh_command_segments "$1")
    printf '%s' "$out"
}

# A double-quoted value containing $( or a backtick is not provably inert --
# bash executes a command substitution inside a double-quoted string, so
# redacting it wholesale could hide a path the shell genuinely resolves
# (adversarial review, issue #299). The bracket expressions below exclude $
# and ` from what a redactable run of characters may contain, so a match
# simply fails -- and the value passes through unredacted -- the moment either
# appears; a single-quoted value is always inert regardless of content and
# keeps no such exclusion.
#
# Blank the QUOTED value attached to a known body-bearing flag: --body/-b, or
# the body= value handed to -f/-F/--field/--raw-field. An unquoted value or a
# file-backed one (body=@file) is left alone -- this only covers what a
# command carries as an inline quoted payload, such as an issue/PR body under
# construction, never a path spelled without quotes.
guard_strip_body_flag_values() {
    local text
    text=$(sed -E '
        s/(--body|-b)([[:space:]]+)"([^"\\$`]|\\.)*"/\1\2"[REDACTED]"/g
        s/((-f|-F|--field|--raw-field)[[:space:]]+body=)"([^"\\$`]|\\.)*"/\1"[REDACTED]"/g
    ' <<< "$1" 2> /dev/null) || text=$1
    sed -E "
        s/(--body|-b)([[:space:]]+)'[^']*'/\1\2'[REDACTED]'/g
        s/((-f|-F|--field|--raw-field)[[:space:]]+body=)'[^']*'/\1'[REDACTED]'/g
    " <<< "$text" 2> /dev/null || printf '%s' "$text"
}

# True when a command carries the syntax that runs a nested command: $( or a
# backtick. Used to tell a heredoc body that is genuinely inert (a
# quoted-delimiter heredoc, or one with no such syntax at all) from one that
# is not provably so.
guard_command_has_expansion() {
    # shellcheck disable=SC2016  # the $( glob literal is intentional, not expansion
    [[ $1 == *'$('* || $1 == *'`'* ]]
}

# The text the pinned-plugin-path lesson (below) may judge. A raw command_line
# cannot tell a path being EXECUTED from one merely QUOTED as data -- inside a
# heredoc body building an issue/PR description, or as the value of a
# body-bearing gh flag -- so this narrows the match text to what a shell would
# actually try to resolve before that lesson's pattern runs against it.
#
# guard_strip_heredoc_bodies drops every heredoc body regardless of whether
# its delimiter was quoted, so it cannot tell an inert body from an EXPANDABLE
# one (<<EOF, unquoted delimiter) whose $(...) the shell actually runs. If
# stripping removed the only $(/backtick evidence in the command, that body is
# not provably inert -- fall back to the untouched text so a path inside it
# still reaches the matcher (adversarial review, issue #299).
guard_pinned_path_probe_text() {
    local raw=$1 stripped
    stripped=$(guard_strip_heredoc_bodies "$raw")
    if guard_command_has_expansion "$raw" && ! guard_command_has_expansion "$stripped"; then
        stripped=$raw
    fi
    guard_strip_body_flag_values "$stripped"
}

input=$(cat 2> /dev/null || true)
command_line=$(jq -r '.tool_input.command // empty' <<< "$input" 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
session=$(jq -r '.session_id // empty' <<< "$input" 2> /dev/null || true)
[[ -n $command_line ]] || emit_empty

guard_resolve_roots "$cwd" "$command_line"
guard_resolve_scope_roots "$cwd"
((${#roots[@]})) || emit_empty
state_root=$(guard_state_root)

# Board discovery. Every helper is named, and named ACCURATELY. Offered only a
# status-mover, an agent hand-rolled GraphQL; offered a digest that reports open
# issues, it correctly ignored the advice when the question was "what is on the
# board" -- the board also holds Done and non-issue items -- and spent three
# calls on the raw API instead. Advice that does not fit the question is worse
# than none: it teaches that the advice is not worth reading.
if guard_has_evidence .agent/board.json &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+project[[:space:]]+(list|item-list|field-list)' \
        <<< "$command_line" &&
    guard_should_advise "$state_root" "$session" board-read; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "This repository declares its board in .agent/board.json, so its ids do not
need discovering. Pick by the question you are answering:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/board-list.sh\"              # what is ON the board, by column
  \"\$agentkit/.shared/scripts/board-list.sh\" --issue N    # where is ONE issue right now
  \"\$agentkit/.shared/scripts/triage-issues.sh\"           # open issues + board status + PRs
  \"\$agentkit/parallel-issues/scripts/move-github-project-item.sh\"  # set one item Status
Each is a single call returning a compact digest, rather than raw JSON to parse.
To confirm a move, use --issue N once. Re-querying the whole board with a
hand-written jq filter gives a differently-shaped answer each time, and answers
that look like they disagree invite asking again -- which is a loop, not a check."
fi

# Per-issue triage. Reading ONE issue body is legitimate and stays that way --
# the digest deliberately omits bodies. What this replaces is walking every
# issue one call at a time. The first distinct issue number is deliberately
# quiet; a second number in the same session is the evidence that a digest is
# cheaper. Timeline fetches still advise immediately because they are never a
# single-body read.
issue_number=''
if [[ $command_line =~ (^|[[:space:];&|])gh[[:space:]]+issue[[:space:]]+view[[:space:]]+([0-9]+)([[:space:];&|]|$) ]]; then
    issue_number=${BASH_REMATCH[2]}
fi
if guard_has_evidence .agent/config.env &&
    [[ -n $issue_number ]] &&
    ! grep -qE '(^|[[:space:];&|])(cat|head|tail|sed|awk|grep|less|more|read)[^;|&]*\.agent/env-contract\.txt' \
        <<< "$command_line" &&
    guard_issue_view_is_distinct "$state_root" "$session" "$issue_number" &&
    guard_should_advise "$state_root" "$session" issue-triage; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "Triaging issues one at a time is replaced by one query:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/triage-issues.sh\"
It returns board status and cross-referenced pull requests for every candidate
together. Reading one issue body directly is still the right call; the first
body read in a session stays quiet, while a second distinct issue number means
the digest is cheaper. Timeline fetches are still covered by this advice."
fi

if guard_has_evidence .agent/config.env &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+api[[:space:]]+[^[:space:]]*/timeline' \
        <<< "$command_line" &&
    guard_should_advise "$state_root" "$session" issue-triage; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "Triaging issues one at a time is replaced by one query:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/triage-issues.sh\"
It returns board status and cross-referenced pull requests for every candidate
together. Timeline fetches and repeated per-issue exploration cost more than
the digest."
fi

# A hardcoded plugin path. Observed live: the resolver line came back empty, the
# call produced nothing, and the session recovered by pasting the absolute path
# it had seen -- including the VERSION directory -- and then used that for every
# later call in the session.
#
# It worked. It works right up until the version bumps, and then it fails as a
# path that no longer exists rather than as anything that names the cause. The
# tree moving is the whole reason the resolver exists, so this is the one place
# a working command still earns a correction.
#
# $command_line is the WHOLE command, so matching it directly cannot tell a
# path being EXECUTED from one merely QUOTED as data -- a heredoc body writing
# an issue description, or the value of a --body/-f body= flag, both of which
# were observed tripping this on prose that documented the hazard rather than
# committing it (issue #299). guard_pinned_path_probe_text narrows the match
# text to what the command would actually resolve before this pattern runs.
if grep -qE 'plugins/cache/[^[:space:]]*agentkit/[0-9]' \
        <<< "$(guard_pinned_path_probe_text "$command_line")" &&
    guard_should_advise "$state_root" "$session" pinned-plugin-path; then
    # A lesson that only names the hazard leaves the model to improvise a
    # remedy, and the one observed improvisation hand-deleted path segments
    # into a path that does not exist -- tripping the scope guard on top. So
    # when the repository's own contract already resolves the skills tree,
    # hand back the RESOLVED VALUE itself. Expanding it here is deliberate,
    # unlike the literal-$agentkit text elsewhere in this file: the resolved
    # directory IS the executable remedy. Trust bar matches RESOLVE_HINT's
    # own: untracked regular file, not a symlink, owned by this user.
    resolved_skills=''
    contract_file="$state_root/.agent/env-contract.txt"
    if [[ -n $state_root && -r $contract_file && -f $contract_file &&
        ! -L $contract_file && -O $contract_file ]] &&
        ! git -C "$state_root" ls-files --error-unmatch -- .agent/env-contract.txt \
            > /dev/null 2>&1; then
        resolved_skills=$(sed -n 's/^skills= path=//p' "$contract_file" 2> /dev/null | head -n 1)
        # The value is rendered into agent-facing text as a copyable shell
        # assignment, so only a plain absolute path qualifies: a space breaks
        # the assignment, and shell metacharacters would inject text into the
        # very command this lesson exists to correct. Anything else falls back
        # to the generic resolver.
        [[ $resolved_skills =~ ^/[A-Za-z0-9._/@+-]+$ && -d $resolved_skills ]] || resolved_skills=''
    fi
    if [[ -n $resolved_skills ]]; then
        # shellcheck disable=SC2016  # the $agentkit references are literal text, see teach()
        teach "That path has a version directory in it, so it stops resolving at the next
plugin update -- and it fails as a missing file, which does not say why.
This repository's environment contract already resolves the current tree. Use exactly:
  agentkit=$resolved_skills
That directory exists right now; build every helper path from \"\$agentkit\". Never
edit version segments out of a path by hand. If it stops resolving after a plugin
update, re-derive it:
$RESOLVE_HINT"
    else
        # shellcheck disable=SC2016  # literal text, see teach()
        teach "That path has a version directory in it, so it stops resolving at the next
plugin update -- and it fails as a missing file, which does not say why.
$RESOLVE_HINT
The find picks the highest version present, which is what you want even when
only one is installed. If it came back empty, the plugin is not installed where
this is looking; say so rather than substituting a literal path."
    fi
fi

# An escaped resolver. `\$` inside double quotes is a literal dollar, so the
# assignment stores the text `${CODEX_HOME:-$HOME/.codex}/skills` rather than a
# path -- and the run fails later as `no such file or directory:
# ${CODEX_HOME:-...}`, which names the symptom and not the cause. A live session
# burned two retries on exactly this before it worked out what had happened.
# The command has usually already failed by the time this fires; the point is to
# make the next attempt the corrected one instead of another guess.
# shellcheck disable=SC2016  # the pattern searches for a literal dollar
if grep -qE '\\\$(\{)?(CODEX_HOME|CLAUDE_CONFIG_DIR|HOME|agentkit)' <<< "$command_line" &&
    grep -q 'agentkit' <<< "$command_line" &&
    guard_should_advise "$state_root" "$session" escaped-resolver; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "The dollar signs in that resolver are escaped, so nothing expanded: the
variable now holds the literal text \"\${CODEX_HOME:-\$HOME/.codex}/skills\"
instead of a directory. Every path built from it points at a file that cannot
exist, and the error you get back names the missing file rather than the
escaping.
Paste the resolver block from the skill verbatim -- backslash-free -- and let
the shell expand it. Nothing in these blocks needs escaping; they are already
quoted for the shell that runs them."
fi

# Blanket staging. Correct ignore rules are what actually protect .agent/; this
# is a nudge toward the helper, and it gates nothing.
if grep -qE '(^|[[:space:];&|])git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$)' \
    <<< "$(guard_strip_git_globals "$command_line")" &&
    guard_should_advise "$state_root" "$session" staging; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "Blanket staging sweeps up .agent/ working state -- the environment contract
carries local paths and an account name. Ignore rules are the real protection
(bootstrap-repo.sh writes them); to stage and commit a worktree's own changes:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/worktree-commit.sh\""
fi

emit_empty
