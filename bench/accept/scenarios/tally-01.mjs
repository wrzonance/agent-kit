// bench/accept/scenarios/tally-01.mjs -- oracle-authored scenario for
// bench/issues/01-tally-empty-state-message.md. Executes ONLY inside the
// forked scenario-runner child (see bench/accept/lib/scenario-runner.mjs)
// -- never in the same process as bench/accept/tally-01.test.mjs's own
// assertions (PR #363 review finding 1). Returns a plain, JSON-safe
// observation object.
export default async function run({ importTarget }) {
  const render = await importTarget('src/render.js');
  const store = await importTarget('src/store.js');

  const emptyStateFnType = typeof render.renderEmptyState;
  const emptyStateText = emptyStateFnType === 'function' ? render.renderEmptyState() : null;
  const emptyStateArity = emptyStateFnType === 'function' ? render.renderEmptyState.length : null;

  const emptyHtml = render.renderApp(store.createState());
  const nonEmptyState = store.addItem(store.createState(), 'Coffee');
  const nonEmptyHtml = render.renderApp(nonEmptyState);

  return {
    emptyStateFnType,
    emptyStateArity,
    emptyStateText,
    emptyHtmlHasEmptyMarkup: emptyHtml.includes('<p class="tally-empty">No tallies yet -- add one above.</p>'),
    nonEmptyHtmlHasEmptyMarkup: nonEmptyHtml.includes('tally-empty'),
  };
}
