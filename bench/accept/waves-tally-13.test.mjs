// bench/accept/waves-tally-13.test.mjs -- oracle for bench/issues/13-tally-filter-items.md (fixture
// tally-waves-v1). Hidden from the trial container.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-13');

test('tally-13: src/search.js exports filterItems', () => {
  assert.equal(obs.filterFnType, 'function');
});

test('tally-13: filterItems matches case-insensitively and never mutates', () => {
  assert.deepEqual(obs.matched, ['Coffee', 'Cocoa']);
  assert.equal(obs.blankLength, 3);
  assert.ok(obs.blankIsNewArray, 'a blank query returns a new array');
  assert.ok(obs.inputUnchanged, 'the input is not mutated');
});

test('tally-13: node test/search.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/search.smoke.mjs');
});

test('tally-13: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
