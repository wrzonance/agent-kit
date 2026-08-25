// bench/accept/scenarios/tally-10.mjs -- oracle-authored scenario for
// bench/issues/10-tally-stats-panel.md. Executes ONLY inside the forked
// scenario-runner child (PR #363 review finding 1).
export default async function run({ importTarget }) {
  const stats = await importTarget('src/stats.js');
  const store = await importTarget('src/store.js');

  const computeStatsFnType = typeof stats.computeStats;
  if (computeStatsFnType !== 'function') {
    return { computeStatsFnType };
  }

  let state = store.createState();
  state = store.addItem(state, 'a');
  state = store.addItem(state, 'b');
  state = store.addItem(state, 'c');
  const [aId, bId, cId] = state.items.map((it) => it.id);
  state = store.increment(state, aId);
  state = store.increment(store.increment(state, bId), bId);
  state = store.increment(store.increment(store.increment(state, cId), cId), cId);
  // counts [1, 2, 3]

  return {
    computeStatsFnType,
    countsResult: stats.computeStats(state),
    emptyResult: stats.computeStats(store.createState()),
  };
}
