// bench/accept/scenarios/tally-04.mjs -- oracle-authored scenario for
// bench/issues/04-tally-reset-all-counts.md. Executes ONLY inside the
// forked scenario-runner child (PR #363 review finding 1).
export default async function run({ importTarget }) {
  const store = await importTarget('src/store.js');

  const resetAllFnType = typeof store.resetAll;
  if (resetAllFnType !== 'function') {
    return { resetAllFnType };
  }

  let state = store.addItem(store.addItem(store.createState(), 'Coffee'), 'Tea');
  const [firstId, secondId] = state.items.map((it) => it.id);
  state = store.increment(store.increment(store.increment(state, firstId), firstId), firstId); // count 3
  for (let i = 0; i < 5; i += 1) state = store.increment(state, secondId); // count 5
  const before = state.items.map((it) => ({ id: it.id, name: it.name }));
  state = store.resetAll(state);

  const empty = store.createState();
  const emptyResult = store.resetAll(empty);

  return {
    resetAllFnType,
    allCountsZero: state.items.every((it) => it.count === 0),
    idsAndNamesPreserved: JSON.stringify(state.items.map((it) => ({ id: it.id, name: it.name }))) === JSON.stringify(before),
    emptyIsSameReference: emptyResult === empty,
  };
}
