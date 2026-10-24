// bench/accept/scenarios/tally-12.mjs -- oracle scenario for bench/issues/12-tally-leaderboard.md.
// Importing leaderboard.js needs src/sorting.js from tally-11: without it the import throws and the
// suite scores fail.
export default async function run({ importTarget }) {
  const board = await importTarget('src/leaderboard.js');
  const topFnType = typeof board.topItems;
  if (topFnType !== 'function') return { topFnType };

  const state = {
    items: [
      { id: 1, name: 'a', count: 1 },
      { id: 2, name: 'b', count: 5 },
      { id: 3, name: 'c', count: 3 },
    ],
    nextId: 4,
  };
  return {
    topFnType,
    topTwo: board.topItems(state, 2).map((i) => i.count),
    topZero: board.topItems(state, 0),
    topMany: board.topItems(state, 10).length,
  };
}
