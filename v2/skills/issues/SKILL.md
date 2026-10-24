---
name: issues
description: Work several GitHub issues in parallel, one worker per issue in its own worktree, each driving its own draft PR to green. Use for "work these issues", "run the Ready column", "parallel issues", or `$issues [--yolo] [--limit N] [--serialize] [--issue N]...`.
---

# issues

`ak` is `<this skill's directory>/../../bin/ak`. Pass the operator's flags straight through to `ak plan`.
Each `ak` command prints what you need next; there is no need to read its scripts or templates.

1. Run `ak plan [flags]`. It prints `run=`, then `spawn`, `after` and `drop` lines.
2. For each `spawn issue=N cwd=… prompt=… model=… effort=… name=issue-N` line, spawn one worker with exactly that
   model and effort (and that cwd, if your spawn tool takes one), `name` as its name (Claude Agent `name`, Codex
   `spawn_agent` `task_name`; `ak wait` finds Codex workers by it), and the content of the prompt file as its task.
   Spawn them all now, before waiting: `--serialize` only turns overlapping issues into `after` lines, which
   `ak collect` starts later. A `next=` line means nothing started; report it and stop.
3. Wait once for the whole wave. Claude: run `ak wait` as ONE background shell task and end the turn with no words;
   a hook holds worker notices, so your next wake is that command's exit. Codex: call `wait_agent` with
   `timeout_ms=3600000`; on each return run `ak wait --check`; exit 3 means wait again with no words, exit 0 means
   run the `next=` command it printed. `ak wait` settles every worker and prints one summary line each.
   While a wave is open, spawn nothing else and send nothing: no progress replies, no relays, no polling.
4. On the wake, review every worker's line. A worker that is wrong or unfinished gets its correction handed back
   (Claude `SendMessage`, Codex `followup_task`); then wait on exactly those workers with `ak wait --issue N…`,
   the same way as step 3. A `next=` line is the operator's step for a parked, hung or red issue: put it in the
   report as printed.
5. When satisfied, run `ak collect --wave`. Spawn a worker for every `spawn` line it prints, as in step 2, and
   wait again as in step 3. Repeat until it prints `wave=done`.
6. Then print every summary line as the report and stop.
