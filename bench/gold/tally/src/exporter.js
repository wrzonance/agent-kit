// tally-08: export state as JSON. Standalone -- not wired into main.js (see
// bench/issues/08-tally-export-json.md).
export function exportState(state) {
  return {
    filename: 'tally-export.json',
    mimeType: 'application/json',
    content: JSON.stringify({ items: state.items, nextId: state.nextId }),
  };
}
