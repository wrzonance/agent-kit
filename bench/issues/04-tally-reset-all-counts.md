---
id: tally-04
conflict_group: store
files: src/store.js
blocked_by:
---

# tally: reset every item's count to zero

## Why

There is no way to zero out every counter at once for a new round --
a user has to click "-" repeatedly on each item. This is one of three
issues that deliberately touch `src/store.js` (see `tally-03`, `tally-05`):
together they form this fixture's controlled `store.js` conflict trio, each
adding a new exported function near the bottom of the file.

## What

- Add an exported `resetAll(state)` returning a new state where every item
  in `items` has `count: 0`; `nextId` and item `id`/`name` fields are
  unchanged. Items themselves are not removed.
- If `state.items` is already empty, `resetAll` returns `state` unchanged
  (same reference).

## Acceptance Criteria

- [ ] `src/store.js` exports `resetAll`.
- [ ] For a state with two items with counts 3 and 5, `resetAll(state)`
      returns a state where both items have `count === 0` and the same
      `name`/`id` as before.
- [ ] `resetAll(createState())` (no items) returns the exact same object
      reference it was given.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
