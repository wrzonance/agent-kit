#!/usr/bin/env bash
# Suite: agent-run.sh caches green named-command evidence by tree state.
set -uo pipefail

TEST_NAME='agent-run-verification-cache'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

real_run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir origin
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    origin=$(mktemp -d "$tmp/origin.XXXXXX")
    git -C "$dir" init -q -b main
    git -C "$dir" config user.name test
    git -C "$dir" config user.email test@example.invalid
    mkdir -p "$dir/.agent" "$dir/tools"
    # The command payload stays unchanged while unrelated tree edits exercise
    # cache invalidation in isolation.
    # shellcheck disable=SC2016  # fixture lines must retain child-shell expansion.
    printf '%s\n' \
        '#!/bin/sh' \
        'count=$(cat "$COUNT_FILE" 2>/dev/null || printf 0)' \
        'count=$((count + 1))' \
        'printf '\''%s'\'' "$count" > "$COUNT_FILE"' \
        'exit "${RESULT:-0}"' > "$dir/tools/run"
    chmod +x "$dir/tools/run"
    printf 'AGENT_CMD_TEST=tools/run\n' > "$dir/.agent/config.env"
    printf '.agent/*\n!.agent/config.env\n' > "$dir/.gitignore"
    printf 'base\n' > "$dir/tracked.txt"
    git -C "$dir" add -- .agent/config.env .gitignore tools/run tracked.txt
    git -C "$dir" commit -qm base
    git -C "$dir" init -q --bare "$origin"
    git -C "$dir" remote add origin "$origin"
    git -C "$dir" push -q origin HEAD:main
    git -C "$dir" fetch -q origin
    printf '%s' "$dir"
}

count() { cat -- "$1" 2>/dev/null || printf '0'; }

repo=$(make_repo)
counter="$tmp/count"

run_test() {
    (cd "$repo" && COUNT_FILE="$counter" \
        "$real_run_sh" --cmd test 2>&1)
}

out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'the first run executes the declared command'
assert_eq '1' "$(count "$counter")" 'the first run executes once'
cache=$(cat -- "$repo/.agent/verification-cache")
assert_contains "$cache" 'cmd=test log=' 'a green run records command and log evidence'
assert_contains "$cache" ' at=' 'a cache record carries a UTC timestamp'

out=$(run_test)
assert_contains "$out" 'agent-run: verification current:' 'an unchanged tree short-circuits'
assert_eq '1' "$(count "$counter")" 'a cache hit does not execute the command'

printf 'edited\n' > "$repo/tracked.txt"
out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'an unstaged tracked edit causes a cache miss'
assert_eq '2' "$(count "$counter")" 'the unstaged edit executes the command again'

git -C "$repo" add -- tracked.txt
out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'a staged tracked edit causes a cache miss'
assert_eq '3' "$(count "$counter")" 'the staged edit executes the command again'

touch "$repo/untracked.txt"
out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'an untracked addition causes a cache miss'
assert_eq '4' "$(count "$counter")" 'the untracked addition executes the command again'

printf 'changed\n' > "$repo/untracked.txt"
out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'changing an untracked file causes a cache miss'
assert_eq '5' "$(count "$counter")" 'the changed untracked file executes the command again'

# Give the intentionally failing invocation a tree state with no prior green
# evidence, so a cache hit cannot hide the failure.
touch "$repo/failure-state.txt"
rc=0
out=$(cd "$repo" && COUNT_FILE="$counter" RESULT=1 \
    "$real_run_sh" --cmd test 2>&1) || rc=$?
assert_eq '1' "$rc" 'a failing command returns its failure status'
assert_contains "$out" 'FAIL(rc=1)' 'a failing command reports failure'
assert_eq '6' "$(count "$counter")" 'the failing command executes'

out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'a run after failure is not served by a stale cache entry'
assert_eq '7' "$(count "$counter")" 'a failing run is never cached'

out=$(cd "$repo" && COUNT_FILE="$counter" \
    "$real_run_sh" --force --cmd test 2>&1)
assert_contains "$out" 'PASS: tools/run' '--force executes instead of short-circuiting'
assert_not_contains "$out" 'verification current:' '--force does not report a cache hit'
assert_eq '8' "$(count "$counter")" '--force executes the command'

