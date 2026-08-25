#!/usr/bin/env bash
# Suite: triage-issues.sh --classify-shape (issue #444's work-shape axis).
#
# The classifier is a pure text mode: it costs no forge call and needs no gh
# on PATH at all, unlike every other triage-issues.sh mode.
set -uo pipefail

TEST_NAME='work-shape'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

tr_sh="$root/agentkit/skills/.shared/scripts/triage-issues.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# A PATH with only grep (no gh, no jq) -- proof this mode needs neither. The
# script is invoked via `/bin/bash "$tr_sh"` rather than executed directly,
# so the #!/usr/bin/env bash shebang line never has to resolve `bash` off
# this stripped PATH (same convention as test-triage-issues.sh's
# environment-blocked case).
mkdir -p "$tmp/nogh"
ln -s -- "$(command -v grep)" "$tmp/nogh/grep"

no_code_fixture="$here/fixtures/work-shape-no-code.txt"
implementation_fixture="$here/fixtures/work-shape-implementation.txt"
false_positive_fixture="$here/fixtures/work-shape-false-positive.txt"

run_classify() {
    PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-shape "$@"
}

# --- no gh needed at all -----------------------------------------------
out=$(run_classify "$no_code_fixture")
assert_contains "$out" 'work-shape=no-code' \
    'a body that forbids branches/commits/PRs classifies as no-code with no gh on PATH'
assert_contains "$out" 'signal=' \
    'a no-code verdict names the matched signal'
assert_contains "$out" 'prohibited branches' \
    'the printed signal names the actual matched phrase'
assert_not_contains "$out" $'\n' \
    'the classifier prints exactly one line even for a multi-line match'

# --- implementation is the default --------------------------------------
out=$(run_classify "$implementation_fixture")
assert_eq 'work-shape=implementation signal=-' "$out" \
    'a body with no forbidding language classifies as implementation'

# --- generic words alone are not a signal -------------------------------
# "read-only" and "research" are common in ordinary feature prose; only
# phrases anchored to the actual git/forge mechanics should fire.
out=$(run_classify "$false_positive_fixture")
assert_eq 'work-shape=implementation signal=-' "$out" \
    '"read-only"/"research" alone, with no branch/commit/PR mechanics, is not a signal'

# --- word boundaries, not bare substrings ---------------------------------
# Without a leading \b, "no branch" matches inside "casino branches" -- a
# substring hit with no boundary before "no", never an actual forbidding
# phrase.
printf 'List every open-source casino branches integration we could use.\n' \
    > "$tmp/casino.txt"
out=$(run_classify "$tmp/casino.txt")
assert_eq 'work-shape=implementation signal=-' "$out" \
    '"casino branches" does not false-positive on the bare "no branch" substring'

# --- usage ---------------------------------------------------------------
assert_rc 2 '--classify-shape requires a value' -- \
    env PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-shape
stderr=$(run_classify "$tmp/does-not-exist.txt" 2>&1 1>/dev/null) && rc=0 || rc=$?
assert_eq '2' "$rc" 'an unreadable --classify-shape file is a usage error'
assert_contains "$stderr" '--classify-shape' \
    'the unreadable-file error names the flag'

stderr=$(PATH="$tmp/nogh" /bin/bash "$tr_sh" --classify-shape "$no_code_fixture" --limit 5 2>&1 1>/dev/null) && rc=0 || rc=$?
assert_eq '2' "$rc" '--classify-shape does not combine with query flags'
assert_contains "$stderr" 'does not combine' \
    'the combined-flags error explains why it was rejected'

# --- exit code is always 0 on a successful classification ----------------
assert_rc 0 'a no-code verdict exits 0' -- run_classify "$no_code_fixture"
assert_rc 0 'an implementation verdict exits 0' -- run_classify "$implementation_fixture"

finish
