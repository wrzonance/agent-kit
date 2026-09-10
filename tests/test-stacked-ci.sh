#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME=stacked-ci
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
lib="$root/agentkit/skills/.shared/scripts/lib/stacked-ci.sh"
if [[ ! -f $lib ]]; then
    assert_eq present missing 'shared observed check-set comparison exists'
    finish
fi
# shellcheck disable=SC1090
source "$lib"
cat >"$tmp/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CI_LOG"
case "$*" in
    *'/pulls?'*)
        [[ ${CI_CASE:-} != unavailable ]] || exit 1
        if [[ ${CI_CASE:-} == pending-first || ${CI_CASE:-} == all-pending ]]; then
            printf '%s\n' '[{"number":715,"head":{"sha":"cccccccccccccccccccccccccccccccccccccccc"},"base":{"ref":"main"}},{"number":716,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"ref":"main"}}]'
            exit 0
        fi
        printf '%s\n' '[{"number":716,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"ref":"main"}}]'
        ;;
    *'/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs?'*)
        [[ ${CI_CASE:-} != empty ]] || { printf '%s\n' '{"check_runs":[]}'; exit 0; }
        status=completed
        [[ ${CI_CASE:-} != all-pending ]] || status=in_progress
        printf '%s\n' '{"check_runs":[{"name":"gates and suites","app":{"id":15368}},{"name":"Analyze (python)","app":{"id":15368}},{"name":"Analyze (javascript-typescript)","app":{"id":15368}}]}' | jq --arg status "$status" '.check_runs |= map(. + {status:$status,conclusion:"success"})'
        ;;
    *'/commits/cccccccccccccccccccccccccccccccccccccccc/check-runs?'*)
        printf '%s\n' '{"check_runs":[{"name":"gates and suites","app":{"id":15368},"status":"in_progress","conclusion":null}]}'
        ;;
    *'/commits/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/check-runs?'*)
        case ${CI_CASE:-partial} in
            zero) printf '%s\n' '{"check_runs":[]}' ;;
            complete) printf '%s\n' '{"check_runs":[{"name":"gates and suites","app":{"id":15368}},{"name":"Analyze (python)","app":{"id":15368}},{"name":"Analyze (javascript-typescript)","app":{"id":15368}}]}' ;;
            wrong-app) printf '%s\n' '{"check_runs":[{"name":"gates and suites","app":{"id":15368}},{"name":"Analyze (python)","app":{"id":999}},{"name":"Analyze (javascript-typescript)","app":{"id":999}}]}' ;;
            *) printf '%s\n' '{"check_runs":[{"name":"gates and suites","app":{"id":15368}}]}' ;;
        esac
        ;;
    *'/status?'*)
        # A same-named optional legacy status never satisfies a check-run identity.
        printf '%s\n' '{"statuses":[{"context":"Analyze (python)","state":"success"}]}'
        [[ ${CI_CASE:-} != zero ]] || exit 0
        ;;
    *) exit 22 ;;
esac
GH
chmod +x "$tmp/gh"
export CI_LOG="$tmp/calls"
pr='{"number":719,"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"base":{"ref":"feat/parent","repo":{"default_branch":"main"}}}'
result=$(stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr")
assert_eq partial-ci-on-stacked-base "$(jq -r .state <<<"$result")" 'one green workflow does not hide missing Analyze checks'
assert_eq 716 "$(jq -r .reference.pr <<<"$result")" 'comparison names an observed default-target PR'
assert_eq aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$(jq -r .reference.sha <<<"$result")" 'comparison pins the reference head'
assert_eq 2 "$(jq '.missing | length' <<<"$result")" 'both missing languages are explicit'
assert_contains "$result" 'Analyze (python)' 'status context cannot stand in for a check run'
result=$(CI_CASE=complete stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr")
assert_eq reference-checks-present "$(jq -r .state <<<"$result")" 'matching observed set is reported without declaring requiredness'
result=$(CI_CASE=pending-first stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr")
assert_eq 716 "$(jq -r .reference.pr <<<"$result")" 'in-flight subset is skipped for an older settled reference'
assert_eq partial-ci-on-stacked-base "$(jq -r .state <<<"$result")" 'in-flight reference cannot bless a one-check subset'
result=$(CI_CASE=all-pending stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr")
assert_eq unknown "$(jq -r .state <<<"$result")" 'no settled reference means unknown coverage'
result=$(CI_CASE=wrong-app stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr")
assert_eq partial-ci-on-stacked-base "$(jq -r .state <<<"$result")" 'different provider identities cannot satisfy the same check names'
for scenario in empty unavailable; do
    result=$(CI_CASE=$scenario stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr")
    assert_eq unknown "$(jq -r .state <<<"$result")" "$scenario reference evidence is not complete"
done
result=$(CI_CASE=zero stacked_ci_snapshot "$tmp/gh" owner/repo '' "$pr" '{"check_runs":[]}' '{"statuses":[]}')
assert_eq no-ci-on-stacked-base "$(jq -r .state <<<"$result")" 'zero checks retain their distinct state'
: >"$CI_LOG"
default_pr=$(jq '.base.ref="main"' <<<"$pr")
result=$(stacked_ci_snapshot "$tmp/gh" owner/repo '' "$default_pr")
assert_eq not-stacked "$(jq -r .state <<<"$result")" 'default-target PR behavior is unchanged'
assert_eq '' "$(cat "$CI_LOG")" 'default-target PRs need no baseline fetch'
finish
