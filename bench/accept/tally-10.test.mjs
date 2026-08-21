// bench/accept/tally-10.test.mjs -- oracle for
// bench/issues/10-tally-stats-panel.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-10.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-10');

test('tally-10: src/stats.js exports a pure computeStats', () => {
  assert.equal(obs.computeStatsFnType, 'function', 'computeStats is exported as a function');
  assert.deepEqual(
    obs.countsResult,
    { itemCount: 3, totalCount: 6, average: 2 },
    'computeStats matches itemCount/totalCount/average for counts [1, 2, 3]',
  );
});

test('tally-10: computeStats(createState()) has no NaN/Infinity', () => {
  assert.deepEqual(
    obs.emptyResult,
    { itemCount: 0, totalCount: 0, average: 0 },
    'an empty state computes zeroed stats with no division by zero',
  );
});

test('tally-10: node test/stats.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/stats.smoke.mjs');
});

test('tally-10: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
