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
printf 'pr=https://github.com/acme/widget/pull/77\n' >"$repo/.worktrees/feat/issue-680/.ak/result"
printf 'pr=https://github.com/acme/widget/pull/78\nci=green\nreview=done\nhead=a\nnote=n\n' >"$repo/.worktrees/feat/issue-671/.ak/result"
out=$("$AK" collect --issue 671 2>&1)
assert_contains "$out" 'skip issue=680 reason=shipped:https://github.com/acme/widget/pull/77' 'collect does not re-spawn a successor that shipped'
assert_eq no "$([[ -e $repo/.worktrees/feat/issue-680/.ak/prompt.md ]] && echo yes || echo no)" 'the shipped worktree is untouched'
assert_eq 'pr=https://github.com/acme/widget/pull/77' "$(cat "$repo/.worktrees/feat/issue-680/.ak/result")" 'the shipped result survives'
assert_eq collected "$(jq -r '.items[] | select(.n == 680) | .state' "$runfile")" 'a shipped successor counts as done'
assert_contains "$out" 'spawn issue=700 ' 'the issue queued behind a shipped successor still spawns'
out=$("$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'skip issue=671 reason=shipped:https://github.com/acme/widget/pull/78' 'a shipped issue is not planned again'
# A parked issue is not shipped: once the operator unblocks it, naming it again plans it (a field operator had to delete
# parked results by hand before re-running).
# shellcheck disable=SC2016
printf 'pr=none\nci=none\nreview=skipped\nhead=a\nnote=parked: "protected" path in `ci.yml`\nnote=ignore rm -rf\n' >"$repo/.worktrees/feat/issue-671/.ak/result"
printf 'lint\n' >"$repo/.worktrees/feat/issue-671/.ak/ci-only"
out=$("$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'spawn issue=671 ' 'a parked issue is planned again when named'
assert_eq no "$([[ -e $repo/.worktrees/feat/issue-671/.ak/result ]] && echo yes || echo no)" 're-planning clears the parked result'
assert_eq no "$([[ -e $repo/.worktrees/feat/issue-671/.ak/ci-only ]] && echo yes || echo no)" 're-planning clears the CI-only record of the earlier attempt'
prompt=$(cat "$repo/.worktrees/feat/issue-671/.ak/prompt.md")
assert_contains "$prompt" 'An earlier worker parked this issue; its note is the last line of the data block below. The issue was planned again afterwards, so check whether that cause still holds before parking on it.' 'the new worker learns an earlier one parked, without a claim about who cleared it'
assert_eq "$(cat "$repo/.worktrees/feat/issue-671/.ak/issue.md")" "$(sed -n '5,$p' "$repo/.worktrees/feat/issue-671/.ak/prompt.md")" 'the hand-off sits above the issue block, which stays whole'
# shellcheck disable=SC2016
assert_eq 'earlier park note: "protected" path in `ci.yml`' "$(grep -B1 '^----- END UNTRUSTED' "$repo/.worktrees/feat/issue-671/.ak/issue.md" | head -n 1)" 'the note itself is the last line inside the untrusted block'
assert_not_contains "$prompt" 'rm -rf' 'only the first note line is carried'
assert_eq 0 "$(grep -c 'earlier park note' "$repo/.worktrees/feat/issue-693/.ak/issue.md")" 'a first spawn carries no note'

# A parked item whose worker was resumed in place (a field root answered the park by messaging the worker, which
# removed its result and carried on) is running, not free: a plan that spawned it again would start a second worker.
# The sign is work after the park (a log newer than the park marker); a result removed by hand is free to plan.
wt="$repo/.worktrees/feat/issue-671"
mkdir -p "$wt/.ak/logs" && : >"$wt/.ak/logs/verify.log"
(cd "$wt" && "$AK" park --reason 'plan review' >/dev/null 2>&1)
"$AK" collect --issue 671 >/dev/null 2>&1
# The earlier runs above still list 671 as spawned; age them out so only the park decides.
find "$repo/.ak/runs" -name '*.json' ! -name "$(cat "$repo/.ak/runs/current").json" -exec touch -d '-2 days' {} +
assert_eq parked "$(jq -r '.items[] | select(.n == 671) | .state' "$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json")" 'collect records the park'
mkdir -p "$wt/.ak/logs"
touch -d '-2 minutes' "$wt"/.ak/logs/* "$wt/.ak/logs/setup.log"
touch -d '-1 minute' "$wt/.ak/parked"
rm -f "$wt/.ak/result"
out=$("$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'spawn issue=671 ' 'a parked result removed with no work after it is planned again'
assert_eq no "$([[ -e $wt/.ak/parked ]] && echo yes || echo no)" 're-planning clears the park marker'
(cd "$wt" && "$AK" park --reason 'plan review' >/dev/null 2>&1)
"$AK" collect --issue 671 >/dev/null 2>&1
touch -d '-2 minutes' "$wt"/.ak/logs/*
touch -d '-1 minute' "$wt/.ak/parked"
rm -f "$wt/.ak/result"
touch "$wt/.ak/logs/verify.log"
out=$("$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'skip issue=671 reason=running' 'a parked item with work after the park has a worker on it again'

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
board_route 5 "{\"items\":[$(board_item 700 Backlog),$(board_item 671 Ready)]}"
issue_route 671 'x'
issue_route 700 'y'
default_routes
out=$("$AK" plan --yolo 2>&1)
assert_eq 'spawn issue=671 spawn issue=700' "$(grep -o 'spawn issue=[0-9]*' <<<"$out" | paste -sd' ')" '--yolo adds Backlog after Ready'

# An empty plan says how to get work instead of stopping silently (a field operator re-ran one twice).
fresh
board_route 5 "{\"items\":[$(board_item 69 Ready '["tier:human-only"]'),$(board_item 700 Backlog),$(board_item 701 Backlog)]}"
default_routes
out=$("$AK" plan 2>&1)
assert_contains "$out" 'next=nothing workable in Ready; --yolo adds 2 Backlog issues, or name issues with --issue N' 'an empty plan names the Backlog way forward'
out=$("$AK" plan --issue 69 2>&1)
assert_contains "$out" 'next=nothing workable; name issues with --issue N' 'an empty named plan says so'
fresh
standard_board
out=$("$AK" plan 2>&1)
assert_not_contains "$out" 'next=' 'a plan that spawns prints no next line'

fresh
items=$(for n in $(seq 100 130); do printf '%s\n' "$(board_item "$n" Ready '["blocked"]')"; done | paste -sd, -)
board_route 5 "{\"items\":[$items,$(board_item 671 Ready)]}"
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
route 'api graphql*' 'gh: GraphQL: API rate limit already exceeded for user ID 1.' 1
out=$("$AK" plan 2>&1); rc=$?
assert_eq 1 "$rc" 'a throttled board read refuses'
assert_contains "$out" 'API rate limit already exceeded' 'the refusal quotes the real error'
assert_contains "$out" 'fix: wait for the GitHub rate limit' 'throttling says wait'
assert_not_contains "$out" 'gh auth refresh' 'throttling never suggests a login'
fresh
route 'api graphql*' 'gh: your token has not been granted the required scopes' 1
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

# An explicit file list is the author's write set, and a fenced block is a command, not a write (a field run,
# 2026-10-05: three independent issues shared a contract paragraph and a fenced command naming four paths, so two of
# three named issues were dropped as collisions).
fresh
shared=$'Rules: do not change src/b.txt or the lib/core.sh runner.\n\n```sh\npy scripts/q.py -- lib/core.sh\n```\n'
# shellcheck disable=SC2016
issue_route 821 "$(printf 'Owned paths:\n\n- Modify: `src/a.txt`\n- Create: `lib/new.sh`\n\n%s' "$shared")"
# shellcheck disable=SC2016
issue_route 822 "$(printf 'Owned paths:\n\n- Create: `src/c.txt`\n\n%s' "$shared")"
# shellcheck disable=SC2016
issue_route 823 "$(printf 'Owned paths:\n\n- Modify: `lib/new.sh`\n\n%s' "$shared")"
# shellcheck disable=SC2016
issue_route 824 "$(printf 'Change `src/b.txt`.\n\n```\nnode lib/core.sh\n```')"
# shellcheck disable=SC2016
issue_route 825 'Rewrite `lib/core.sh`.'
default_routes
out=$("$AK" plan --issue 821 --issue 822 --issue 823 --issue 824 --issue 825 2>&1)
assert_contains "$out" 'spawn issue=821' 'the first listed issue spawns'
assert_contains "$out" 'spawn issue=822' 'shared prose and fenced paths outside the list do not collide'
assert_contains "$out" 'drop issue=823 reason=collides-with-#821' 'a listed path shared with an earlier list still collides'
assert_contains "$out" 'spawn issue=825' 'without a list, a path inside a fenced block is not a write'
# The list narrows collisions, never the protected-path guard: a worker reads the whole body.
fresh
# shellcheck disable=SC2016
issue_route 826 "$(printf 'Owned paths:\n\n- Modify: `src/a.txt`\n\nAlso edit .github/workflows/ci.yml to add the step.')"
# shellcheck disable=SC2016
issue_route 827 "$(printf 'Change `src/b.txt`.\n\n```\nsed -i s/a/b/ .github/workflows/ci.yml\n```')"
default_routes
out=$("$AK" plan --issue 826 --issue 827 2>&1)
assert_contains "$out" 'drop issue=826 reason=protected:.github/workflows/ci.yml' 'a protected path outside the list still drops'
assert_contains "$out" 'drop issue=827 reason=protected:.github/workflows/ci.yml' 'a protected path inside a fenced block still drops'
# A protected entry without a trailing slash or glob is a prefix (field run: `docs/adrs` let two ADR edits ship).
fresh
(cd "$repo" && mkdir -p docs/adrs docs/adrs-old && printf 'x\n' >docs/adrs/adr-001.md && printf 'x\n' >docs/adrs-old/x.md &&
    git add . && git commit -q -m docs && git push -q origin main)
printf 'AGENT_PROTECTED_PATHS=.github/**,docs/adrs\n' >>"$repo/.agent/config.env"
# shellcheck disable=SC2016
issue_route 831 "$(printf 'Owned paths:\n\n- Modify: `docs/adrs/adr-001.md`')"
# shellcheck disable=SC2016
issue_route 832 "$(printf 'Owned paths:\n\n- Modify: `docs/adrs-old/x.md`')"
# shellcheck disable=SC2016
issue_route 833 "$(printf 'Owned paths:\n\n- Modify: `.github/workflows/ci.yml`')"
default_routes
out=$("$AK" plan --issue 831 --issue 832 --issue 833 2>&1)
assert_contains "$out" 'drop issue=831 reason=protected:docs/adrs/adr-001.md' 'a bare directory entry protects its subpaths'
assert_contains "$out" 'spawn issue=832' 'a bare directory entry does not match a sibling that shares its prefix'
assert_contains "$out" 'drop issue=833 reason=protected:.github/workflows/ci.yml' 'a glob entry still matches beside a bare one'
# protected_hit per entry shape: trailing slash and bare entries are prefixes, globs stay globs, `/`, `.`, `./`
# and an empty item protect nothing, and a leading `./` is stripped like a listed path's.
ph() {
    AGENT_PROTECTED_PATHS=$1 bash -c 'AK_HOME=$1; source "$1/lib/common.sh"; source "$1/lib/plan.sh"; protected_hit "$2"' _ "$REPO/v2" "$2"
}
assert_eq 'docs/adrs/x.md' "$(ph 'docs/adrs/' 'docs/adrs/x.md')" 'a trailing-slash entry protects its subpaths'
assert_eq '' "$(ph 'docs/adrs/' 'docs/adrs-old/x.md')" 'a trailing-slash entry does not match a sibling prefix'
assert_eq 'docs/adrs' "$(ph 'docs/adrs' 'docs/adrs')" 'a bare entry protects the exact path'
assert_eq 'docs/adrs/x.md' "$(ph 'docs/adrs' 'docs/adrs/x.md')" 'a bare entry protects its subpaths'
assert_eq '' "$(ph 'docs/adrs' $'docs/adrsx\ndocs/adrsx/y')" 'a bare entry does not match a sibling prefix'
assert_eq '.github/workflows/ci.yml' "$(ph '.github/**' '.github/workflows/ci.yml')" 'a ** glob still matches'
assert_eq '' "$(ph '.github/**' $'.github\n.githubx/y')" 'a ** glob is not a prefix'
assert_eq 'src/a.sh' "$(ph 'src/*.sh' $'src/a.txt\nsrc/a.sh')" 'a * glob still matches'
assert_eq '' "$(ph 'src/*.sh' $'src\nlib/a.sh')" 'a * glob is not a prefix'
for entry in '/' '.' './' '' '.github/**,,docs/adrs' ' , '; do
    assert_eq '' "$(ph "$entry" $'src/a.txt\n.\n/')" "entry '$entry' protects nothing"
done
assert_eq 'docs/adrs/x.md' "$(ph './docs/adrs' 'docs/adrs/x.md')" 'a leading ./ is stripped from a bare entry'
assert_eq 'docs/adrs/x.md' "$(ph './docs/adrs/' 'docs/adrs/x.md')" 'a leading ./ is stripped from a trailing-slash entry'
assert_eq 'src/a.sh' "$(ph './src/*.sh' 'src/a.sh')" 'a leading ./ is stripped from a glob entry'
# shellcheck disable=SC2016
ws=$(cd "$repo" && bash -c '
    AK_HOME=$1; source "$1/lib/common.sh"; source "$1/lib/plan.sh"
    FILES=$(mktemp); git ls-files >"$FILES"
    write_set "$2"' _ "$REPO/v2" "$(printf -- '- Modify: `src/a.txt`, `./src/b.txt`.\n- Create: `deploy/native/lock.json`\n- Test: `tests/t.sh`\nAlso see lib/core.sh.')")
assert_eq $'deploy/native/lock.json\nsrc/a.txt\nsrc/b.txt\ntests/t.sh' "$ws" 'listed paths are taken as written, new directories included, and prose paths are left out'
# shellcheck disable=SC2016
ws=$(cd "$repo" && bash -c '
    AK_HOME=$1; source "$1/lib/common.sh"; source "$1/lib/plan.sh"
    FILES=$(mktemp); git ls-files >"$FILES"
    write_set "$2"' _ "$REPO/v2" "$(printf -- '- Modify: `src/../.github/workflows/ci.yml`, `lib/./core.sh`, `../outside.txt`, `/etc/passwd`\n```sh\n~~~\n```\n- Create: `src/c.txt`')")
assert_eq $'.github/workflows/ci.yml\nlib/core.sh\nsrc/c.txt' "$ws" 'listed paths are normalised, paths that leave the repository are dropped, and a ~~~ inside a backtick fence does not close it'

# A spawn whose worker never started does not block re-planning once the grace has passed (field run: a lost plan
# output left five never-started spawns that every later plan skipped as running); a started worker still does.
fresh
standard_board
"$AK" plan >/dev/null 2>&1
wt="$repo/.worktrees/feat/issue-671"
out=$(AK_SPAWN_GRACE=0 "$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'spawn issue=671 ' 'a never-started spawn is planned again'
mkdir -p "$wt/.ak/logs"
out=$(AK_SPAWN_GRACE=0 "$AK" plan --new --issue 671 2>&1)
assert_contains "$out" 'skip issue=671 reason=running' 'a started worker still blocks re-planning'
out=$("$AK" plan --new --issue 693 2>&1)
assert_contains "$out" 'skip issue=693 reason=running' 'a fresh spawn inside the grace still counts as running'

# One plan at a time: a live lock holder makes a second plan wait, then refuse; a dead holder's lock is taken over.
sleep 30 &
holder=$!
mkdir -p "$repo/.ak/locks/run" && printf '%s\n' "$holder" >"$repo/.ak/locks/run/pid"
out=$(AK_RUN_LOCK_WAIT=1 "$AK" plan --new --issue 700 2>&1); rc=$?
assert_eq 1 "$rc" 'a plan waits for a live lock holder, then refuses'
assert_contains "$out" 'another ak plan or ak collect is still running' 'the refusal names the cause'
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
out=$("$AK" plan --new --issue 700 2>&1); rc=$?
assert_eq 0 "$rc" "a dead holder's lock is taken over"
assert_eq no "$([[ -e $repo/.ak/locks/run ]] && echo yes || echo no)" 'a finished plan releases its lock'
# A plan that outlives an agent's shell yield says to wait rather than re-run (a field root re-ran a yielded plan).
out=$(AK_SLOW_NOTICE=0 "$AK" plan --new --issue 700 2>&1)
assert_contains "$out" 'ak plan: still working; wait for this call to finish. If its output is lost, run the same ak plan again' 'a slow plan says to wait, and how to get lost output back'
assert_not_contains "$out" 'do not re-run' 'the notice never forbids the re-run that recovers a lost plan (a field root stopped for good on it)'
out=$("$AK" plan --new --issue 700 2>&1)
assert_not_contains "$out" 'still working' 'a fast plan prints no notice'

# sync_base: a reused worktree with commits of its own merges the new base; on conflict it leaves .ak/resolve.
sb=$(mktemp -d)
git -C "$sb" init -q -b main && git -C "$sb" config user.email t@t && git -C "$sb" config user.name t
printf 'a\n' >"$sb/f" && git -C "$sb" add f && git -C "$sb" commit -q -m base
git -C "$sb" checkout -q -b pred && printf 'pred\n' >"$sb/p" && git -C "$sb" add p && git -C "$sb" commit -q -m pred
git -C "$sb" checkout -q -b own main && printf 'own\n' >"$sb/o" && git -C "$sb" add o && git -C "$sb" commit -q -m own
mkdir -p "$sb/.akd"
run_sync() { bash -c 'AK_LOG=/dev/null; source "$1/lib/common.sh"; source "$1/lib/plan.sh"; sync_base "$2" "$3" "$4"' _ "$REPO/v2" "$@"; }
run_sync "$sb" pred "$sb/.akd"
assert_rc 0 'a worktree with its own commits gets the new base merged in' -- git -C "$sb" merge-base --is-ancestor pred HEAD
assert_eq no "$([[ -e $sb/.akd/resolve ]] && echo yes || echo no)" 'a clean merge leaves no resolve marker'
git -C "$sb" checkout -q -b clash main && printf 'clash\n' >"$sb/p" && git -C "$sb" add p && git -C "$sb" commit -q -m clash
run_sync "$sb" pred "$sb/.akd"
assert_eq pred "$(cat "$sb/.akd/resolve")" 'a conflicting base is left to the worker as .ak/resolve'
assert_eq '' "$(git -C "$sb" status --porcelain -- p f o)" 'a conflicting merge is aborted, not left half-done'

# A blocker sitting In progress with no PR is named as such (a field dependent dropped run after run behind a stale one).
fresh
board_route 5 "{\"items\":[$(board_item 1 'In progress'),$(board_item 690 Ready)]}"
route 'api repos/acme/widget/issues/690/dependencies/blocked_by*' '[{"number":1,"state":"open"}]'
issue_route 690 'x'
default_routes
out=$("$AK" plan 2>&1)
assert_contains "$out" 'drop issue=690 reason=blocked-by:#1(in-progress-without-pr)' 'an In-progress blocker with no PR is named'

# A path the issue names that sits only in the operator's checkout drops the issue with the fix (a field worker built
# without the untracked spec its issue named; two later issues parked on the gap).
fresh
mkdir -p docs && printf 'spec\n' >docs/spec.md && printf 'ignored\n' >.agent/notes.md
issue_route 800 'Implement per docs/spec.md and .agent/notes.md in src/a.txt'
issue_route 801 'Edit src/b.txt per docs/absent.md'
default_routes
out=$("$AK" plan --issue 800 --issue 801 2>&1)
assert_contains "$out" "drop issue=800 reason=missing-at-base:docs/spec.md note=only in the operator's checkout, so no worker can see it; the operator decides whether it belongs on main" 'an untracked file the issue names drops it and leaves the commit to the operator'
assert_not_contains "$out" 'commit and push' 'the drop never tells an agent to publish a file an issue named'
assert_contains "$out" 'spawn issue=801' 'a named path that exists nowhere (a file to create) and a git-ignored one do not drop'
git add docs/spec.md && git commit -q -m spec
out=$("$AK" plan --new --issue 800 2>&1)
assert_contains "$out" 'missing-at-base:docs/spec.md' 'a committed but unpushed file is still missing at the base'
git push -q origin main
out=$("$AK" plan --new --issue 800 2>&1)
assert_contains "$out" 'spawn issue=800' 'once the file is on the base branch the issue spawns'
printf 'spec\n' >SPEC.md
issue_route 802 'Follow SPEC.md (v2.0, e.g. src/b.txt)'
out=$("$AK" plan --new --issue 802 2>&1)
assert_contains "$out" 'drop issue=802 reason=missing-at-base:SPEC.md' 'a root-level file the issue names counts too'
rm -f SPEC.md
printf 'secret\n' >"$WORK/outside.txt"
issue_route 803 "Use ../$(basename "$WORK")/outside.txt and ../outside.txt and src/a.txt"
( cd "$repo" && ln -s "$WORK" up 2>/dev/null )
out=$("$AK" plan --new --issue 803 2>&1)
assert_not_contains "$out" 'missing-at-base' 'a path that climbs out of the checkout is never probed or printed'
rm -f "$repo/up"

# A re-run of the same plan resumes even when one named issue was dropped, and reprints that drop (a field root lost the
# plan output and could not get it back: the dropped issue made the re-run a new plan that skipped everything).
fresh
issue_route 810 'Edit src/a.txt'
route 'api repos/acme/widget/issues/811' '{"number":811,"title":"T","state":"open","body":"x","labels":[{"name":"needs:brainstorm"}]}'
default_routes
first=$("$AK" plan --issue 810 --issue 811 2>&1)
assert_contains "$first" 'drop issue=811 reason=label:needs:brainstorm' 'the labelled issue drops'
again=$("$AK" plan --issue 810 --issue 811 2>&1)
assert_eq "$(sed -n 1p <<<"$first") resumed" "$(sed -n 1p <<<"$again")" 'the identical re-run resumes the run'
assert_eq "$(sed 1d <<<"$first")" "$(sed 1d <<<"$again")" 'the resume prints the same spawn and drop lines'
mkdir -p "$repo/.worktrees/feat/issue-810/.ak/logs"
issue_route 812 'Edit src/b.txt'
out=$("$AK" plan --issue 810 --issue 812 2>&1)
assert_contains "$out" 'skip issue=810 reason=running' 'a started worker is skipped by a later plan'
again=$("$AK" plan --issue 810 --issue 812 2>&1)
assert_contains "$again" 'resumed' 'a re-run with a skipped issue also resumes'
assert_eq 1 "$(grep -c 'spawn issue=812' <<<"$again")" 'the unstarted spawn is offered again'
mkdir -p "$repo/.worktrees/feat/issue-812/.ak/logs"
again=$("$AK" plan --issue 810 --issue 812 2>&1)
assert_not_contains "$again" 'spawn issue=812' 'once its worker started, a resume never offers the spawn a second time'

# A blocker that already shipped (open PR on its branch) is the stack parent, not a drop; and a named issue that
# overlaps a dropped one is held with it (a field re-plan of a chain dropped four links and spawned the fifth on main).
fresh
git checkout -q -b feat/issue-820 && printf 'p\n' >src/p.txt && git add src/p.txt && git commit -q -m p && git push -q origin feat/issue-820 && git checkout -q main
issue_route 821 'Edit src/a.txt'
issue_route 822 'Edit src/a.txt too'
issue_route 823 'Edit src/b.txt'
issue_route 824 'Edit src/b.txt too'
route 'api repos/acme/widget/issues/821/dependencies/blocked_by*' '[{"number":820,"state":"open"}]'
route 'api repos/acme/widget/issues/823/dependencies/blocked_by*' '[{"number":1,"state":"open"}]'
route 'api repos/acme/widget/pulls?state=open&head=acme:feat/issue-820*' '[{"number":50}]'
default_routes
out=$("$AK" plan --serialize --issue 821 --issue 822 --issue 823 --issue 824 2>&1)
wt821="$repo/.worktrees/feat/issue-821"
assert_contains "$out" "spawn issue=821 cwd=$wt821" 'an issue blocked only by a shipped issue spawns'
assert_eq 'feat/issue-820' "$(cat "$wt821/.ak/base")" 'its PR base is the shipped blocker branch'
assert_eq "$(git rev-parse origin/feat/issue-820)" "$(git -C "$wt821" rev-parse HEAD)" 'its worktree starts from that branch'
assert_contains "$out" 'after issue=822 needs=821' 'the next link queues behind it'
assert_contains "$out" 'drop issue=823 reason=blocked-by:#1' 'a blocker with no PR still drops'
assert_contains "$out" 'drop issue=824 reason=needs-dropped-#823' 'a named issue that overlaps a dropped one is dropped with it, not spawned'
# An issue with an open PR, and one whose worktree cannot be reused, hold the named issues that overlap them too.
fresh
issue_route 840 'Edit src/a.txt'
issue_route 841 'Edit src/a.txt as well'
issue_route 842 'Edit src/b.txt'
issue_route 843 'Edit src/b.txt as well'
route 'api repos/acme/widget/pulls?state=open&head=acme:feat/issue-840*' '[{"number":60}]'
default_routes
git worktree add -q -b feat/issue-842 "$repo/.worktrees/feat/issue-842" origin/main && printf 'dirty\n' >"$repo/.worktrees/feat/issue-842/src/b.txt"
out=$("$AK" plan --issue 840 --issue 841 --issue 842 --issue 843 2>&1)
assert_contains "$out" 'drop issue=841 reason=needs-dropped-#840' 'an issue overlapping one with an open PR is held with it'
assert_contains "$out" 'drop issue=842 reason=worktree-unusable' 'a dirty leftover worktree drops its issue'
assert_contains "$out" 'drop issue=843 reason=needs-dropped-#842' 'an issue overlapping a worktree drop is held with it'
assert_eq 4 "$(jq '.others | length' "$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json")" 'every drop, the worktree one included, is stored for a resume'

# An issue listed above its blocker queues behind it once the blocker is chosen, and so does the issue behind that one
# (a field board listed a three-issue chain in reverse: the blocker spawned and the other two stayed dropped).
fresh
board_route 5 "{\"items\":[$(board_item 852 Ready),$(board_item 851 Ready),$(board_item 850 Ready),$(board_item 853 Ready)]}"
issue_route 850 'Edit src/a.txt'
issue_route 851 'Edit lib/core.sh'
issue_route 852 'Edit src/b.txt'
issue_route 853 'Anything else'
route 'api repos/acme/widget/issues/851/dependencies/blocked_by*' '[{"number":850,"state":"open"}]'
route 'api repos/acme/widget/issues/852/dependencies/blocked_by*' '[{"number":851,"state":"open"}]'
route 'api repos/acme/widget/issues/853/dependencies/blocked_by*' '[{"number":1,"state":"open"}]'
default_routes
out=$("$AK" plan --limit 5 2>&1)
assert_contains "$out" 'spawn issue=850' 'the blocker spawns'
assert_contains "$out" 'after issue=851 needs=850' 'the issue listed above its blocker queues behind it'
assert_contains "$out" 'after issue=852 needs=851' 'and the issue behind that one follows'
assert_not_contains "$out" 'drop issue=851' 'its earlier drop line is withdrawn'
assert_contains "$out" 'drop issue=853 reason=blocked-by:#1' 'a blocker outside the run still drops'
assert_eq '850 851 852' "$(jq -r '[.items[].n] | join(" ")' "$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json")" 'the run file holds the chain in dependency order'
assert_eq '853' "$(jq -r '[.others[].n] | join(" ")' "$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json")" 'only the real drop is stored'
assert_eq 1 "$(grep -c 'issues/851/dependencies' "$FAKE_GH_LOG")" 'the second look at a dropped issue reads GitHub no further'
assert_eq origin/feat/issue-850 "$(git -C "$repo/.worktrees/feat/issue-850" rev-parse --abbrev-ref '@{u}' 2>&1)" 'the spawned branch is pushed and tracked'

# The reads for a batch of candidates run at once (a field plan read 26 candidates one call after another and took
# 60 s to print 3 spawn lines), and every spawned branch goes up in one push.
fresh
items=$(for n in $(seq 900 907); do printf '%s\n' "$(board_item "$n" Ready)"; done | paste -sd, -)
board_route 5 "{\"items\":[$items]}"
for n in $(seq 900 907); do issue_route "$n" "Edit only docs/$n.md"; done
route 'api repos/acme/widget/issues/90[2-7]/dependencies/blocked_by*' '[{"number":1,"state":"open"}]'
default_routes
out=$(FAKE_GH_DELAY=0.3 "$AK" plan --limit 8 2>&1)
assert_eq 2 "$(grep -c '^spawn issue=90[01] ' <<<"$out")" 'the plan spawns the two unblocked issues'
assert_eq 6 "$(grep -c '^drop issue=90[2-7] reason=blocked-by:#1' <<<"$out")" 'and drops the six blocked ones'
# Calls in flight at once, from the fake gh log: a line per call when it starts and `done` when it ends.
peak=$(awk '$0 == "done" { now-- ; next } { now++; if (now > max) max = now } END { print max + 0 }' "$FAKE_GH_LOG")
assert_eq 1 "$((peak >= 8))" "a batch of candidate reads is in flight at once (peak $peak)"
assert_eq 'origin/feat/issue-900 origin/feat/issue-901' "$(for n in 900 901; do git -C "$repo/.worktrees/feat/issue-$n" rev-parse --abbrev-ref '@{u}'; done | paste -sd' ')" 'both branches are pushed and tracked'
assert_eq 2 "$(grep -c 'project item-edit' "$FAKE_GH_LOG")" 'both issues move on the board'

# A queued issue that needs both an in-run blocker and a shipped one outside the run gets the shipped branch too
# when it spawns, and a collision drop holds what would build on it.
fresh
git checkout -q -b feat/issue-830 && printf 'q\n' >src/q.txt && git add src/q.txt && git commit -q -m q && git push -q origin feat/issue-830 && git checkout -q main
issue_route 831 'Edit src/a.txt'
issue_route 832 'Edit lib/core.sh'
issue_route 833 'Edit src/a.txt and src/b.txt'
issue_route 834 'Edit src/b.txt'
route 'api repos/acme/widget/issues/832/dependencies/blocked_by*' '[{"number":831,"state":"open"},{"number":830,"state":"open"}]'
route 'api repos/acme/widget/pulls?state=open&head=acme:feat/issue-830*' '[{"number":51}]'
default_routes
out=$("$AK" plan --issue 831 --issue 832 --issue 833 --issue 834 2>&1)
runfile="$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json"
assert_contains "$out" 'after issue=832 needs=831' 'an issue with an in-run and a shipped blocker queues behind the in-run one'
assert_eq 830 "$(jq -r '.items[] | select(.n == 832) | .stack' "$runfile")" 'the run records the shipped blocker it also needs'
assert_contains "$out" 'drop issue=833 reason=collides-with-#831' 'without --serialize a collision drops'
assert_contains "$out" 'drop issue=834 reason=needs-dropped-#833' 'what overlaps a collision drop is held with it'
printf 'pr=https://github.com/acme/widget/pull/52\nci=green\nreview=done\nhead=a\nnote=n\n' >"$repo/.worktrees/feat/issue-831/.ak/result"
out=$("$AK" collect --issue 831 2>&1)
assert_contains "$out" 'spawn issue=832' 'collecting the in-run blocker releases it'
assert_rc 0 'the spawned successor contains the shipped blocker branch' -- git -C "$repo/.worktrees/feat/issue-832" merge-base --is-ancestor origin/feat/issue-830 HEAD

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
