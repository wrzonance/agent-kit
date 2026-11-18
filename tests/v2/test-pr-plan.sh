#!/usr/bin/env bash
# ak pr-plan: one worktree and worker prompt per open PR, and a run file.
TEST_NAME=v2-pr-plan
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1
for b in feat/a feat/b; do
    git checkout -q -b "$b" main
    printf '%s\n' "$b" >"src/${b#feat/}.txt"
    git add src && git commit -q -m "$b" && git push -q origin "$b" 2>/dev/null
done
git checkout -q main
git branch -q -D feat/b
git worktree add -q "$WORK/existing-a" feat/a

pr_json() { # N HEAD BASE STATE [MERGED_AT] [HEAD_REPO]
    printf '{"number":%s,"title":"Fix & things <%s>","state":"%s","merged_at":%s,"head":{"ref":"%s","sha":"abc","repo":{"full_name":"%s"}},"base":{"ref":"%s"}}' \
        "$1" "$1" "$4" "${5:-null}" "$2" "${6:-acme/widget}" "$3"
}
route 'api repos/acme/widget/pulls/11' "$(pr_json 11 feat/a main open)"
route 'api repos/acme/widget/pulls/12' "$(pr_json 12 feat/b feat/a open)"
route 'api repos/acme/widget/pulls/13' "$(pr_json 13 feat/c main closed)"
route 'api repos/acme/widget/pulls/14' "$(pr_json 14 feat/d main closed '"2026-01-01T00:00:00Z"')"
route 'api repos/acme/widget/pulls/15' "$(pr_json 15 feat/e main open null someone/fork)"

out=$("$AK" pr-plan 2>&1); rc=$?
assert_eq 2 "$rc" 'no --pr is a usage error'
out=$("$AK" pr-plan --pr x 2>&1); rc=$?
assert_eq 2 "$rc" 'a non-numeric PR is a usage error'

printf 'dirty\n' >>src/a.txt
export CODEX_HOME=/x AGENT_WORKER_MODELS='claude-sonnet-5,gpt-5.6-terra' AGENT_WORKER_EFFORT=high
out=$("$AK" pr-plan --pr 11 --pr 12 --pr 13 --pr 14 --pr 15 --pr 11 2>&1); rc=$?
assert_eq 0 "$rc" 'pr-plan exits 0'
run=$(sed -n 's/^run=//p' <<<"$out")
assert_contains "$out" "spawn pr=11 cwd=$WORK/existing-a prompt=$WORK/existing-a/.ak/prompt.md model=gpt-5.6-terra effort=high name=pr_11" 'an existing worktree is reused; model matches the harness'
wt="$repo/.worktrees/feat/b"
assert_contains "$out" "spawn pr=12 cwd=$wt prompt=$wt/.ak/prompt.md" 'a new worktree is created under .worktrees'
assert_eq 1 "$(grep -c '^spawn pr=11 ' <<<"$out")" 'a PR named once spawns once'
assert_contains "$out" 'drop pr=13 reason=closed' 'a closed PR is dropped'
assert_contains "$out" 'drop pr=14 reason=merged' 'a merged PR is dropped'
assert_contains "$out" 'drop pr=15 reason=fork' 'a fork PR is dropped'
assert_eq feat/b "$(git -C "$wt" branch --show-current)" 'the worktree is on the PR branch'
assert_eq origin/feat/b "$(git -C "$wt" rev-parse --abbrev-ref '@{u}')" 'the branch tracks origin'
assert_eq 12 "$(cat "$wt/.ak/pr")" '.ak/pr holds the number'
assert_eq '' "$(ls -A "$repo/.ak/handed" 2>/dev/null)" 'a PR planned for the first time records no hand-over'
assert_eq feat/a "$(cat "$wt/.ak/base")" '.ak/base holds the PR base'
prompt=$(cat "$wt/.ak/prompt.md")
assert_contains "$prompt" 'PR #12 Fix & things <12>' 'the title is substituted verbatim'
assert_contains "$prompt" "branch feat/b into feat/a" 'branch and base are substituted'
assert_contains "$prompt" "\`$REPO/v2/bin/ak\`" 'the worker command definition uses the absolute ak path'
assert_not_contains "$prompt" '{{' 'no placeholder is left'
assert_not_contains "$prompt" 'ak setup' 'no setup command configured, no setup step'
file="$repo/.ak/runs/$run.json"
assert_eq "$run" "$(cat "$repo/.ak/runs/current")" 'current names the run'
assert_eq '11 12' "$(jq -r '[.items[] | select(.kind == "pr" and .state == "spawned") | .n] | join(" ")' "$file")" 'the run file lists the spawned PRs'
assert_eq "$wt" "$(jq -r '.items[1].worktree' "$file")" 'the run file records the worktree'
assert_contains "$(jq -r .porcelain "$file")" 'src/a.txt' 'the run file records the root porcelain'
assert_eq '' "$(git status --porcelain --untracked-files=all -- .ak .worktrees)" '.ak and worktrees stay out of git status'

