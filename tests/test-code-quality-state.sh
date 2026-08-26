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

# --- --head: the merge-gate scan-state token (issue #472, reworked) --------
#
# merge-gate.sh needs a token produced from live evidence, not asserted by
# hand. code-quality/analyses and pulls/N/code-quality both 404 in a real
# repository (confirmed live against GitHub -- the offline PR review that
# shipped the analyses-endpoint version could not see this), so --head
# derives its evidence from two surfaces that are actually live: the head's
# check-runs (in-flight detection) and the PR's own review comments
# (per-head attributable findings), corroborated by the repository-wide
# findings list for reachability.

readonly HEAD_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly OTHER_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
readonly PR=9

# Routes a gh stub across the three endpoints --head consults, each
# independently controllable: check-runs, the findings reachability probe,
# and the PR's review comments. "ok" prints the given body on stdout and
# exits 0; anything else prints the body on stderr and exits 1. Logs every
# invocation's argv (one "---" per call) so a test can assert exact argv
# shape (e.g. -X GET) for a specific endpoint.
write_gh_head() {
    local cr_mode=$1 cr_body=$2 f_mode=$3 f_body=$4 c_mode=$5 c_body=$6
    cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
endpoint=''
for arg in "\$@"; do
    case "\$arg" in repos/*) endpoint="\$arg" ;; esac
done
{
    for a in "\$@"; do printf 'ARG:%s\n' "\$a"; done
    printf -- '---\n'
} >> "$tmp/gh-argv.log"
case "\$endpoint" in
repos/o/r/commits/*/check-runs\?*)
    if [[ '$cr_mode' == ok ]]; then printf '%s\n' '$cr_body'; exit 0; fi
    printf '%s\n' '$cr_body' >&2
    exit 1
    ;;
repos/o/r/code-quality/findings\?*)
    if [[ '$f_mode' == ok ]]; then printf '%s\n' '$f_body'; exit 0; fi
    printf '%s\n' '$f_body' >&2
    exit 1
    ;;
