#!/usr/bin/env bash
# bench/lib/concurrency-cap-gate.sh -- the design doc's "first-order
# confounder" control (Environment section): both arms must read an
# identical, present max_concurrent_threads_per_session before any trial
# spends a token, or the run aborts.
#
# Reuses agentkit/skills/parallel-issues/scripts/concurrency-cap.sh -- the
# same parser the shipped skill itself uses to read this value at dispatch
# time -- rather than a second awk/toml parser here that could silently
# disagree with it about the same file (see code.md's "reuse before
# reinventing"). That script is outside this issue's declared write set
# (frozen from this slice's point of view); this file only calls it twice
# and compares the two outputs.
#
# Source this file; do not execute it directly.

# concurrency_cap_gate OLD_CONFIG NEW_CONFIG [CAP_SCRIPT]
#
# OLD_CONFIG / NEW_CONFIG: paths to each arm's ~/.codex/config.toml (or a
# test fixture shaped like one). CAP_SCRIPT defaults to the real
# agentkit/skills/parallel-issues/scripts/concurrency-cap.sh resolved
# relative to this file; a caller may override it in tests.
#
# Prints `cap=N` to stdout and returns 0 when both arms report the same
# positive integer cap. Returns 1 -- printing the diagnosis to stderr, never
# just an exit code -- when either config is missing the key (absent must
# abort before spend, per the design doc) or the two arms disagree.
concurrency_cap_gate() {
    local old_config=$1 new_config=$2
    local cap_script=${3:-}
    local lib_dir
    lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    [[ -n $cap_script ]] || cap_script="$lib_dir/../../agentkit/skills/parallel-issues/scripts/concurrency-cap.sh"

    [[ -x $cap_script ]] || {
        printf 'concurrency_cap_gate: concurrency-cap.sh not found or not executable: %s\n' "$cap_script" >&2
        return 1
    }

    local old_out old_rc=0 new_out new_rc=0
    old_out=$("$cap_script" --config "$old_config" --spawn-capable 2>&1) || old_rc=$?
    new_out=$("$cap_script" --config "$new_config" --spawn-capable 2>&1) || new_rc=$?

    if ((old_rc != 0)); then
        printf 'concurrency_cap_gate: old arm -- cap absent or unreadable, aborting before spend:\n%s\n' "$old_out" >&2
        return 1
    fi
    if ((new_rc != 0)); then
        printf 'concurrency_cap_gate: new arm -- cap absent or unreadable, aborting before spend:\n%s\n' "$new_out" >&2
        return 1
    fi

    local old_cap new_cap
    old_cap=$(grep -oE '[0-9]+' <<< "$old_out" | head -n1)
    new_cap=$(grep -oE '[0-9]+' <<< "$new_out" | head -n1)

    if [[ -z $old_cap || -z $new_cap ]]; then
        printf 'concurrency_cap_gate: could not extract a numeric cap from concurrency-cap.sh output\nold: %s\nnew: %s\n' \
            "$old_out" "$new_out" >&2
        return 1
    fi

    if [[ $old_cap != "$new_cap" ]]; then
        printf 'concurrency_cap_gate: caps differ between arms -- old=%s new=%s. A differing cap silently changes parallelism and invalidates every token figure; aborting before spend.\n' \
            "$old_cap" "$new_cap" >&2
        return 1
    fi

    printf 'cap=%s\n' "$old_cap"
    return 0
}
