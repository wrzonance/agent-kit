#!/usr/bin/env bash
# Read the probe log and report what the runtime actually sends.
#
# Answers P3 (can a hook tell a worker from the main session?) from recorded
# evidence. P1/P2 -- whether PostToolUse context reaches the model -- cannot be
# read from a log: it is answered by whether the agent could repeat the code
# word, which only the live session shows.
set -uo pipefail

log_dir=${AGENTKIT_PROBE_DIR:-$HOME/.agentkit-probe}
log="$log_dir/payloads.jsonl"

if [[ ! -r $log ]]; then
    printf 'No probe log at %s\n' "$log" >&2
    printf 'Run the session in tests/probe/README.md first.\n' >&2
    exit 1
fi

# Parse per line and drop anything unparseable. The recorder deliberately keeps
# a payload it could not parse -- that is forensic evidence in its own right --
# so the reader must tolerate a line that is not JSON rather than abort on it.
records=$(jq -Rc 'fromjson? // empty' "$log" 2> /dev/null || true)
malformed=$(($(grep -c . "$log" 2> /dev/null || echo 0) - $(grep -c . <<< "$records" || echo 0)))

if [[ -z $records ]]; then
    printf 'The log holds no parseable payloads (%s lines).\n' "$malformed" >&2
    exit 1
fi

q() { jq -r "$1" <<< "$records" 2> /dev/null || true; }

printf '== events recorded\n'
q '.hook_event_name // "?"' | sort | uniq -c | sort -rn
[[ $malformed -le 0 ]] || printf '   (%d unparseable line(s) skipped)\n' "$malformed"

printf '\n== fields present, by event\n'
q '(.hook_event_name // "?") + "  " + ([keys[]] | join(","))' | sort -u

printf '\n== P3: is a worker distinguishable?\n'
# agent_type is the field the binary lists among hook inputs. If PreToolUse
# carries it inside a worker, Layer 2 can be suppressed there precisely rather
# than relying on the override sentence alone.
printf -- '-- agent_type values seen\n'
seen=$(q 'select(.agent_type != null)
    | (.hook_event_name // "?") + "  agent_type=" + (.agent_type | tostring)' | sort | uniq -c)
printf '%s\n' "${seen:-   none}"

printf -- '-- distinct session ids\n'
q '.session_id // empty' | sort -u | sed 's/^/   /'

with=$(q 'select(.hook_event_name == "PreToolUse" and .agent_type != null) | "x"' | grep -c . || true)
total=$(q 'select(.hook_event_name == "PreToolUse") | "x"' | grep -c . || true)
printf -- '-- PreToolUse payloads carrying agent_type: %s of %s\n' "$with" "$total"

printf '\n== verdict\n'
if ((total == 0)); then
    printf '   INCONCLUSIVE  no PreToolUse recorded -- the worker must run a SHELL\n'
    printf '                 command, not just read a file, or the hook never fires.\n'
elif ((with > 0)); then
    printf '   P3 YES  PreToolUse carries agent_type; a worker can be identified.\n'
else
    printf '   P3 NO   PreToolUse never carried agent_type. Suppressing guards for\n'
    printf '           workers is not possible from this field; the override\n'
    printf '           sentence remains the floor.\n'
fi
