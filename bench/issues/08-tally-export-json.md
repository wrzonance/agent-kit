---
id: tally-08
conflict_group: none
files: src/exporter.js, test/exporter.smoke.mjs
blocked_by: tally-07
---

# tally: export state as JSON

## Why

There is no way to get a state snapshot out of the app for backup or
sharing. This is one of five disjoint issues in this fixture (see
`tally-06`): it shares no file with any other issue. It is
`blocked_by: tally-07` -- the third link in this fixture's one dependency
chain (`tally-06` -> `tally-07` -> `tally-08` -> `tally-09`).

## What

- Add `src/exporter.js` exporting a pure `exportState(state)` returning a
  plain object `{ filename, mimeType, content }` where `filename` is
  `'tally-export.json'`, `mimeType` is `'application/json'`, and `content`
  is `JSON.stringify({ items: state.items, nextId: state.nextId })` (no
  browser `Blob`/`URL` APIs -- this module stays Node-testable and
  browser-agnostic, matching `src/store.js`'s `toJSON`).
- Add its own smoke test, `test/exporter.smoke.mjs` (same style as
  `test/keyboard.smoke.mjs`).
- Standalone module, not wired into `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/exporter.js` exports `exportState`; for a non-empty state,
      `exportState(state).filename === 'tally-export.json'`,
      `.mimeType === 'application/json'`, and `JSON.parse(.content)` deep-
      equals `{ items: state.items, nextId: state.nextId }`.
- [ ] `node test/exporter.smoke.mjs` exits 0 and prints a line starting
      with `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
