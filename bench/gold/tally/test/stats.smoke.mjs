#!/usr/bin/env node
// tally-10 public smoke test.
import assert from 'node:assert/strict';
import { computeStats } from '../src/stats.js';
import { createState, addItem, increment } from '../src/store.js';

let state = createState();
state = addItem(state, 'a');
state = addItem(state, 'b');
state = addItem(state, 'c');
const [a, b, c] = state.items;
state = increment(state, a.id);
state = increment(state, b.id);
state = increment(state, b.id);
state = increment(state, c.id);
state = increment(state, c.id);
state = increment(state, c.id);

assert.deepEqual(computeStats(state), { itemCount: 3, totalCount: 6, average: 2 });
assert.deepEqual(computeStats(createState()), { itemCount: 0, totalCount: 0, average: 0 });

console.log('PASS bench/gold/tally stats smoke: 2 assertions');
