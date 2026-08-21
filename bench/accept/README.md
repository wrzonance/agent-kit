# bench/accept/ -- the Tier-1 hidden acceptance oracle (issue #326)

Slice 4 of the token-benchmark epic (#152). Design doc:
`docs/superpowers/specs/2026-08-13-token-benchmark-design.md` (branch
`docs/token-benchmark-spec`) was not present on this directory's base
branch (`main`) at implementation time -- see `bench/README`'s
"Construction decisions" stanza for how earlier slices handled the same
gap. This file follows issue #326's body directly.

## Why a hidden oracle

A trial that spends fewer tokens by doing less work must lose, not win.
Scoring an issue at anything less than 100% of its acceptance cases would
let a trial that implements 80% of an issue and claims done look
indistinguishable, in the ledger, from one that implements all of it. Every
case in a per-issue suite must be green for that issue to score.

## Layout

    bench/accept/
      README.md              -- this file
      run-accept.sh           -- scores a target Tally tree; see below
      tally-01.test.mjs .. tally-10.test.mjs
                               -- one node:test suite per bench/issues/*.md,
                                  one-to-one with its Acceptance Criteria.
                                  Never imports target code directly (see
                                  "Process isolation" below) -- asserts only
                                  on plain values returned by runScenario().
      scenarios/
        tally-01.mjs .. tally-10.mjs
                               -- oracle-authored, executed ONLY inside the
                                  forked scenario-runner child. Imports and
                                  calls the target's functions, returns a
                                  plain JSON-safe observation object.
      lib/
        target.mjs             -- resolves the tree under test via
                                   BENCH_ACCEPT_TARGET (never a hardcoded
                                   bench/gold/tally or bench/fixtures/tally
                                   path); importFromTarget/readFromTarget/
                                   existsInTarget all resolve strictly
                                   inside it, rejecting ".." traversal,
                                   absolute paths, and symlink escapes
        isolated.mjs             -- runScenario(id): forks scenario-runner
                                   with a bounded timeout; the ONLY signal
                                   trusted is the child's single structured
                                   IPC message, never its exit code
        scenario-runner.mjs      -- the fork() entrypoint that actually
                                   imports and runs one scenarios/*.mjs
        smoke.mjs               -- the "node test/smoke.mjs still exits 0"
                                   and "node test/<module>.smoke.mjs exits 0
                                   and prints PASS" checks every issue's
                                   acceptance list repeats; shared so each
                                   is defined once, with a bounded timeout
        dom-stub.mjs            -- the vendored, zero-dependency HTML
                                   fragment parser the design names,
                                   for the badge-placement and
                                   index.html/head checks (parses plain
                                   strings -- executes no target code, so
                                   it runs in the test-file process)

## Process isolation (PR #363 review finding 1)

Every `tally-NN.test.mjs` process's own `node:assert/strict` and
`node:test` bookkeeping never share a process with imported target code.
Target modules are only ever imported inside a `fork()`ed
`lib/scenario-runner.mjs` child (via `lib/isolated.mjs`'s `runScenario()`),
a completely separate OS process with its own memory -- not merely a
separate module cache or realm. This closes two concrete forgery vectors a
shared-process design leaves open:

- **Monkeypatching**: `node:assert/strict`'s methods are plain, mutable
  object properties. A target module importing `node:assert/strict` and
  reassigning `assert.ok`/`assert.equal` in the SAME process as the
  oracle's own assertions would neuter every later assertion in that
  process. In this design the target's `assert` mutation happens inside
  the disposable child; the parent's `assert` was never in that process.
- **`process.exit()` during import**: the original design let
  `run-accept.sh` treat a suite's exit code as its pass/fail signal. A
  target module calling `process.exit(0)` while being imported would force
  `node --test`'s own exit code to 0 with no assertion ever having run --
  a sharper vector than assert-monkeypatching, since it needs no shared
  `assert` reference at all. `lib/isolated.mjs` never inspects the child's
  exit code; the only trusted signal is the single structured
  `process.send({ok, value|error})` message `scenario-runner.mjs` sends.
  A child that exits (for any reason, including `process.exit()`) without
  ever sending that message is reported as a **failed** call.

A scenario call that never responds is killed and also reported as a
failed call (`BENCH_ACCEPT_SCENARIO_TIMEOUT_MS`, default 10s) -- the
finding 2 per-call timeout; `run-accept.sh`'s own outer per-suite `timeout`
wrapper (`BENCH_ACCEPT_TIMEOUT_SECONDS`, default 30s) is the remaining
backstop. `tests/test-bench-accept.sh` pins all three regressions directly:
assert-monkeypatching does not flip a correct target to fail (it has no
effect at all) and does not flip a broken target to pass; `process.exit(0)`
at import scores fail; a target call that never returns is killed and
scores fail.

`readFromTarget`/`existsInTarget` execute no code (plain `fs` reads) and
stay in the `tally-NN.test.mjs` process; so does `lib/dom-stub.mjs`, which
only parses already-returned HTML strings.

## Running it

    bench/accept/run-accept.sh TARGET_DIR

`TARGET_DIR` is any tree shaped like Tally: `bench/fixtures/tally` (the
untouched skeleton), `bench/gold/tally` (the reference solution), or a
trial agent's tree. Reproduces the epic's two known-good numbers directly
against this repo:

    bench/accept/run-accept.sh bench/gold/tally      # -> score 10, total 10
    bench/accept/run-accept.sh bench/fixtures/tally  # -> score 0,  total 10

No network, no `npm install` -- every suite runs under node's built-in
`node --test`, `node:assert/strict`, and `node:child_process`/`node:fs`
only, plus the vendored `lib/dom-stub.mjs`. `jq` builds the output JSON
(already a `bench/`-wide dependency; see `bench/tier0.sh`).

## Scoring contract

- **Per-issue pass** = every `test()` case in that issue's
  `tally-NN.test.mjs` suite is green. `run-accept.sh` runs each suite as
  its own `node --test` process and records `pass` only when that process
  exits 0.
- **Trial acceptance** = the full ten-entry per-issue vector `run-accept.sh`
  prints (`results` in its JSON output), not a single aggregate score --
  a consumer that needs a scalar reduces over the vector itself (e.g.
  `score`/`total` are provided as that reduction for convenience).
- This script does **not** write to `bench/results/*.jsonl`. It is a pure
  scoring function of `(oracle suites, target tree) -> vector`; a later
  Tier-1 ledger slice is the consumer that appends `bench/results/tier1.jsonl`
  rows carrying this vector (or a reduction of it). Until that slice lands,
  `bench/accept/` intentionally produces no ledger record, so
  `tests/test-bench-preregistration.sh`'s "the ledger currently holds zero
  Tier-1 records" assertion holds.

## Injection interface (owned by the harness slice; documented here)

`bench/accept/` must never be present in the container a trial agent works
in -- an agent that can read its own oracle could special-case its
implementation to the exact assertions rather than the issue's actual
acceptance criteria, defeating the hidden-oracle design. The interface a
harness slice implements against:

1. **Before a trial**: the harness prepares a container/worktree from
   `bench/fixtures/tally` (or from a repo state where `bench/accept/` has
   been removed/excluded) -- `bench/accept/**` bytes are not copied in.
   `bench/accept/` living in this repository's own git history is not a
   violation of "never present in the trial container": the trial
   container is a *different* filesystem view the harness constructs, not
   this checkout.
2. **During the trial**: the agent under test has no path to
   `bench/accept/**` and cannot read, list, or infer its contents.
3. **After the trial completes**: the harness copies/mounts
   `bench/accept/**` into (or alongside) the trial's resulting tree and
   runs `bench/accept/run-accept.sh <trial-tree>` to produce the
   acceptance vector, which it hands to the ledger writer.

This slice does not implement container construction or the injection step
itself -- that is the harness slice's job, per the issue body ("injection
step owned by the harness slice; interface documented here"). What this
slice guarantees is that `run-accept.sh` and every `tally-NN.test.mjs`
suite work unmodified against any directory passed as `TARGET_DIR`, which
is the contract the injection step needs to hold.

### In-process fs isolation is defence in depth, not the primary control

Target code executes inside the forked `scenario-runner.mjs` child (see
`lib/isolated.mjs`), in the same OS process as the scenario module that
scores it. `lib/target.mjs`'s `resolveInTarget()` only constrains the
oracle's *own* helper calls (`importFromTarget`/`readFromTarget`/
`existsInTarget`) to stay inside `targetRoot()` -- it cannot stop target
code from calling `import('node:fs')` directly and reading arbitrary paths
on disk, including this oracle's own `bench/accept/scenarios/*.mjs` files,
to tailor its output to the exact assertions.

`lib/isolated.mjs` forks that child under Node's `--permission` model
(`--allow-fs-read`), granting read access only to: this oracle's `lib/`
directory (no secrets there), the single scenario module the run in
progress needs, and `targetRoot()` itself. A target that tries to read a
sibling scenario file is denied and the run fails outright (see
`tests/test-bench-accept.sh`'s "target code cannot read the oracle's own
scenario files" case). This closes the specific vector of a target reading
its *own suite's neighbors* through this process.

It does **not** make in-process execution of untrusted target code safe in
general -- Node's permission model does not sandbox against every
side channel (environment variables not already scrubbed, timing,
`node:child_process`/`node:worker_threads` reachability, future target
code exploiting a permission-model bug), and this oracle intentionally
runs target code with no OS-level sandbox (no container, no seccomp, no
separate user). **The real secrecy control is the injection design above:
`bench/accept/**` is never present in the trial container while the agent
under test is working (points 1-2 above) -- there is nothing on disk for a
side channel to find.** The permission-model restriction here is a second
layer against a *specific, cheap* attack (a target that reads its own
oracle's assertions out of curiosity or via a generic "read everything
nearby" strategy), not a claim that arbitrary untrusted code execution is
contained.

## Frozen-set membership

Per `bench/README`'s "Frozen-set boundary" section, `bench/accept/` joins
the frozen set alongside `bench/fixtures/**`, `bench/gold/**`, and
`bench/issues/**`: a future edit to any oracle suite's assertions (fixing a
bug in a check, tightening a criterion) forks `fixture_version` rather than
mutating a published fixture's scoring behavior in place, once a Tier-1
ledger slice has actually written rows under a given `fixture_version`. No
Tier-1 ledger record exists yet as of this slice (see "Scoring contract"
above), so this slice establishes the frozen baseline rather than forking
one.
