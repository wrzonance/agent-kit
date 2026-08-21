# Tally bench fixture -- construction notes (issue #325)

**This is NOT the epic's design doc.** The epic #152 design doc
(`docs/superpowers/specs/2026-08-13-token-benchmark-design.md`, branch
`docs/token-benchmark-spec`) was not present on `main` when issue #325 was
implemented and was not fetched (see `bench/README`'s "Construction
decisions" stanza, which this doc summarizes as a standalone reference).
This file exists only so a reader who lands in `docs/superpowers/specs/`
looking for "the Tally spec" finds a pointer to where it actually lives and
an honest label on its provenance, rather than assuming this doc is the
missing one.

## Where the real content lives

- `bench/README` -- layout, the ten issues' conflict/dependency structure,
  the frozen-set boundary rule, and the full "Construction decisions" list.
- `bench/fixtures/tally/` -- the Tally skeleton itself (read the source; it
  is small).
- `bench/issues/*.md` -- the ten issue bodies, each spec-grade with its own
  Acceptance Criteria.
- `bench/gold/tally/` -- the reference solution all ten issues resolve to.
- `bench/verify-issues.py` -- the mechanical check for the conflict/
  dependency structure claims (run: `python3 bench/verify-issues.py`).
- `bench/build-gold.sh` -- builds and runs the gold tree's public smoke
  suite (run: `bench/build-gold.sh`).

## One-line summary, for search

Tally is a tally-counter list SPA (add/increment/decrement/remove/rename a
named counter) used purely as Tier 1's controlled task substrate: ten
frozen issues, five of which are designed to collide (two in
`src/render.js`, three in `src/store.js`) and five of which are disjoint,
single-module additions chained by `blocked_by` to a longest depth of 3.
