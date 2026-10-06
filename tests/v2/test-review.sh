#!/usr/bin/env bash
# ak review: one blind cross-provider review of the pushed head.
TEST_NAME=v2-review
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1
git worktree add -q -b fix/thing "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1
printf 'two\n' >>src/a.txt
git commit -q -am 'change a'
export FAKE_REVIEW_LOG="$WORK/review.log"
unset AGENT_ADVERSARIAL_REVIEWER AGENT_ADVERSARIAL_REVIEW_MODEL AGENT_ADVERSARIAL_REVIEW_EFFORT

out=$("$AK" review 2>&1); rc=$?
assert_eq 1 "$rc" 'an unpushed head is refused'
assert_contains "$out" 'fix: ak ship --message' 'the refusal names ak ship'
git push -q -u origin fix/thing 2>/dev/null
head=$(git rev-parse HEAD)

mkdir -p .ak && printf 'SECRET ISSUE TEXT\n' >.ak/issue-body.md
export CODEX_HOME=/x
export FAKE_REVIEW_OUT=$'P1: off by one \xe2\x80\x94 src/a.txt:2 \xe2\x80\x94 loops past end\nP2: vague name \xe2\x80\x94 src/a.txt:1 \xe2\x80\x94 unclear'
out=$("$AK" review 2>&1); rc=$?
assert_eq 0 "$rc" 'review exits 0'
assert_contains "$out" 'review=done findings=2' 'findings are counted'
assert_contains "$out" 'P1: off by one' 'P1 title is printed'
assert_contains "$out" 'P2: vague name' 'P2 title is printed'
assert_not_contains "$out" 'loops past end' 'only titles are printed'
log=$(cat "$FAKE_REVIEW_LOG")
assert_contains "$log" 'bin=claude' 'under codex the reviewer is claude'
assert_contains "$log" '--tools  --permission-mode dontAsk' 'claude runs with no tools'
assert_contains "$log" '--model claude-opus-5' 'claude default model'
assert_contains "$log" '+two' 'the prompt carries the diff'
assert_contains "$log" 'NO FINDINGS' 'the prompt carries the header'
assert_not_contains "$log" 'SECRET ISSUE TEXT' 'the prompt carries no issue text'
assert_not_contains "$log" "cwd=$WORK/wt" 'the reviewer does not run in the worktree'
assert_eq "reviewer=claude model=claude-opus-5 head=$head" "$(head -n 1 .ak/review.md)" 'review.md first line'
assert_contains "$(cat .ak/review.md)" 'P1: off by one' 'review.md keeps the findings'
unset CODEX_HOME

: >"$FAKE_REVIEW_LOG"
export CLAUDECODE=1 FAKE_REVIEW_OUT='NO FINDINGS'
out=$("$AK" review --again 2>&1); rc=$?
assert_eq 'review=done findings=0' "$out" 'NO FINDINGS counts zero'
log=$(cat "$FAKE_REVIEW_LOG")
assert_contains "$log" 'bin=codex' 'under claude the reviewer is codex'
assert_contains "$log" '-s read-only' 'codex runs read-only'
assert_contains "$log" '-m gpt-5.6-sol' 'codex default model'
assert_contains "$log" 'model_reasoning_effort="xhigh"' 'codex default effort'
assert_eq "reviewer=codex model=gpt-5.6-sol head=$head" "$(head -n 1 .ak/review.md)" 'codex review.md first line'
unset CLAUDECODE

: >"$FAKE_REVIEW_LOG"
export AGENT_ADVERSARIAL_REVIEWER=codex AGENT_ADVERSARIAL_REVIEW_MODEL=gpt-9
"$AK" review --again >/dev/null 2>&1
assert_contains "$(cat "$FAKE_REVIEW_LOG")" '-m gpt-9' 'unknown harness uses the configured reviewer and model'
unset AGENT_ADVERSARIAL_REVIEWER AGENT_ADVERSARIAL_REVIEW_MODEL

export FAKE_REVIEW_OUT=$'P1: a\nP1: b\nP1: c\nP1: d\nP1: e\nP1: f\nP1: g\nP1: h\nP1: i\nP1: j\nP1: k\nP1: l\nP1: m\nP1: n\nP1: o\nP1: p\nP1: q\nP1: r\nP1: s\nP1: t\nP1: u'
out=$("$AK" review --again 2>&1)
assert_contains "$out" 'review=done findings=21' 'all findings are counted'
assert_eq 20 "$(wc -l <<<"$out")" 'output is capped at 20 lines'

export FAKE_REVIEW_OUT='this looks fine to me'
out=$("$AK" review --again 2>&1); rc=$?
assert_eq 0 "$rc" 'an unparsed review exits 0'
assert_contains "$out" 'findings=unparsed' 'an unparsed review is never clean'

export FAKE_REVIEW_OUT='NO FINDINGS' FAKE_REVIEW_RC=3
out=$("$AK" review --again 2>&1); rc=$?
assert_eq 0 "$rc" 'a failing reviewer exits 0'
assert_eq 'review=unavailable reason=exit-3' "$out" 'non-zero exit is unavailable'
assert_eq 'exit-3' "$(cat .ak/review.unavailable)" 'unavailable file names the reason'
assert_eq no "$([[ -e .ak/review.md ]] && echo yes || echo no)" 'a stale review.md is removed'
unset FAKE_REVIEW_RC

export FAKE_REVIEW_SLEEP=5 AK_REVIEW_TIMEOUT=1
out=$("$AK" review 2>&1); rc=$?
assert_eq 0 "$rc" 'a timed-out reviewer exits 0'
assert_eq 'review=unavailable reason=timeout' "$out" 'timeout is unavailable'
unset FAKE_REVIEW_SLEEP AK_REVIEW_TIMEOUT

