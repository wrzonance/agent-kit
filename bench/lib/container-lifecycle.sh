#!/usr/bin/env bash
# bench/lib/container-lifecycle.sh -- one container per trial, destroyed
# after (design doc "Environment": "per trial, not per arm, because
# ~/.codex/sessions accumulates"). This file is the single place that
# builds, runs, and destroys a trial container, and the single place that
# proves destruction actually happened -- so bench/run-trial.sh never has to
# improvise a `docker` invocation inline, and a lifecycle bug shows up here
# once instead of at every call site.
#
# Dry-run mode (BENCH_CONTAINER_DRY_RUN=1, or --dry-run on the functions
# below) never shells out to `docker` at all. It simulates the same state
# machine -- build marks an image "built", run marks a container "running"
# with a fresh, empty state directory standing in for the mounted home,
# destroy removes that state -- against plain marker files under
# --state-dir. This is what lets tests/test-bench-harness.sh exercise the
# full lifecycle sequencing and the destruction proof deterministically,
# without docker, network, or the minutes a real image build costs (see
# bench/container/README.md's "Building" section for why CI never builds
# the real image).
#
# Source this file; do not execute it directly.

# _container_dry_run DRY_RUN_ARG -- true when dry-run mode applies, via
# either spelling the header above documents: the positional --dry-run
# argument every function below accepts, or BENCH_CONTAINER_DRY_RUN=1 in
# the environment. Every function checks both through this one helper so
# the two spellings cannot silently drift apart (a caller relying on the
# env var while only the flag was actually honored is exactly how this bug
# shipped the first time -- issue #327 PR #389 review finding F2).
_container_dry_run() {
    [[ ${1:-} == --dry-run || ${BENCH_CONTAINER_DRY_RUN:-} == 1 ]]
}

# container_build STATE_DIR IMAGE_TAG DOCKERFILE_DIR [--dry-run]
container_build() {
    local state_dir=$1 image_tag=$2 dockerfile_dir=$3 dry_run=${4:-}
    mkdir -p -- "$state_dir" || return 1
    if _container_dry_run "$dry_run"; then
        printf '%s\n' "$image_tag" > "$state_dir/built-image"
        printf 'container_build (dry-run): would build %s from %s\n' "$image_tag" "$dockerfile_dir"
        return 0
    fi
    command -v docker > /dev/null 2>&1 || {
        printf 'container_build: docker is required and was not found on PATH\n' >&2
        return 1
    }
    docker build -t "$image_tag" "$dockerfile_dir" || return 1
    printf '%s\n' "$image_tag" > "$state_dir/built-image"
}

# container_run STATE_DIR CONTAINER_NAME IMAGE_TAG HOME_DIR [--dry-run]
#
# HOME_DIR is the baked-empty home (bench/lib/home-empty.sh) mounted as the
# container's own $HOME. Secrets are read from this process's own
# environment and passed with -e, never written to a file the image or a
# log could retain (bench/container/README.md's "Secrets" section).
container_run() {
    local state_dir=$1 name=$2 image_tag=$3 home_dir=$4 dry_run=${5:-}
    [[ -f "$state_dir/built-image" ]] || {
        printf 'container_run: no image built in %s -- call container_build first\n' "$state_dir" >&2
        return 1
    }
    if [[ -e "$state_dir/running-$name" ]]; then
        printf 'container_run: a container named %s is already running in this state dir -- one trial per container\n' "$name" >&2
        return 1
    fi
    if _container_dry_run "$dry_run"; then
        printf '%s\n' "$home_dir" > "$state_dir/running-$name"
        printf 'container_run (dry-run): would run %s from image %s with HOME=%s\n' "$name" "$image_tag" "$home_dir"
        return 0
    fi
    command -v docker > /dev/null 2>&1 || {
        printf 'container_run: docker is required and was not found on PATH\n' >&2
        return 1
    }
    docker run -d --name "$name" \
        -v "$home_dir:/home/bench:rw" \
        -e "GH_TOKEN=${GH_TOKEN:-}" \
        -e "CODEX_API_KEY=${CODEX_API_KEY:-}" \
        "$image_tag" sleep infinity \
        > /dev/null || return 1
    printf '%s\n' "$home_dir" > "$state_dir/running-$name"
}

# container_destroy STATE_DIR CONTAINER_NAME [--dry-run]
#
# Returns non-zero -- and leaves the running-marker in place -- when
# `docker rm -f` itself fails, rather than discarding its exit status and
# reporting success regardless (PR #389 review finding F3): a container
# this function could not actually remove must never be reported as
# destroyed.
container_destroy() {
    local state_dir=$1 name=$2 dry_run=${3:-}
    if _container_dry_run "$dry_run"; then
        rm -f -- "$state_dir/running-$name"
        printf 'container_destroy (dry-run): would destroy %s\n' "$name"
        return 0
    fi
    command -v docker > /dev/null 2>&1 || {
        printf 'container_destroy: docker is required and was not found on PATH\n' >&2
        return 1
    }
    local destroy_output
    if ! destroy_output=$(docker rm -f "$name" 2>&1); then
        printf 'container_destroy: docker rm -f failed for %s -- it may still be running, refusing to report success:\n%s\n' \
            "$name" "$destroy_output" >&2
        return 1
    fi
    rm -f -- "$state_dir/running-$name"
}

# container_is_destroyed STATE_DIR CONTAINER_NAME [--dry-run]
#
# The harness's own proof that a trial's container is gone before the next
# trial starts (acceptance criterion: "per-trial container destruction
# verified by the harness itself"). Returns 0 when destroyed, 1 when a
# container by this name is still live -- checked against the real docker
# daemon in live mode, never inferred from having merely called
# container_destroy.
container_is_destroyed() {
    local state_dir=$1 name=$2 dry_run=${3:-}
    if _container_dry_run "$dry_run"; then
        [[ ! -e "$state_dir/running-$name" ]]
        return
    fi
    command -v docker > /dev/null 2>&1 || {
        printf 'container_is_destroyed: docker is required and was not found on PATH\n' >&2
        return 1
    }
    # docker ps's own exit status is checked, not just its (possibly empty
    # on failure) stdout: a failed query used to read identically to "no
    # matching container", which would let a real docker outage report a
    # live container as destroyed (PR #389 review finding F3).
    local ps_output
    if ! ps_output=$(docker ps -aq -f "name=^${name}$" 2>&1); then
        printf 'container_is_destroyed: docker ps failed -- cannot confirm %s is actually gone:\n%s\n' "$name" "$ps_output" >&2
        return 1
    fi
    [[ -z $ps_output ]]
}
