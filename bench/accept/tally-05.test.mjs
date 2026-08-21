// bench/accept/tally-05.test.mjs -- oracle for
// bench/issues/05-tally-rename-item.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

test('tally-05: src/store.js exports renameItem', async () => {
  const { renameItem } = await importFromTarget('src/store.js');
  assert.equal(typeof renameItem, 'function', 'renameItem is exported as a function');
});

test('tally-05: renameItem trims the new name and leaves count untouched', async () => {
  const { createState, addItem, increment, renameItem } = await importFromTarget('src/store.js');
  let state = addItem(createState(), 'Coffee');
  const id = state.items[0].id;
  state = increment(increment(state, id), id);
  state = renameItem(state, id, '  Tea  ');
  assert.equal(state.items[0].name, 'Tea', 'the name is trimmed and applied');
  assert.equal(state.items[0].count, 2, 'the count is left untouched');
});

test('tally-05: renameItem with a blank name is a no-op (same reference)', async () => {
  const { createState, addItem, renameItem } = await importFromTarget('src/store.js');
  const state = addItem(createState(), 'Coffee');
  const id = state.items[0].id;
  assert.equal(renameItem(state, id, '   '), state, 'a blank-after-trim name returns the same state reference');
});

test('tally-05: renameItem with an unknown id is a no-op (same reference)', async () => {
  const { createState, addItem, renameItem } = await importFromTarget('src/store.js');
  const state = addItem(createState(), 'Coffee');
  assert.equal(renameItem(state, -1, 'X'), state, 'an unknown id returns the same state reference');
});

test('tally-05: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