# --- execution directory scopes cache evidence -----------------------------
scope_repo=$(make_repo)
mkdir -p "$scope_repo/one" "$scope_repo/two"
cp -- "$scope_repo/tools/run" "$scope_repo/one/tools-run"
cp -- "$scope_repo/tools/run" "$scope_repo/two/tools-run"
mkdir -p "$scope_repo/one/tools" "$scope_repo/two/tools"
mv -- "$scope_repo/one/tools-run" "$scope_repo/one/tools/run"
mv -- "$scope_repo/two/tools-run" "$scope_repo/two/tools/run"
git -C "$scope_repo" add -- one two
git -C "$scope_repo" commit -qm 'add scoped command payloads'
scope_counter="$tmp/scope-count"

run_scoped_test() {
    local run_dir=$1
    (cd "$scope_repo" && COUNT_FILE="$scope_counter" \
        "$real_run_sh" --dir "$run_dir" --cmd test 2>&1)
}

out=$(run_scoped_test "$scope_repo/one")
assert_contains "$out" 'PASS: tools/run' 'the first execution directory runs the command'
assert_eq '1' "$(count "$scope_counter")" 'the first execution directory executes once'
out=$(run_scoped_test "$scope_repo/two")
assert_contains "$out" 'PASS: tools/run' 'a different execution directory does not reuse evidence'
assert_eq '2' "$(count "$scope_counter")" 'the second execution directory executes independently'
out=$(run_scoped_test "$scope_repo/one")
assert_contains "$out" 'agent-run: verification current:' 'repeating an execution directory may hit'
assert_eq '2' "$(count "$scope_counter")" 'the repeated execution directory does not execute again'

# --- state-producing command names are not cached ---------------------------
build_repo=$(make_repo)
printf 'AGENT_CMD_BUILD=tools/run\n' > "$build_repo/.agent/config.env"
git -C "$build_repo" add -- .agent/config.env
git -C "$build_repo" commit -qm 'declare build command'
build_counter="$tmp/build-count"

run_build() {
    (cd "$build_repo" && COUNT_FILE="$build_counter" \
        "$real_run_sh" --cmd build 2>&1)
}

out=$(run_build)
assert_contains "$out" 'PASS: tools/run' 'a build command executes the first time'
assert_eq '1' "$(count "$build_counter")" 'the first build executes once'
out=$(run_build)
assert_contains "$out" 'PASS: tools/run' 'a build command executes again on unchanged bytes'
assert_not_contains "$out" 'verification current:' 'a build command never uses verification cache evidence'
assert_eq '2' "$(count "$build_counter")" 'the unchanged build executes twice'
build_cache=$(cat -- "$build_repo/.agent/verification-cache" 2>/dev/null || true)
assert_not_contains "$build_cache" 'cmd=build ' 'a build command is never recorded in verification cache'

# --- the focus selector is part of the cache key --------------------------
# Green evidence for `--only ALPHA` must never satisfy `--only BETA` or a full
# unfocused run: they verify different things on identical bytes. The selector
# is folded into compute_tree_hash, so the cache key differs; this pins that,
# because nothing else in the suite exercised --only at all.
focus_repo=$(make_repo)
printf 'AGENT_CMD_TEST=tools/run\nAGENT_CMD_TEST_FOCUS=tools/run %%s\n' \
    > "$focus_repo/.agent/config.env"
git -C "$focus_repo" add -- .agent/config.env
git -C "$focus_repo" commit -qm 'declare focused test command'
focus_counter="$tmp/focus-count"
run_focus() { # $1 = --only value, or empty
    if [[ -n $1 ]]; then
        (cd "$focus_repo" && COUNT_FILE="$focus_counter" \
            "$real_run_sh" --cmd test --only "$1" 2>&1)
    else
        (cd "$focus_repo" && COUNT_FILE="$focus_counter" \
            "$real_run_sh" --cmd test 2>&1)
    fi
}

out=$(run_focus ALPHA)
assert_not_contains "$out" 'verification current:' 'the first focused run executes'
out=$(run_focus ALPHA)
assert_contains "$out" 'verification current:' 'the same selector on unchanged bytes hits the cache'

out=$(run_focus BETA)
assert_not_contains "$out" 'verification current:' \
    'a different selector does not reuse the first selector evidence'

out=$(run_focus '')
assert_not_contains "$out" 'verification current:' \
    'the unfocused full run does not reuse focused evidence'

finish
