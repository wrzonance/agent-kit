---
id: tally-09
conflict_group: none
files: src/importer.js, test/importer.smoke.mjs
blocked_by: tally-08
---

# tally: import state from JSON

## Why

`tally-08` added export with no matching way back in. This is one of five
disjoint issues in this fixture (see `tally-06`): it shares no file with
any other issue. It is `blocked_by: tally-08` -- the fourth and final link
in this fixture's one dependency chain (`tally-06` -> `tally-07` ->
`tally-08` -> `tally-09`, three `blocked_by` edges: depth 3, one under both
arms' byte-identical chain depth cap of 4).

## What

- Add `src/importer.js` exporting a pure `parseImport(text)`: attempts
  `JSON.parse(text)`; on success with a shape matching `{ items: array,
  nextId: integer }`, returns `{ ok: true, state: { items, nextId } }`; on
  any parse failure or shape mismatch, returns `{ ok: false, error: string
  }` (a short, non-empty message) -- never throws.
- Add its own smoke test, `test/importer.smoke.mjs` (same style as
  `test/keyboard.smoke.mjs`).
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/importer.js` exports `parseImport`.
- [ ] `parseImport('{"items":[],"nextId":1}')` returns
      `{ ok: true, state: { items: [], nextId: 1 } }`.
- [ ] `parseImport('not json')` returns `{ ok: false, error: <non-empty
      string> }` without throwing.
- [ ] `parseImport('{"nextId":1}')` (missing `items`) returns `{ ok: false,
      ... }` without throwing.
- [ ] `node test/importer.smoke.mjs` exits 0 and prints a line starting
      with `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
