#!/usr/bin/env bash
# Probe hook: record the raw payload, decide nothing.
#
# Deliberately opinion-free. It emits {} on every event so it cannot deny, cannot
# halt, and cannot perturb the behaviour being measured -- the point is to learn
# what the runtime SENDS, not to react to it.
set -uo pipefail

emit() { printf '{}\n'; exit 0; }
trap 'emit' ERR

log_dir=${AGENTKIT_PROBE_DIR:-$HOME/.agentkit-probe}
input=$(cat 2> /dev/null || true)
[[ -n $input ]] || emit

mkdir -p "$log_dir" 2> /dev/null || emit

# One payload per line. jq collapses a pretty-printed payload into a single
# record; without it a multi-line payload would corrupt every later line.
if ! jq -c . <<< "$input" >> "$log_dir/payloads.jsonl" 2> /dev/null; then
    tr -d '\n' <<< "$input" >> "$log_dir/payloads.jsonl" 2> /dev/null || true
    printf '\n' >> "$log_dir/payloads.jsonl" 2> /dev/null || true
fi

emit
