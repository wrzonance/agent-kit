// bench/accept/lib/dom-stub.mjs -- vendored, zero-dependency HTML fragment
// parser for the Tier-1 oracle suites (epic #152, issue #326). Not a full
// DOM: parses the small, well-formed HTML fragments Tally's render.js
// output and index.html contain into a plain element tree, and exposes
// query()/queryAll()/closest() over a narrow selector grammar (tag,
// .class, [attr], [attr="value"], and tag+class/tag+attr combinations).
// Never installed as an npm dependency; never present in the trial
// container (see bench/accept/README.md's "Injection interface").

const VOID_TAGS = new Set(['br', 'hr', 'img', 'input', 'link', 'meta']);

function decodeEntities(text) {
  return text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');
}

function parseAttrs(raw) {
  const attrs = {};
  const attrRe = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*("([^"]*)"|'([^']*)'|[^\s"'=<>]+))?/g;
  let match;
  while ((match = attrRe.exec(raw))) {
    const name = match[1].toLowerCase();
    const value = match[3] ?? match[4] ?? match[2] ?? '';
    attrs[name] = decodeEntities(value);
  }
  return attrs;
}

// Markup that only appears inside an HTML comment was never rendered --
// a target returning `<!-- <p class="tally-empty">...</p> -->` must not
// get acceptance credit for it. Strip comments before generic tag
// tokenization ever sees the string, so nothing inside one can be parsed
// into an element or survive as text content.
//
// An UNCLOSED `<!--` (no matching `-->` anywhere after it) must also
// consume everything to the end of the input -- that is what real
// browsers do, and a target emitting one could otherwise hide/alter
// arbitrary subsequent markup from being tokenized as real elements while
// still getting it stripped from view. The `(?:-->|$)` alternation
// prefers the closing marker when one exists (matching the original
// closed-comment behavior) and falls back to end-of-string only when a
// comment is never closed.
function stripComments(html) {
  return html.replace(/<!--[\s\S]*?(?:-->|$)/g, '');
}

function tokenize(rawHtml) {
  const html = stripComments(rawHtml);
  const tokens = [];
  const tagRe = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^<>]*?)?)\s*(\/?)>/g;
  let last = 0;
  let match;
  while ((match = tagRe.exec(html))) {
    if (match.index > last) {
      tokens.push({ type: 'text', value: html.slice(last, match.index) });
    }
    const [, closing, tag, attrsRaw, selfClose] = match;
    if (closing) {
      tokens.push({ type: 'close', tag: tag.toLowerCase() });
    } else {
      tokens.push({
        type: 'open',
        tag: tag.toLowerCase(),
        attrs: parseAttrs(attrsRaw),
        selfClose: Boolean(selfClose) || VOID_TAGS.has(tag.toLowerCase()),
      });
    }
    last = tagRe.lastIndex;
  }
  if (last < html.length) tokens.push({ type: 'text', value: html.slice(last) });
  return tokens;
}

function makeElement(tagName, attrs, parent) {
  return { tagName, attrs, children: [], parent };
}

export function parseFragment(html) {
  const root = makeElement('#root', {}, null);
  const stack = [root];
  for (const token of tokenize(html)) {
    const top = stack.at(-1);
    if (token.type === 'text') {
      if (token.value.length > 0) top.children.push({ text: decodeEntities(token.value), parent: top });
    } else if (token.type === 'open') {
      const el = makeElement(token.tag, token.attrs, top);
      top.children.push(el);
      if (!token.selfClose) stack.push(el);
    } else if (token.type === 'close') {
      for (let i = stack.length - 1; i > 0; i -= 1) {
        if (stack[i].tagName === token.tag) {
          stack.length = i;
          break;
        }
      }
    }
  }
  return root;
}

export function textContent(el) {
  if (el.text !== undefined) return el.text;
  return (el.children ?? []).map(textContent).join('');
}

export function closest(el, tagName) {
  let cur = el.parent;
  while (cur) {
    if (cur.tagName === tagName) return cur;
    cur = cur.parent;
  }
  return null;
}

function classList(el) {
  return (el.attrs?.class ?? '').split(/\s+/).filter(Boolean);
}

const SELECTOR_RE =
  /^([a-zA-Z][a-zA-Z0-9-]*)?(\.[a-zA-Z0-9_-]+)?(\[[a-zA-Z_:][-a-zA-Z0-9_:.]*(?:="[^"]*")?\])?$/;

function parseSimpleSelector(selector) {
  const match = SELECTOR_RE.exec(selector.trim());
  if (!match) throw new Error(`dom-stub: unsupported selector: ${selector}`);
  const [, tag, cls, attr] = match;
  let attrName;
  let attrValue;
  if (attr) {
    const inner = attr.slice(1, -1);
    const eq = inner.indexOf('=');
    if (eq === -1) {
      attrName = inner;
    } else {
      attrName = inner.slice(0, eq);
      attrValue = inner.slice(eq + 1).replace(/^"(.*)"$/, '$1');
    }
  }
  return { tag, cls: cls ? cls.slice(1) : undefined, attrName, attrValue };
}

function matches(el, sel) {
  if (el.text !== undefined) return false;
  if (sel.tag && el.tagName !== sel.tag) return false;
  if (sel.cls && !classList(el).includes(sel.cls)) return false;
  if (sel.attrName && !(sel.attrName in (el.attrs ?? {}))) return false;
  if (sel.attrValue !== undefined && el.attrs?.[sel.attrName] !== sel.attrValue) return false;
  return true;
}

export function queryAll(root, selector) {
  const sel = parseSimpleSelector(selector);
  const out = [];
  (function walk(node) {
    for (const child of node.children ?? []) {
      if (matches(child, sel)) out.push(child);
      walk(child);
    }
  })(root);
  return out;
}

export function query(root, selector) {
  return queryAll(root, selector)[0] ?? null;
}
