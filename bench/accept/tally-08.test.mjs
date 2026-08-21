// bench/accept/tally-08.test.mjs -- oracle for
// bench/issues/08-tally-export-json.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget, existsInTarget } from './lib/target.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

test('tally-08: src/exporter.js exports a pure exportState', async () => {
  assert.ok(existsInTarget('src/exporter.js'), 'src/exporter.js must exist');
  const { exportState } = await importFromTarget('src/exporter.js');
  const { createState, addItem, increment } = await importFromTarget('src/store.js');
  assert.equal(typeof exportState, 'function', 'exportState is exported as a function');
  let state = addItem(createState(), 'Coffee');
  state = increment(state, state.items[0].id);
  const result = exportState(state);
  assert.equal(result.filename, 'tally-export.json', 'filename is tally-export.json');
  assert.equal(result.mimeType, 'application/json', 'mimeType is application/json');
  assert.deepEqual(
    JSON.parse(result.content),
    { items: state.items, nextId: state.nextId },
    'content JSON.parses to items/nextId matching state',
  );
});

test('tally-08: node test/exporter.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/exporter.smoke.mjs');
});

test('tally-08: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
