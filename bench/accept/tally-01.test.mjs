// bench/accept/tally-01.test.mjs -- oracle for
// bench/issues/01-tally-empty-state-message.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget, existsInTarget } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

test('tally-01: src/render.js exports renderEmptyState taking no arguments', async () => {
  assert.ok(existsInTarget('src/render.js'), 'src/render.js must exist');
  const { renderEmptyState } = await importFromTarget('src/render.js');
  assert.equal(typeof renderEmptyState, 'function', 'renderEmptyState is exported as a function');
  assert.equal(renderEmptyState.length, 0, 'renderEmptyState takes no arguments');
  assert.equal(
    renderEmptyState(),
    '<p class="tally-empty">No tallies yet -- add one above.</p>',
    'renderEmptyState returns the exact copy',
  );
});

test('tally-01: renderApp(createState()) contains the empty-state message', async () => {
  const { createState } = await importFromTarget('src/store.js');
  const { renderApp } = await importFromTarget('src/render.js');
  const html = renderApp(createState());
  assert.ok(
    html.includes('<p class="tally-empty">No tallies yet -- add one above.</p>'),
    'renderApp includes the empty-state markup for an empty state',
  );
});

test('tally-01: renderApp for a non-empty state does not contain "tally-empty"', async () => {
  const { createState, addItem } = await importFromTarget('src/store.js');
  const { renderApp } = await importFromTarget('src/render.js');
  const state = addItem(createState(), 'Coffee');
  const html = renderApp(state);
  assert.ok(!html.includes('tally-empty'), 'renderApp omits tally-empty once there are items');
});

test('tally-01: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
