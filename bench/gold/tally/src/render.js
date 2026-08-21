// Tally -- pure render module (gold: base + tally-01 empty state +
// tally-02 total badge, merged). Every export returns an HTML string;
// nothing here touches `document`.
import { total } from './store.js';

export function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

// tally-01
export function renderEmptyState() {
  return '<p class="tally-empty">No tallies yet -- add one above.</p>';
}

export function renderItemRow(item) {
  return (
    `<li class="tally-item" data-id="${item.id}">` +
    `<span class="tally-item-name">${escapeHtml(item.name)}</span>` +
    `<span class="tally-item-count">${item.count}</span>` +
    `<button type="button" data-action="decrement" data-id="${item.id}">-</button>` +
    `<button type="button" data-action="increment" data-id="${item.id}">+</button>` +
    `<button type="button" data-action="remove" data-id="${item.id}">remove</button>` +
    `</li>`
  );
}

export function renderApp(state) {
  // tally-02: running total badge in the header.
  const header =
    `<header class="tally-header"><h1>Tally</h1>` +
    `<span class="tally-total">Total: ${total(state)}</span></header>`;
  // tally-01: empty-state message when there are no items.
  const body =
    state.items.length === 0
      ? renderEmptyState()
      : `<ul class="tally-list">${state.items.map(renderItemRow).join('')}</ul>`;
  return header + body;
}
