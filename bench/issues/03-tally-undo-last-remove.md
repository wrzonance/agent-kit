---
id: tally-03
conflict_group: store
files: src/store.js
blocked_by:
---

# tally: undo the last removed item

## Why

`removeItem` is permanent -- a misclick deletes an item's whole count
history with no way back. This is one of three issues that deliberately
touch `src/store.js` (see `tally-04`, `tally-05`): together they form this
fixture's controlled `store.js` conflict trio, each adding a new exported
function near the bottom of the file.

## What

- `removeItem(state, id)` returns `{ items, nextId, lastRemoved }` where
  `lastRemoved` is the removed item object (`{ id, name, count }`) if found,
  or the state's existing `lastRemoved` (or `undefined`) if `id` did not
  match anything.
- Add an exported `undoRemove(state)`: if `state.lastRemoved` is set,
  returns a new state with that item appended back to `items` (preserving
  its original `count`) and `lastRemoved` cleared to `undefined`; the id
  ordering does not need to match the original position. If
  `state.lastRemoved` is unset, `undoRemove` returns `state` unchanged
  (same reference).
- `createState()` continues to return `{ items: [], nextId: 1 }`
  (`lastRemoved` starts absent/undefined, not present as an explicit key).

## Acceptance Criteria

- [ ] `src/store.js` exports `undoRemove`.
- [ ] Removing an item then calling `undoRemove` restores an item with the
      same `name` and `count` as the removed one.
- [ ] Calling `undoRemove` twice in a row (nothing removed the second time)
      is a no-op: the second call returns the same state reference.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
