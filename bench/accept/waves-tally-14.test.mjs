// bench/accept/waves-tally-14.test.mjs -- oracle for bench/issues/14-tally-search-results-view.md
// (fixture tally-waves-v1). Needs tally-13's src/search.js: results.js imports it, so a tree without
// the partner's change fails here.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk, assertModuleSmokeOk } from './lib/smoke.mjs';

const obs = await runScenario('tally-14');

test('tally-14: src/results.js exports renderResults', () => {
  assert.equal(obs.renderFnType, 'function');
});

test('tally-14: renderResults shows matching rows and a no-match message', () => {
  assert.equal(obs.teaHtml, obs.teaRowHtml, 'the Tea row uses renderItemRow markup');
  assert.ok(!obs.teaHtml.includes('Coffee'), 'the Coffee row is not rendered');
  assert.equal(obs.noMatchHtml, '<p class="tally-empty">No matches</p>');
});

test('tally-14: node test/results.smoke.mjs exits 0 and prints a PASS line', () => {
  assertModuleSmokeOk('test/results.smoke.mjs');
});

test('tally-14: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
