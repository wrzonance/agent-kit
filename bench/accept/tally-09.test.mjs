// bench/accept/tally-09.test.mjs -- oracle for
// bench/issues/09-tally-import-json.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-09.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-09');

test('tally-09: src/importer.js exports a pure, never-throwing parseImport', () => {
  assert.equal(obs.parseImportFnType, 'function', 'parseImport is exported as a function');
  assert.ok(obs.okResultMatches, 'valid JSON parses to ok:true with the expected state');

  assert.ok(!obs.badJsonThrew, 'invalid JSON does not throw');
  assert.equal(obs.badJsonOk, false, 'invalid JSON returns ok:false');
  assert.equal(obs.badJsonErrorType, 'string', 'invalid JSON returns a string error');
  assert.ok(obs.badJsonErrorNonEmpty, 'invalid JSON returns a non-empty error message');

  assert.ok(!obs.badShapeThrew, 'a shape mismatch does not throw');
  assert.equal(obs.badShapeOk, false, 'missing items returns ok:false');
});

test('tally-09: node test/importer.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/importer.smoke.mjs');
});

test('tally-09: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
