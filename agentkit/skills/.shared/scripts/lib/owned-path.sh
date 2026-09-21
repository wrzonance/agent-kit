#!/usr/bin/env bash
# Side-effect-free diagnostics for workflow paths guarded by ownership.

# Print the specific validation failure and return 1, or print nothing and
# return 0. Callers retain their own error prefix and exit-code contract.
owned_path_diagnostic() {
    local path=$1 expected=$2 label=$3 producer=$4 noun
    case $expected in
        file) noun='regular file' ;;
        directory) noun=directory ;;
        *)
            printf 'internal error: unsupported owned path type: %s\n' "$expected"
            return 1
            ;;
    esac

    if [[ ! -e $path && ! -L $path ]]; then
        printf '%s is missing; run %s first: %s\n' "$label" "$producer" "$path"
        return 1
    fi
    if [[ -L $path ]]; then
        printf '%s must be an owned %s, not a symlink (path is a symlink): %s\n' \
            "$label" "$noun" "$path"
        return 1
    fi
    if [[ ! -O $path ]]; then
        printf '%s must be an owned %s, not a symlink (path is not owned by the current user): %s\n' \
            "$label" "$noun" "$path"
        return 1
    fi
    if [[ $expected == file && ! -f $path ]]; then
        printf '%s must be a regular file (path is not a regular file): %s\n' "$label" "$path"
        return 1
    fi
    if [[ $expected == directory && ! -d $path ]]; then
        printf '%s must be a directory (path is not a directory): %s\n' "$label" "$path"
        return 1
    fi
}
