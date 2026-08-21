// bench/accept/tally-03.test.mjs -- oracle for
// bench/issues/03-tally-undo-last-remove.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-03.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-03');

test('tally-03: src/store.js exports undoRemove', () => {
  assert.equal(obs.undoRemoveFnType, 'function', 'undoRemove is exported as a function');
});

test('tally-03: undoRemove restores the removed item with its name and count', () => {
  assert.equal(obs.removeItemFnType, 'function', 'removeItem is exported as a function');
  assert.equal(obs.itemsAfterRemove, 0, 'removeItem removes the item');
  assert.equal(obs.itemsAfterUndo, 1, 'undoRemove restores an item');
  assert.equal(obs.restoredName, 'Coffee', 'the restored item has the same name');
  assert.equal(obs.restoredCount, 2, 'the restored item has the same count');
});

test('tally-03: a second undoRemove with nothing pending is a no-op (same reference)', () => {
  assert.ok(obs.secondUndoIsSameReference, 'undoRemove with no pending removal returns the same state reference');
});

test('tally-03: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
