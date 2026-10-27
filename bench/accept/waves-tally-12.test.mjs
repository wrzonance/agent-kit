// bench/accept/waves-tally-12.test.mjs -- oracle for bench/issues/12-tally-leaderboard.md (fixture
// tally-waves-v1). Needs tally-11's src/sorting.js: leaderboard.js imports it, so a tree without the
// partner's change fails here.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-12');

test('tally-12: src/leaderboard.js exports topItems', () => {
  assert.equal(obs.topFnType, 'function');
});

test('tally-12: topItems returns the highest counts first', () => {
  assert.deepEqual(obs.topTwo, [5, 3]);
  assert.deepEqual(obs.topZero, []);
  assert.equal(obs.topMany, 3);
});

test('tally-12: node test/leaderboard.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/leaderboard.smoke.mjs');
});

test('tally-12: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
