// bench/accept/tally-05.test.mjs -- oracle for
// bench/issues/05-tally-rename-item.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-05.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-05');

test('tally-05: src/store.js exports renameItem', () => {
  assert.equal(obs.renameItemFnType, 'function', 'renameItem is exported as a function');
});

test('tally-05: renameItem trims the new name and leaves count untouched', () => {
  assert.equal(obs.renamedName, 'Tea', 'the name is trimmed and applied');
  assert.equal(obs.renamedCount, 2, 'the count is left untouched');
});

test('tally-05: renameItem with a blank name is a no-op (same reference)', () => {
  assert.ok(obs.blankIsSameReference, 'a blank-after-trim name returns the same state reference');
});

test('tally-05: renameItem with an unknown id is a no-op (same reference)', () => {
  assert.ok(obs.unknownIsSameReference, 'an unknown id returns the same state reference');
});

test('tally-05: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
