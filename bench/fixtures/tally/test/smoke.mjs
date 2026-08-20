#!/usr/bin/env node
// Tally -- public smoke test for the base fixture. Runs under plain `node`,
// no network, no bundler: `node test/smoke.mjs`. Exercises store.js and
// render.js only (main.js needs a real `document`; see its header comment).
import assert from 'node:assert/strict';
import {
  createState,
  addItem,
  removeItem,
  increment,
  decrement,
  total,
  toJSON,
  fromJSON,
} from '../src/store.js';
import { renderApp, renderItemRow, escapeHtml } from '../src/render.js';

let state = createState();
assert.deepEqual(state, { items: [], nextId: 1 }, 'createState starts empty');

state = addItem(state, '  Coffee  ');
assert.equal(state.items.length, 1, 'addItem adds a trimmed item');
assert.equal(state.items[0].name, 'Coffee', 'addItem trims whitespace');
assert.equal(state.items[0].count, 0, 'a new item starts at 0');

const beforeAdd = state;
state = addItem(state, '   ');
assert.equal(state, beforeAdd, 'addItem ignores a blank name (same reference: no mutation)');

const id = state.items[0].id;
state = increment(state, id);
state = increment(state, id);
state = decrement(state, id);
assert.equal(state.items[0].count, 1, 'increment/decrement compose');
assert.equal(total(state), 1, 'total sums every item count');

state = decrement(state, id);
state = decrement(state, id);
assert.equal(state.items[0].count, 0, 'decrement floors at 0, never negative');

const roundTripped = fromJSON(toJSON(state));
assert.deepEqual(roundTripped, state, 'toJSON/fromJSON round-trips exactly');

state = removeItem(state, id);
assert.equal(state.items.length, 0, 'removeItem removes by id');

assert.equal(escapeHtml('<script>'), '&lt;script&gt;', 'escapeHtml escapes markup');
const row = renderItemRow({ id: 7, name: '<b>x</b>', count: 3 });
assert.ok(row.includes('data-id="7"'), 'renderItemRow carries the item id');
assert.ok(row.includes('&lt;b&gt;x&lt;/b&gt;'), 'renderItemRow escapes the item name');
assert.ok(renderApp(createState()).includes('<ul class="tally-list"></ul>'), 'renderApp renders an empty list');

console.log('PASS bench/fixtures/tally smoke: 12 assertions');
