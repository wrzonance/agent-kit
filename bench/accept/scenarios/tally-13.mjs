// bench/accept/scenarios/tally-13.mjs -- oracle scenario for bench/issues/13-tally-filter-items.md.
// Executes ONLY inside the forked scenario-runner child.
export default async function run({ importTarget }) {
  const search = await importTarget('src/search.js');
  const filterFnType = typeof search.filterItems;
  if (filterFnType !== 'function') return { filterFnType };

  const items = [
    { id: 1, name: 'Coffee', count: 0 },
    { id: 2, name: 'Tea', count: 0 },
    { id: 3, name: 'Cocoa', count: 0 },
  ];
  const before = JSON.stringify(items);
  const matched = search.filterItems(items, 'co');
  const blank = search.filterItems(items, '   ');
  return {
    filterFnType,
    matched: matched.map((i) => i.name),
    blankLength: blank.length,
    blankIsNewArray: blank !== items,
    inputUnchanged: JSON.stringify(items) === before,
  };
}
