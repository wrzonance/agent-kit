// Tally -- pure state module. No DOM, no I/O: every export takes a state
// object and returns a NEW state object (or a plain value), never mutating
// its argument. This is what lets test/smoke.mjs exercise the whole data
// model under plain `node`, with no browser and no bundler.
//
// State shape: { items: [{ id, name, count }], nextId }

export function createState() {
  return { items: [], nextId: 1 };
}

export function addItem(state, name) {
  const trimmed = (name ?? '').trim();
  if (!trimmed) return state;
  const item = { id: state.nextId, name: trimmed, count: 0 };
  return { items: [...state.items, item], nextId: state.nextId + 1 };
}

export function removeItem(state, id) {
  return { items: state.items.filter((it) => it.id !== id), nextId: state.nextId };
}

export function increment(state, id) {
  return {
    ...state,
    items: state.items.map((it) => (it.id === id ? { ...it, count: it.count + 1 } : it)),
  };
}

export function decrement(state, id) {
  return {
    ...state,
    items: state.items.map((it) => (it.id === id ? { ...it, count: Math.max(0, it.count - 1) } : it)),
  };
}

export function total(state) {
  return state.items.reduce((sum, it) => sum + it.count, 0);
}

export function toJSON(state) {
  return JSON.stringify({ items: state.items, nextId: state.nextId });
}

export function fromJSON(json) {
  const parsed = JSON.parse(json);
  const items = Array.isArray(parsed.items) ? parsed.items : [];
  const nextId = Number.isInteger(parsed.nextId) ? parsed.nextId : 1;
  return { items, nextId };
}
