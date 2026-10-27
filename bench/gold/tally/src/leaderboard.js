// tally-12: the top n items by count, built on tally-11's sortItems.
import { sortItems } from './sorting.js';

export function topItems(state, n) {
  if (n <= 0) return [];
  return sortItems(state.items, 'count').slice(0, n);
}
