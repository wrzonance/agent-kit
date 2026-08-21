// bench/accept/tally-04.test.mjs -- oracle for
// bench/issues/04-tally-reset-all-counts.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

test('tally-04: src/store.js exports resetAll', async () => {
  const { resetAll } = await importFromTarget('src/store.js');
  assert.equal(typeof resetAll, 'function', 'resetAll is exported as a function');
});

test('tally-04: resetAll zeroes every item count and keeps name/id', async () => {
  const { createState, addItem, increment, resetAll } = await importFromTarget('src/store.js');
  let state = addItem(addItem(createState(), 'Coffee'), 'Tea');
  const [firstId, secondId] = state.items.map((it) => it.id);
  state = increment(increment(increment(state, firstId), firstId), firstId); // count 3
  state = increment(increment(increment(increment(increment(state, secondId), secondId), secondId), secondId), secondId); // count 5
  const before = state.items.map((it) => ({ id: it.id, name: it.name }));
  state = resetAll(state);
  assert.ok(
    state.items.every((it) => it.count === 0),
    'every item count is zero after resetAll',
  );
  assert.deepEqual(
    state.items.map((it) => ({ id: it.id, name: it.name })),
    before,
    'resetAll preserves every item id and name',
  );
});

test('tally-04: resetAll on an empty state is a no-op (same reference)', async () => {
  const { createState, resetAll } = await importFromTarget('src/store.js');
  const empty = createState();
  assert.equal(resetAll(empty), empty, 'resetAll on an empty state returns the same object reference');
});

test('tally-04: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
