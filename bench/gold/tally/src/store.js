// Tally -- pure state module (gold: base + tally-03 undoRemove + tally-04
// resetAll + tally-05 renameItem, merged). No DOM, no I/O: every export
// takes a state object and returns a NEW state object (or a plain value),
// never mutating its argument.
//
// State shape: { items: [{ id, name, count }], nextId, lastRemoved? }

export function createState() {
  return { items: [], nextId: 1 };
}

export function addItem(state, name) {
  const trimmed = (name ?? '').trim();
  if (!trimmed) return state;
  const item = { id: state.nextId, name: trimmed, count: 0 };
  return { ...state, items: [...state.items, item], nextId: state.nextId + 1 };
}

// tally-03: track the removed item so undoRemove can restore it.
export function removeItem(state, id) {
  const removed = state.items.find((it) => it.id === id);
  return {
    items: state.items.filter((it) => it.id !== id),
    nextId: state.nextId,
    lastRemoved: removed ?? state.lastRemoved,
  };
}

// tally-03: restore the last-removed item, if any; otherwise a no-op.
export function undoRemove(state) {
  if (!state.lastRemoved) return state;
  const { lastRemoved, ...rest } = state;
  return { ...rest, items: [...state.items, lastRemoved], lastRemoved: undefined };
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

// tally-04: zero every item's count; a no-op (same reference) when empty.
export function resetAll(state) {
  if (state.items.length === 0) return state;
  return { ...state, items: state.items.map((it) => ({ ...it, count: 0 })) };
}

// tally-05: rename a matching item; blank-after-trim or unknown id is a
// no-op (same reference), matching addItem's existing convention.
export function renameItem(state, id, name) {
  const trimmed = (name ?? '').trim();
  if (!trimmed) return state;
  const exists = state.items.some((it) => it.id === id);
  if (!exists) return state;
  return {
    ...state,
    items: state.items.map((it) => (it.id === id ? { ...it, name: trimmed } : it)),
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
