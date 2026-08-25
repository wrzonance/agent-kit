// tally-09: import state from JSON. Standalone -- not wired into main.js
// (see bench/issues/09-tally-import-json.md). Never throws.
export function parseImport(text) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, error: 'invalid JSON' };
  }
  if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.items) || !Number.isInteger(parsed.nextId)) {
    return { ok: false, error: 'expected {items: array, nextId: integer}' };
  }
  return { ok: true, state: { items: parsed.items, nextId: parsed.nextId } };
}
