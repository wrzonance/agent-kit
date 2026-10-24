# shellcheck shell=bash
# Per-harness worker transcripts for ak wait: find one, say whether it ended, say how long it has been quiet.
# Facts: docs/superpowers/specs/2026-10-23-ak-wave-wait-spikes.md (S1, S3, Ruling 17).

# transcript_claude WORKTREE: the newest sub-agent transcript of this root session whose first line names WORKTREE.
transcript_claude() {
    local base file best=''
    base="$HOME/.claude/projects/$(main_root | tr -c 'a-zA-Z0-9\n' '-')"
    while IFS= read -r file; do
        head -n 1 -- "$file" | grep -qF -- "$1" || continue
        [[ -z $best || $file -nt $best ]] && best=$file
    done < <(find "$base" -path "$base/${CLAUDE_CODE_SESSION_ID:-*}/subagents/agent-*.jsonl" 2>/dev/null)
    [[ -z $best ]] || printf '%s\n' "$best"
}

# transcript_codex NAME: the newest child rollout of this root thread whose agent_path is /root/NAME. Codex lowercases and
# underscores task names, so issue-5 is also looked for as issue_5. Spawn prompts are encrypted: never match on them.
transcript_codex() {
    local file best=''
    [[ -n ${CODEX_THREAD_ID:-} && -n $1 ]] || return 0
    while IFS= read -r file; do
        head -n 1 -- "$file" | grep -qF -- "$CODEX_THREAD_ID" || continue
        head -n 1 -- "$file" | jq -e --arg root "$CODEX_THREAD_ID" --arg a "/root/$1" --arg b "/root/${1//-/_}" \
            '.payload | (.parent_thread_id // .source.subagent.thread_spawn.parent_thread_id) == $root and (.agent_path | IN($a, $b))' \
            >/dev/null 2>&1 || continue
        [[ -z $best || $file -nt $best ]] && best=$file
    done < <(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name 'rollout-*.jsonl' -mtime -7 2>/dev/null)
    [[ -z $best ]] || printf '%s\n' "$best"
}

# transcript_find WORKTREE [NAME]: the worker's transcript path, or nothing.
transcript_find() {
    if [[ $(harness) == codex ]]; then transcript_codex "${2:-}"; else transcript_claude "$1"; fi
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
    printf '%d\n' $(($(date +%s) - $(stat -c %Y -- "$1")))
}
