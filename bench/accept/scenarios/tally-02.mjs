// bench/accept/scenarios/tally-02.mjs -- oracle-authored scenario for
// bench/issues/02-tally-total-badge.md. Executes ONLY inside the forked
// scenario-runner child (PR #363 review finding 1). Returns the rendered
// HTML strings; bench/accept/tally-02.test.mjs parses them with the
// vendored DOM stub in its OWN process (string parsing executes no
// target code, so it is safe outside the isolation boundary).
export default async function run({ importTarget }) {
  const store = await importTarget('src/store.js');
  const render = await importTarget('src/render.js');

  let state = store.addItem(store.createState(), 'Coffee');
  const firstId = state.items[0].id;
  for (let i = 0; i < 4; i += 1) state = store.increment(state, firstId);
  state = store.addItem(state, 'Tea');
  const secondId = state.items.at(-1).id;
  state = store.increment(state, secondId);
  // items now sum to 5

  const fiveHtml = render.renderApp(state);
  const emptyHtml = render.renderApp(store.createState());

  const nonEmptyState = store.addItem(store.createState(), 'Coffee');
  const nonEmptyHtml = render.renderApp(nonEmptyState);

  return { fiveHtml, emptyHtml, nonEmptyHtml };
}
