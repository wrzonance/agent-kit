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
                                  one-to-one with its Acceptance Criteria
      lib/
        target.mjs             -- resolves the tree under test via
                                   BENCH_ACCEPT_TARGET (never a hardcoded
                                   bench/gold/tally or bench/fixtures/tally
                                   path)
        smoke.mjs               -- the "node test/smoke.mjs still exits 0"
                                   check every issue's acceptance list
                                   repeats; shared so it is defined once
        dom-stub.mjs            -- the vendored, zero-dependency HTML
                                   fragment parser the design names,
                                   for the badge-placement and
                                   index.html/head checks

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
