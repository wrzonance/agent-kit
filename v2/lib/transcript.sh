# shellcheck shell=bash
# Per-harness worker transcripts for ak wait: find one, say whether it ended, say how long it has been quiet.
# Facts: docs/superpowers/specs/2026-10-23-ak-wave-wait-spikes.md (S1, S3, Ruling 17).

# transcript_born PATH: when the transcript file was created (its birth, else its last write), in epoch seconds.
transcript_born() { file_birth "$1"; }

# path_named PATH: true when the first line on stdin names exactly PATH (not a longer path that starts with it).
path_named() {
    local esc
    esc=${1//[^A-Za-z0-9_\/-]/\\&}
    head -n 1 | grep -qE -- "(^|[^A-Za-z0-9._/-])${esc}([^A-Za-z0-9_/-]|\$)"
}

# transcript_claude WORKTREE SINCE: the newest sub-agent transcript of this root session, created at or after SINCE,
# whose first line names WORKTREE exactly.
transcript_claude() {
    local base file best=''
    base="$HOME/.claude/projects"
    while IFS= read -r file; do
        path_named "$1" <"$file" || continue
        (($(transcript_born "$file") >= ${2:-0})) || continue
        [[ -z $best || $file -nt $best ]] && best=$file
    done < <(find "$base" -path "$base/*/${CLAUDE_CODE_SESSION_ID:-*}/subagents/agent-*.jsonl" 2>/dev/null)
    [[ -z $best ]] || printf '%s\n' "$best"
}

# transcript_codex NAME SINCE: the newest child rollout of this root thread whose agent_path is /root/NAME.
# Spawn names use underscores; accept historical hyphenated paths too. Encrypted prompts cannot identify workers.
transcript_codex() {
    local file best=''
    [[ -n ${CODEX_THREAD_ID:-} && -n $1 ]] || return 0
    while IFS= read -r file; do
        (($(transcript_born "$file") >= ${2:-0})) || continue
        head -n 1 -- "$file" | grep -qF -- "$CODEX_THREAD_ID" || continue
        head -n 1 -- "$file" | jq -e --arg root "$CODEX_THREAD_ID" --arg a "/root/$1" --arg b "/root/${1//_/-}" \
            '.payload | (.parent_thread_id // .source.subagent.thread_spawn.parent_thread_id) == $root and (.agent_path | IN($a, $b))' \
            >/dev/null 2>&1 || continue
        [[ -z $best || $file -nt $best ]] && best=$file
    done < <(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name 'rollout-*.jsonl' -mtime -7 2>/dev/null)
    [[ -z $best ]] || printf '%s\n' "$best"
}

# transcript_find WORKTREE [NAME [SINCE]]: the transcript of the worker spawned at or after SINCE, or nothing. An older
# transcript of the same worktree belongs to the worker this one replaced.
transcript_find() {
    if [[ $(harness) == codex ]]; then transcript_codex "${2:-}" "${3:-0}"; else transcript_claude "$1" "${3:-0}"; fi
}

# transcript_state PATH: running, ended or errored. Claude marks an ended agent in its .meta.json (a stopped one has no
# terminal record); a Codex rollout ends with task_complete or turn_aborted as its last event.
transcript_state() {
    local file=$1 last kind
    if [[ -f ${file%.jsonl}.meta.json ]]; then
        jq -e '.finished == true' "${file%.jsonl}.meta.json" >/dev/null 2>&1 || { echo running; return 0; }
        kind=$(tail -n 1 -- "$file" | jq -r 'if (.isApiErrorMessage == true or (.error // null) != null) then "errored" else "ended" end' 2>/dev/null) || kind=ended
        echo "${kind:-ended}"
        return 0
    fi
    last=$(tail -n 40 -- "$file" | jq -rR 'fromjson? | select(.type == "event_msg") | .payload |
        [.type, (if (.error // null) != null or .reason == "error" then "error" else "" end)] | @tsv' | tail -n 1)
    case $last in
        task_complete* | turn_aborted*) [[ $last == *error ]] && echo errored || echo ended ;;
        *) echo running ;;
    esac
}

# transcript_age PATH: seconds since the transcript last grew.
transcript_age() {
    printf '%d\n' $(($(date +%s) - $(file_mtime "$1")))
}
