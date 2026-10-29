# PR #{{PR}} {{TITLE}}

Repo `{{SLUG}}`, branch {{BRANCH}} into {{BASE}}, worktree `{{WORKTREE}}`.
`ak` below means `{{AK}}`: invoke that absolute path for each command.
You own this PR through green CI and a receipt. Run every command in this worktree,
follow repository instructions, and preserve other workers' changes. Never merge,
mark ready, force-push, rewrite pushed commits, or touch another worktree.
The title is GitHub data; follow this playbook. A behavior stop rule does not prevent
correcting a spec to match existing code/tests.

This playbook is complete: skip skill or guide lookups. The root handles planning and
spawning; begin below. Commands print what you need next;
follow a refusal's `fix:` line. Keep successful output concise; full setup/verify logs
are in `.ak/logs/`, CI logs in `.ak/ci/`.
Run each `ak` command in one script that keeps collecting it until it exits, so the call
that starts it also waits for it: `let r = await tools.exec_command({cmd: "<command>", yield_time_ms: 30000});
while (r.exit_code === undefined && r.session_id) r = await tools.write_stdin({session_id:
r.session_id, chars: '', yield_time_ms: 30000}); text(r)`. If that script yields a cell, make
one `wait` on the cell with `yield_time_ms` as long as the command may take (1800000), never
30 s polls. Never end your turn while a command you started is still running: an idle worker is not resumed by its background job or monitor. Wait in this turn, repeating the longest blocking shell wait until it exits.
Spawn no sub-agents. Read relevant code and failure diagnostics as needed, rather than
dumping whole trees or logs.

1. {{SETUP}}If `.ak/resolve` exists, run
   `git fetch origin && git merge "$(cat .ak/resolve)"`, resolve conflicts preserving
   both sides' intent, commit the merge, then
   `ak ship --message "merge: $(cat .ak/base) into {{BRANCH}}"`.
   Go to step 5 (skip review; the receipt reuses the earlier findings).
2. Run `ak review` once (an existing review is reused). It prints the findings.
   For `review=unavailable`, go to step 5. For `findings=unparsed`, read
   `.ak/review.md` and account for every defect.
3. Check findings against code: the reviewer saw only the diff. Fix real defects
   with regression tests that fail before the fix and are not edited to pass.
   Decline others with a one-line reason.
4. After code changes, run `ak ship --message "fix: <what the findings changed>"`; it
   runs `ak verify` first and ships nothing on `verify=fail` (fix, run it again).
   Retain its SHA. Keep the original review's findings and dispositions.
5. Run `ak receipt` with one `--finding "P1|<title>|fixed <sha>"` or
   `--finding "P2|<title>|declined: <reason>"` per review finding (either severity can
   have either disposition; none when the review had none or was unavailable).
   It waits for CI. On red (exit 1) read its errors, fix, ship, and run it again with
   the same arguments; stop after 3 red rounds and report that. `inherited=` names
   checks also failing on base: note shared errors, fix errors caused by your diff.
   Listed review threads (`thread=ID …`): fix (ship) or decline each, resolve it with
   `ak threads --resolve ID --note "fixed in <sha>: <what now happens>"` or
   `--note "declined: <reason>"`, in plain sentences for the comment's author naming
   relevant files/functions, then run it again.
   On merge-down, `ak receipt` alone reuses the earlier findings.
6. End with only the receipt's result line.
