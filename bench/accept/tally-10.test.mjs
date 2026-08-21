// bench/accept/tally-10.test.mjs -- oracle for
// bench/issues/10-tally-stats-panel.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget, existsInTarget } from './lib/target.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

test('tally-10: src/stats.js exports a pure computeStats', async () => {
  assert.ok(existsInTarget('src/stats.js'), 'src/stats.js must exist');
  const { computeStats } = await importFromTarget('src/stats.js');
  const { createState, addItem, increment } = await importFromTarget('src/store.js');
  assert.equal(typeof computeStats, 'function', 'computeStats is exported as a function');

  let state = createState();
  state = addItem(state, 'a');
  state = addItem(state, 'b');
  state = addItem(state, 'c');
  const [aId, bId, cId] = state.items.map((it) => it.id);
  state = increment(state, aId);
  state = increment(increment(state, bId), bId);
  state = increment(increment(increment(state, cId), cId), cId);
  // counts [1, 2, 3]
  assert.deepEqual(
    computeStats(state),
    { itemCount: 3, totalCount: 6, average: 2 },
    'computeStats matches itemCount/totalCount/average for counts [1, 2, 3]',
  );
});

test('tally-10: computeStats(createState()) has no NaN/Infinity', async () => {
  const { computeStats } = await importFromTarget('src/stats.js');
  const { createState } = await importFromTarget('src/store.js');
  assert.deepEqual(
    computeStats(createState()),
    { itemCount: 0, totalCount: 0, average: 0 },
    'an empty state computes zeroed stats with no division by zero',
  );
});

test('tally-10: node test/stats.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/stats.smoke.mjs');
});

test('tally-10: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
