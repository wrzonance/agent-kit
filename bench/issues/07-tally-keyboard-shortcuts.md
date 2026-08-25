---
id: tally-07
conflict_group: none
files: src/keyboard.js, test/keyboard.smoke.mjs
blocked_by: tally-06
---

# tally: keyboard shortcuts module

## Why

Every count change needs a mouse click on `+`/`-`. This is one of five
disjoint issues in this fixture (see `tally-06`): it shares no file with
any other issue. It is `blocked_by: tally-06` -- the second link in this
fixture's one dependency chain (`tally-06` -> `tally-07` -> `tally-08` ->
`tally-09`), a purely sequencing constraint (this issue could as easily
land first technically; the chain exists so the benchmark has a depth-3
`blocked_by` path to exercise) rather than a file overlap with `tally-06`.

## What

- Add `src/keyboard.js` exporting a pure `matchShortcut(event)`, where
  `event` is `{ key: string }`: maps `'+'` -> `'increment'`, `'-'` ->
  `'decrement'`, `'Delete'` -> `'remove'`, any other key -> `null`.
- Add its own smoke test, `test/keyboard.smoke.mjs` (mirrors
  `test/smoke.mjs`'s style: `node:assert/strict`, prints a `PASS` line,
  runnable standalone via `node test/keyboard.smoke.mjs`).
- Like `tally-06`, this module is standalone -- not wired into
  `src/main.js` in this issue.

## Acceptance Criteria

- [ ] `src/keyboard.js` exports `matchShortcut`; `matchShortcut({key:'+'})
      === 'increment'`, `matchShortcut({key:'-'}) === 'decrement'`,
      `matchShortcut({key:'Delete'}) === 'remove'`,
      `matchShortcut({key:'a'}) === null`.
- [ ] `node test/keyboard.smoke.mjs` exits 0 and prints a line starting
      with `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
