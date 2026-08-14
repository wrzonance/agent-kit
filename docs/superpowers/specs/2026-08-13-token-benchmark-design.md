# Token-consumption benchmark — design

Measuring whether the token-compression refactor (`#104`–`#108`, PRs `#115`→`#120`)
actually reduced what agent-kit costs to run.

## The two questions, kept apart

The refactor is easy to overclaim. This design answers two questions that sound
like one, and keeps their evidence separate because their epistemics differ.

**Q1 — did the compression happen?** A static property of three files at two
commits. Deterministic, free, reproducible forever. This is the verdict.

**Q2 — is the current plugin cheaper to run end-to-end?** A stochastic property
of live agent runs. Published work on agentic coding tasks finds per-task token
usage varying **up to 30×** across repeated runs of the *identical* task, with the
dearest of ten repetitions typically ~2× the cheapest; the [minimal-pair
cleanliness study][cleanliness] needed 660 trials to resolve a 7–8% effect. A
single run per arm therefore adjudicates nothing. This is corroboration, reported
with error bars.

Q2 also measures more than compression. The arms are separated by ~20 merged
issues, not by the refactor alone — see [Threats](#threats-to-validity).

[cleanliness]: https://arxiv.org/abs/2605.20049

## Non-goals

- Benchmarking the *model*. Both arms run the same pinned model; only the plugin differs.
- Measuring `review-remote-pr`. It blocks on a human by design (ready-flip, manual
  CodeRabbit trigger) and cannot run unattended without measuring a path that is not
  the shipped one.
- Measuring `onboard-repo`. It is ATTENDED; `--yolo` past its approval stops is a
  known hazard, not a benchmark.
- A general-purpose agent benchmark. Existing suites ([SWE-bench][swe],
  [Terminal-Bench][tb], [aider polyglot][ap]) measure models against single-repo tasks;
  none exercise multi-issue orchestration, conflict serialization, or worktrees.

[swe]: https://arxiv.org/pdf/2607.02606
[tb]: https://www.digitalapplied.com/blog/swe-bench-terminal-bench-benchmark-guide-2026
[ap]: https://github.com/Aider-AI/polyglot-benchmark

## Arms

| Arm | SHA | Notes |
|---|---|---|
| `old` | `06d18cf` | Merge of PR #110 (issue #103) — last commit before the compression sprint |
| `new` | `53e7e8c` | Merge of PR #131 (issue #125) — after the sprint and the #109/#113/#121/#122/#123/#125 wave |

Both arms accept the benchmark command verbatim. Verified at both SHAs:
`--yolo`, `--fast-mode`, `--auto-review`, and `--auto-serialize` all exist
(`--auto-serialize` landed in `f9aad86`, an ancestor of `06d18cf`), and the two
governing limits are byte-identical strings — `Max 10 issues` and
`chain depth cap: 4`. No adapter layer is needed, and the 10-issue set sits
exactly at the documented ceiling on both.

Arm SHAs are pinned. Re-pinning `new` invalidates every prior trial.

These two are the *first two points*, not the design's limit: an arm is any
plugin SHA, and the harness is built to accumulate them. See
[Longitudinal operation](#longitudinal-operation).

---

# Tier 0 — static accounting

## Method

For each arm, at its pinned SHA, sum body bytes and divide by 4 — the same
estimator `tests/lint-skill-size.sh:86` already uses, so Tier 0 and the existing
size gate cannot disagree.

Two surfaces, and the distinction is the whole point:

- **Resident** — `skills/*/SKILL.md` bodies. Loaded unconditionally, every run.
- **Reachable** — resident + `skills/*/references/*.md` + `skills/.shared/*.md`.
  The corpus that exists.

## Result

| Surface | `06d18cf` | `53e7e8c` | Δ |
|---|---|---|---|
| Resident | ~69,579 tok | ~28,242 tok | **−59.4%** (−41,337) |
| Reachable | ~69,701 tok | ~63,492 tok | −8.9% (−6,209) |

Per skill on `53e7e8c`: `parallel-issues` ~15,311 tok / 947 lines,
`review-remote-pr` ~7,846 / 520, `onboard-repo` ~5,085 / 372.
`lint-skill-size.sh` reports 3 skills, 0 violations.

## What the two numbers mean together

The refactor removed ~41k tokens from what loads unconditionally but only ~6k
from the corpus. The other ~35k did not vanish — it moved into 9 `references/`
files and `.shared/`, neither of which existed at baseline.

**The saving is therefore conditional on a behavior, not on a byte count:**

- references rarely read → ~41k saved per session
- references usually read → ~6k saved, *plus* added file-read round-trips and
  tool calls. It can net out **worse**.

This is what Tier 1 exists to settle, and it is why the primary Tier 1
instrument is the reference hit rate rather than the token total.

## Verdict rule (Q1)

Compression is demonstrated iff resident tokens on `new` are ≥40% below `old`.
Met: −59.4%. Recorded here so the bar is not moved after the fact.

---

# Tier 1 — the A/B experiment

## Trial definition

One trial = one fresh container, one fresh repo, one command:

```
/parallel-issues --yolo --fast-mode --auto-review --auto-serialize
```

No issue numbers. All ten issues sit in **Ready** on the Project board; the skill
selects, orders, and chains them itself. The trial terminates when draft PRs exist
for every issue the skill selected, or on a wall-clock timeout (initial value set
by the pilot).

Letting the skill self-select is deliberate. Both arms receive an identical board
and must complete the same ten issues, so totals stay comparable, while the
selection, batching, and chaining *strategy* becomes an outcome variable — which
is exactly the behavior under test.

## Effort tiers

`#125` (`spawn-contract.md:41-46`) resolves `AGENT_WORKER_MODEL`,
`AGENT_WORKER_MODEL_FALLBACK`, and `AGENT_WORKER_EFFORT` from `.agent/config.env`.
Tiers sweep `AGENT_WORKER_EFFORT` ∈ {`low`, `medium`, `high`} at
`AGENT_WORKER_MODEL=gpt-5.6-luna`.

The `old` arm predates `#125` and cannot read the key, so its tier is set by
patching the effort literal in its `spawn-contract.md` — the minimum edit that
achieves the same dispatch, and nothing else. The mechanisms differ; the outcome
must not. **Every trial asserts the realised tier** from the completion table's
`worker model` column. A trial whose realised tier differs from its assigned tier
is void, not adjusted.

## Staged plan

Per-trial cost is unknown until measured, so spend is staged behind go/no-go gates.

1. **Pilot — 2 trials.** `old@high`, `new@high`. Validates the harness end to end
   and yields real cost, wall-clock, and GraphQL-per-trial figures. Sets the timeout.
2. **Dominance probe — 5 paired trials (10 runs).** `new@low` vs `old@high`.
   This is the highest-value comparison: effort tiers move tokens by *multiples*
   while the refactor moves them by *percents*, so a dominance result survives the
   noise floor that a percentage delta does not.
3. **Frontier — remaining cells.** 2 arms × 3 tiers, filled in only if stage 2
   justifies it. Deliverable is acceptance score vs blended USD, two curves.

Arms alternate `A,B,B,A` rather than running all of one then all of the other, so
provider-side drift cancels rather than aliasing onto the arm.

## Environment

**Container.** One image from `debian:13-trixie` pinned **by digest**, carrying
pinned `git`, `gh`, `node`, `jq`, `python3`, and a pinned Codex CLI. **One trial
per container, then destroyed** — per trial, not per arm, because
`~/.codex/sessions` accumulates.

**Home directory baked empty.** No global `AGENTS.md`, no `rules/`, no claude-mem,
no memory hooks. Memory is *stateful across trials*: trial N would contaminate
trial N+1. This is the control most likely to silently destroy the study.

**Concurrency cap — first-order confounder.** Both arms read
`max_concurrent_threads_per_session` from `~/.codex/config.toml`
(`53e7e8c` line 525, `06d18cf` line 755) and are contracted to *stop and ask*
when it is absent. So the value must be **present and identical** in both
containers, or differing values silently change parallelism and invalidate every
token figure — or an absent value deadlocks the unattended run by design.

**Plugin** mounted read-only from a worktree at the arm's SHA. **Secrets** injected
as runtime env, never baked into the image.

## The repository under test

A single repo, `tally`, **deleted and recreated from a template before every
trial**. One repo rather than two mirrors: trials run serially anyway, and a
single repo means both arms see byte-identical starting state down to the issue
numbers, with no repo name or history for an agent to notice. Arm assignment
lives in the container, never in the repo.

Reset must be delete-and-recreate, not clean-in-place: a PR cannot be deleted,
only closed, and a trial opening with ten closed PRs saying "already done" is a
live contamination vector.

Templates copy files but not issues, so per trial the harness runs:
`gh repo create --template` → 10 REST issue creates → create and link the board
→ add all ten items to **Ready** → write the `blocked_by` edges.

A canonical `.agent/config.env` and `.agent/board.json` are **hand-authored into
the template**, not produced by running `onboard-repo`. That skill is ATTENDED,
and old-vs-new versions of it could emit different configs — making the two arms'
*inputs* differ. The config is experiment input, not output.

Board work runs against GraphQL, which is the scarce pool. The harness gates each
trial on `gh api rate_limit` and **pauses** rather than failing mid-run.

## The mock application — "Tally"

Deliberately unoriginal. Ambiguity in the spec becomes variance in the
measurement, so clarity beats novelty.

```
index.html      shell, mounts #app
src/store.js    state + reducer        <- cluster A (7, 8, 9)
src/render.js   DOM rendering          <- cluster B (2, 4)
src/history.js  action log             <- disjoint
src/persist.js  localStorage           <- disjoint
src/filters.js  derived views          <- disjoint
src/format.js   pure date/text utils   <- disjoint
styles.css                             <- disjoint
```

The starting state is a *working* skeleton — renders a hardcoded list, bare state
object, no persistence. Not an empty repo: agents need existing conventions to
follow, or half the measurement becomes them inventing conventions differently
each run.

`bench/gold/index.html`, built from the final reference tree by
`bench/build-gold.sh`, is a single inlined file openable in a browser. It is
documentation and a sanity check — never the scorer.

It lives in `bench/` and is **never pushed to `tally`**, for the same reason the
oracle is not: an agent that can read the finished application is not solving the
issues, it is transcribing the answer.

## The ten issues

| # | File | Summary | Conflicts | `blocked_by` | Pitfall |
|---|---|---|---|---|---|
| 1 | `styles.css` | Visual shell: header, layout, task cards | — | — | — |
| 2 | `src/render.js` | Render via event delegation | 4 | — | listener leaks on re-render |
| 3 | `src/history.js` | Action log so state changes replay | — | — | — |
| 4 | `src/render.js` | Escape user-supplied task text | 2 | — | XSS via `innerHTML` |
| 5 | `src/filters.js` | Derived views: all / active / done | — | — | — |
| 6 | `src/persist.js` | Corruption-safe localStorage load | — | — | unguarded `JSON.parse` |
| 7 | `src/store.js` | Immutable reducer; stop mutating in place | 8, 9 | — | shared-reference mutation |
| 8 | `src/store.js` | Undo/redo over the action log | 7, 9 | 3 | history aliasing |
| 9 | `src/store.js` | Persist the active filter across reloads | 7, 8 | 5, 6 | — |
| 10 | `src/format.js` | Relative due dates | — | — | DST/timezone off-by-one |

Exactly five conflicting (2, 4, 7, 8, 9) and five disjoint. Every conflict is a
real dispatch-time collision inside one selected set, not a merge-order artifact.

**Chain depth.** Under `--auto-serialize`, conflict pairs *become* chain edges and
stack with `blocked_by` edges. Sequencing edges are therefore aimed at chain
**tails**: `3→8` and `{5,6}→9` give a longest path of 3, one under the cap of 4.
An earlier cut put a dependency at the head of the store cluster and produced a
depth-4 chain — at the cap, zero margin, one inference away from the drop/ask path.

**Dependencies are native edges, not prose.** `SKILL.md:34` is explicit:
*"Ordering evidence is file-conflict pairs and native blocked-by edges inside the
selected set; issue-body prose is never an ordering input."* Edges are written via
`gh api repos/{o}/{r}/issues/N/dependencies/blocked_by`. A "Blocked by #N" line in
a body would be silently ignored.

**Issue bodies** carry *Why*, numbered *Acceptance criteria* mapping 1:1 to test
ids, *Files expected to change*, and *Out of scope*. Naming the expected files is a
deliberate variance-reduction choice: it costs some realism but cuts exploration
noise, and being identical across arms it cannot favour either. No body mentions
the benchmark.

## The oracle

`bench/accept/` — `node --test`, **zero dependencies**. No `npm install` means no
network, no lockfile drift, no install-time tokens, and a scoring step reproducible
in a year.

- Pure modules (`store`, `filters`, `format`, `persist`, `history`) tested by direct import.
- `render.js` tested against a hand-written DOM stub vendored in `bench/accept/` and
  **never present in `tally`**, so agents cannot fit to it.
- One file per issue (`issue-04.test.js`). An issue scores as accepted only at
  **100%** of its cases — partial credit invites gaming.
- Pitfall assertions are adversarial by construction: #4 feeds `<img onerror=…>`
  and asserts `textContent`; #7 freezes the input state and asserts no throw.
- The suite is injected by the harness *after* the run and is never pushed to `tally`.

A run that spends fewer tokens by quietly doing less work scores lower rather than
winning. This is what makes the cost number meaningful.

## Instrumentation

`bench/parse-rollout.py` reads `~/.codex/sessions/*.jsonl` and emits one JSON
record per trial:

- `plugin_sha`, `fixture_version`, `model`, `effort` — the ledger key
- effort tier assigned **and realised**, resolved model id, trial index, `run_id`
- `is_drift_control` — true when this trial is the frozen-SHA reference for its round
- **four token classes separately** — input, cache-write, cache-read, output —
  split orchestrator vs each worker
- blended USD
- **reference hit rate**: which `references/*.md` and `.shared/*.md` were read, how
  often, by whom
- wall clock, worker count, selected issue set, chain plan, serialization and retry events
- acceptance score per issue
- exit condition (complete / partial / timeout)

Reporting the four token classes separately is not bookkeeping. Moving content out
of the resident spine and into files that get read shifts cost *between* classes;
a single "total tokens" figure can hide the entire effect in either direction.

## Pre-registration

`bench/PREREGISTRATION.md` is written and committed **before the first trial**.
Noise cannot be adjudicated away, but binding to a rule chosen before seeing the
data is what makes the conclusion honest.

- **Q1 verdict** — resident token delta ≥40%. Already met at −59.4%.
- **Dominance** — `new@low` dominates `old@high` iff median acceptance is ≥ *and*
  median blended USD is <, with non-overlapping IQRs.
- **Reference siting** — a reference read in ≥90% of runs is misfiled and belongs
  back in the spine; one read in 0% of runs is dead weight. Both are actionable
  with no token comparison at all, and both are deterministic given the logs.
- **Void trials** — realised tier ≠ assigned tier, or model id drift mid-study.
  Void, never adjusted.
- **Fixture fork** — any change under `bench/fixtures/`, `bench/issues/`, or
  `bench/accept/` increments `fixture_version`. Points from different fixture
  versions are never plotted on one line.
- **Drift normalisation** — a measurement round without a drift-control trial is
  uninterpretable, and its points are excluded from any trend claim.

The reference-siting rule doubles as evidence for a claim currently asserted in
`lint-skill-size.sh`: that `parallel-issues`' 900-line target is "a design floor,
not an interrupted ratchet."

## Longitudinal operation

The benchmark is intended as standing infrastructure, not a one-shot study: arms
generalise to any plugin SHA, and results accumulate into a series showing how
agent-kit fares across releases, models, and effort tiers.

### The results ledger

`bench/results/*.jsonl` — append-only, committed, one record per trial, keyed by
`(plugin_sha, fixture_version, model, effort)`. Records are never rewritten or
deleted, so every chart is a pure function of the ledger: a plot can always be
regenerated and can never disagree with its source.

### Fixture freezing

A series is meaningful only while the task holds still. Improving an issue body,
repairing a flaky oracle case, or tidying the Tally skeleton silently makes every
earlier point incomparable — and the graph will bend rather than warn.

Therefore any change under `bench/fixtures/`, `bench/issues/`, or `bench/accept/`
**increments `fixture_version` and forks a new series.** Points from different
fixture versions are never plotted on one line. This is deliberately painful; the
alternative is a chart that quietly mixes two different measurements.

### Drift control arm

`gpt-5.6-luna` in six months is not `gpt-5.6-luna` today. Provider-side change
moves the numbers with no plugin change at all, and an uncontrolled series cannot
distinguish *"agent-kit regressed"* from *"the model changed underneath us."*

Every measurement round therefore re-runs a **frozen** plugin SHA — `06d18cf`,
which will never move again — alongside whatever is being measured. The delta
between that frozen arm's original result and its result today **is** the drift
correction, and every other point in the round is normalised against it. Without
it the series is decorative; with it, it is evidence.

### Cadence

The two tiers want opposite rhythms, and together they make the chart:

- **Tier 0 — every merge to `main`.** A script over the repo, so it costs nothing.
  `lint-skill-size.sh` already computes these numbers in order to gate on them; a
  CI step appends them to the ledger instead of discarding them, turning a yes/no
  gate into a dense, free trace of resident and reachable surface over time.
- **Tier 1 — rare and deliberate.** Sparse anchors on the same axis, each with its
  drift-control companion.

### Sampling, not a grid

Models × efforts × SHAs grows multiplicatively and is not affordable as a full
matrix. Default round: the drift control, plus current `main` at each effort tier.
A new model enters by running the **frozen** arm on it first — establishing that
model's own baseline — before any agent-kit claim is made on that model.

## Threats to validity

- **The arms differ by more than compression.** ~20 merged issues separate them,
  including `#122`'s stacked-PR retarget fix — present on `new`, absent on `old`.
  Correctness fixes cut both ways: avoiding a wasted retarget loop *saves* tokens,
  added verification *costs* them. Not separable, and not to be reported as
  "compression saved X%". Tier 0 is the compression claim; Tier 1 is a
  whole-plugin claim.
- **Variance.** Stage 2 at n=5 can detect dominance, not a sub-10% delta. Any
  percentage claim needs stage 3 at minimum, and probably more.
- **Self-selection.** If the arms select different issue sets, per-trial totals
  need normalising per accepted issue. Selection is recorded for exactly this.
- **Board contention.** Trials burn GraphQL against the same account as ordinary
  work. Serial execution plus the rate-limit gate bounds it; it does not eliminate it.
- **Provider drift.** Model id is asserted per trial; drift mid-study voids
  affected trials. Across a *series*, drift is the dominant threat and is handled
  structurally by the drift control arm rather than by assertion — see below.

## Layout

```
bench/
  PREREGISTRATION.md      decision rules, committed before trial 1
  fixtures/tally/         template repo content + hand-authored .agent/
  issues/*.md             the ten bodies
  accept/                 hidden oracle + DOM stub (never pushed)
  gold/                   reference tree + build-gold.sh
  results/*.jsonl         append-only ledger, never rewritten
  parse-rollout.py        token + reference-hit meter
  run-trial.sh            container lifecycle, repo reset, invocation, scoring
  tier0.sh                static accounting at any SHA; appends to the ledger
  plot.py                 charts, a pure function of results/
```

`bench/fixtures/`, `bench/issues/`, and `bench/accept/` are the frozen set: edits
there fork `fixture_version`.

## Status

Design approved 2026-08-13; amended the same day for longitudinal operation
(results ledger, fixture freezing, drift control arm, per-merge Tier 0).
Implementation not started.
