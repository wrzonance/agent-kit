#!/usr/bin/env bash
# gh() retries transient failures safely: reads on resets, writes only on rate limits, refusals never.
TEST_NAME=v2-gh-retry
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../../v2/lib/common.sh
source "$REPO/v2/lib/common.sh"

# A gh that fails with $FAIL_MSG (exit $FAIL_RC) for the first $FAIL_TIMES calls, then succeeds. Calls are counted.
mkdir "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
n=$(($(cat "$WORK/count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$WORK/count"
if ((n <= FAIL_TIMES)); then echo "$FAIL_MSG" >&2; exit "${FAIL_RC:-1}"; fi
echo ok
STUB
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" WORK AK_GH_RETRY_SLEEP=0

# attempt FAIL_TIMES MSG ARGS...: run gh, leaving stdout in $out, stderr in $err, status in $rc, calls in $calls.
attempt() {
    FAIL_TIMES=$1 FAIL_MSG=$2
    export FAIL_TIMES FAIL_MSG
    shift 2
    rm -f "$WORK/count"
    rc=0
    out=$(gh "$@" 2>"$WORK/err") || rc=$?
    err=$(cat "$WORK/err")
    calls=$(cat "$WORK/count")
}

attempt 2 'read tcp: connection reset by peer' api repos/o/r/issues
assert_eq '0 ok 3' "$rc $out $calls" 'a GET is retried on a reset until it succeeds'
assert_eq '' "$err" 'a recovered GET leaves no stderr behind'

attempt 9 'Post: EOF' api -X POST repos/o/r/pulls -f title=x
assert_eq '1 1' "$rc $calls" 'a POST is not retried on a reset'
assert_eq 'Post: EOF' "$err" 'the failed POST keeps its stderr'

attempt 1 'You have exceeded a secondary rate limit' api repos/o/r/issues/1/comments -f body=x
assert_eq '0 ok 2' "$rc $out $calls" 'a POST is retried on a secondary rate limit'

attempt 9 'HTTP 422: Validation Failed' api repos/o/r/pulls -X GET
assert_eq '1 1' "$rc $calls" 'a 422 is never retried'

FAIL_RC=4 attempt 9 'HTTP 503: unavailable' api repos/o/r/issues
assert_eq '4 3' "$rc $calls" 'a persistent transient failure stops after 3 attempts with its exit code'
assert_eq 'HTTP 503: unavailable' "$err" 'only the final attempt stderr is emitted'

attempt 1 'connection reset' pr ready 5
assert_eq '0 2' "$rc $calls" 'the idempotent pr ready is retried on a reset'

attempt 1 'connection reset' pr merge 5
assert_eq '1 1' "$rc $calls" 'pr merge is not retried on a reset'

export AK_GH_RETRY_SLEEP='3 3'
sleep() { echo "slept $1" >>"$WORK/sleeps"; }
attempt 1 'HTTP 502' api repos/o/r
assert_eq 'slept 3' "$(cat "$WORK/sleeps")" 'AK_GH_RETRY_SLEEP sets the backoff'
export AK_GH_RETRY_SLEEP=0
unset -f sleep
: >"$WORK/sleeps"
sleep() { echo "slept $1" >>"$WORK/sleeps"; }
attempt 2 'HTTP 502' api repos/o/r
assert_eq '' "$(cat "$WORK/sleeps")" 'AK_GH_RETRY_SLEEP=0 never sleeps'
finish
