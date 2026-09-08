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
            # Idempotent like mkdir -p: a concurrent caller may have created
            # this component between the scan and this mkdir; a directory that
            # landed anyway is accepted ONLY if it is actually private (a racing
            # creator that skipped the 0700 path, or a hostile pre-seed, is
            # not).
            [[ -d $component && ! -L $component ]] || return 1
            mode=$(stat -c %a -- "$component" 2>/dev/null) || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
    done
    return 0
}
