# Command trust and fencing

## Contents

- Why `--yolo` must thread through to every dispatched verification call
- Never forge the command-trust gate, under any flag or mode
- Verification cache and suite cadence
- Attended command-approval handoff

Read this when constructing dispatched worker prompts under `--yolo` or `--trust-trunk`, or
when deciding how often to re-run verification during red/green iteration. `SKILL.md` keeps
the pinned rule sentences (the placeholder text a prompt must carry, the exact refusal
wording); this file carries the rationale behind them.

## Why `--yolo` threads through to verification

`agent-run.sh`'s command-trust gate reads its approval from an interactive terminal, and a
dispatched worker has none — so in an unattended run every worker that reaches verification
dead-ends there, with nobody watching. Measured in a live `--yolo --fast-mode` fleet: three
of four leads finished or nearly finished their implementation and then reported BLOCKED at
the gate; the fourth forged the confirmation through a pseudo-terminal, which is strictly
worse. The invocation line is the human authorization; threading `--yolo` onto every
`agent-run.sh` line in every assembled prompt carries that authorization to the workers
instead of making each one ask a question nobody is present to answer.

The bypass is trunk-bounded: a command whose declaration, runner, or repo-backed
argv/module payload or nearby build manifest changed on the branch is still refused under
`--yolo`, and that refusal is a correct BLOCKED report, not a defect to work around.

## Never forge the gate — any flag, any mode

A worker that hits `refusing unapproved repository command` on a prompt without `--yolo`
reports BLOCKED with that reason and stops. Driving a pseudo-terminal (`script`, `expect`),
piping `y` into `--approve`, or writing a trust record directly is manufacturing the human's
consent, and a green log obtained that way is not verification evidence — no flag or mode
changes that.

**Be precise about what the terminal check is.** `--approve`'s interactive confirmation is
**defense in depth, not proof of operator presence**: any process running as the same user
can allocate a pseudo-terminal or write the trust record itself, so it is not a human-only
or cryptographic boundary. That is exactly why the no-forgery rule above is stated as a rule
the agent must keep rather than a control that stops it — the gate raises the cost of an
accident, and the agent's own discipline is what makes it mean anything. Treating it as an
unforgeable proof of a human would make a forged approval look like evidence.

## Verification cache and suite cadence

On a green completion for an eligible verification name (`test`, `lint`, `typecheck`,
`coverage`, `verify`, or `check`), `agent-run.sh` records evidence in the excluded
per-worktree `.agent/verification-cache`, keyed by the command name, execution directory,
and current tree state. Repeating the same eligible `--cmd` in the same directory on
unchanged bytes prints `agent-run: verification current: <log>` and exits 0; `--force`
bypasses that shortcut. The trust gate still runs on every invocation, including cache hits.

During red/green iteration, run focused suites for changed files, then run the full suite
once per tree state before commit. State-producing names such as `build`, `setup`, `seed`,
and `migrate` are always executed and never cached. After push, GitHub CI is authoritative
for that SHA; an unchanged local full-suite request is evidence-backed by the cache rather
than a new run.

## Attended command-approval handoff

When an attended invocation carries neither `--yolo` nor `--trust-trunk`, prepare one
batched, copy-pasteable approval block **before or at dispatch**: one `cd <worktree> &&
agent-run.sh --approve --cmd <name>` line per worktree per needed command. Collect the exact
verification invocations the prompts will use, then print one line per worktree per needed
command using the absolute runner path resolved by Step 0:

```text
Workers will block at command approval until these are run from an operator terminal:

cd /ABS/PATH/.worktrees/feat/issue-123 && /ABS/PATH/agentkit/skills/.shared/scripts/agent-run.sh --approve --cmd test
cd /ABS/PATH/.worktrees/feat/issue-123 && /ABS/PATH/agentkit/skills/.shared/scripts/agent-run.sh --approve --cmd lint
cd /ABS/PATH/.worktrees/feat/issue-124 && /ABS/PATH/agentkit/skills/.shared/scripts/agent-run.sh --approve --cmd test
```

Use the actual absolute worktree and runner paths and include focused selectors when they
are part of the exact invocation. This is one batched handoff for the entire predictable
approval burden: workers block until it runs, and predictable refusals are never surfaced
serially. Every recipe must start with `cd <worktree>`; never hand off the main checkout
or substitute its path for a worker worktree. If `--trust-trunk` or `--yolo` is present,
do not print this approval block because the dispatched prompts carry the trunk grant.
