#!/usr/bin/env bash
# Exercise the real runner through startup, cleanup and persistence; only external processes are doubled.
set -uo pipefail
TEST_NAME='bench tui lifecycle'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
source "$here/lib/assert.sh"
tmp=$(mktemp -d)
cleanup() {
    if [[ -f $tmp/claude-projects ]]; then
        while IFS= read -r project; do rm -rf -- "$project"; done <"$tmp/claude-projects"
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/bin" "$tmp/kit/bench/live" "$tmp/kit/bench/issues" "$tmp/kit/bench/results"
cp "$repo_root"/bench/live/{trial-tui.sh,trial-lib.sh,score.py,gh-calls.py,gh-shim} "$tmp/kit/bench/live/"
cp "$here/fixtures/bench-tui/command.py" "$tmp/bin/command.py"
chmod +x "$tmp/bin/command.py"
for command in tmux codex claude gh git sleep; do ln -s command.py "$tmp/bin/$command"; done
printf '{"repo":"fixture/repo","board":{"number":1},"tag":"fixture-v1"}\n' >"$tmp/kit/bench/live/sandbox.json"
printf 'status: Ready\n' >"$tmp/kit/bench/issues/11-fixture.md"
cat >"$tmp/kit/bench/live/sandbox.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"tally-11":11}\n' >"$AK_BENCH_WORK/current-issues.json"
STUB
cat >"$tmp/kit/bench/live/outcome.sh" <<'STUB'
#!/usr/bin/env bash
jq -n --argjson rc "$4" '{exit_rc:$rc,passed:1,prs:1,prs_green:1,wanted:1}'
STUB
chmod +x "$tmp/kit/bench/live/"*.sh
git -C "$tmp/kit" init -q -b fixture
git -C "$tmp/kit" add .
git -C "$tmp/kit" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
printf '{}\n' >"$tmp/auth.json"
export TUI_FIXTURE="$tmp" TUI_REAL_GIT
TUI_REAL_GIT=$(command -v git)
run_case() {
    local mode=$1 harness=${2:-codex}
    trial="$mode-$harness"
    : >"$tmp/calls"; : >"$tmp/invocations"
    out=$(TUI_MODE="$mode" PATH="$tmp/bin:$PATH" AK_BENCH_WORK="$tmp/work" \
        AK_BENCH_CODEX_AUTH="$tmp/auth.json" AK_BENCH_TUI_READY_TIMEOUT=1 \
        AK_BENCH_TUI_POLL=0 timeout 8 "$tmp/kit/bench/live/trial-tui.sh" \
        --harness "$harness" --ref HEAD --issues 11 --trial "$trial" --timeout 1 2>&1)
    rc=$?
    row="$tmp/work/$trial/row.json"
}

for harness in codex claude; do
    run_case normal "$harness"
    assert_eq 0 "$rc" "$harness: completed work survives CLI closing on first interrupt"
    assert_eq 1 "$(wc -l <"$tmp/invocations")" "$harness: CLI receives exactly one initial invocation"
    assert_eq yes "$([[ -f $row ]] && echo yes || echo no)" "$harness: completed score is persisted"
    assert_contains "$out" 'turn started' "$harness: startup is confirmed from the transcript"
done
assert_eq root "$(jq -r .session_id "$tmp/work/normal-codex/row.json" 2>/dev/null)" 'a newer child rollout cannot replace the root score'

for mode in no-start child-only; do
    run_case "$mode"
    assert_eq 1 "$rc" "$mode: an idle composer is not a started turn"
    assert_contains "$out" 'no agent turn' "$mode: startup failure names the missing signal"
    assert_not_contains "$(cat "$tmp/calls")" '/pulls?' "$mode: receipts are not polled before a turn starts"
    assert_eq 1 "$(wc -l <"$tmp/invocations")" "$mode: failed startup never resubmits the invocation"
done

run_case already-gone
assert_eq 0 "$rc" 'a CLI already gone at cleanup does not fail completed work'
assert_eq 0 "$(jq -r .outcome.exit_rc "$row" 2>/dev/null)" 'already-gone trial keeps its successful outcome'
assert_eq 1 "$(grep -c '"trial": "already-gone-codex"' "$tmp/kit/bench/results/live.jsonl" 2>/dev/null)" 'already-gone trial appends exactly one ledger row'

run_case cleanup-error
assert_eq 1 "$rc" 'an unexpected cleanup error fails the trial'
assert_contains "$out" 'unexpected terminal write error' 'unexpected cleanup diagnostics stay visible'
assert_eq 1 "$(jq -r .outcome.exit_rc "$row" 2>/dev/null)" 'cleanup error is preserved in the scored outcome'

run_case premature
assert_eq 1 "$rc" 'a CLI exit before receipts is a failure rather than a timeout or success'
assert_eq 1 "$(jq -r .outcome.exit_rc "$row" 2>/dev/null)" 'premature exit still persists a failed score'
finish
