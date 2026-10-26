---
id: tally-14
conflict_group: none
files: src/results.js, test/results.smoke.mjs
blocked_by: tally-13
status: Backlog
---

# tally: render search results

## Why

Matching items need a view. This issue is `blocked_by: tally-13`: it is the
second-wave issue of the second pair, and its acceptance cannot pass
without `filterItems` from `tally-13`.

## Files to create

- Create: `src/results.js`
- Create: `test/results.smoke.mjs`

## What

- Add `src/results.js` exporting a pure `renderResults(state, query)` that
  imports `filterItems` from `src/search.js` (added by `tally-13`) and
  returns the `renderItemRow` markup (from `src/render.js`) of every
  matching item joined into one string; no match returns the string
  `<p class="tally-empty">No matches</p>`.
- Add its own smoke test, `test/results.smoke.mjs`, which imports the real
  `src/search.js`.
- Do not edit `src/render.js`; import from it.
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/results.js` exports `renderResults` and uses `filterItems` from
      `src/search.js`; the change is built on `tally-13`'s merged work.
- [ ] `renderResults` over `Coffee` and `Tea` with query `tea` contains the
      `Tea` row and not the `Coffee` row.
- [ ] A query with no match returns `<p class="tally-empty">No matches</p>`.
- [ ] `node test/results.smoke.mjs` exits 0 and prints a line starting with
      `PASS`; it fails if `src/search.js` is absent.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
