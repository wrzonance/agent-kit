// bench/accept/scenarios/tally-11.mjs -- oracle scenario for bench/issues/11-tally-sort-items.md.
// Executes ONLY inside the forked scenario-runner child.
export default async function run({ importTarget }) {
  const sorting = await importTarget('src/sorting.js');
  const sortFnType = typeof sorting.sortItems;
  if (sortFnType !== 'function') return { sortFnType };

  const items = [
    { id: 1, name: 'Tea', count: 1 },
    { id: 2, name: 'coffee', count: 5 },
    { id: 3, name: 'Apple', count: 3 },
  ];
  const before = JSON.stringify(items);
  const byName = sorting.sortItems(items, 'name');
  const byCount = sorting.sortItems(items, 'count');
  const unknown = sorting.sortItems(items, 'nope');
  return {
    sortFnType,
    nameOrder: byName.map((i) => i.name),
    countOrder: byCount.map((i) => i.count),
    unknownOrder: unknown.map((i) => i.name),
    returnsNewArray: byName !== items && byCount !== items,
    inputUnchanged: JSON.stringify(items) === before,
  };
}
