// Tally -- browser entry point. Wires store.js (state) to render.js (view)
// through a single container element, persisting to localStorage. Not
// exercised by test/smoke.mjs (it requires `document`); the base fixture's
// standalone-ness is instead proven by index.html loading this module in a
// real browser -- see bench/README's "Reproducing" section for how a later
// tier is expected to drive that.
import { createState, addItem, removeItem, increment, decrement, toJSON, fromJSON } from './store.js';
import { renderApp } from './render.js';

const STORAGE_KEY = 'tally-state-v1';

function loadState() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? fromJSON(raw) : createState();
  } catch {
    return createState();
  }
}

function saveState(state) {
  try {
    localStorage.setItem(STORAGE_KEY, toJSON(state));
  } catch {
    // localStorage unavailable (private browsing, quota) -- degrade to in-memory only.
  }
}

function main() {
  const app = document.getElementById('app');
  const form = document.getElementById('add-form');
  const input = document.getElementById('add-input');
  if (!app || !form || !input) return;

  let state = loadState();

  function rerender() {
    app.innerHTML = renderApp(state);
    saveState(state);
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    state = addItem(state, input.value);
    input.value = '';
    rerender();
  });

  app.addEventListener('click', (event) => {
    const button = event.target.closest('button[data-action]');
    if (!button) return;
    const id = Number(button.dataset.id);
    const action = button.dataset.action;
    if (action === 'increment') state = increment(state, id);
    else if (action === 'decrement') state = decrement(state, id);
    else if (action === 'remove') state = removeItem(state, id);
    rerender();
  });

  rerender();
}

main();