printf 'pr=old\n' >"$wt/.ak/result"
unset CODEX_HOME AGENT_WORKER_MODELS AGENT_WORKER_EFFORT
export CLAUDECODE=1
out=$(AGENT_CMD_SETUP='npm ci' "$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" "spawn pr=12 cwd=$wt prompt=$wt/.ak/prompt.md model=sonnet effort=medium" 'a rerun reuses the worktree with claude defaults'
# shellcheck disable=SC2016 # markdown code span in the expected text
assert_contains "$(cat "$wt/.ak/prompt.md")" '1. Run `ak setup`. If' 'a configured setup command renders the setup step'
assert_eq no "$([[ -e $wt/.ak/result ]] && echo yes || echo no)" 'a stale result is removed'
run2=$(sed -n 's/^run=//p' <<<"$out")
assert_eq no "$([[ $run2 == "$run" ]] && echo yes || echo no)" 'a second run gets its own id'

# A PR a worker already took to green and reviewed at this head gets no second worker (field run: re-reviewing seven
# such PRs cost 19.6M tokens and turned four of them red). A result for an older head still respawns.
printf 'pr=12\nci=green\nreview=done\nhead=abc\nnote=findings=0\n' >"$wt/.ak/result"
printf 'keep\n' >"$wt/.ak/prompt.md"
out=$("$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" 'skip pr=12 reason=green-and-reviewed-at-head' 'a PR green and reviewed at its head is skipped'
assert_not_contains "$out" 'spawn pr=12' 'a skipped PR gets no worker'
assert_eq keep "$(cat "$wt/.ak/prompt.md")" 'a skipped PR keeps its worktree state'
run3=$(sed -n 's/^run=//p' <<<"$out")
assert_eq collected "$(jq -r '.items[0].state' "$repo/.ak/runs/$run3.json")" 'a skipped PR is recorded as collected'
# Review bots comment after the worker's receipt: a PR done at its head but with open threads still gets a worker.
route 'api graphql -F owner=acme -F name=widget -F n=12 *' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":{"login":"github-code-quality"},"body":"x"}]}}]}}}}}'
printf 'pr=12\nci=green\nreview=done\nhead=abc\nnote=findings=0\n' >"$wt/.ak/result"
out=$("$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" 'spawn pr=12' 'a PR with open review threads gets a worker'
printf 'pr=12\nci=green\nreview=done\nhead=old\n' >"$wt/.ak/result"
out=$("$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" 'spawn pr=12' 'a result for an older head respawns the worker'

# A parked PR the root plans again records what was committed there since the park, so ak ship can tell the
# operator's answer from the worker's own changes.
prwt="$repo/.worktrees/feat/b"
mkdir -p "$prwt/.ak/logs" && : >"$prwt/.ak/logs/verify.log"
(cd "$prwt" && "$AK" park --reason 'protected path needs the operator' >/dev/null)
"$AK" collect --pr 12 >/dev/null 2>&1
parked=$(git -C "$prwt" rev-parse HEAD)
git -C "$prwt" commit -q --allow-empty -m 'the operator answers the park'
"$AK" pr-plan --pr 12 >/dev/null 2>&1
record=$(bash -c 'source "$1/lib/common.sh"; handed_file "$2"' _ "$REPO/v2" "$prwt")
assert_eq "$parked $(git -C "$prwt" rev-parse HEAD)" "$(cat "$record" 2>/dev/null)" 'planning a parked PR again records what was committed since the park'

# A worktree a worker's PR branch is checked out in must be current and real (a field run: a reboot emptied /tmp, the
# registration outlived its directory, and mkdir recreated a bare non-git directory for the worker).
wt_branch() { # NAME: branch feat/NAME on origin, checked out at $WORK/wt-NAME
    git branch -q "feat/$1" main && git push -q origin "feat/$1" 2>/dev/null
    git worktree add -q "$WORK/wt-$1" "feat/$1"
}
advance() { # NAME: a new commit on origin's feat/NAME that the local branch lacks
    git push -q origin "$(git commit-tree "$(git rev-parse "feat/$1^{tree}")" -p "$(git rev-parse "origin/feat/$1")" -m advance):refs/heads/feat/$1" 2>/dev/null
    git fetch -q origin
}
n=21
for name in gone behind dirty diverged; do
    wt_branch "$name"
    route "api repos/acme/widget/pulls/$n" "$(pr_json "$n" "feat/$name" main open)"
    n=$((n + 1))
done
rm -rf "$WORK/wt-gone"
advance gone
out=$("$AK" pr-plan --pr 21 2>&1); rc=$?
assert_eq 0 "$rc" 'a registered but deleted worktree is planned'
assert_contains "$out" "spawn pr=21 cwd=$repo/.worktrees/feat/gone " 'a deleted worktree is rebuilt under the worktree root'
assert_eq "$(git rev-parse origin/feat/gone)" "$(git -C "$repo/.worktrees/feat/gone" rev-parse HEAD)" 'the rebuilt worktree is at the origin head'
assert_eq "$repo/.worktrees/feat/gone" "$(git -C "$repo/.worktrees/feat/gone" rev-parse --show-toplevel)" 'the rebuilt worktree is a git worktree, not a bare directory'

advance behind
out=$("$AK" pr-plan --pr 22 2>&1); rc=$?
assert_eq 0 "$rc" 'a clean worktree behind origin is planned'
assert_contains "$out" "spawn pr=22 cwd=$WORK/wt-behind " 'a behind worktree is reused in place'
assert_eq "$(git rev-parse origin/feat/behind)" "$(git -C "$WORK/wt-behind" rev-parse HEAD)" 'a clean behind worktree is fast-forwarded'

printf 'mine\n' >"$WORK/wt-dirty/unfinished.txt"
before=$(git -C "$WORK/wt-dirty" rev-parse HEAD)
advance dirty
out=$("$AK" pr-plan --pr 23 2>&1); rc=$?
assert_eq 1 "$rc" 'a dirty worktree behind origin is refused'
assert_contains "$out" 'uncommitted work' 'the refusal names the cause'
assert_eq mine "$(cat "$WORK/wt-dirty/unfinished.txt")" 'the uncommitted work is preserved'
assert_eq "$before" "$(git -C "$WORK/wt-dirty" rev-parse HEAD)" 'the dirty worktree is left where it was'

git -C "$WORK/wt-diverged" commit -q --allow-empty -m 'local only'
advance diverged
out=$("$AK" pr-plan --pr 24 2>&1); rc=$?
assert_eq 1 "$rc" 'a diverged worktree is refused'
assert_contains "$out" 'diverged from origin/feat/diverged' 'the refusal names the divergence'

finish
