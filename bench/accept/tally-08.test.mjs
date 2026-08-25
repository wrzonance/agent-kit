// bench/accept/tally-08.test.mjs -- oracle for
// bench/issues/08-tally-export-json.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-08.mjs into a separate process (PR #363 review
// finding 1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-08');

test('tally-08: src/exporter.js exports a pure exportState', () => {
  assert.equal(obs.exportStateFnType, 'function', 'exportState is exported as a function');
  assert.equal(obs.filename, 'tally-export.json', 'filename is tally-export.json');
  assert.equal(obs.mimeType, 'application/json', 'mimeType is application/json');
  // deepEqual, not a JSON.stringify() string comparison (PR #363 review
  // finding 4) -- key insertion order must not be able to fail a
  // compliant target.
  assert.deepEqual(obs.contentItems, obs.stateItems, 'content JSON.parses to items matching state');
  assert.deepEqual(obs.contentNextId, obs.stateNextId, 'content JSON.parses to nextId matching state');
});

test('tally-08: node test/exporter.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/exporter.smoke.mjs');
});

test('tally-08: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
