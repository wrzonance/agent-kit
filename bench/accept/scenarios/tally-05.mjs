// bench/accept/scenarios/tally-05.mjs -- oracle-authored scenario for
// bench/issues/05-tally-rename-item.md. Executes ONLY inside the forked
// scenario-runner child (PR #363 review finding 1).
export default async function run({ importTarget }) {
  const store = await importTarget('src/store.js');

  const renameItemFnType = typeof store.renameItem;
  if (renameItemFnType !== 'function') {
    return { renameItemFnType };
  }

  let state = store.addItem(store.createState(), 'Coffee');
  const id = state.items[0].id;
  state = store.increment(store.increment(state, id), id);
  const renamed = store.renameItem(state, id, '  Tea  ');

  const blankResult = store.renameItem(renamed, id, '   ');
  const unknownResult = store.renameItem(renamed, -1, 'X');

  return {
    renameItemFnType,
    renamedName: renamed.items[0].name,
    renamedCount: renamed.items[0].count,
    blankIsSameReference: blankResult === renamed,
    unknownIsSameReference: unknownResult === renamed,
  };
}
