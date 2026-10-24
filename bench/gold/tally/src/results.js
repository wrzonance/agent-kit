// tally-14: search results view, built on tally-13's filterItems.
import { filterItems } from './search.js';
import { renderItemRow } from './render.js';

export function renderResults(state, query) {
  const matches = filterItems(state.items, query);
  if (matches.length === 0) return '<p class="tally-empty">No matches</p>';
  return matches.map(renderItemRow).join('');
}
