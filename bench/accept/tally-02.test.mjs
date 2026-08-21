// bench/accept/tally-02.test.mjs -- oracle for
// bench/issues/02-tally-total-badge.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
//
// This process never imports target code directly -- runScenario() forks
// scenarios/tally-02.mjs into a separate process and returns only the
// already-rendered HTML strings (PR #363 review finding 1). Parsing those
// strings with the DOM stub here is safe: it executes no target code.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runScenario } from './lib/isolated.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';
import { parseFragment, query, textContent, closest } from './lib/dom-stub.mjs';

const obs = await runScenario('tally-02');

test('tally-02: renderApp shows a total badge matching total(state)', () => {
  // Queries the parsed fragment rather than substring-matching the raw
  // HTML (PR #363 review finding 2) -- markup smuggled inside an HTML
  // comment must not count as a rendered badge.
  const root = parseFragment(obs.fiveHtml);
  const badge = query(root, 'span.tally-total');
  assert.ok(badge, 'a span.tally-total element exists for a total of 5');
  assert.equal(textContent(badge), 'Total: 5', 'the badge text matches total(state)');
});

test('tally-02: renderApp(createState()) shows a total badge of 0', () => {
  const root = parseFragment(obs.emptyHtml);
  const badge = query(root, 'span.tally-total');
  assert.ok(badge, 'a span.tally-total element exists for an empty state');
  assert.equal(textContent(badge), 'Total: 0', 'the badge text matches total(state)');
});

test('tally-02: the badge is inside header.tally-header, not the ul', () => {
  const root = parseFragment(obs.nonEmptyHtml);
  const badge = query(root, 'span.tally-total');
  assert.ok(badge, 'a span.tally-total element exists');
  assert.equal(textContent(badge), 'Total: 0', 'the badge text matches total(state)');
  const header = closest(badge, 'header');
  assert.ok(header, 'the badge is inside a header element');
  assert.ok(header.attrs.class?.split(/\s+/).includes('tally-header'), 'that header carries class="tally-header"');
  assert.equal(closest(badge, 'ul'), null, 'the badge is not inside a ul element');
});

test('tally-02: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
