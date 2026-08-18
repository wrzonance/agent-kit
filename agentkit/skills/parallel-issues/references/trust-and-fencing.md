# Command trust and fencing

## Contents

- Why `--yolo` must thread through to every dispatched verification call
- How far one approval reaches, and repositories whose declarations are per-machine
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

## Changed-input refusals are adjudication requests

A `--yolo` refusal because a command input differs from its trust base is not permission to
discard the input or retry through another command spelling. The root preserves that one
workstream, while other workstreams continue, and creates an input-diff digest before any
remediation decision. The digest names every changed command input, includes a diffstat, and
includes the complete diff for each input. For a repo-root shared input, the handoff also says
that sibling PRs may conflict with it at merge time.

From the refused worktree, use the exact trust base reported by `agent-run.sh` (the trunk ref or
the pinned base) and the changed inputs named by the refusal:

```bash
# The base the refusal named above -- the trunk ref, or the pinned base SHA on a
# chained workstream. Do not substitute origin/main: a chained run compares
# against its pinned SHA, and diffing the wrong anchor produces evidence about
# a comparison point nobody refused.
base_ref='PASTE THE REPORTED TRUST BASE'
git status --short --untracked-files=all
git diff --stat "$base_ref" -- path/to/input
git diff --binary "$base_ref" -- path/to/input
```

Repeat the two `git diff` commands for each changed input. For an untracked input, include its
diff with `git diff --no-index --binary /dev/null path/to/input || test $? -eq 1`; the exit code
of one means the expected no-index difference was found, not that the digest failed. Preserve
the resulting file list, diffstat, and diffs as the handoff evidence.

After reviewing that evidence, the root has exactly two sanctioned outcomes:

- `approve-with-record`: run the harness's interactive
  `agent-run.sh --approve --cmd NAME` flow for the refused worktree and command. This creates
  an explicit approval record for the reviewed state; it is never forged and is never implied
  by `--yolo`.
- `park-and-hand-off`: leave only the refused workstream parked and hand off its worktree, the
  input-diff digest, the shared-input merge-risk note when applicable, and the exact
  `agent-run.sh --approve --cmd NAME` remediation command.

After `approve-with-record`, resume the parked workstream with its **exact original threaded
invocation, `--yolo` included** -- do not drop the flag or substitute a literal command.
`agent-run.sh` consults the recorded approval before falling back to the trunk-comparison gate,
so a matching record satisfies that same `--yolo` call instead of refusing it again. Both stderr
and the run log distinguish this outcome as `trust gate satisfied by approval record; --yolo not
exercised`, never as an ordinary `--yolo` skip -- an audit must be able to tell the two apart.

Literal command invocations remain caller-supplied and do not satisfy this gate. Running one to
obtain green evidence is evasion, not remediation.

## How far one approval reaches

An approval record for an ordinary worktree is scoped to the **repository** — the clone's shared
git directory — not to the checkout it was made from. One `--approve` per command therefore
covers every ordinary worktree of that clone (a pull-request checkout is the exception, below),
until a declaration or a repository-backed command input changes and the fingerprint
stops matching. Nothing about *what* is approved changed with that scope: the fingerprint still
pins the declaration values, argv, the content of every repository-backed input, the runner, and
the nearby build manifests, so a sibling worktree that edits any of them is refused exactly as
before. Approve from any checkout of the clone; the record is the same either way.

**A pull-request checkout is the exception, and it keeps its own approval.** `pr-worktree.sh`
marks the worktree it creates for a PR, and `agent-run.sh` keys that checkout on its own path
instead of the clone's. So a maintainer's parallel worktrees share one approval, and a
contributor's branch never inherits it.

That exception is not tidiness — it closes a real hole. The fingerprint reaches only the inputs
this command contract can identify by name: a declaration naming a task runner and a task carries
no path in argv at all, so the script it ultimately resolves is not something the fingerprint
hashes. A pull request can rewrite that script without changing one byte of the record. Under a
clone-wide scope that would run contributor-controlled code on an approval a maintainer granted
in a different checkout entirely. The per-checkout prompt is the only thing standing there, so a
PR checkout earns its own.

Detection fails closed. Anything marker-shaped — present, unreadable, malformed — resolves to the
checkout scope, because absence of proof that a worktree is ordinary is not proof that it is.
`pr-worktree.sh` refuses to create a worktree it could not mark, rather than leaving one that
would silently take the wider scope.

The honest residual is now the ordinary one: for a maintainer's own worktrees the record still
does not cover the wrapped command's deeper transitive inputs. That is the boundary every
verification run has always drawn, on branches the maintainer wrote.

### Repositories whose declarations are per-machine

`onboard-repo` writes `.agent/config.env` untracked by default, and `--yolo` validates
declarations against the trunk — which then carries none of them. On such a repository the trunk
grant is **structurally void**: every declared command refuses in every worktree, and retrying
never changes that. `agent-run.sh` names the cause (`.agent/config.env is not carried by <base>`)
and the two durable fixes, which are not mutually exclusive:

- **Trunk-carried declarations** — commit `.agent/config.env`. Recommended for any repository
  meant to run unattended: it is what the gate's authorization model actually says, since
  `--yolo` executes what the trunk reviewed, and it holds declarations only (the resolver refuses
  secrets). The trade is that later declaration edits need a trunk PR before an unattended run
  picks them up. agent-kit does this to itself.
- **Approve once per config-state** — the per-machine escape hatch. One interactive `--approve`
  per command, after which every ordinary worktree of the clone is covered; a PR checkout still
  approves separately.

**`--yolo` does not excuse the approval handoff here.** Before dispatch, check whether the trunk
carries the declarations at all:

```bash
git cat-file -e "origin/${AGENT_BASE_BRANCH:-main}:.agent/config.env" 2> /dev/null &&
    echo trunk-carried || echo per-machine
```

`per-machine` means the dispatched prompts carry a grant that will refuse, so prepare the batched
approval block anyway — see the handoff section below.

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

```bash
"$agentkit/parallel-issues/scripts/print-approval-handoff.sh" \
  --worktree /ABS/PATH/.worktrees/feat/issue-123 --cmd test --cmd lint \
  --worktree /ABS/PATH/.worktrees/feat/issue-124 --cmd test
```

It prints the heading and one `cd <worktree> && <absolute agent-run.sh>
--approve --cmd <name>` line per worktree and command. The helper refuses the
main checkout, so never hand off that path in a manually assembled recipe.

Use the actual absolute worktree and runner paths and include focused selectors when they
are part of the exact invocation. This is one batched handoff for the entire predictable
approval burden: workers block until it runs, and predictable refusals are never surfaced
serially. Every recipe must start with `cd <worktree>`; never hand off the main checkout
or substitute its path for a worker worktree. Because the record is repository-scoped, one
worktree's lines cover the clone — the remaining per-worktree lines are idempotent no-ops,
so a shorter block is not a missing one.

Print this block whenever the approvals are actually needed, which is **not** the same as
"no autonomy flag was given". Suppress it only when `--trust-trunk` or `--yolo` is present
**and** the trunk carries `.agent/config.env`: then the dispatched prompts carry a grant that
works. When the declarations are per-machine, that grant is structurally void (see *How far one
approval reaches*), so print the block regardless of the flag — suppressing it there is what
turns one predictable batch into one serial stall per command.
