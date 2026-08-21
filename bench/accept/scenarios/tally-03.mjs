// bench/accept/scenarios/tally-03.mjs -- oracle-authored scenario for
// bench/issues/03-tally-undo-last-remove.md. Executes ONLY inside the
// forked scenario-runner child (PR #363 review finding 1).
export default async function run({ importTarget }) {
  const store = await importTarget('src/store.js');

  const undoRemoveFnType = typeof store.undoRemove;
  const removeItemFnType = typeof store.removeItem;
  if (undoRemoveFnType !== 'function' || removeItemFnType !== 'function') {
    return { undoRemoveFnType, removeItemFnType };
  }

  let state = store.addItem(store.createState(), 'Coffee');
  const id = state.items[0].id;
  state = store.increment(store.increment(state, id), id);
  state = store.removeItem(state, id);
  const itemsAfterRemove = state.items.length;
  state = store.undoRemove(state);
  const restored = state.items[0];
  const secondUndo = store.undoRemove(state);
  const secondUndoIsSameReference = secondUndo === state;

  return {
    undoRemoveFnType,
    removeItemFnType,
    itemsAfterRemove,
    restoredName: restored?.name,
    restoredCount: restored?.count,
    itemsAfterUndo: state.items.length,
    secondUndoIsSameReference,
  };
}
