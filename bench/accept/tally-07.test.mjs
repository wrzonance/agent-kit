// bench/accept/tally-07.test.mjs -- oracle for
// bench/issues/07-tally-keyboard-shortcuts.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { importFromTarget, existsInTarget, targetRoot } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

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
  const result = spawnSync(process.execPath, ['test/keyboard.smoke.mjs'], {
    cwd: targetRoot(),
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, `test/keyboard.smoke.mjs exited ${String(result.status)}: ${result.stderr}`);
  assert.match(result.stdout, /^PASS/m, 'test/keyboard.smoke.mjs prints a line starting with PASS');
});

test('tally-07: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