export FAKE_REVIEW_OUT=$'P1: off by one \xe2\x80\x94 src/a.txt:2 \xe2\x80\x94 loops past end'
"$AK" review >/dev/null 2>&1
assert_eq no "$([[ -e .ak/review.unavailable ]] && echo yes || echo no)" 'a completed review clears review.unavailable'

# One review per PR; fixes follow it (field run 10: 10 PRs cost 23 reviewer runs because every head that had only
# moved by a fix or a base update was reviewed again).
first=$(head -n 1 .ak/review.md)
printf 'three\n' >>src/a.txt
git commit -q -am 'fix: off by one'
git push -q origin fix/thing 2>/dev/null
: >"$FAKE_REVIEW_LOG"
out=$("$AK" review 2>&1); rc=$?
assert_eq 0 "$rc" 'a head that only moved by fixes exits 0'
assert_eq "review=done findings=1 reused head=${head:0:7} note=one review per PR; ak review --again reviews the current diff"$'\n''P1: off by one' "$out" 'the existing review is reused with its titles'
assert_eq '' "$(cat "$FAKE_REVIEW_LOG")" 'a reused review does not run the reviewer'
assert_eq "$first" "$(head -n 1 .ak/review.md)" 'a reused review keeps its head'

export FAKE_REVIEW_OUT='NO FINDINGS'
out=$("$AK" review --again 2>&1); rc=$?
assert_eq 0 "$rc" '--again exits 0'
assert_eq 'review=done findings=0' "$out" '--again reviews the current diff'
assert_contains "$(cat "$FAKE_REVIEW_LOG")" '+three' '--again sends the current diff to the reviewer'
assert_eq "reviewer=claude model=claude-opus-5 head=$(git rev-parse HEAD)" "$(head -n 1 .ak/review.md)" '--again rewrites the reviewed head'

foreign=$(git commit-tree -p HEAD -m elsewhere "$(git rev-parse 'HEAD^{tree}')")
sed -i "1s/head=.*/head=$foreign/" .ak/review.md
: >"$FAKE_REVIEW_LOG"
out=$("$AK" review 2>&1)
assert_eq 'review=done findings=0' "$out" 'a review of a head outside this branch is replaced'
assert_contains "$(cat "$FAKE_REVIEW_LOG")" 'bin=' 'replacing a foreign review runs the reviewer'
assert_eq "reviewer=claude model=claude-opus-5 head=$(git rev-parse HEAD)" "$(head -n 1 .ak/review.md)" 'the replacement names the current head'

# Only review fixes and merge-downs may follow a reused review; other commits are work the reviewer never saw.
printf 'four\n' >>src/a.txt
git commit -q -am 'feat: more'
git push -q origin fix/thing 2>/dev/null
: >"$FAKE_REVIEW_LOG"
out=$("$AK" review 2>&1)
assert_eq 'review=done findings=0' "$out" 'a feat: commit after the review gets a fresh review'
assert_contains "$(cat "$FAKE_REVIEW_LOG")" '+four' 'the fresh review sees the new work'
assert_eq "reviewer=claude model=claude-opus-5 head=$(git rev-parse HEAD)" "$(head -n 1 .ak/review.md)" 'the fresh review names the new head'
reviewed=$(git rev-parse HEAD)

printf 'five\n' >>src/a.txt
git commit -q -am 'fix(a): review finding'
git push -q origin fix/thing 2>/dev/null
: >"$FAKE_REVIEW_LOG"
out=$("$AK" review 2>&1)
assert_contains "$out" "findings=0 reused head=${reviewed:0:7}" 'a fix(scope): commit reuses the review'
assert_eq '' "$(cat "$FAKE_REVIEW_LOG")" 'the fix commit does not run the reviewer'

(cd "$repo" && printf 'b\n' >src/b.txt && git add src/b.txt && git commit -q -m 'feat: main work' && git push -q origin main 2>/dev/null)
git fetch -q origin
git merge -q --no-edit origin/main
git push -q origin fix/thing 2>/dev/null
out=$("$AK" review 2>&1)
assert_contains "$out" "findings=0 reused head=${reviewed:0:7}" 'a merge-down of new base work reuses the review'
assert_eq '' "$(cat "$FAKE_REVIEW_LOG")" 'the merge-down does not run the reviewer'

sed -i "1s/head=.*/head=$(git rev-parse origin/main)/" .ak/review.md
out=$("$AK" review 2>&1)
assert_eq 'review=done findings=0' "$out" 'a review of a base commit is not reused'
assert_contains "$(cat "$FAKE_REVIEW_LOG")" 'bin=' 'the base-commit review is replaced by a fresh run'

out=$("$AK" review --nope 2>&1); rc=$?
assert_eq 2 "$rc" 'an unknown flag is a usage error'

nobin="$WORK/nobin"
mkdir -p "$nobin"
ln -s "$V2_TESTS/stub/gh" "$nobin/gh"
path="$nobin"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
    [[ $d == "$V2_TESTS/stub" || -x $d/claude ]] || path+=":$d"
done
out=$(CODEX_HOME=/x PATH=$path "$AK" review --again 2>&1); rc=$?
assert_eq 0 "$rc" 'a missing reviewer CLI exits 0'
assert_eq 'review=unavailable reason=missing-claude' "$out" 'missing CLI is unavailable'

git checkout -q -b empty origin/main
git push -q -u origin empty 2>/dev/null
out=$("$AK" review 2>&1); rc=$?
assert_eq 1 "$rc" 'an empty diff is refused'
assert_contains "$out" 'empty' 'the refusal names the empty diff'

finish
