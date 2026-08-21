---
id: tally-05
conflict_group: store
files: src/store.js
blocked_by:
---

# tally: rename an existing item

## Why

An item's name is fixed at creation -- a typo or a changed mind means
deleting and re-adding, which loses the count. This is one of three issues
that deliberately touch `src/store.js` (see `tally-03`, `tally-04`):
together they form this fixture's controlled `store.js` conflict trio, each
adding a new exported function near the bottom of the file.

## What

- Add an exported `renameItem(state, id, name)`: trims `name`; if the
  trimmed result is non-empty and an item with that `id` exists, returns a
  new state with that item's `name` replaced (its `count` and `id`
  unchanged); otherwise returns `state` unchanged (same reference) --
  matching `addItem`'s existing blank-name convention.

## Acceptance Criteria

- [ ] `src/store.js` exports `renameItem`.
- [ ] `renameItem(state, id, '  Tea  ')` renames the matching item to
      `'Tea'` (trimmed) and leaves its `count` untouched.
- [ ] `renameItem(state, id, '   ')` (blank after trim) returns the same
      state reference unchanged.
- [ ] `renameItem(state, nonexistentId, 'X')` returns the same state
      reference unchanged.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
