#!/usr/bin/env bash
# Suite: provider capability resolution and safe fallback behavior.
set -uo pipefail

TEST_NAME='review-provider-config'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

resolver="$root/agentkit/skills/.shared/scripts/review-provider-config.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local value=$1 repo=$tmp/repo
    rm -rf -- "$repo"
    mkdir -p -- "$repo/.agent"
    if [[ $value != __missing__ ]]; then
        printf 'AGENT_REVIEW_PROVIDERS=%s\n' "$value" > "$repo/.agent/config.env"
    fi
    printf '%s' "$repo"
}

repo=$(make_repo 'coderabbit,github-code-quality')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq $'provider=coderabbit mode=triggerable source=declared\nprovider=github-code-quality mode=observe-only source=declared' \
    "$out" 'declared providers resolve to their capability modes'
assert_eq '' "$(<"$tmp/err")" 'valid declarations are silent'

repo=$(make_repo 'coderabbit,coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'duplicate providers fall back to one disabled plan'

repo=$(make_repo none)
out=$(bash "$resolver" --repo-root "$repo")
assert_eq 'provider=none mode=disabled source=declared' "$out" \
    'none is an explicit disabled plan'

repo=$(make_repo 'none,coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'mixed none declarations fall back to a disabled plan'
assert_contains "$(<"$tmp/err")" 'invalid value for AGENT_REVIEW_PROVIDERS' \
    'mixed none declarations explain the rejection'

repo=$(make_repo 'coderabbit,')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a trailing delimiter is rejected rather than silently dropped'

repo=$(make_repo 'none,')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a trailing delimiter after none is rejected rather than silently dropped'

repo=$(make_repo ',coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a leading delimiter is rejected'

repo=$(make_repo 'coderabbit,,coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a repeated delimiter is rejected'

repo=$(make_repo 'unknown-provider')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'unknown providers cannot select a trigger'

repo=$(make_repo __missing__)
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=missing' "$out" \
    'missing configuration uses the safe disabled plan'
assert_contains "$(<"$tmp/err")" 'using effective none' \
    'missing configuration warns without blocking'

marker=$tmp/should-not-exist
repo=$(make_repo "coderabbit;touch $marker")
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'shell-looking declarations are rejected as data'
assert_rc 1 'invalid declarations never execute shell-looking payloads' -- test -e "$marker"

assert_rc 2 'unknown options are usage errors' -- bash "$resolver" --unexpected

finish
