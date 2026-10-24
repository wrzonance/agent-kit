---
id: tally-13
conflict_group: none
files: src/search.js, test/search.smoke.mjs
blocked_by:
---

# tally: filter items by a search query

## Why

A long list is hard to scan. This is the second of two independent
wave-fixture issues (see `tally-11`): it shares no file with any other
issue, and `tally-14` builds on it.

## What

- Add `src/search.js` exporting a pure `filterItems(items, query)`: returns
  a NEW array of the items whose `name` contains `query`, case-insensitive,
  in their original order. A blank or whitespace-only `query` returns a
  copy of every item. It never mutates its input.
- Add its own smoke test, `test/search.smoke.mjs` (same style as
  `test/keyboard.smoke.mjs`).
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/search.js` exports `filterItems`.
- [ ] `filterItems` over `Coffee`, `Tea`, `Cocoa` with query `co` returns
      `Coffee` and `Cocoa`.
- [ ] A blank query returns every item, as a new array.
- [ ] The input array is not mutated.
- [ ] `node test/search.smoke.mjs` exits 0 and prints a line starting with
      `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
