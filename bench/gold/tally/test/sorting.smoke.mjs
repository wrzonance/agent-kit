#!/usr/bin/env node
// tally-11 public smoke test.
import assert from 'node:assert/strict';
import { sortItems } from '../src/sorting.js';

const items = [{ id: 1, name: 'Tea', count: 1 }, { id: 2, name: 'coffee', count: 5 }, { id: 3, name: 'Apple', count: 3 }];
assert.deepEqual(sortItems(items, 'name').map((i) => i.name), ['Apple', 'coffee', 'Tea']);
assert.deepEqual(sortItems(items, 'count').map((i) => i.count), [5, 3, 1]);
assert.equal(items[0].name, 'Tea', 'input is not mutated');
console.log('PASS bench/gold/tally sorting smoke: 3 assertions');
