#!/usr/bin/env bash
# PostToolUse -> teach after the fact; structurally incapable of blocking. The
# command has already run, so the agent pays for the call it wanted once and
# knows the cheaper route before the second. Rests on a MEASURED fact:
# additionalContext reaches the model (systemMessage was not shown to). NEVER
# exits non-zero, never emits a decision.
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

# Blank the QUOTED value of a body-bearing flag (--body/-b, or
# -f/-F/--field/--raw-field body=): a single-quoted value is inert; a
# double-quoted one is redacted only when it carries no $( or backtick, since
# bash executes a substitution inside double quotes (issue #299 review).
# Unquoted or file-backed (body=@file) values pass through.
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

# The text the pinned-path and escaped-resolver lessons (below) may judge: only
# what the shell would actually resolve. guard_destructive_command_segments
# (guard-lib.sh) drops a quoted-delimiter heredoc body handed to an inert
# consumer, recovers the $(...)/backtick substitutions of an expandable body and
# the whole body of one handed to a shell (issues #299/#364); body-bearing gh
# flag values are then redacted. A quoted body that merely CONTAINS `$(` is
# inert and is never matched.
guard_pinned_path_probe_text() {
    local segment out=''
    while IFS= read -r segment; do
        out+="$segment"$'\n'
    done < <(guard_destructive_command_segments "$1")
    guard_strip_body_flag_values "$out"
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
    teach "This repository declares its board in .agent/board.json; do not rediscover its ids. Pick by question:
$RESOLVE_POINTER
  \"\$agentkit/.shared/scripts/board-list.sh\"              # what is ON the board, by column
  \"\$agentkit/.shared/scripts/board-list.sh\" --issue N    # where ONE issue is now (confirm a move with this, once)
  \"\$agentkit/.shared/scripts/triage-issues.sh\"           # open issues + board status + PRs
  \"\$agentkit/parallel-issues/scripts/move-github-project-item.sh\"  # set one item's Status
Each is one call returning a compact digest; a hand-written jq over the raw board answers differently each time."
fi

# Per-issue triage. Reading ONE issue body is legitimate and stays that way --
# the digest deliberately omits bodies. What this replaces is walking every
# issue one call at a time. The first distinct issue number is deliberately
# quiet; a second number in the same session is the evidence that a digest is
# cheaper. Timeline fetches still advise immediately because they are never a
# single-body read.
# A single issue's timeline is a per-issue read like its body (2026-09-08: one
# `.../issues/N/timeline` fetch was advised as triage), so both feed the same
# distinct-issue counter; only a timeline URL whose issue number cannot be
# parsed still advises immediately.
issue_number=''
if [[ $command_line =~ (^|[[:space:];&|])gh[[:space:]]+issue[[:space:]]+view[[:space:]]+([0-9]+)([[:space:];&|]|$) ]]; then
    issue_number=${BASH_REMATCH[2]}
elif [[ $command_line =~ (^|[[:space:];&|])gh[[:space:]]+api[[:space:]]+[^[:space:]]*/issues/([0-9]+)/timeline ]]; then
    issue_number=${BASH_REMATCH[2]}
fi
# shellcheck disable=SC2016  # literal text, see teach()
triage_lesson="Per-issue reads (gh issue view N, .../issues/N/timeline) across several issues are replaced by one query:
$RESOLVE_POINTER
  \"\$agentkit/.shared/scripts/triage-issues.sh\"   # board status + cross-referenced PRs for every candidate
Reading one issue body is still right -- the first body read in a session stays quiet; a second distinct issue number means the digest is cheaper."
if guard_has_evidence .agent/config.env &&
    [[ -n $issue_number ]] &&
    ! grep -qE '(^|[[:space:];&|])(cat|head|tail|sed|awk|grep|less|more|read)[^;|&]*\.agent/env-contract\.txt' \
        <<< "$command_line" &&
    guard_issue_view_is_distinct "$state_root" "$session" "$issue_number" &&
    guard_should_advise "$state_root" "$session" issue-triage; then
    teach "$triage_lesson"
fi

if [[ -z $issue_number ]] && guard_has_evidence .agent/config.env &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+api[[:space:]]+[^[:space:]]*/timeline' \
        <<< "$command_line" &&
    guard_should_advise "$state_root" "$session" issue-triage; then
    teach "$triage_lesson"
fi

# A hardcoded plugin path -- only a WRONG one. Observed: an empty resolver line
# made a session paste an absolute path and reuse it; the lesson then fired on a
# correct contract-resolved path, and the one improvisation swapped agent-kit
# (marketplace dir) for agentkit (plugin dir) -- issue #335 Case 1. Judged on
# guard_pinned_path_probe_text, never the raw command (issue #299).
probe_text=$(guard_pinned_path_probe_text "$command_line")
mapfile -t pinned_raw_matches < <(grep -oE \
    '[^[:space:]"'"'"']*plugins/cache/[^[:space:]"'"'"']*agentkit/[0-9][^[:space:]"'"'"']*' \
    <<< "$probe_text" 2> /dev/null)
# A leading NAME= assignment or $( opener and a trailing shell separator are
# syntax, not path (2026-09-08: `agentkit=/.../0.7.4/skills;` compared unequal
# to the very tree it named and was "corrected" to itself).
pinned_syntax_re='^[^/]*[=(`]([/~].*)$'
matched_path=''
if ((${#pinned_raw_matches[@]})); then
    # When the contract resolves the skills tree, hand back the RESOLVED VALUE
    # itself (a hazard-only lesson made a model hand-delete path segments).
    # Trust bar matches RESOLVE_HINT: untracked regular file, not a symlink,
    # owned by this user.
    resolved_skills=''
    contract_file=''
    # Harness-keyed first, legacy bare name as a read-only fallback (issue
    # #551) -- resolving the BARE, shared file here is exactly the bug this
    # lesson used to trip on: a second harness's SessionStart could rewrite
    # it with a DIFFERENT skills tree, and this check would then flag the
    # calling harness's own correct path as "wrong".
    [[ -z $state_root ]] || contract_file=$(contract_cache_contract_file "$state_root")
    if [[ -n $state_root && -n $contract_file && -r $contract_file && -f $contract_file &&
        ! -L $contract_file && -O $contract_file ]] &&
        ! git -C "$state_root" ls-files --error-unmatch -- "${contract_file#"$state_root"/}" \
            > /dev/null 2>&1; then
        resolved_skills=$(sed -n 's/^skills= path=//p' "$contract_file" 2> /dev/null | head -n 1)
        # The value is rendered into agent-facing text as a copyable shell
        # assignment, so only a plain absolute path qualifies: a space breaks
        # the assignment, and shell metacharacters would inject text into the
        # very command this lesson exists to correct. Anything else falls back
        # to the generic resolver.
        [[ $resolved_skills =~ ^/[A-Za-z0-9._/@+-]+$ && -d $resolved_skills ]] || resolved_skills=''
    fi
    # A command can carry more than one plugins/cache match -- e.g. a correct
    # agentkit=<tree> assignment followed by a stale helper path read from an
    # old checkout. Taking only the FIRST match let the correct assignment hide
    # a stale second one entirely (K1 review F1): normalise every match the same
    # way and teach on the first one that is NOT the contract-resolved tree,
    # judged below. Containment is LEXICAL (guard_scope_canonical resolves ..
    # components), never a string-prefix compare -- a textual compare would
    # count a stale path merely starting with the resolved tree's text as
    # correct (issue #335 review F2); a failed canonicalization counts as NOT
    # correct.
    for raw_match in "${pinned_raw_matches[@]}"; do
        candidate=$raw_match
        [[ $candidate =~ $pinned_syntax_re ]] && candidate=${BASH_REMATCH[1]}
        candidate=${candidate%%[;&|)]*}
        [[ -n $candidate ]] || continue
        candidate_is_correct=0
        if [[ -n $resolved_skills ]]; then
            canonical_candidate=$(guard_scope_canonical "$candidate") || canonical_candidate=''
            canonical_resolved=$(guard_scope_canonical "$resolved_skills") || canonical_resolved=''
            [[ -n $canonical_candidate && -n $canonical_resolved &&
                ( $canonical_candidate == "$canonical_resolved" ||
                  $canonical_candidate == "$canonical_resolved"/* ) ]] &&
                candidate_is_correct=1
        fi
        if ((! candidate_is_correct)); then
            matched_path=$candidate
            break
        fi
    done
fi
if [[ -n $matched_path ]]; then
    # The flagged path is a genuine mismatch (not the contract-resolved tree,
    # by the loop above) -- fall through to the advisory below, and,
    # critically, WITHOUT consuming guard_should_advise's once-per-session
    # claim when every match was correct: a genuinely stale path read later in
    # the same session must still get its own lesson, which a spent claim here
    # would silently swallow.
    if guard_should_advise "$state_root" "$session" pinned-plugin-path; then
        if [[ -n $resolved_skills && $resolved_skills == "$matched_path" ]]; then
            # Defensive only -- unreachable given path_is_correct above, which
            # excludes exact equality before we get here. A remedy that
            # equals the flagged path is a bug in the check, not something to
            # hand the agent; assert it into the error log, never print it.
            guard_log_error 'pinned-plugin-path-remedy-equals-input' 2> /dev/null || true
        elif [[ -n $resolved_skills ]]; then
            # shellcheck disable=SC2016  # the $agentkit reference is literal text, see teach()
            teach "Wrong plugin path -- marketplace dir is agent-kit, plugin dir is agentkit; the requested helper path did not resolve. Use exactly:
  agentkit=$resolved_skills"
        else
            # shellcheck disable=SC2016  # literal text, see teach()
            teach "Wrong plugin path -- marketplace dir is agent-kit, plugin dir is agentkit; the requested helper path did not resolve, and this checkout's contract names no usable skills tree. Re-run the resolver block from your session or worker context (contract file, else the plugins/cache bootstrap, which picks the highest installed version); if it comes back empty, say the plugin is not installed rather than substituting a literal path."
        fi
    fi
fi

# An escaped resolver: \$ inside double quotes is a literal dollar, so the
# assignment stores the ${CODEX_HOME:-...}/skills text and the run fails later
# naming the missing file, not the cause. Make the next attempt the corrected
# one.
# shellcheck disable=SC2016  # the pattern searches for a literal dollar
if grep -qE '\\\$(\{)?(CODEX_HOME|CLAUDE_CONFIG_DIR|HOME|agentkit)' <<< "$probe_text" &&
    grep -q 'agentkit' <<< "$probe_text" &&
    guard_should_advise "$state_root" "$session" escaped-resolver; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "The dollar signs in that resolver are escaped, so nothing expanded: the variable holds the literal text \"\${CODEX_HOME:-\$HOME/.codex}/skills\" instead of a directory, and every path built from it names a missing file. Paste the resolver block verbatim -- backslash-free; it is already quoted for the shell that runs it."
fi

# Blanket staging. Correct ignore rules are what actually protect .agent/; this
# is a nudge toward the helper, and it gates nothing.
if grep -qE '(^|[[:space:];&|])git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$)' \
    <<< "$(guard_strip_git_globals "$command_line")" &&
    guard_should_advise "$state_root" "$session" staging; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "Blanket staging sweeps up .agent/ working state (the contract carries local paths and an account name). Stage and commit a worktree's own changes with:
$RESOLVE_POINTER
  \"\$agentkit/.shared/scripts/worktree-commit.sh\" --exact --message SUBJECT -- FILES"
fi

emit_empty
