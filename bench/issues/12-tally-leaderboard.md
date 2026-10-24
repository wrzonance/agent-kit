---
id: tally-12
conflict_group: none
files: src/leaderboard.js, test/leaderboard.smoke.mjs
blocked_by: tally-11
---

# tally: leaderboard of the top items

## Why

A summary of the highest counts needs the ordering `tally-11` adds. This
issue is `blocked_by: tally-11`: it is the second-wave issue of the first
pair, and its acceptance cannot pass without `sortItems` from `tally-11`.

## What

- Add `src/leaderboard.js` exporting a pure `topItems(state, n)` that
  imports `sortItems` from `src/sorting.js` (added by `tally-11`) and
  returns the first `n` items of `state.items` ordered by `'count'`
  descending. `n` of 0 or less returns `[]`; `n` larger than the list
  returns every item.
- Add its own smoke test, `test/leaderboard.smoke.mjs`, which imports the
  real `src/sorting.js`.
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/leaderboard.js` exports `topItems` and uses `sortItems` from
      `src/sorting.js`; the change is built on `tally-11`'s merged work.
- [ ] `topItems` over counts 1, 5, 3 with `n = 2` returns the items with
      counts 5 and 3, in that order.
- [ ] `topItems(state, 0)` returns `[]`.
- [ ] `node test/leaderboard.smoke.mjs` exits 0 and prints a line starting
      with `PASS`; it fails if `src/sorting.js` is absent.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
