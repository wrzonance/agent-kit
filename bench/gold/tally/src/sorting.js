// tally-11: pure item ordering. Returns a new array; never mutates its input.
export function sortItems(items, key) {
  const copy = [...items];
  if (key === 'name') {
    return copy.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  }
  if (key === 'count') {
    return copy.sort((a, b) => b.count - a.count);
  }
  return copy;
}
