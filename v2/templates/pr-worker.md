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
are in `.ak/logs/`, CI logs in `.ak/ci/`. Use the longest shell wait and collect an
existing handle and exit code when a call yields. Read relevant code and failure
diagnostics as needed, rather than dumping whole trees or logs.

1. {{SETUP}}If `.ak/resolve` exists, run
   `git fetch origin && git merge "$(cat .ak/resolve)"`, resolve conflicts preserving
   both sides' intent, commit the merge, then `ak verify`,
   `ak ship --message "merge: $(cat .ak/base) into {{BRANCH}}"`, `ak ci`.
   Go to step 6 keeping the earlier findings file (skip review).
2. Run `ak review` once (an existing review is reused). It prints finding titles;
   full findings are in `.ak/review.md`. For `review=unavailable`, go to step 5.
   For `findings=unparsed`, read that file and account for every defect.
3. Check findings against code: the reviewer saw only the diff. Fix real defects
   with regression tests that fail before the fix and are not edited to pass.
   Decline others with a one-line reason.
4. After code changes, run `ak verify` until pass, then
   `ak ship --message "fix: <what the findings changed>"`; retain its SHA.
   Keep the original review's findings and dispositions; continue to CI after fixes.
5. Run `ak ci`: 0 = green/no CI, 1 = red, 3 = pending (run it again).
   On red, read its errors, fix, verify, ship, retry; stop after 3 red rounds and
   report that. `inherited=` names checks also failing on base: note shared errors,
   fix errors caused by your diff.
6. Run `ak threads`. Fix (verify, ship) or decline each thread, then resolve with
   `ak threads --resolve ID --note "fixed in <sha>: <what now happens>"` or
   `--note "declined: <reason>"`. Write plain sentences for the comment's author,
   naming relevant files/functions. Open threads block the receipt.
   Write `.ak/findings`, one line per finding: `P1|<title>|fixed <sha>` or
   `P2|<title>|declined: <reason>`; either severity can have either disposition.
   Use `none` when there were no findings or review was unavailable. On merge-down,
   keep the earlier file. Run `ak receipt --findings .ak/findings`.
7. End with only the receipt's result line.
