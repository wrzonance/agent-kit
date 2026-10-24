---
id: tally-11
conflict_group: none
files: src/sorting.js, test/sorting.smoke.mjs
blocked_by:
---

# tally: sort items by name or count

## Why

The list shows items in insertion order only. This is the first of two
independent wave-fixture issues (see `tally-13`): it shares no file with any
other issue, and `tally-12` builds on it. Together `tally-11` to `tally-14`
make the two-wave fixture for the interactive trials: two issues ready now,
two that become ready when their blockers merge.

## What

- Add `src/sorting.js` exporting a pure `sortItems(items, key)` where `key`
  is `'name'` or `'count'`. It returns a NEW array and never mutates its
  input. `'name'` sorts ascending, case-insensitive; `'count'` sorts
  descending; ties keep their original relative order.
- An unknown `key` returns a copy of `items` in the original order.
- Add its own smoke test, `test/sorting.smoke.mjs` (same style as
  `test/keyboard.smoke.mjs`).
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/sorting.js` exports `sortItems`.
- [ ] `sortItems(items, 'name')` orders `Tea`, `coffee`, `Apple` as `Apple`,
      `coffee`, `Tea`.
- [ ] `sortItems(items, 'count')` orders counts 1, 5, 3 as 5, 3, 1.
- [ ] The input array is not mutated and a new array is returned.
- [ ] `node test/sorting.smoke.mjs` exits 0 and prints a line starting with
      `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
