// tally-07: keyboard shortcuts. Standalone -- not wired into main.js (see
// bench/issues/07-tally-keyboard-shortcuts.md).
export function matchShortcut(event) {
  switch (event.key) {
    case '+':
      return 'increment';
    case '-':
      return 'decrement';
    case 'Delete':
      return 'remove';
    default:
      return null;
  }
}
