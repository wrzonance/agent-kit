// tally-06: dark mode toggle. Standalone -- not wired into main.js (see
// bench/issues/06-tally-dark-mode-toggle.md).
export function toggleTheme(current) {
  return current === 'light' ? 'dark' : current === 'dark' ? 'light' : 'dark';
}