repos/o/r/pulls/*/comments\?*)
    if [[ '$c_mode' == ok ]]; then printf '%s\n' '$c_body'; exit 0; fi
    printf '%s\n' '$c_body' >&2
    exit 1
    ;;
*)
    printf 'unexpected endpoint %s\n' "\$endpoint" >&2
    exit 1
    ;;
esac
EOF
    chmod +x "$tmp/bin/gh"
    rm -f "$tmp/gh-argv.log"
}

run_head() {
    PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA" --pr "$PR" "$@"
}

# --- Step 1: an in-flight github-code-quality check-run always blocks as
# pending, before anything else is consulted.
write_gh_head \
    ok '{"check_runs":[{"app":{"slug":"github-code-quality"},"status":"in_progress"}]}' \
    ok '[]' \
    ok '[]'
out=$(run_head)
rc=$?
assert_eq "scan-state=pending head=$HEAD_SHA" "$out" \
    'an in-flight github-code-quality check-run reports pending'
assert_eq '0' "$rc" 'a pending scan-state exits 0'

# A check-run under a different app slug (e.g. github-actions/CodeQL) never
# satisfies the pending match, even if it is itself still running.
write_gh_head \
    ok '{"check_runs":[{"app":{"slug":"github-actions"},"status":"in_progress"}]}' \
    ok '[]' \
    ok '[]'
out=$(run_head)
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=0" "$out" \
    'an in-flight check-run under an unrelated app slug is never mistaken for a pending Code Quality scan'

# --- Step 2/3: no in-flight run -- findings-on-head is counted from
# github-code-quality[bot]'s own PR review comments attributed to this exact
# head, distinct from any comment on a different (e.g. pre-force-push) head.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[]' \
    ok "[{\"user\":{\"login\":\"github-code-quality[bot]\"},\"commit_id\":\"$HEAD_SHA\"},{\"user\":{\"login\":\"github-code-quality[bot]\"},\"commit_id\":\"$HEAD_SHA\"},{\"user\":{\"login\":\"github-code-quality[bot]\"},\"commit_id\":\"$OTHER_SHA\"}]"
out=$(run_head)
rc=$?
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=2" "$out" \
    'two bot comments attributed to the exact head report complete findings-on-head=2, excluding the one on another head'
assert_eq '0' "$rc" 'a complete scan-state exits 0'

# A bot comment recorded only against a different head never counts, and
# zero attributable comments is itself a valid, complete, zero-finding scan.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[]' \
    ok "[{\"user\":{\"login\":\"github-code-quality[bot]\"},\"commit_id\":\"$OTHER_SHA\"}]"
out=$(run_head)
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=0" "$out" \
    'a bot comment attributed only to a different head reports complete findings-on-head=0'

# original_commit_id also attributes a comment to this head (a thread that
# outlived a force-push still carries its original head SHA).
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[]' \
    ok "[{\"user\":{\"login\":\"github-code-quality[bot]\"},\"original_commit_id\":\"$HEAD_SHA\"}]"
out=$(run_head)
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=1" "$out" \
    'original_commit_id also attributes a bot comment to this head'

# A non-bot human comment on the exact head is never counted as a finding.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[]' \
    ok "[{\"user\":{\"login\":\"alice\"},\"commit_id\":\"$HEAD_SHA\"}]"
out=$(run_head)
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=0" "$out" \
    'a human comment on the exact head is never counted as a Code Quality finding'

# --- not-enabled: decided by the findings reachability probe's confirmed
# 403, exactly as before.
write_gh_head \
    ok '{"check_runs":[]}' \
    error 'gh: Code quality is not enabled for this repository (HTTP 403)' \
    ok '[]'
out=$(run_head)
rc=$?
assert_eq 'scan-state=not-enabled' "$out" 'a confirmed not-enabled 403 on the findings probe reports not-enabled'
assert_eq '0' "$rc" 'a not-enabled scan-state exits 0'

# --- unknown: every other failure on any of the three surfaces fails
# closed, and never reports complete.
write_gh_head error 'gh: Internal Server Error (HTTP 500)' ok '[]' ok '[]'
out=$(run_head)
rc=$?
assert_contains "$out" 'scan-state=unknown' 'an unreadable check-runs response is reported unknown, never complete'
assert_eq '1' "$rc" 'an unknown scan-state from check-runs exits 1'

write_gh_head \
    ok '{"check_runs":[]}' \
    error 'gh: Resource not accessible by integration (HTTP 403)' \
    ok '[]'
out=$(run_head)
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'an auth/scope 403 on the findings probe is reported unknown, never not-enabled or complete'
assert_eq '1' "$rc" 'an unknown scan-state from the findings probe exits 1'

write_gh_head ok '{"check_runs":[]}' ok '[]' error 'gh: Internal Server Error (HTTP 500)'
out=$(run_head)
rc=$?
assert_contains "$out" 'scan-state=unknown' 'an unreadable comments response is reported unknown, never complete'
assert_eq '1' "$rc" 'an unknown scan-state from comments exits 1'

# Regression: a gh failure body is often pretty-printed multi-line JSON --
# head -n 1 on that would print a bare, useless "{". The reason must be the
# JSON body's own .message, never a truncated brace.
write_gh_head ok '{"check_runs":[]}' ok '[]' error $'{\n  "message": "Resource not accessible by integration",\n  "status": "403"\n}'
out=$(run_head)
assert_contains "$out" 'reason=Resource not accessible by integration' \
    'a multi-line JSON error body surfaces its .message, never a bare "{"'
assert_not_contains "$out" 'reason={' 'the reason is never a truncated opening brace'

# --- --baseline-file: a per-PR evidence artifact measured, never copied ----
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[{"number":1},{"number":2},{"number":3}]' \
    ok "[{\"user\":{\"login\":\"github-code-quality[bot]\"},\"commit_id\":\"$HEAD_SHA\"}]"
baseline="$tmp/baseline.json"
rm -f "$baseline"
out=$(run_head --baseline-file "$baseline")
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=1" "$out" \
    '--baseline-file does not change the printed token'
assert_eq '1' "$(jq -r '.findingsOnHead' "$baseline")" \
    'the baseline artifact records the same findings-on-head count'
assert_eq '3' "$(jq -r '.repoWideOpen' "$baseline")" \
    'the baseline artifact records the repository-wide open-finding count separately'
assert_eq "$HEAD_SHA" "$(jq -r '.head' "$baseline")" 'the baseline artifact records the head SHA'
mode=$(stat -c %a "$baseline" 2>/dev/null || stat -f %Lp "$baseline")
assert_eq '600' "$mode" 'the baseline artifact is written mode 600'

# Regression (issue #486 item 1): the repo-wide findings read must paginate
# and slurp, like the check-runs/comments reads, instead of reporting only
# the first page's length -- a real `gh api --paginate` concatenates one
# JSON array per page onto stdout with no separator.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[{"number":1},{"number":2}][{"number":3}]' \
    ok "[{\"user\":{\"login\":\"github-code-quality[bot]\"},\"commit_id\":\"$HEAD_SHA\"}]"
baseline_paged="$tmp/baseline-paged.json"
rm -f "$baseline_paged"
out=$(run_head --baseline-file "$baseline_paged")
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=1" "$out" \
    'a paginated findings response does not change the printed scan-state token'
assert_eq '3' "$(jq -r '.repoWideOpen' "$baseline_paged")" \
    'repoWideOpen sums every paginated findings page, not just the first'
argv_paged=$(cat "$tmp/gh-argv.log")
assert_contains "$argv_paged" 'ARG:--paginate' \
    'the repo-wide findings read is issued with --paginate'

# Regression (issue #486 item 1): the readability guard must still refuse a
# malformed paginated response instead of miscounting it as zero.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok 'not json' \
    ok '[]'
out=$(run_head)
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'an unparseable paginated findings response is reported unknown, never a bare 0 count'
assert_eq '1' "$rc" 'an unknown scan-state from a malformed paginated findings response exits 1'

# Regression (root review finding on issue #486 item 1): `all` over an EMPTY
# array is vacuously true, so a blank/empty --paginate response (gh printed
# nothing at all -- distinct from a genuine single page of `[]`, zero real
# findings) must still be refused as unreadable, never silently counted as
# repoWideOpen=0. "The API returned nothing" and "there are zero open
# findings" must stay distinguishable.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '' \
    ok '[]'
out=$(run_head)
rc=$?
assert_contains "$out" 'scan-state=unknown' \
    'a blank/empty findings response is reported unknown, never repoWideOpen=0'
assert_eq '1' "$rc" 'an unknown scan-state from a blank findings response exits 1'

# A genuine single page reporting zero findings is still a valid, complete,
# zero-finding read -- only a page-less/blank response is refused.
write_gh_head \
    ok '{"check_runs":[]}' \
    ok '[]' \
    ok '[]'
baseline_zero="$tmp/baseline-zero.json"
rm -f "$baseline_zero"
out=$(run_head --baseline-file "$baseline_zero")
assert_eq "scan-state=complete head=$HEAD_SHA findings-on-head=0" "$out" \
    'a real single page of zero findings still reports complete'
assert_eq '0' "$(jq -r '.repoWideOpen' "$baseline_zero")" \
    'a real single page of zero findings records repoWideOpen=0, distinct from an unreadable response'

# Regression (issue #472 review): every filtered read (-f/-F present or not)
# --head issues is forced to GET, never inferred as POST.
write_gh_head ok '{"check_runs":[]}' ok '[]' ok '[]'
run_head >/dev/null
argv=$(cat "$tmp/gh-argv.log")
assert_contains "$argv" $'ARG:-X\nARG:GET' 'each --head read is forced to GET'

# --- --head usage validation -------------------------------------------------

write_gh_head ok '{"check_runs":[]}' ok '[]' ok '[]'
assert_rc 1 '--head cannot be combined with --probe' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA" --pr "$PR" --probe

assert_rc 1 '--head cannot be combined with --summary' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA" --pr "$PR" --summary

assert_rc 1 '--head requires a full 40-character SHA' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head short --pr "$PR"

assert_rc 1 '--head requires --pr' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --head "$HEAD_SHA"

assert_rc 1 '--pr is only meaningful with --head' -- \
    env PATH="$tmp/bin:$PATH" "$quality" --repo o/r --probe --pr "$PR"

finish
