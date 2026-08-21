// bench/accept/tally-03.test.mjs -- oracle for
// bench/issues/03-tally-undo-last-remove.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

test('tally-03: src/store.js exports undoRemove', async () => {
  const { undoRemove } = await importFromTarget('src/store.js');
  assert.equal(typeof undoRemove, 'function', 'undoRemove is exported as a function');
});

test('tally-03: undoRemove restores the removed item with its name and count', async () => {
  const { createState, addItem, increment, removeItem, undoRemove } = await importFromTarget('src/store.js');
  assert.equal(typeof removeItem, 'function', 'removeItem is exported as a function');
  assert.equal(typeof undoRemove, 'function', 'undoRemove is exported as a function');
  let state = addItem(createState(), 'Coffee');
  const id = state.items[0].id;
  state = increment(increment(state, id), id);
  state = removeItem(state, id);
  assert.equal(state.items.length, 0, 'removeItem removes the item');
  state = undoRemove(state);
  assert.equal(state.items.length, 1, 'undoRemove restores an item');
  assert.equal(state.items[0].name, 'Coffee', 'the restored item has the same name');
  assert.equal(state.items[0].count, 2, 'the restored item has the same count');
});

test('tally-03: a second undoRemove with nothing pending is a no-op (same reference)', async () => {
  const { createState, addItem, removeItem, undoRemove } = await importFromTarget('src/store.js');
  let state = addItem(createState(), 'Coffee');
  const id = state.items[0].id;
  state = undoRemove(removeItem(state, id));
  const again = undoRemove(state);
  assert.equal(again, state, 'undoRemove with no pending removal returns the same state reference');
});

test('tally-03: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
