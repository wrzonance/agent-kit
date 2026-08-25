// bench/accept/tally-07.test.mjs -- oracle for
// bench/issues/07-tally-keyboard-shortcuts.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-07.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-07');

test('tally-07: src/keyboard.js exports a pure matchShortcut', () => {
  assert.equal(obs.matchShortcutFnType, 'function', 'matchShortcut is exported as a function');
  assert.equal(obs.plus, 'increment', "'+' maps to 'increment'");
  assert.equal(obs.minus, 'decrement', "'-' maps to 'decrement'");
  assert.equal(obs.del, 'remove', "'Delete' maps to 'remove'");
  assert.equal(obs.other, null, 'any other key maps to null');
});

test('tally-07: node test/keyboard.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/keyboard.smoke.mjs');
});

test('tally-07: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
