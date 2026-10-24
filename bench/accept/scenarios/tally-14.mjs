// bench/accept/scenarios/tally-14.mjs -- oracle scenario for bench/issues/14-tally-search-results-view.md.
// Importing results.js needs src/search.js from tally-13: without it the import throws and the suite
// scores fail.
export default async function run({ importTarget }) {
  const results = await importTarget('src/results.js');
  const renderFnType = typeof results.renderResults;
  if (renderFnType !== 'function') return { renderFnType };

  const state = {
    items: [
      { id: 1, name: 'Coffee', count: 0 },
      { id: 2, name: 'Tea', count: 0 },
    ],
    nextId: 3,
  };
  return {
    renderFnType,
    teaHtml: results.renderResults(state, 'tea'),
    noMatchHtml: results.renderResults(state, 'zzz'),
  };
}
