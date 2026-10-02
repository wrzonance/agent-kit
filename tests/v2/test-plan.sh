#!/usr/bin/env bash
# ak plan: board pick, drops, write sets, collisions, worktrees, prompts, and the run file.
TEST_NAME=v2-plan
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=plan-fixture.sh
source "$V2_TESTS/plan-fixture.sh"
ak_with_template

# fresh: a new fixture repository and route table for one case.
fresh() {
    rm -rf -- "$WORK/repo" "$WORK/origin.git"
    : >"$FAKE_GH_ROUTES"
    : >"$FAKE_GH_LOG"
    repo=$(board_repo)
    cd "$repo" || exit 1
}

fresh
standard_board
out=$("$AK" plan 2>&1); rc=$?
assert_eq 0 "$rc" 'plan exits 0'
wt="$repo/.worktrees/feat/issue-671"
expected="spawn issue=671 cwd=$wt prompt=$wt/.ak/prompt.md model=gpt-5.6-luna effort=medium
drop issue=69 reason=label:tier:human-only
drop issue=680 reason=collides-with-#671
drop issue=690 reason=blocked-by:#1
drop issue=691 reason=protected:.github/workflows/ci.yml
drop issue=692 reason=open-pr
spawn issue=693 cwd=$repo/.worktrees/feat/issue-693 prompt=$repo/.worktrees/feat/issue-693/.ak/prompt.md model=gpt-5.6-luna effort=medium"
run=$(sed -n 1p <<<"$out")
assert_contains "$run" 'run=' 'the first line names the run'
assert_eq "$expected" "$(sed 1d <<<"$out")" 'spawn and drop lines follow board order'
assert_not_contains "$out" 'issue=700' 'Backlog is not picked without --yolo'
assert_not_contains "$out" 'issue=694' 'Done items are not candidates'
assert_not_contains "$out" 'issue=695' 'a closed issue still on the board prints no drop line'
assert_eq yes "$( (( $(wc -l <<<"$out") <= 20 )) && echo yes || echo no)" 'output is at most 20 lines'
assert_eq 'feat/issue-671' "$(git -C "$wt" branch --show-current)" 'the worktree is on feat/issue-671'
assert_eq "$(git rev-parse origin/main)" "$(git -C "$wt" rev-parse HEAD)" 'the worktree starts at origin/main'
git ls-remote --exit-code --heads origin feat/issue-671 >/dev/null
assert_eq 0 "$?" 'the branch is pushed'
assert_eq 671 "$(cat "$wt/.ak/issue")" '.ak/issue holds the number'
prompt=$(cat "$wt/.ak/prompt.md")
assert_contains "$prompt" 'Issue 671: Title 671' 'the prompt substitutes number and title'
assert_contains "$prompt" "branch=feat/issue-671 worktree=$wt base=main slug=acme/widget ak=$WORK/v2/bin/ak" 'the prompt substitutes the run facts'
assert_contains "$prompt" 'untrusted' 'the issue block is labelled untrusted'
assert_eq 'title: Title 671' "$(head -n 1 "$wt/.ak/issue.md")" '.ak/issue.md starts with the title line ship reads'
assert_eq main "$(cat "$wt/.ak/base")" '.ak/base holds the PR base'
assert_contains "$prompt" 'please hurry' 'comments are included'
assert_contains "$prompt" 'AGENTS.md {{BRANCH}}' 'issue text is not itself substituted'
assert_eq "$(cat "$wt/.ak/issue.md")" "$(sed -n '3,$p' "$wt/.ak/prompt.md")" 'the prompt block is .ak/issue.md'
assert_eq '' "$(git -C "$wt" status --porcelain)" 'the worktree stays clean'
assert_contains "$(cat "$FAKE_GH_LOG")" 'project item-edit --id I_671' 'the spawned issue moves to In progress'
runfile="$repo/.ak/runs/${run#run=}.json"
assert_eq "${run#run=}" "$(cat "$repo/.ak/runs/current")" 'current names the run'
assert_eq '{"kind":"issue","n":671,"worktree":"'"$wt"'","branch":"feat/issue-671","state":"spawned","needs":[]}' \
    "$(jq -c '.items[0]' "$runfile")" 'the run file records the spawned item'
