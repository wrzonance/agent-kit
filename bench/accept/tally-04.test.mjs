// bench/accept/tally-04.test.mjs -- oracle for
// bench/issues/04-tally-reset-all-counts.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-04.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-04');

test('tally-04: src/store.js exports resetAll', () => {
  assert.equal(obs.resetAllFnType, 'function', 'resetAll is exported as a function');
});

test('tally-04: resetAll zeroes every item count and keeps name/id', () => {
  assert.ok(obs.allCountsZero, 'every item count is zero after resetAll');
  assert.ok(obs.idsAndNamesPreserved, 'resetAll preserves every item id and name');
});

test('tally-04: resetAll on an empty state is a no-op (same reference)', () => {
  assert.ok(obs.emptyIsSameReference, 'resetAll on an empty state returns the same object reference');
});

test('tally-04: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
