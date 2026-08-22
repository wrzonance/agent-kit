#!/usr/bin/env bash
# bench/lib/ledger-append.sh -- append one line to a bench/results/*.jsonl
# ledger, the same append-only, symlink-refusing discipline bench/tier0.sh
# uses inline (bench/README's "Append-only" section). Extracted here rather
# than copied because bench/run-trial.sh needed the exact same guarantee for
# a second ledger file (bench/results/tier1.jsonl) and a second inline copy
# is exactly the kind of divergence-prone duplication code.md's DRY guidance
# warns about. bench/tier0.sh itself is outside this issue's declared write
# set and keeps its own inline copy rather than being retrofitted to source
# this file.
#
# Source this file; do not execute it directly.

# ledger_append LEDGER_PATH JSON_LINE
#
# JSON_LINE must already be one complete, single-line JSON object (build it
# with jq before calling this -- this function does not validate JSON
# shape, only that the append itself is safe). Creates the ledger's parent
# directory if needed. Refuses to write through a symlink, and refuses a
# JSON_LINE containing an embedded newline (which would silently split into
# two ledger rows).
ledger_append() {
    local ledger=$1 line=$2
    [[ $line != *$'\n'* ]] || {
        printf 'ledger_append: JSON_LINE must not contain an embedded newline: %s\n' "$ledger" >&2
        return 1
    }
    local ledger_dir
    ledger_dir=$(dirname -- "$ledger")
    mkdir -p -- "$ledger_dir" || {
        printf 'ledger_append: could not create ledger directory: %s\n' "$ledger_dir" >&2
        return 1
    }
    [[ ! -e $ledger || ! -L $ledger ]] || {
        printf 'ledger_append: refusing to append through a symlink: %s\n' "$ledger" >&2
        return 1
    }
    printf '%s\n' "$line" >> "$ledger" || {
        printf 'ledger_append: could not append to ledger: %s\n' "$ledger" >&2
        return 1
    }
}