assert_eq '2 string' "$(jq -r '"\(.items | length) \(.porcelain | type)"' "$runfile")" 'the run file has both spawns and the root porcelain'
assert_eq 1 "$(grep -c 'issues/693/dependencies' "$FAKE_GH_LOG")" 'one deps read per candidate'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'issues/69/' 'a label drop costs no REST call'

# A second plan while workers are still out resumes the run instead of planning nothing (the 2026-09-30 smoke run).
: >"$FAKE_GH_LOG"
again=$("$AK" plan 2>&1); rc=$?
assert_eq 0 "$rc" 'a re-run plan exits 0'
assert_eq "${run} resumed" "$(sed -n 1p <<<"$again")" 'a re-run plan resumes the current run'
assert_contains "$again" "spawn issue=671 cwd=$wt" 'a re-run plan reprints the spawn lines'
assert_eq '' "$(grep -E 'project|issues' "$FAKE_GH_LOG" || true)" 'a resume makes no board or issue calls'
named=$("$AK" plan --issue 700 2>&1)
assert_not_contains "$named" 'resumed' 'naming an issue the current run never planned is new work, not a resume'
assert_contains "$named" 'spawn issue=700' 'the named issue spawns while the earlier workers keep running'
printf 'pr=x\n' >"$wt/.ak/result"
printf 'pr=y\n' >"$repo/.worktrees/feat/issue-693/.ak/result"
printf 'pr=z\n' >"$repo/.worktrees/feat/issue-700/.ak/result"
fresh_plan=$("$AK" plan 2>&1)
assert_not_contains "$fresh_plan" 'resumed' 'a run whose workers all reported is not resumed'
forced=$("$AK" plan --new 2>&1)
assert_not_contains "$forced" 'resumed' '--new always plans fresh'

fresh
standard_board
out=$("$AK" plan --limit 1 2>&1)
assert_eq 1 "$(grep -c '^spawn' <<<"$out")" '--limit 1 spawns one issue'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'issues/680' '--limit stops checking once the limit is filled'

fresh
standard_board
out=$("$AK" plan --serialize 2>&1)
assert_contains "$out" 'after issue=680 needs=671' '--serialize chains the colliding issue'
assert_eq no "$([[ -e $repo/.worktrees/feat/issue-680 ]] && echo yes || echo no)" 'a queued issue gets no worktree'
runfile="$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json"
assert_eq 'queued [671]' "$(jq -r '.items[] | select(.n == 680) | "\(.state) \(.needs | tojson)"' "$runfile")" 'the queued item records its needs'

