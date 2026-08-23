#!/usr/bin/env bash
# Suite: GitHub Code Quality reachability probing (issue #403).
#
# AGENT_REVIEW_PROVIDERS=github-code-quality used to be accepted at plan
# time even when the repository had Code Quality disabled, and this helper
# then died mid-gate with a raw 403. --probe decides reachability without
# fetching findings, and must distinguish a confirmed "not enabled" 403 from
# every other failure (network, auth/scope, 5xx) -- only the former is proof
# of disablement.
set -uo pipefail

TEST_NAME='code-quality-state --probe'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

quality="$root/agentkit/skills/review-remote-pr/scripts/code-quality-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/bin"

write_gh() {
    # $1: gh's stdout on success (empty when it should fail)
    # $2: gh's exit code
    # $3: combined stdout+stderr text to print when failing
    local ok_body=$1 exit_code=$2 fail_text=${3-}
    cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
if [[ "$exit_code" == 0 ]]; then
    printf '%s\n' '$ok_body'
    exit 0
fi
printf '%s\n' '$fail_text' >&2
exit $exit_code
EOF
    chmod +x "$tmp/bin/gh"
}

# --- enabled: a readable 2xx response is a decided "enabled" answer --------

write_gh '{"findings":[]}' 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe)
rc=$?
assert_eq 'state=enabled' "$out" 'a readable response probes as enabled'
assert_eq '0' "$rc" 'an enabled probe exits 0'

# --- not-enabled: a 403 whose message specifically says "not enabled" is a --
# stable repository fact and is the only outcome that resolves not-enabled.

write_gh '' 1 'gh: Code quality is not enabled for this repository (HTTP 403)'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe)
rc=$?
assert_eq 'state=not-enabled' "$out" 'a 403 "not enabled" message probes as not-enabled'
assert_eq '0' "$rc" 'a not-enabled probe exits 0 -- it is a decided answer, not a failure'

# --- unknown: every other failure must fail closed, never downgrade --------

write_gh '' 1 'gh: Resource not accessible by integration (HTTP 403)'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe)
rc=$?
assert_contains "$out" 'state=unknown' \
    'a 403 with a different message (auth/scope) is never treated as not-enabled'
assert_eq '1' "$rc" 'an unknown probe exits 1 so callers fail closed'

write_gh '' 1 'gh: Internal Server Error (HTTP 500)'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe)
rc=$?
assert_contains "$out" 'state=unknown' 'a 5xx is reported unknown, never not-enabled'
assert_eq '1' "$rc" 'a 5xx probe exits 1'

write_gh '' 1 'gh: connection refused'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe)
rc=$?
assert_contains "$out" 'state=unknown' 'a network failure with no HTTP code is reported unknown'
assert_eq '1' "$rc" 'a network-failure probe exits 1'

# --- usage: --probe is mutually exclusive with --summary --------------------

write_gh '{"findings":[]}' 0
assert_rc 1 '--probe cannot be combined with --summary' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe --summary

# --- --probe still requires a valid --repo, same as every other mode -------

assert_rc 1 '--probe still validates --repo' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo not-a-slug --probe

finish
