#!/usr/bin/env bash
# The live benchmark's actual issue bodies must plan two independent pairs, not four singleton waves.
TEST_NAME=v2-bench-plan
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=plan-fixture.sh
source "$V2_TESTS/plan-fixture.sh"

repo=$(board_repo)
cd "$repo" || exit 1
cp -R "$REPO/bench/fixtures/tally/src" "$REPO/bench/fixtures/tally/test" .
git add src test && git commit -q -m tally && git push -q origin main
board_route 5 "{\"items\":[$(board_item 11 Ready),$(board_item 12 Backlog),$(board_item 13 Ready),$(board_item 14 Backlog)]}"
for n in 11 12 13 14; do
    body=$(
        issue_file=("$REPO"/bench/issues/"$n"-*.md)
        # The same renderer used by sandbox create/reset, including front-matter removal.
        # shellcheck source=../../bench/live/sandbox.sh
        source "$REPO/bench/live/sandbox.sh"
        issue_body "${issue_file[0]}"
    )
    issue_route "$n" "$body"
done
route 'api repos/acme/widget/issues/12/dependencies/blocked_by*' '[{"number":11,"state":"open"}]'
route 'api repos/acme/widget/issues/14/dependencies/blocked_by*' '[{"number":13,"state":"open"}]'
default_routes

out=$("$AK" plan --serialize --yolo --limit 4 2>&1); rc=$?
assert_eq 0 "$rc" 'the live benchmark invocation plans successfully'
assert_eq '11 13' "$(sed -n 's/^spawn issue=\([0-9]*\) .*/\1/p' <<<"$out" | paste -sd ' ' -)" 'both independent workers start together'
runfile="$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json"
assert_eq '[[11,1,[]],[12,2,[11]],[13,1,[]],[14,2,[13]]]' \
    "$(jq -c '[.items | sort_by(.n)[] | [.n,.wave,.needs]]' "$runfile")" 'only the two real dependency edges determine the waves'

# Feed the printed task names into native child metadata, then let wait find those exact workers.
export CODEX_THREAD_ID=bench-root CODEX_HOME="$WORK/codex"
mkdir -p "$CODEX_HOME/sessions"
while read -r name; do
    jq -nc --arg name "$name" '{type:"session_meta",payload:{parent_thread_id:"bench-root",agent_path:("/root/" + $name)}}' >"$CODEX_HOME/sessions/rollout-$name.jsonl"
    printf '{"type":"event_msg","payload":{"type":"task_started"}}\n' >>"$CODEX_HOME/sessions/rollout-$name.jsonl"
done < <(sed -n 's/^spawn .* name=//p' <<<"$out")
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq 3 "$rc" 'the printed workers are still running'
assert_eq $'issue=11 state=running\nissue=13 state=running\nwave=1 settled=0/2' "$out" 'wait matches both printed names to their native transcripts'
unset CODEX_THREAD_ID CODEX_HOME

# Settle both first-wave workers through the real collect boundary, then release the second pair.
for n in 11 13; do
    printf 'pr=https://github.com/acme/widget/pull/%s\nci=green\nreview=done\nhead=abc\nnote=n\n' "$n" >"$repo/.worktrees/feat/issue-$n/.ak/result"
    "$AK" collect --issue "$n" >"$WORK/collect-$n.out" 2>&1
done
out=$("$AK" collect --wave 2>&1); rc=$?
assert_eq 0 "$rc" 'releasing the next wave succeeds'
assert_eq '12 14' "$(sed -n 's/^spawn issue=\([0-9]*\) .*/\1/p' <<<"$out" | paste -sd ' ' -)" 'both dependent workers start together'
assert_eq 2 "$(jq -r '.open_wave' "$runfile")" 'the second wave is the final wave'

finish
