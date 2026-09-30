---
name: issues
description: Work several GitHub issues in parallel, one worker per issue in its own worktree, each driving its own draft PR to green. Use for "work these issues", "run the Ready column", "parallel issues", or `$issues [--yolo] [--limit N] [--serialize] [--issue N]...`.
---

# issues

`ak` is `<this skill's directory>/../../bin/ak`. Pass the operator's flags straight through to `ak plan`.

1. Run `ak plan [flags]`. It prints `run=`, then `spawn`, `after` and `drop` lines.
2. For each `spawn issue=N cwd=… prompt=… model=… effort=…` line, spawn one worker with exactly that model
   and effort (and that cwd, if your spawn tool takes one), and the content of the prompt file as its task.
3. Wait with your harness's native wait, using the longest window it allows. Do not poll or refresh anything
   between waits.
4. When a worker finishes, run `ak collect --issue N`. Spawn a worker for every `spawn` line it prints, the same
   way as step 2.
5. When no workers remain, print every collect line as the report and stop.
