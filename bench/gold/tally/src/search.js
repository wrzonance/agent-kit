// tally-13: pure name filter. Returns a new array; never mutates its input.
export function filterItems(items, query) {
  const needle = (query ?? '').trim().toLowerCase();
  if (!needle) return [...items];
  return items.filter((it) => it.name.toLowerCase().includes(needle));
}
