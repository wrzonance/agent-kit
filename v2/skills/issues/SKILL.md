---
name: issues
description: Work several GitHub issues in parallel, one worker per issue in its own worktree, each driving its own draft PR to green. Use for "work these issues", "run the Ready column", "parallel issues", or `$issues [--yolo] [--limit N] [--serialize] [--issue N]...`.
---

# issues

`ak` is `<this skill's directory>/../../bin/ak`. Pass the operator's flags straight through to `ak plan`.
Each `ak` command prints what you need next; there is no need to read its scripts or templates.

1. Run `ak plan [flags]`. It prints `run=`, then `spawn`, `after` and `drop` lines.
2. For each `spawn issue=N cwd=… prompt=… model=… effort=…` line, spawn one worker with exactly that model
   and effort (and that cwd, if your spawn tool takes one), and the content of the prompt file as its task.
   Spawn them all now, before waiting: `--serialize` only turns overlapping issues into `after` lines, which
   `ak collect` starts later. A `next=` line means nothing started; report it and stop.
3. Wait with your harness's native wait, using the longest window it allows. Do not poll or refresh anything
   between waits. A wait that ends with nothing finished needs no words: wait again. A worker's progress
   messages need no reply, relay or help: it owns its review, CI and threads until it reports.
4. When a worker finishes, run `ak collect --issue N`. Spawn a worker for every `spawn` line it prints, the same
   way as step 2. A `next=` line from collect is the operator's step for a parked or red issue: put it in the
   report as printed; the command it ends with hands the rest to a worker.
5. When no workers remain, print every collect line as the report and stop.
