// bench/accept/tally-02.test.mjs -- oracle for
// bench/issues/02-tally-total-badge.md. Hidden from the trial container;
// injected only for scoring (see bench/accept/README.md). Scores the
// Tally tree at BENCH_ACCEPT_TARGET.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { importFromTarget } from './lib/target.mjs';
import { assertBaseSmokeOk } from './lib/smoke.mjs';
import { parseFragment, query, textContent, closest } from './lib/dom-stub.mjs';

test('tally-02: renderApp shows a total badge matching total(state)', async () => {
  const { createState, addItem, increment } = await importFromTarget('src/store.js');
  const { renderApp } = await importFromTarget('src/render.js');
  let state = addItem(createState(), 'Coffee');
  const id = state.items[0].id;
  state = increment(increment(increment(increment(state, id), id), id), id);
  state = addItem(state, 'Tea');
  const secondId = state.items.at(-1).id;
  state = increment(state, secondId);
  // items sum to 5
  const html = renderApp(state);
  assert.ok(
    html.includes('<span class="tally-total">Total: 5</span>'),
    'renderApp includes the exact badge markup for a total of 5',
  );
});

test('tally-02: renderApp(createState()) shows a total badge of 0', async () => {
  const { createState } = await importFromTarget('src/store.js');
  const { renderApp } = await importFromTarget('src/render.js');
  const html = renderApp(createState());
  assert.ok(
    html.includes('<span class="tally-total">Total: 0</span>'),
    'renderApp includes the exact badge markup for an empty state',
  );
});

test('tally-02: the badge is inside header.tally-header, not the ul', async () => {
  const { createState, addItem } = await importFromTarget('src/store.js');
  const { renderApp } = await importFromTarget('src/render.js');
  const state = addItem(createState(), 'Coffee');
  const root = parseFragment(renderApp(state));
  const badge = query(root, 'span.tally-total');
  assert.ok(badge, 'a span.tally-total element exists');
  assert.equal(textContent(badge), 'Total: 0', 'the badge text matches total(state)');
  assert.ok(closest(badge, 'header'), 'the badge is inside a header element');
  const header = closest(badge, 'header');
  assert.ok(header.attrs.class?.split(/\s+/).includes('tally-header'), 'that header carries class="tally-header"');
  assert.equal(closest(badge, 'ul'), null, 'the badge is not inside a ul element');
});

test('tally-02: node test/smoke.mjs still exits 0', assertBaseSmokeOk);
