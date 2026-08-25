// tally-10: computed stats. Standalone -- not wired into main.js (see
// bench/issues/10-tally-stats-panel.md).
export function computeStats(state) {
  const itemCount = state.items.length;
  const totalCount = state.items.reduce((sum, it) => sum + it.count, 0);
  const average = itemCount === 0 ? 0 : Math.round((totalCount / itemCount) * 100) / 100;
  return { itemCount, totalCount, average };
}
