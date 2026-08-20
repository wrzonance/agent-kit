#!/usr/bin/env node
// Tally (gold) -- public smoke test covering the base fixture's behavior
// plus tally-01..tally-05's merged store.js/render.js changes. Runs under
// plain `node`, no network, no bundler.
import assert from 'node:assert/strict';
import {
  createState,
  addItem,
  removeItem,
  undoRemove,
  increment,
  decrement,
  resetAll,
  renameItem,
  total,
  toJSON,
  fromJSON,
} from '../src/store.js';
import { renderApp, renderEmptyState, renderItemRow, escapeHtml } from '../src/render.js';

// --- base behavior, unchanged --------------------------------------------
let state = createState();
assert.deepEqual(state, { items: [], nextId: 1 }, 'createState starts empty');

state = addItem(state, '  Coffee  ');
assert.equal(state.items.length, 1, 'addItem adds a trimmed item');
assert.equal(state.items[0].name, 'Coffee', 'addItem trims whitespace');

const id = state.items[0].id;
state = increment(state, id);
state = increment(state, id);
state = decrement(state, id);
assert.equal(state.items[0].count, 1, 'increment/decrement compose');
assert.equal(total(state), 1, 'total sums every item count');

const roundTripped = fromJSON(toJSON(state));
assert.deepEqual(roundTripped.items, state.items, 'toJSON/fromJSON round-trips items');

// --- tally-03: undoRemove -------------------------------------------------
const beforeRemove = state;
state = removeItem(state, id);
assert.equal(state.items.length, 0, 'removeItem removes by id');
state = undoRemove(state);
assert.equal(state.items.length, 1, 'undoRemove restores the removed item');
assert.equal(state.items[0].name, 'Coffee', 'undoRemove restores the same name');
assert.equal(state.items[0].count, beforeRemove.items[0].count, 'undoRemove restores the same count');
const noOpUndo = undoRemove(state);
assert.equal(noOpUndo, state, 'a second undoRemove with nothing pending is a no-op (same reference)');

// --- tally-04: resetAll ---------------------------------------------------
const secondId = addItem(state, 'Tea').items.at(-1).id;
state = addItem(state, 'Tea');
state = increment(state, secondId);
state = increment(state, secondId);
state = resetAll(state);
assert.ok(
  state.items.every((it) => it.count === 0),
  'resetAll zeroes every item count',
);
const emptyState = createState();
assert.equal(resetAll(emptyState), emptyState, 'resetAll on an empty state is a no-op (same reference)');

// --- tally-05: renameItem -------------------------------------------------
state = renameItem(state, id, '  Latte  ');
assert.equal(
  state.items.find((it) => it.id === id).name,
  'Latte',
  'renameItem trims and applies the new name',
);
const unchangedByBlank = renameItem(state, id, '   ');
assert.equal(unchangedByBlank, state, 'renameItem with a blank name is a no-op (same reference)');
const unchangedByUnknownId = renameItem(state, -1, 'X');
assert.equal(unchangedByUnknownId, state, 'renameItem with an unknown id is a no-op (same reference)');

// --- tally-01: empty-state message ----------------------------------------
assert.ok(renderApp(createState()).includes('tally-empty'), 'renderApp shows the empty state when there are no items');
assert.equal(
  renderEmptyState(),
  '<p class="tally-empty">No tallies yet -- add one above.</p>',
  'renderEmptyState returns the exact copy',
);
assert.ok(!renderApp(state).includes('tally-empty'), 'renderApp hides the empty state once there are items');

// --- tally-02: total badge -------------------------------------------------
const totalNow = total(state);
assert.ok(
  renderApp(state).includes(`<span class="tally-total">Total: ${totalNow}</span>`),
  'renderApp shows a total badge matching total(state)',
);

assert.equal(escapeHtml('<script>'), '&lt;script&gt;', 'escapeHtml escapes markup');
const row = renderItemRow({ id: 7, name: '<b>x</b>', count: 3 });
assert.ok(row.includes('&lt;b&gt;x&lt;/b&gt;'), 'renderItemRow escapes the item name');

console.log('PASS bench/gold/tally smoke: base + tally-01..tally-05 merged behavior');
