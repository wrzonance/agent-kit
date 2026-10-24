#!/usr/bin/env node
// tally-13 public smoke test.
import assert from 'node:assert/strict';
import { filterItems } from '../src/search.js';

const items = [{ id: 1, name: 'Coffee', count: 0 }, { id: 2, name: 'Tea', count: 0 }, { id: 3, name: 'Cocoa', count: 0 }];
assert.deepEqual(filterItems(items, 'co').map((i) => i.name), ['Coffee', 'Cocoa']);
const all = filterItems(items, '  ');
assert.equal(all.length, 3);
assert.notEqual(all, items, 'a blank query still returns a new array');
console.log('PASS bench/gold/tally search smoke: 3 assertions');
