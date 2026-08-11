#!/usr/bin/env bash
# Suite: agent-run.sh caches green named-command evidence by tree state.
set -uo pipefail

TEST_NAME='agent-run-verification-cache'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

real_run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tty_approve="$here/lib/tty-approve"
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
    # cache invalidation without tripping the command trust gate.
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
trust_root="$tmp/trust"
(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$real_run_sh" --approve --cmd test) > /dev/null 2>&1

run_test() {
    (cd "$repo" && COUNT_FILE="$counter" AGENT_TRUST_ROOT="$trust_root" \
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

# Give the intentionally failing invocation a tree state with no prior green
# evidence, so a cache hit cannot hide the failure.
touch "$repo/failure-state.txt"
rc=0
out=$(cd "$repo" && COUNT_FILE="$counter" RESULT=1 AGENT_TRUST_ROOT="$trust_root" \
    "$real_run_sh" --cmd test 2>&1) || rc=$?
assert_eq '1' "$rc" 'a failing command returns its failure status'
assert_contains "$out" 'FAIL(rc=1)' 'a failing command reports failure'
assert_eq '5' "$(count "$counter")" 'the failing command executes'

out=$(run_test)
assert_contains "$out" 'PASS: tools/run' 'a run after failure is not served by a stale cache entry'
assert_eq '6' "$(count "$counter")" 'a failing run is never cached'

out=$(cd "$repo" && COUNT_FILE="$counter" AGENT_TRUST_ROOT="$trust_root" \
    "$real_run_sh" --force --cmd test 2>&1)
assert_contains "$out" 'PASS: tools/run' '--force executes instead of short-circuiting'
assert_not_contains "$out" 'verification current:' '--force does not report a cache hit'
assert_eq '7' "$(count "$counter")" '--force executes the command'

# Seed a would-be hit for the changed declaration, then prove the command trust
# gate still refuses before it can inspect or use that cache entry.
printf 'AGENT_CMD_TEST=sh -c true\n' > "$repo/.agent/config.env"
tree_hash=$(
    {
        git -C "$repo" rev-parse HEAD
        git -C "$repo" diff HEAD
        git -C "$repo" status --porcelain=v2
    } | sha256sum | awk '{print $1}'
)
log=$(find "$repo/.agent/logs" -name '*-test.log' -type f | sort | tail -1)
printf '%s cmd=test log=%s at=2026-01-01T00:00:00Z\n' "$tree_hash" "$log" \
    > "$repo/.agent/verification-cache"
rc=0
out=$(cd "$repo" && COUNT_FILE="$counter" AGENT_TRUST_ROOT="$trust_root" \
    "$real_run_sh" --cmd test 2>&1) || rc=$?
assert_eq '1' "$rc" 'the trust gate still refuses a changed declaration'
assert_contains "$out" 'refusing unapproved repository command' 'trust refusal is reported before cache lookup'
assert_not_contains "$out" 'verification current:' 'a would-be hit cannot bypass the trust gate'
assert_eq '7' "$(count "$counter")" 'trust refusal never executes the command'

finish
