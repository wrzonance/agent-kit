---
id: tally-10
conflict_group: none
files: src/stats.js, test/stats.smoke.mjs
blocked_by: tally-06
---

# tally: computed stats module

## Why

There is no summary view -- item count, total, or average are each hand-
computed by the user. This is one of five disjoint issues in this fixture
(see `tally-06`): it shares no file with any other issue.
`blocked_by: tally-06` makes it a second, shorter branch off the same head
as the `tally-06` -> `tally-07` -> `tally-08` -> `tally-09` chain (depth 1
on this branch; the longest path through the whole graph is still the
depth-3 chain via `tally-09`).

## What

- Add `src/stats.js` exporting a pure `computeStats(state)` returning
  `{ itemCount, totalCount, average }`: `itemCount` is `state.items.length`;
  `totalCount` is the sum of every item's `count`; `average` is
  `totalCount / itemCount` rounded to 2 decimal places (a `number`, not a
  string), or `0` when `itemCount === 0` (no division by zero).
- Add its own smoke test, `test/stats.smoke.mjs` (same style as
  `test/keyboard.smoke.mjs`).
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/stats.js` exports `computeStats`.
- [ ] For items with counts `[1, 2, 3]`, `computeStats(state)` equals
      `{ itemCount: 3, totalCount: 6, average: 2 }`.
- [ ] `computeStats(createState())` (no items) equals
      `{ itemCount: 0, totalCount: 0, average: 0 }` (no `NaN`/`Infinity`).
- [ ] `node test/stats.smoke.mjs` exits 0 and prints a line starting with
      `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
