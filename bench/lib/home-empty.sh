#!/usr/bin/env bash
# bench/lib/home-empty.sh -- the design doc's "Home directory baked empty"
# control (Environment section): no global AGENTS.md, no rules/, no
# claude-mem, no memory hooks. Memory is stateful across trials -- trial N
# would otherwise contaminate trial N+1, "the control most likely to
# silently destroy the study" per the design doc. This file is what lets
# bench/run-trial.sh assert that control mechanically, rather than trusting
# that the container image happened to start clean.
#
# Source this file; do not execute it directly.

# The paths a live agent home directory accumulates state under, across
# both harnesses this repo supports (see agents.md's harness-neutrality
# convention -- this benchmark measures Codex, but the check names both so
# a future Claude-arm trial does not silently skip its own equivalent
# state).
_HOME_EMPTY_STATEFUL_PATHS=(
    'AGENTS.md'
    '.codex/AGENTS.md'
    '.codex/config.toml'
    '.codex/sessions'
    '.codex/rules'
    '.claude/CLAUDE.md'
    '.claude/rules'
    '.claude/projects'
    '.claude-mem'
)

# verify_empty_home DIR -- prints every stateful path found under DIR (one
# per line, to stderr) and returns 1 if any exist; returns 0 (silent) for a
# genuinely empty home. Never treats "directory does not exist yet" as a
# violation -- that is the state build_empty_home leaves before a container
# mounts and populates its own runtime files (e.g. a fresh .codex/config.toml
# containing only the pinned concurrency cap; see
# bench/lib/concurrency-cap-gate.sh) -- so this checks for the STATEFUL
# subset above, not for the directory being literally empty.
verify_empty_home() {
    local dir=$1
    local found=0 path
    [[ -d $dir ]] || {
        printf 'verify_empty_home: not a directory: %s\n' "$dir" >&2
        return 1
    }
    for path in "${_HOME_EMPTY_STATEFUL_PATHS[@]}"; do
        if [[ -e "$dir/$path" ]]; then
            printf 'verify_empty_home: stateful path present: %s\n' "$dir/$path" >&2
            found=1
        fi
    done
    return "$found"
}

# build_empty_home DIR -- destroys and recreates DIR as a fresh, empty
# directory (mode 0700, matching a real $HOME), then verifies it against
# verify_empty_home before returning -- a home that fails its own
# post-condition is a hard failure, never a silently-contaminated trial.
build_empty_home() {
    local dir=$1
    [[ -n $dir && $dir != / ]] || {
        printf 'build_empty_home: refusing an empty or root path: %s\n' "$dir" >&2
        return 1
    }
    rm -rf -- "$dir" || {
        printf 'build_empty_home: could not remove existing directory: %s\n' "$dir" >&2
        return 1
    }
    mkdir -p -- "$dir" || {
        printf 'build_empty_home: could not create directory: %s\n' "$dir" >&2
        return 1
    }
    chmod 0700 -- "$dir" || {
        printf 'build_empty_home: could not set permissions on: %s\n' "$dir" >&2
        return 1
    }
    verify_empty_home "$dir" || {
        printf 'build_empty_home: freshly built home failed its own emptiness check: %s\n' "$dir" >&2
        return 1
    }
    return 0
}
