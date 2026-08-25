---
id: tally-02
conflict_group: render
files: src/render.js
blocked_by:
---

# tally: show a running total badge in the header

## Why

There is no at-a-glance total across all tally counters -- a user with
several items has to add the numbers up themselves. This is the second of
the two issues that deliberately touch `src/render.js`'s header region (see
`tally-01`): together they form this fixture's controlled `render.js`
conflict pair, both editing the same `<header class="tally-header">` output.

## What

- Import `total` from `./store.js` in `src/render.js`.
- `renderApp(state)` includes a badge inside the header:
  `<span class="tally-total">Total: N</span>` where `N` is `total(state)`,
  placed inside `<header class="tally-header">` after the `<h1>`.
- No other exported function's signature changes.

## Acceptance Criteria

- [ ] `renderApp(state)` for a state whose items sum to 5 contains
      `<span class="tally-total">Total: 5</span>`.
- [ ] `renderApp(createState())` (no items) contains
      `<span class="tally-total">Total: 0</span>`.
- [ ] The badge is inside `<header class="tally-header">...</header>`, not
      the `<ul>`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