# Field run 2026-10-01: a second plan spawned an issue another run still had queued, and a collect re-spawned an
# issue that had already shipped elsewhere, deleting its result.
out=$("$AK" plan --new --issue 680 2>&1)
assert_contains "$out" 'skip issue=680 reason=queued-after-#671' 'an issue queued in a live run is not planned again'
out=$("$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'skip issue=671 reason=running' 'an issue whose worker is still out is not planned again'
jq '.items += [{kind: "issue", n: 700, state: "queued", needs: [680]}]' "$runfile" >"$runfile.tmp" && mv "$runfile.tmp" "$runfile"
git -C "$repo" push -q origin HEAD:refs/heads/feat/issue-680
mkdir -p "$repo/.worktrees/feat/issue-680/.ak"
printf 'pr=elsewhere\n' >"$repo/.worktrees/feat/issue-680/.ak/result"
printf 'pr=x\nci=green\nreview=done\nhead=a\nnote=n\n' >"$repo/.worktrees/feat/issue-671/.ak/result"
out=$("$AK" collect --issue 671 2>&1)
assert_contains "$out" 'skip issue=680 reason=shipped:elsewhere' 'collect does not re-spawn a successor that shipped'
assert_eq no "$([[ -e $repo/.worktrees/feat/issue-680/.ak/prompt.md ]] && echo yes || echo no)" 'the shipped worktree is untouched'
assert_eq 'pr=elsewhere' "$(cat "$repo/.worktrees/feat/issue-680/.ak/result")" 'the shipped result survives'
assert_eq collected "$(jq -r '.items[] | select(.n == 680) | .state' "$runfile")" 'a shipped successor counts as done'
assert_contains "$out" 'spawn issue=700 ' 'the issue queued behind a shipped successor still spawns'
out=$("$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'skip issue=671 reason=shipped:x' 'a shipped issue is not planned again'

fresh
standard_board
out=$(AGENT_PLAN_LIMIT=1 "$AK" plan --issue 671 --issue 693 2>&1)
assert_eq 2 "$(grep -c '^spawn' <<<"$out")" 'every named issue is planned past the default limit'

# A blocker chosen earlier in the run queues the issue behind it, even without --serialize (a field run dropped an
# issue as blocked-by an issue it had just spawned).
fresh
route 'api repos/acme/widget/issues/693/dependencies/blocked_by*' '[{"number":671,"state":"open"}]'
standard_board
out=$("$AK" plan 2>&1)
assert_contains "$out" 'after issue=693 needs=671' 'an issue blocked by a chosen issue queues behind it'
assert_not_contains "$out" 'drop issue=693' 'an issue blocked by a chosen issue is not dropped'
assert_contains "$out" 'drop issue=690 reason=blocked-by:#1' 'a blocker outside the run still drops'

fresh
standard_board
out=$(CODEX_HOME=/x AGENT_WORKER_MODELS='claude-sonnet-5, gpt-5.6-terra' AGENT_WORKER_EFFORT=high "$AK" plan --yolo --issue 700 2>&1)
assert_contains "$out" 'spawn issue=700 ' 'an explicit --issue is planned'
assert_contains "$out" 'model=gpt-5.6-terra effort=high' 'the roster entry for the running harness wins'
assert_eq 2 "$(wc -l <<<"$out")" 'only the explicit issue is planned'
out=$(CODEX_HOME=/x "$AK" plan --issue 693 2>&1)
assert_contains "$out" 'model=gpt-5.6-luna' 'codex defaults to gpt-5.6-luna'
out=$(CLAUDECODE=1 AGENT_WORKER_MODELS='gpt-5.6-terra,claude-sonnet-5' "$AK" plan --issue 671 2>&1)
assert_contains "$out" 'model=claude-sonnet-5' 'claude skips the codex roster entry'

fresh
route 'project item-list 5 --owner acme*' "{\"items\":[$(board_item 700 Backlog),$(board_item 671 Ready)]}"
issue_route 671 'x'
issue_route 700 'y'
default_routes
out=$("$AK" plan --yolo 2>&1)
assert_eq 'spawn issue=671 spawn issue=700' "$(grep -o 'spawn issue=[0-9]*' <<<"$out" | paste -sd' ')" '--yolo adds Backlog after Ready'

fresh
items=$(for n in $(seq 100 130); do printf '%s\n' "$(board_item "$n" Ready '["blocked"]')"; done | paste -sd, -)
route 'project item-list 5 --owner acme*' "{\"items\":[$items,$(board_item 671 Ready)]}"
issue_route 671 'x'
default_routes
out=$("$AK" plan 2>&1)
assert_eq 20 "$(wc -l <<<"$out")" 'many drops still print 20 lines'
assert_contains "$out" 'spawn issue=671' 'the spawn line survives the cap'
assert_contains "$out" 'drop more=14 log=' 'hidden drops point at the log'

fresh
printf 'AGENT_PROJECT_OWNER=\nAGENT_PROJECT_NUMBER=\n' >>.agent/config.env
out=$("$AK" plan 2>&1); rc=$?
assert_eq 1 "$rc" 'no board and no ready label refuses'
assert_contains "$out" 'fix: ' 'the refusal names the fix'
route 'api repos/acme/widget/issues?state=open&labels=agent:ready*' '[{"number":5,"title":"T","state":"open","body":"b","labels":[{"name":"agent:ready"}]},{"number":6,"pull_request":{},"labels":[]}]'
issue_route 5 'b'
default_routes
out=$(AGENT_READY_LABEL=agent:ready "$AK" plan 2>&1)
assert_contains "$out" 'spawn issue=5 ' 'the ready label is the fallback source'
assert_not_contains "$out" 'issue=6' 'pull requests are not issues'

# A path that only appears in a verification command or a "still passes" line is not a write (ak-bench batch,
# 2026-10-01: every tally issue says `node test/smoke.mjs` still exits 0, so all three issues serialized).
fresh
# shellcheck disable=SC2016 # literal backticks in issue bodies
issue_route 801 $'Change `src/a.txt`.\n\n- [ ] `node lib/core.sh` still exits 0.'
issue_route 802 $'Change `src/b.txt`.\n\n- [ ] lib/core.sh still passes'
# shellcheck disable=SC2016
issue_route 803 'Fix `src/a.txt` too.'
default_routes
out=$("$AK" plan --issue 801 --issue 802 --issue 803 2>&1)
assert_contains "$out" 'spawn issue=801' 'an issue whose only shared path is a test command spawns'
assert_contains "$out" 'spawn issue=802' 'a "still passes" path is not a write either'
assert_contains "$out" 'drop issue=803 reason=collides-with-#801' 'a real shared write still collides'

# A failed board read names its real cause; throttling never sends the root into an interactive login
# (bench 2026-10-01: a throttled read was reported as a missing scope and the root started a device login).
fresh
route 'project item-list 5 --owner acme*' 'GraphQL: API rate limit already exceeded for user ID 1.' 1
out=$("$AK" plan 2>&1); rc=$?
assert_eq 1 "$rc" 'a throttled board read refuses'
assert_contains "$out" 'API rate limit already exceeded' 'the refusal quotes the real error'
assert_contains "$out" 'fix: wait for the GitHub rate limit' 'throttling says wait'
assert_not_contains "$out" 'gh auth refresh' 'throttling never suggests a login'
fresh
route 'project item-list 5 --owner acme*' 'error: your token has not been granted the required scopes' 1
out=$("$AK" plan 2>&1)
assert_contains "$out" 'fix: operator: gh auth refresh -h github.com -s project' 'a missing scope is an operator step'
# A script path run with flags, or a "Run ..." instruction line, is a command, not a write (a field run,
# 2026-10-01: both named `scripts/verify.py --fast` and the split issues collided).
fresh
# shellcheck disable=SC2016
issue_route 811 $'Change `src/a.txt`.\n\n- `lib/core.sh --fast`'
# shellcheck disable=SC2016
issue_route 812 $'Change `src/b.txt`.\n\n- Run lib/core.sh and report anything unavailable.'
default_routes
out=$("$AK" plan --issue 811 --issue 812 2>&1)
assert_contains "$out" 'spawn issue=811' 'a path run with flags is not a write'
assert_contains "$out" 'spawn issue=812' 'a Run instruction line is not a write'
ws=$(cd "$repo" && bash -c '
    source "$1/lib/common.sh"; source "$1/lib/plan.sh"
    FILES=$(mktemp); git ls-files >"$FILES"
    write_set "Make \`src/a.txt\` export \`buildIt()\` and keep \`node x --y\` green."' _ "$REPO/v2")
assert_eq 'src/a.txt' "$ws" 'dropping a command span never glues its neighbours into a path'

fresh
standard_board
rm -f -- "$WORK/v2/templates/issue-worker.md"
out=$("$AK" plan 2>&1); rc=$?
assert_eq 1 "$rc" 'a missing template refuses'
assert_contains "$out" 'issue-worker.md' 'the refusal names the template'

# The shipped templates use only the placeholders their composers substitute, and the issue block stands alone.
real="$REPO/v2/templates/issue-worker.md"
assert_eq '' "$(grep -oE '\{\{[A-Z_]+\}\}' "$real" | grep -vxE '\{\{(ISSUE|TITLE|BRANCH|WORKTREE|BASE|SLUG|AK|ISSUE_BLOCK)\}\}' || true)" 'issue-worker.md has no unknown placeholders'
assert_eq 1 "$(grep -cx '{{ISSUE_BLOCK}}' "$real")" 'issue-worker.md has the issue block on its own line'

finish
