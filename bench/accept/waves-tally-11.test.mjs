// bench/accept/waves-tally-11.test.mjs -- oracle for bench/issues/11-tally-sort-items.md (fixture
// tally-waves-v1; run with run-accept.sh --set waves). Hidden from the trial container.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-11');

test('tally-11: src/sorting.js exports sortItems', () => {
  assert.equal(obs.sortFnType, 'function');
});

test('tally-11: sortItems orders by name and by count without mutating', () => {
  assert.deepEqual(obs.nameOrder, ['Apple', 'coffee', 'Tea']);
  assert.deepEqual(obs.countOrder, [5, 3, 1]);
  assert.deepEqual(obs.unknownOrder, ['Tea', 'coffee', 'Apple']);
  assert.ok(obs.returnsNewArray, 'a new array is returned');
  assert.ok(obs.inputUnchanged, 'the input is not mutated');
});

test('tally-11: node test/sorting.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/sorting.smoke.mjs');
});

test('tally-11: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
