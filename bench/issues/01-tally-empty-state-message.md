---
id: tally-01
conflict_group: render
files: src/render.js
blocked_by:
---

# tally: show an empty-state message when there are no items

## Why

`renderApp` currently renders an empty `<ul>` with nothing else when
`state.items` is empty -- a first-time user sees a blank page with no
indication that the app is working. This is one of two issues that
deliberately touch `src/render.js` in the header/list region (see
`bench/README`'s Tier-1 fixture note): together with `tally-02` it is part
of this fixture's controlled `render.js` conflict pair.

## What

- Add an exported `renderEmptyState()` in `src/render.js` returning exactly:
  `<p class="tally-empty">No tallies yet -- add one above.</p>`
- `renderApp(state)` calls `renderEmptyState()` and includes its output
  immediately after `<header class="tally-header">...</header>` whenever
  `state.items.length === 0`.
- When `state.items.length > 0`, `renderApp`'s output must NOT contain the
  string `tally-empty`.
- No other exported function's signature changes.

## Acceptance Criteria

- [ ] `src/render.js` exports a `renderEmptyState` function taking no
      arguments and returning the exact string above.
- [ ] `renderApp(createState())` (an empty state) contains
      `<p class="tally-empty">No tallies yet -- add one above.</p>`.
- [ ] `renderApp(state)` for a state with one item does NOT contain the
      substring `tally-empty`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
