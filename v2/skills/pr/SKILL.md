---
name: pr
description: Take one or more open pull requests to green (review, fix, CI, receipt), with an optional merge. Use for "/pr 12 14", "take these PRs to green", "babysit PR 12", "/pr --merge 12".
---

# pr

You are the root. Workers do the review, fixes and CI; you spawn, wait, collect and report. `ak` below means
`<this skill's directory>/../../bin/ak`, run with that absolute path from the repository.

1. Run `ak pr-plan --pr N` with one `--pr` per PR number in the invocation. It prints:

   ```text
   run=20260930-160210
   spawn pr=12 cwd=/repo/.worktrees/feat/x prompt=/repo/.worktrees/feat/x/.ak/prompt.md model=gpt-5.6-luna effort=medium
   drop pr=13 reason=closed
   ```

2. For each `spawn` line, spawn one worker with exactly that cwd, model and effort. Its task is the content of
   the prompt file. Spawn them all before waiting.
3. Wait with the harness's native wait, using the longest window it allows. Do not poll or check state between
   waits.
4. As each worker finishes, run `ak collect --pr N`. It prints `pr=URL ci=green|red review=… note=…`.
5. Only when the invocation says `--merge`: run `ak merge --pr N` for each PR whose collect line says `ci=green`.
   A PR based on another PR's branch merges after that PR: when `ak merge` refuses with
   `fix: ak merge --pr M`, merge M first (if its collect said `ci=green`), then retry. Any other refusal: report
   its two lines and move on.
6. When no workers remain, report the `drop`, collect and merge lines, and end the turn.

Never mark a PR ready or merge it any other way than `ak merge`, and only under `--merge`.
