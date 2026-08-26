#!/usr/bin/env bash
# secure_mkdir_p -- create a directory (and any missing intermediate
# components) at mode 0700 regardless of the ambient umask.
#
# WHY THIS EXISTS (issue #474)
#   Every `.agent` directory the kit creates is meant to satisfy the kit's
#   own private-directory validators (session-ledger.sh's validate_parent,
#   private_dir_ensure). A plain `mkdir -p` inherits the ambient umask, so on
#   a `umask 002` machine (shared-group setups, WSL) the directory the kit
#   just created comes out 0775 -- group-writable -- and its own validator
#   then refuses it. `mkdir -m MODE` sets the given mode outright rather than
#   masking it against umask (the idiom already used by run-dir.sh and
#   parallel-issues/SKILL.md's dispatch-reports directory), so every
#   component this function creates is 0700 from the moment it exists, no
#   umask involved.
#
# A path that already exists (in whole or in part) is left untouched --
# validating an existing directory's mode is the caller's job, not this
# helper's; auto-fixing it here would silently paper over a directory the
# kit did not create. Returns 1, without printing anything, if any missing
# component could not be created, so each caller keeps its own error/
# fallback semantics (a hard `die`, or a soft `note`-and-continue).

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
