// Tally -- pure render module. Every export returns an HTML string; nothing
// here touches `document`. main.js is the only file that assigns innerHTML
// and attaches listeners, so this module (like store.js) is fully testable
// under plain `node`.

export function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
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
  const rows = state.items.map(renderItemRow).join('');
  return `<header class="tally-header"><h1>Tally</h1></header><ul class="tally-list">${rows}</ul>`;
}
