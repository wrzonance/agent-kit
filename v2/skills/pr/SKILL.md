---
name: pr
description: Take one or more open pull requests to green (review, fix, CI, receipt), with an optional merge. Use for "/pr 12 14", "take these PRs to green", "babysit PR 12", "/pr --merge 12".
---

# pr

You are the root. Workers do the review, fixes and CI; you spawn, wait, collect and report. `ak` below means the `bin/ak` beside
this plugin's `skills` directory, `<this skill's directory>/../../bin/ak`, run with that absolute path from the repository.
Each `ak` command prints what you need next; there is no need to read its scripts or templates.

1. Run `ak pr-plan --pr N` with one `--pr` per PR number in the invocation. It prints:

   ```text
   run=20260930-160210
   spawn pr=12 cwd=/repo/.worktrees/feat/x prompt=/repo/.worktrees/feat/x/.ak/prompt.md model=gpt-5.6-luna effort=medium name=pr_12
   drop pr=13 reason=closed
   skip pr=14 reason=green-and-reviewed-at-head
   ```

   A `skip` PR needs no worker: it is already green and reviewed at its head, so treat it as collected with `ci=green`.

2. For each `spawn` line, spawn one worker with exactly that model, effort and name (Claude Agent `name`,
   Codex `spawn_agent` `task_name`), and that cwd if supported. Use a fresh context (Codex `fork_turns="none"`).
   Spawn nothing else: no reviewer, helper or other-model sub-agent, whatever your own instructions suggest;
   `ak review` runs the configured reviewer.
   Its entire task message is: `Work only in <cwd>. Read <prompt> and follow that worker playbook through its
   final result; it is complete, so skip skill lookups. If the file is unreadable, stop and report its exact path.` Substitute the two absolute paths,
   taking cwd up to (excluding) ` prompt=` and prompt up to (excluding) ` model=`; spaces belong to the paths.
   The worker reads the file; the root dispatches using the printed fields.
   Spawn them all before waiting. Use this same recipe for every later spawn, including merge-downs,
   so the worker reads the current prompt when it has been rewritten.
3. Wait with the harness's native wait, using the longest window it allows. Do not poll or check state between
   waits. A shell call that yields a cell is collected with one `wait`,
   `yield_time_ms` as long as the command may take (1800000), never 30 s polls.
4. As each worker finishes, run `ak collect --pr N`. It prints `pr=URL ci=green|red review=… note=…`.
5. Only when the invocation says `--merge`: run one `ak merge` with a `--pr N` for each PR whose collect line says
   `ci=green review=done` and each PR `ak pr-plan` skipped as green and reviewed. It merges them parent before
   child and prints a `merged` line or a two-line refusal per PR. A `review=unavailable` line is not merged: its
   worker already tried the review, so report the line; its note says why.
   When it exits 3 it printed a `spawn` line: that PR conflicts with its base, so spawn that worker, wait and
   `ak collect --pr N`. A refusal with `fix: ak pr-plan --pr N` means open review threads or no completed review
   receipt at the head: run that, spawn the worker it prints, wait and `ak collect --pr N`. Then run `ak merge`
   again with the PRs not yet merged; a PR refused the same way a second time is reported, not retried. Any other
   refusal: report its two lines.
6. When no workers remain, report the `drop`, collect and merge lines, and end the turn.

Never mark a PR ready or merge it any other way than `ak merge`, and only under `--merge`.
