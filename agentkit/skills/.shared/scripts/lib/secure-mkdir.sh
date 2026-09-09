#!/usr/bin/env bash
# secure_mkdir_p -- create a directory (and missing intermediates) at mode 0700
# regardless of umask (`mkdir -m` sets the mode outright; issue #474: a plain
# mkdir -p under umask 002 produced group-writable .agent dirs the kit's own
# validators then refused). Existing components are left untouched -- validating
# them is the caller's job. Returns 1, printing nothing, when a component could
# not be created, so each caller keeps its own die/note semantics.

secure_mkdir_p() {
    local dir=$1 current parent
    local -a missing=()

    [[ -n $dir ]] || return 1

    current=$dir
    while [[ ! -e $current ]]; do
        missing+=("$current")
        parent=$(dirname -- "$current")
        [[ $parent != "$current" ]] || break
        current=$parent
    done

    local i component mode
    for ((i = ${#missing[@]} - 1; i >= 0; i--)); do
        component=${missing[i]}
        if ! mkdir -m 700 -- "$component" 2>/dev/null; then
            # Idempotent like the `mkdir -p` this replaces: a concurrent
            # caller (e.g. two overlapping ledger appends racing to create
            # the same not-yet-existing parent) may have won the race for
            # this exact component between the scan above and this mkdir. A
            # directory that landed there anyway is fine ONLY if it is
            # actually private -- a racing creator that did not go through
            # this same mode-0700 path (or a hostile pre-seed racing the
            # scan) must not be silently accepted just because it exists.
            [[ -d $component && ! -L $component ]] || return 1
            mode=$(stat -c %a -- "$component" 2>/dev/null) || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
    done
    return 0
}
