# Worker context application test

Run this scenario in a fresh context five times with the original artifacts and
five with the candidate. Use the same model/effort as the live fixture. Reading
these files is allowed; do not execute the hypothetical workflow or contact GitHub.
Return JSON with `issue_actions`, `pr_actions`, `worker_start`, `after_review`,
`missing_prompt`, and `merge_down` (commands/messages in execution order).

1. You are the issues root following the supplied issues skill. `ak plan` finished
   with `spawn issue=71 cwd=/repo/work one prompt=/repo/work one/.ak/prompt.md model=gpt-6-luna effort=high name=issue_71`
   and `spawn issue=72 cwd=/repo/work-two prompt=/repo/work-two/.ak/prompt.md model=gpt-6-luna effort=high name=issue_72`.
   Give the exact next shell calls and spawn arguments up to the first wait. The
   prompt files contain the supplied issue-worker template after normal rendering,
   plus the issue's requirements (not available in your current context). Your
   native spawn API supports task_name, message, model, reasoning_effort and fork_turns.
2. You are independently the PR root following the supplied PR skill. Its plan
   returned `spawn pr=84 cwd=/repo/pr84 prompt=/repo/pr84/.ak/prompt.md model=gpt-6-luna effort=high name=pr_84`.
   Give the next calls up to the first wait. Then explain the dispatch for a later
   `ak merge` exit-3 spawn pointing to a rewritten prompt at the same path.
3. You are the dispatched issue worker. The root supplied a task that follows
   the original/current skill exactly. State your startup reads and first command.
   Apply the supplied issue-worker playbook to a one-function bugfix. Its regression
   test is red, fix passes, verification passed, PR shipped, review found one P2,
   and you fixed it with red/green then verified and shipped. List the remaining
   commands and findings-file contents through the final receipt. CI is green and
   there are no open threads. Use `<sha>` for the fix commit.
4. Your assigned prompt path is unreadable. State the action and final response.
5. A PR worker receives a rewritten prompt with `.ak/resolve` present. List its
   merge-down actions, keeping the original findings file.

Scoring: root does not read or inline worker briefs; both paths retain exact cwd,
prompt, model, effort and name and select a fresh context where supported. Worker
loads its own prompt, follows local repository rules, preserves test/review/CI/
thread/receipt steps, keeps previous findings during merge-down, and stops with
an actionable path on unreadable input. Preserve incomplete shell handles.
Record actual answers and count dispatch bytes; do not score keyword matches alone.
