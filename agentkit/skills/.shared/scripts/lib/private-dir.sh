#!/usr/bin/env bash
# Shared private-directory creation and validation for artifact-producing
# helpers. The caller supplies die; failures remain fatal at the boundary.

private_dir_ensure() {
    local dir=$1 label=$2 current parent mode
    local -a missing=()

    [[ -n $dir ]] || die "$label must name a directory"
    current=$dir
    while :; do
        [[ ! -L $current ]] ||
            die "$label must be an existing directory, not a symlink: $dir"
        if [[ -e $current ]]; then
            [[ -d $current ]] ||
                die "$label must be an existing directory, not a symlink: $dir"
        else
            missing+=("$current")
        fi
        parent=$(dirname -- "$current")
        [[ $parent != "$current" ]] || break
        current=$parent
    done

    mkdir -p -- "$dir" || die "could not create private $label: $dir"
    local i
    for ((i = ${#missing[@]} - 1; i >= 0; i--)); do
        chmod 700 -- "${missing[i]}" || die "could not secure private $label: $dir"
    done

    # Recheck every lexical component after creation so a symlinked ancestor
    # cannot silently turn the requested path into a different directory.
    current=$dir
    while :; do
        [[ ! -L $current ]] ||
            die "$label must be an existing directory, not a symlink: $dir"
        [[ -d $current ]] ||
            die "$label must be an existing directory, not a symlink: $dir"
        parent=$(dirname -- "$current")
        [[ $parent != "$current" ]] || break
        current=$parent
    done

    mode=$(stat -c %a -- "$dir") || die "could not inspect $label: $dir"
    [[ $mode == 700 ]] || die "$label must have mode 0700: $dir"
    [[ -O $dir ]] || die "$label is not owned by this user: $dir"
}
