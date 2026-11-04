# Worker turns reduction (#1019)

Follow-on to the worker-context change (#1012 / PR #1013). The latest live batch
(`bench/results/batches/20261027T030637Z-codex-08c2516.jsonl`) cut root tokens 41%
but worker tokens rose 14%. Reading the twelve candidate worker transcripts shows
why: each worker turn re-sends a 16–26k token context, and about six turns per
worker are overhead the kit itself causes. This change removes those turns; it
does not touch tests, review, CI, threads, receipt or acceptance semantics.

## Measured on 08c2516 (12 workers, three trials, Codex gpt-6-luna/high)

Mean 20.3 turns and 497k tokens per worker (82093d0: 18.0 and 433k).

1. `ak ship` refused 7 of 12 first ships with "the ## Tests section carries run
   output". The 08c2516 playbook asks for "commands, results, and what each test
   proves" under `## Tests`; `ship_body_check` refuses `verify=` words and long code
   spans there. Each refusal costs two turns (the refusal, the rewrite). 82093d0's
   wording ("per test file, what it proves") was refused once in 12.
2. Every worker opened a skill file (`using-superpowers`, `test-driven-development`,
   `brainstorming`; ~13 KB each) before or just after the prompt, and carried it in
   context for the rest of the run.
3. `ak setup` printed `setup=none` in 12 of 12 workers: one turn with no effect.
4. `ak threads` printed `threads=0` in 12 of 12 workers, right after `ak ci` green.
5. About 8 of 12 workers wrote `.ak/findings` in its own turn before `ak receipt`.
6. 7 of 12 workers ran `cat .ak/review.md` after `ak review` printed titles only.

Out of scope: `ak review` and `ak ci` calls that yield at the shell's 30 s cap and
are collected in the next turn (reviewer and CI wall time), and exploration reads.

## Changes

- **Playbook `## Tests` line** says what each test file proves and that commands
  and status lines do not belong there, matching the gate. The gate is unchanged.
- **Skill lookups.** The root's spawn message (both skills) and both templates say
  the playbook is complete and skill or guide lookups are unnecessary; the
  repository's own instructions still apply.
- **Setup step** renders only when `AGENT_CMD_SETUP` is configured: a `{{SETUP}}`
  placeholder in both templates, substituted by `setup_step` in `common.sh`.
- **`ak ci`** appends `threads=N` (and one `thread=…` line each, as `ak threads`
  prints) when it reports `ci=green` or `ci=none`, using the PR number
  `ci_blocked` already looked up. A failed thread read prints
  `threads=? note=…; run ak threads`. The playbook's step 6 runs `ak threads` only
  to resolve listed threads. `ak receipt` still refuses while threads are open.
- **`ak receipt`** accepts repeated `--finding LINE`; `--findings FILE` stays. With
  neither, it uses an existing `.ak/findings` (merge-down), else `none` when the
  review found nothing or was unavailable, else refuses naming the flag. The
  decided lines are written to `.ak/findings` for a later receipt.
- **`ak review`** prints each finding's whole line (`P1: title — file:line — why`),
  each cut at 200 characters, still capped at 20 lines. The playbook no longer
  points at `.ak/review.md` except for `findings=unparsed`.

## Verification

Each change is pinned in `tests/v2`. `tests/run-tests.sh` is the gate. The
measurement is the next live batch: `08c2516` versus this branch's candidate,
same harness, fixture, models and local harness edits, ABBAAB, three trials per
arm, exported per batch and compared with `bench/live/compare.py`. The claim to
test is fewer worker turns per issue at 4/4 acceptance; worker-token change is
reported with its range. Prior batches stay in `bench/results/batches/`.
