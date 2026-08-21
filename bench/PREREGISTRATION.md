bench/ -- token-benchmark epic (#152) pre-registration
========================================================

Dated: 2026-08-20. Committed before any Tier-1 trial record exists in
`bench/results/*.jsonl` (see "Why" below) -- `tests/test-bench-preregistration.sh`
asserts the ledger holds zero Tier-1 records, which combined with this file
existing in the same commit is what makes "pre-registration precedes trial 1"
a checkable fact rather than an assertion to trust.

Design doc: docs/superpowers/specs/2026-08-13-token-benchmark-design.md
(branch docs/token-benchmark-spec), section "Pre-registration". That doc was
not present on this directory's base branch (main) at implementation time
(see `bench/README`'s "Construction decisions" stanza for the same situation
on the prior two slices); the rules below are restated from the issue body
verbatim rather than the design doc's own wording.

Why
---

Q2 is stochastic -- repeated identical agentic tasks vary in token spend by
up to ~30x (verified: "How Do Coding Agents Spend Your Money? Analyzing and
Predicting Token Consumption in Agentic Coding Tasks", arXiv:2604.22750),
and the minimal-pair cleanliness study (verified: arXiv:2605.20049) needed
660 trials to resolve a 7-8% token effect. Noise cannot be adjudicated away;
binding to decision rules chosen before seeing data is what makes the
eventual conclusion honest.

Rules
-----

- **Q1 verdict** -- resident token delta >=40% (already met at -59.4%).

- **Dominance** -- `new@low` dominates `old@high` iff median acceptance >=
  AND median blended USD <, with non-overlapping IQRs.

- **Reference siting** -- a reference read in >=90% of runs is misfiled (belongs
  in the spine); 0% is dead weight; both actionable deterministically from
  logs. (This rule doubles as evidence for `lint-skill-size.sh`'s "design
  floor, not interrupted ratchet" claim on the 900-line target.)

- **Void trials** -- realised tier != assigned tier, or mid-study model-id
  drift: void, never adjusted.

- **Fixture fork** -- any change under `bench/fixtures/`, `bench/issues/`,
  `bench/accept/` increments `fixture_version`; cross-version points never
  share a plotted line.

- **Drift normalisation** -- a round without a frozen-`06d18cf`
  drift-control trial is excluded from trend claims.
