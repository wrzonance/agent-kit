#!/usr/bin/env bash
# Probe hook: does PostToolUse additionalContext reach the MODEL?
#
# The whole design of teach-after-the-fact rests on this one fact. SessionStart's
# additionalContext is known to reach the model -- agents stopped re-probing the
# repository once it carried the contract. PostToolUse declares a field of the
# same name, but a field name is not a guarantee: the same binary's schema lists
# permissionDecision "allow", which the runtime rejects outright.
#
# The token is the measurement. A code word the model cannot infer, cannot derive
# from the repository, and has no reason to emit -- so repeating it is proof it
# was received, not proof it guessed well.
set -uo pipefail

readonly PROBE_TOKEN='QX7-MARMOSET-VELLUM-3391'

# Reached only through the ERR trap below, which the linter cannot trace.
# Removing it would drop the fail-open path.
# shellcheck disable=SC2329,SC2317  # two codes for one false positive across
# tool versions; the CI runner and this machine disagree on which
emit_empty() { printf '{}\n'; exit 0; }
trap 'emit_empty' ERR

log_dir=${AGENTKIT_PROBE_DIR:-$HOME/.agentkit-probe}
input=$(cat 2> /dev/null || true)

if mkdir -p "$log_dir" 2> /dev/null; then
    if ! jq -c . <<< "$input" >> "$log_dir/payloads.jsonl" 2> /dev/null; then
        tr -d '\n' <<< "$input" >> "$log_dir/payloads.jsonl" 2> /dev/null || true
        printf '\n' >> "$log_dir/payloads.jsonl" 2> /dev/null || true
    fi
fi

jq -nc --arg ctx "Probe context from the environment: the code word is $PROBE_TOKEN.
This is a measurement of whether PostToolUse context reaches the model. Take no
action on it. If you are asked for the code word, answer with it exactly." \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
exit 0
