---
id: tally-06
conflict_group: none
files: src/theme.js, style.css, index.html, test/theme.smoke.mjs
blocked_by:
---

# tally: dark mode toggle

## Why

Tally has no theming at all -- always the browser default background. This
is one of five issues in this fixture that are deliberately disjoint: it
does not touch `src/render.js` or `src/store.js`, and shares no file with
any other disjoint issue (see `bench/README`'s Tier-1 fixture note). It is
the head of this fixture's one dependency chain (`tally-07` -> `tally-08`
-> `tally-09` build on it via `blocked_by`; `tally-10` also depends on it).

## What

- Add `src/theme.js` exporting a pure `toggleTheme(current)`: returns
  `'dark'` when `current === 'light'`, and `'light'` for any other input
  (including `undefined`) -- so the default (no stored preference) toggles
  to dark on first use.
- Add `style.css` with two selectors, `.theme-light` and `.theme-dark`,
  each setting at least a `background` and `color` declaration.
- `index.html` gains `<link rel="stylesheet" href="./style.css" />` in
  `<head>`. Nothing else in `index.html` changes.
- `src/theme.js` is a standalone module in this issue -- it is not wired
  into `src/main.js` here (wiring is out of scope for this fixture; see the
  "disjoint issues are self-contained" note in `bench/README`).
- Add its own smoke test, `test/theme.smoke.mjs` (mirrors `test/smoke.mjs`'s
  style: `node:assert/strict`, prints a `PASS` line, runnable standalone via
  `node test/theme.smoke.mjs`).

## Acceptance Criteria

- [ ] `src/theme.js` exports `toggleTheme`; `toggleTheme('light') === 'dark'`,
      `toggleTheme('dark') === 'light'`, `toggleTheme(undefined) === 'dark'`.
- [ ] `style.css` defines both `.theme-light` and `.theme-dark` with a
      `background` and `color` declaration each.
- [ ] `index.html` links `style.css` in `<head>`; its `<body>` is
      unchanged from the base fixture.
- [ ] `node test/theme.smoke.mjs` exits 0 and prints a line starting with
      `PASS`.
- [ ] `node test/smoke.mjs` still exits 0 (base assertions unaffected).
