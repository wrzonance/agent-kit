#!/usr/bin/env bash
# Shared private-directory creation and validation for artifact-producing
# helpers. The caller supplies die; failures remain fatal at the boundary.

private_dir_ensure() {
    local dir=$1 label=$2 current parent mode
    local base='' found_base=0 check_private=1
    local -a missing=()

    [[ -n $dir ]] || die "$label must name a directory"
    current=$dir
    while :; do
        [[ ! -L $current ]] ||
            die "$label must be an existing directory, not a symlink: $dir"
        if [[ -e $current ]]; then
            [[ -d $current ]] ||
                die "$label must be an existing directory, not a symlink: $dir"
            if (( ! found_base )); then
                mode=$(stat -c %a -- "$current") || die "could not inspect $label: $dir"
                [[ $mode == 700 ]] || die "$label must have mode 0700: $dir"
                [[ -O $current ]] || die "$label is not owned by this user: $dir"
                base=$current
                found_base=1
            fi
        else
            (( found_base )) || missing+=("$current")
        fi
        parent=$(dirname -- "$current")
        [[ $parent != "$current" ]] || break
        current=$parent
    done
    (( found_base )) || die "$label must be beneath an existing private mode-0700 directory: $dir"

    mkdir -p -- "$dir" || die "could not create private $label: $dir"
    local i
    for ((i = ${#missing[@]} - 1; i >= 0; i--)); do
        chmod 700 -- "${missing[i]}" || die "could not secure private $label: $dir"
    done

    # Recheck the requested path through its trusted private base after
    # creation, so an ancestor replacement cannot silently redirect a write.
    current=$dir
    while :; do
        [[ ! -L $current ]] ||
            die "$label must be an existing directory, not a symlink: $dir"
        [[ -d $current ]] ||
            die "$label must be an existing directory, not a symlink: $dir"
        if (( check_private )); then
            mode=$(stat -c %a -- "$current") || die "could not inspect $label: $dir"
            [[ $mode == 700 ]] || die "$label must have mode 0700: $dir"
            [[ -O $current ]] || die "$label is not owned by this user: $dir"
            [[ $current == "$base" ]] && check_private=0
        fi
        parent=$(dirname -- "$current")
        [[ $parent != "$current" ]] || break
        current=$parent
    done
}
