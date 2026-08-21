// bench/accept/tally-01.test.mjs -- oracle for
// bench/issues/01-tally-empty-state-message.md. Hidden from the trial
// container; injected only for scoring (see bench/accept/README.md).
// Scores the Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-01.mjs into a separate process and returns only its
// plain, already-computed observations (PR #363 review finding 1: target
// code executing in the same process as these assertions could
// monkeypatch assert.ok/assert.equal, or call process.exit() during
// import to force a false pass).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-01');

test('tally-01: src/render.js exports renderEmptyState taking no arguments', () => {
  assert.equal(obs.emptyStateFnType, 'function', 'renderEmptyState is exported as a function');
  assert.equal(obs.emptyStateArity, 0, 'renderEmptyState takes no arguments');
  assert.equal(
    obs.emptyStateText,
    '<p class="tally-empty">No tallies yet -- add one above.</p>',
    'renderEmptyState returns the exact copy',
  );
});

test('tally-01: renderApp(createState()) contains the empty-state message', () => {
  assert.ok(obs.emptyHtmlHasEmptyMarkup, 'renderApp includes the empty-state markup for an empty state');
});

test('tally-01: renderApp for a non-empty state does not contain "tally-empty"', () => {
  assert.ok(!obs.nonEmptyHtmlHasEmptyMarkup, 'renderApp omits tally-empty once there are items');
});

test('tally-01: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
