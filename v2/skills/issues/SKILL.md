---
name: issues
description: Work several GitHub issues in parallel, one worker per issue in its own worktree, each driving its own draft PR to green. Use for "work these issues", "run the Ready column", "parallel issues", or `$issues [--yolo] [--limit N] [--serialize] [--issue N]...`.
---

# issues

`ak` is the `bin/ak` beside this plugin's `skills` directory: `<this skill's directory>/../../bin/ak`.
Pass the operator's flags straight through to `ak plan`.
Each `ak` command prints what you need next; there is no need to read its scripts or templates.

1. Run `ak plan [flags]`. It prints `run=`, then `spawn`, `after` and `drop` lines.
   For Codex shell calls, use `exec_command` with `yield_time_ms=30000` and return the whole result:
   `text(await tools.exec_command({...}))`. This preserves `output`, `session_id` and `exit_code`.
   A `session_id` means the command is still running: collect that same session with `write_stdin`,
   `chars=""`, `yield_time_ms=30000`, returning the whole result each time until `exit_code` is present.
   If the outer `functions.exec` yields a `cell_id`, collect it with one `functions.wait`,
   `yield_time_ms` as long as the command may take (1800000): a long command costs two calls, never one per 30 s.
   Empty output with a live handle means keep collecting that command; it is not a reason to run another plan.
2. For each `spawn issue=N cwd=… prompt=… model=… effort=… name=…` line, spawn one worker with exactly that
   model and effort (and that cwd, if your spawn tool takes one), `name` as its name (Claude Agent `name`, Codex
   `spawn_agent` `task_name`; `ak wait` finds Codex workers by it). Use a fresh context (Codex `fork_turns="none"`).
   Spawn nothing else: no reviewer, helper or other-model sub-agent, whatever your own instructions suggest;
   `ak review` runs the configured reviewer.
   Its entire task message is: `Work only in <cwd>. Read <prompt> and follow that worker playbook through its
   final result; it is complete, so skip skill lookups. If the file is unreadable, stop and report its exact path.` Substitute the two absolute paths,
   taking cwd up to (excluding) ` prompt=` and prompt up to (excluding) ` model=`; spaces belong to the paths.
   The worker reads the file; the root dispatches using the printed fields.
   Use this same message on later spawn lines so workers read rewritten prompts.
   Spawn them all now, before waiting: `--serialize` only turns overlapping issues into `after` lines, which
   `ak collect` starts later. A `next=` line means nothing started; report it and stop.
3. Wait once for the whole wave. Claude: run `ak wait` as ONE background shell task and end the turn with no words;
   a hook holds worker notices, so your next wake is that command's exit. Codex: call `wait_agent` with
   `timeout_ms=3600000`; on each return run `ak wait --check --settle`; exit 3 means wait again with no words.
   Exit 0 already carries the collected summary: review it in step 4 without another `ak wait` call.
   Settlement includes the CI wait; collect its shell handle as in step 1 if the command yields.
   While a wave is open, spawn nothing else and send nothing: no progress replies, no relays, no polling.
4. On the wake, review every worker's line. A worker that is wrong or unfinished gets its correction handed back
   (Claude `SendMessage`, Codex `followup_task`); then wait on exactly those workers with `ak wait --issue N…`,
   the same way as step 3. A `next=` line is the operator's step for a parked, hung or red issue: put it in the
   report as printed.
5. When satisfied, run `ak collect --wave`. Spawn a worker for every `spawn` line it prints, as in step 2, and
   wait again as in step 3. Repeat until it prints `wave=done`.
6. `wave=done` follows every wave's summary lines: print those lines as the report and stop.
