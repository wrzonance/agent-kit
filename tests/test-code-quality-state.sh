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

# --- --head: the merge-gate scan-state token (issue #472) ------------------
#
# merge-gate.sh needs a token produced from live evidence, not asserted by
# hand -- --head derives it from the Code Quality API's own completed-
# analysis record for the exact commit, mirroring the code-scanning/analyses
# precedent (#413) instead of a check-run app slug.

readonly HEAD_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly OTHER_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

# complete: a completed analysis is recorded against this exact commit_sha,
# and its own findings_count -- not the repository-wide open-finding count
# -- is reported as findings-on-head.
write_gh "[{\"commit_sha\":\"$HEAD_SHA\",\"findings_count\":0,\"created_at\":\"2026-08-20T00:00:00Z\"}]" 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=0" "$out" \
    'a completed analysis for the exact head reports complete with its own findings count'
assert_eq '0' "$rc" 'a complete scan-state exits 0'

# A PR with zero attributable findings passes even while the repository
# carries pre-existing, unrelated open findings elsewhere -- findings_count
# on the matched analysis is the only number that reaches the token.
write_gh "[{\"commit_sha\":\"$OTHER_SHA\",\"findings_count\":18,\"created_at\":\"2026-08-19T00:00:00Z\"},{\"commit_sha\":\"$HEAD_SHA\",\"findings_count\":0,\"created_at\":\"2026-08-20T00:00:00Z\"}]" 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=0" "$out" \
    'a zero-finding head is reported complete even alongside a repository-wide open finding elsewhere'

# Regression (issue #472 review, F1): a missing or null findings_count on the
# matched analysis must never be read as a clean zero-finding scan via a `//
# 0` default -- it is unreadable evidence and must report unknown, never
# complete.
write_gh "[{\"commit_sha\":\"$HEAD_SHA\",\"findings_count\":null,\"created_at\":\"2026-08-20T00:00:00Z\"}]" 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'a null findings_count on the matched analysis is reported unknown, never complete'
assert_eq '1' "$rc" 'a null findings_count exits 1'

write_gh "[{\"commit_sha\":\"$HEAD_SHA\",\"created_at\":\"2026-08-20T00:00:00Z\"}]" 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'an absent findings_count key on the matched analysis is reported unknown, never complete'
assert_eq '1' "$rc" 'an absent findings_count key exits 1'

# pending: a readable but empty (no match for this commit) analyses array is
# a normal still-outstanding scan, never an error.
write_gh '[]' 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_eq "scan-state=pending head=$HEAD_SHA" "$out" \
    'no matching completed analysis for the head reports pending'
assert_eq '0' "$rc" 'a pending scan-state exits 0'

write_gh "[{\"commit_sha\":\"$OTHER_SHA\",\"findings_count\":0,\"created_at\":\"2026-08-20T00:00:00Z\"}]" 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
assert_eq "scan-state=pending head=$HEAD_SHA" "$out" \
    'an analysis recorded for a different commit never satisfies this head'

# not-enabled: the same confirmed 403 rule as --probe.
write_gh '' 1 'gh: Code quality is not enabled for this repository (HTTP 403)'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_eq 'scan-state=not-enabled' "$out" 'a confirmed not-enabled 403 reports not-enabled for --head too'
assert_eq '0' "$rc" 'a not-enabled scan-state exits 0'

# unknown: every other failure fails closed, and never reports complete.
write_gh '' 1 'gh: Resource not accessible by integration (HTTP 403)'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'an auth/scope 403 is reported unknown, never complete or not-enabled'
assert_eq '1' "$rc" 'an unknown scan-state exits 1 so callers fail closed'

write_gh '' 1 'gh: Internal Server Error (HTTP 500)'
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_contains "$out" 'scan-state=unknown' 'a 5xx is reported unknown for --head too'
assert_eq '1' "$rc" 'a 5xx --head probe exits 1'

# A readable 2xx response that is not a JSON array is unreadable evidence,
# never proof of completion.
write_gh '{"findings":[]}' 0
out=$(PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA")
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'a non-array analyses response is reported unknown, never complete'
assert_eq '1' "$rc" 'a malformed analyses response exits 1'

# Regression (issue #472 review): `gh api` infers POST whenever -f/-F fields
# are present -- the analyses call passes -f ref=... -F per_page=100, so
# without an explicit -X GET this filtered read silently becomes a write
# against the repository. Assert the exact method is forced.
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do printf 'ARG:%s\n' "\$arg"; done >> "$tmp/gh-analyses-argv.log"
printf '[]\n'
exit 0
EOF
chmod +x "$tmp/bin/gh"
rm -f "$tmp/gh-analyses-argv.log"
PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA" >/dev/null
assert_contains "$(cat "$tmp/gh-analyses-argv.log")" $'ARG:-X\nARG:GET' \
    'the analyses read is forced to GET, never inferred as POST from its -f/-F fields'

# --- --head usage validation -------------------------------------------------

write_gh '[]' 0
assert_rc 1 '--head cannot be combined with --probe' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA" --probe

assert_rc 1 '--head cannot be combined with --summary' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA" --summary

assert_rc 1 '--head requires a full 40-character SHA' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head short

finish
