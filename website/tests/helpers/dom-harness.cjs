'use strict';

// A deliberately small DOM fixture for controller integration tests. It parses
// the real page and dispatches its event handlers, but does not render CSS,
// emulate native layout, or claim browser/accessibility compatibility coverage.
// Comparison/shortcut modules are spies: standalone tests cover their behavior;
// this fixture verifies the app's handoff to those modules.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const decode = value => value.replace(/&(?:amp|quot|apos|lt|gt);/g, entity => ({
  '&amp;': '&', '&quot;': '"', '&apos;': "'", '&lt;': '<', '&gt;': '>',
})[entity]);
const cssName = name => name.replace(/[A-Z]/g, c => `-${c.toLowerCase()}`);
const dataName = name => `data-${cssName(name)}`;

function styleDeclaration() {
  const values = new Map();
  const methods = {
    setProperty(name, value) { values.set(name, String(value)); },
    getPropertyValue(name) { return values.get(name) || ''; },
    removeProperty(name) { const old = values.get(name) || ''; values.delete(name); return old; },
  };
  return new Proxy(methods, {
    get(target, key) { return key in target ? target[key] : values.get(cssName(key)) || ''; },
    set(_target, key, value) { values.set(cssName(key), String(value)); return true; },
  });
}

class Element {
  constructor(tag, attrs = {}, ownerDocument = null) {
    this.tagName = tag.toUpperCase();
    this.attributes = new Map(Object.entries(attrs));
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.parentElement = null;
    this.listeners = new Map();
    this.captures = new Set();
    this.style = styleDeclaration();
    this._text = '';
    this.value = attrs.value || '';
    this.tabIndex = Number(attrs.tabindex ?? -1);
    this.bounds = { left: 100, top: 50, width: 1000, height: 600 };
    this.dataset = new Proxy({}, {
      get: (_target, key) => this.attributes.get(dataName(key)),
      set: (_target, key, value) => { this.setAttribute(dataName(key), value); return true; },
    });
    this.classList = {
      contains: value => this.classNames().includes(value),
      add: (...values) => this.setAttribute('class', [...new Set([...this.classNames(), ...values])].join(' ')),
      remove: (...values) => this.setAttribute('class', this.classNames().filter(v => !values.includes(v)).join(' ')),
      toggle: (value, force) => {
        const enabled = force ?? !this.classList.contains(value);
        this.classList[enabled ? 'add' : 'remove'](value);
        return enabled;
      },
    };
  }
  classNames() { return (this.attributes.get('class') || '').split(/\s+/).filter(Boolean); }
  setAttribute(key, value) { this.attributes.set(key, String(value)); }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  hasAttribute(key) { return this.attributes.has(key); }
  removeAttribute(key) { this.attributes.delete(key); }
  get hidden() { return this.hasAttribute('hidden'); }
  set hidden(value) { value ? this.setAttribute('hidden', '') : this.removeAttribute('hidden'); }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this._text = String(value); this.children = []; }
  get clientWidth() { return this.bounds.width; }
  get clientHeight() { return this.bounds.height; }
  get offsetWidth() { return this.bounds.width; }
  get offsetHeight() { return this.bounds.height; }
  getBoundingClientRect() {
    return { ...this.bounds, right: this.bounds.left + this.bounds.width, bottom: this.bounds.top + this.bounds.height };
  }
  addEventListener(type, callback, options = {}) {
    if (options.signal?.aborted) return;
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(callback);
    options.signal?.addEventListener('abort', () => this.removeEventListener(type, callback), { once: true });
  }
  removeEventListener(type, callback) { this.listeners.get(type)?.delete(callback); }
  dispatch(type, props = {}) {
    const event = {
      type, target: this, currentTarget: this, defaultPrevented: false,
      bubbles: true, pointerId: 1, pointerType: 'mouse', button: 0,
      preventDefault() { this.defaultPrevented = true; },
      stopPropagation() { this.stopped = true; },
      ...props,
    };
    let node = this;
    do {
      event.currentTarget = node;
      for (const listener of node.listeners.get(type) || []) listener(event);
      node = event.bubbles && !event.stopped ? node.parentElement : null;
    } while (node);
    return event;
  }
  focus() { this.ownerDocument.activeElement = this; }
  scrollIntoView(options) { this.scrollOptions = options; }
  setPointerCapture(id) { this.captures.add(id); }
  hasPointerCapture(id) { return this.captures.has(id); }
  releasePointerCapture(id) {
    if (this.captures.delete(id)) this.dispatch('lostpointercapture', { pointerId: id, bubbles: false });
  }
  showModal() { this.open = true; }
  close() { this.open = false; }
  matches(selector) {
    const clauses = selector.match(/\[[^\]]+\]|#[\w-]+|\.[\w-]+|^[\w-]+/g) || [];
    return clauses.length > 0 && clauses.every(clause => {
      if (clause[0] === '#') return this.getAttribute('id') === clause.slice(1);
      if (clause[0] === '.') return this.classList.contains(clause.slice(1));
      if (clause[0] !== '[') return this.tagName.toLowerCase() === clause.toLowerCase();
      const [, name, , value] = clause.match(/^\[([^=\s\]]+)(?:\s*=\s*(["']?)(.*?)\2)?\]$/);
      return value === undefined ? this.hasAttribute(name) : this.getAttribute(name) === value;
    });
  }
  querySelectorAll(selector) {
    const result = [];
    const visit = node => {
      for (const child of node.children) {
        if (child.matches(selector)) result.push(child);
        visit(child);
      }
    };
    visit(this);
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node;
    return null;
  }
}

function parsePage(html) {
  const document = new Element('#document');
  document.ownerDocument = document;
  document.hidden = false;
  const stack = [document];
  const voidTags = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);
  const tokens = html.match(/<!--[\s\S]*?-->|<![^>]*>|<\/?[a-zA-Z][^>]*>|[^<]+/g) || [];
  for (const token of tokens) {
    if (token.startsWith('<!')) continue;
    if (token.startsWith('</')) {
      const tag = token.match(/^<\/([^\s>]+)/)[1].toUpperCase();
      const index = stack.findLastIndex(node => node.tagName === tag);
      if (index > 0) stack.length = index;
      continue;
    }
    if (!token.startsWith('<')) { stack.at(-1)._text += decode(token); continue; }
    const [, tag, body] = token.match(/^<([^\s/>]+)([\s\S]*?)\/?\s*>$/);
    const attrs = {};
    for (const match of body.matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
      attrs[match[1]] = decode(match[2] ?? match[3] ?? match[4] ?? '');
    }
    const element = new Element(tag, attrs, document);
    element.parentElement = stack.at(-1);
    element.parentElement.children.push(element);
    if (!voidTags.has(tag.toLowerCase()) && !token.endsWith('/>')) stack.push(element);
  }
  document.documentElement = document.querySelector('html');
  document.body = document.querySelector('body');
  document.getElementById = id => document.querySelector(`#${id}`);
  return document;
}

function createClock() {
  let now = 0, nextId = 1;
  const jobs = new Map();
  const schedule = (callback, delay, kind) => {
    const id = nextId++;
    jobs.set(id, { at: now + delay, callback, kind });
    return id;
  };
  return {
    get now() { return now; },
    setTimeout: (fn, delay = 0) => schedule(fn, delay, 'timeout'),
    clearTimeout: id => jobs.delete(id),
    requestAnimationFrame: fn => schedule(fn, 16, 'raf'),
    cancelAnimationFrame: id => jobs.delete(id),
    count: kind => [...jobs.values()].filter(job => !kind || job.kind === kind).length,
    advance(milliseconds) {
      const end = now + milliseconds;
      for (let guard = 0; guard < 10000; guard++) {
        const pending = [...jobs].filter(([, job]) => job.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!pending) { now = end; return; }
        const [id, job] = pending;
        jobs.delete(id); now = job.at; job.callback(now);
      }
      throw new Error('Controller did not settle within 10,000 scheduled callbacks');
    },
  };
}

function loadApp({ reducedMotion = false, config = {}, realModules = false } = {}) {
  const root = path.resolve(__dirname, '../..');
  const document = parsePage(fs.readFileSync(path.join(root, 'index.html'), 'utf8'));
  const clock = createClock();
  const media = new Element('media');
  media.matches = reducedMotion;
  const observers = [];
  const navigations = [];
  const moduleCalls = [];
  const compare = {
    active: null, value: null, calls: [],
    setValue(value, options) {
      this.value = value;
      const call = { module: 'compare', method: 'setValue', value, options: { ...options } };
      this.calls.push(call); moduleCalls.push(call);
    },
    setActive(active) {
      this.active = active;
      const call = { module: 'compare', method: 'setActive', active };
      this.calls.push(call); moduleCalls.push(call);
    },
  };
  const showcase = {
    active: null, calls: [],
    setActive(active) {
      this.active = active;
      const call = { module: 'showcase', method: 'setActive', active };
      this.calls.push(call); moduleCalls.push(call);
    },
  };
  class IntersectionObserver {
    constructor(callback) { this.callback = callback; this.targets = new Set(); observers.push(this); }
    observe(target) { this.targets.add(target); }
    unobserve(target) { this.targets.delete(target); }
    disconnect() { this.targets.clear(); }
  }
  const window = {
    AWM_CONFIG: config,
    WorkspaceCompare: compare,
    WorkspaceShowcase: showcase,
    IntersectionObserver,
    matchMedia: () => media,
    location: { assign: url => navigations.push(url) },
  };
  const context = vm.createContext({
    window, document, URL, console, IntersectionObserver, AbortController,
    // Exposes assigned geometry only; this fixture does not interpolate CSS.
    getComputedStyle: element => element.style,
    performance: { now: () => clock.now },
    setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout,
    requestAnimationFrame: clock.requestAnimationFrame,
    cancelAnimationFrame: clock.cancelAnimationFrame,
  });
  if (realModules) {
    for (const filename of ['comparison.js', 'showcase.js']) {
      vm.runInContext(fs.readFileSync(path.join(root, filename), 'utf8'), context, { filename });
    }
  }
  vm.runInContext(fs.readFileSync(path.join(root, 'app.js'), 'utf8'), context, { filename: 'app.js' });
  const find = selector => {
    const element = document.querySelector(selector);
    if (!element) throw new Error(`Actual page is missing test target ${selector}`);
    return element;
  };
  return {
    document, clock, media, navigations, find,
    modules: { compare: window.WorkspaceCompare, showcase: window.WorkspaceShowcase }, moduleCalls,
    all: selector => document.querySelectorAll(selector),
    click: selector => find(selector).dispatch('click'),
    key: (selector, key, props = {}) => find(selector).dispatch('keydown', { key, ...props }),
    input: (selector, value) => { const el = find(selector); el.value = String(value); return el.dispatch('input'); },
    intersect(selector, isIntersecting = true) {
      const target = find(selector);
      for (const observer of observers) if (observer.targets.has(target)) observer.callback([{ target, isIntersecting }]);
    },
    setReducedMotion(value) { media.matches = value; media.dispatch('change', { matches: value, bubbles: false }); },
    setHidden(value) { document.hidden = value; document.dispatch('visibilitychange'); },
  };
}

module.exports = { loadApp };
