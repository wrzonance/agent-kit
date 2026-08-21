// bench/accept/tally-07.test.mjs -- oracle for
// bench/issues/07-tally-keyboard-shortcuts.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget, existsInTarget } from './lib/target.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

test('tally-07: src/keyboard.js exports a pure matchShortcut', async () => {
  assert.ok(existsInTarget('src/keyboard.js'), 'src/keyboard.js must exist');
  const { matchShortcut } = await importFromTarget('src/keyboard.js');
  assert.equal(typeof matchShortcut, 'function', 'matchShortcut is exported as a function');
  assert.equal(matchShortcut({ key: '+' }), 'increment', "'+' maps to 'increment'");
  assert.equal(matchShortcut({ key: '-' }), 'decrement', "'-' maps to 'decrement'");
  assert.equal(matchShortcut({ key: 'Delete' }), 'remove', "'Delete' maps to 'remove'");
  assert.equal(matchShortcut({ key: 'a' }), null, 'any other key maps to null');
});

test('tally-07: node test/keyboard.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/keyboard.smoke.mjs');
});

test('tally-07: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
