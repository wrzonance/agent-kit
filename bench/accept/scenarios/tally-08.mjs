// bench/accept/scenarios/tally-08.mjs -- oracle-authored scenario for
// bench/issues/08-tally-export-json.md. Executes ONLY inside the forked
// scenario-runner child (PR #363 review finding 1). Returns the parsed
// values themselves rather than a precomputed JSON.stringify() equality
// boolean (PR #363 review finding 4) -- key insertion order changes
// JSON.stringify()'s text without changing the value it represents, so a
// compliant target could otherwise fail this scenario for free.
export default async function run({ importTarget }) {
  const exporter = await importTarget('src/exporter.js');
  const store = await importTarget('src/store.js');

  const exportStateFnType = typeof exporter.exportState;
  if (exportStateFnType !== 'function') {
    return { exportStateFnType };
  }

  let state = store.addItem(store.createState(), 'Coffee');
  state = store.increment(state, state.items[0].id);
  const result = exporter.exportState(state);
  const parsedContent = JSON.parse(result.content);

  return {
    exportStateFnType,
    filename: result.filename,
    mimeType: result.mimeType,
    contentItems: parsedContent.items,
    contentNextId: parsedContent.nextId,
    stateItems: state.items,
    stateNextId: state.nextId,
  };
}
