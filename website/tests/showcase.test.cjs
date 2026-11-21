'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'showcase.js'), 'utf8');

class Element extends EventTarget {
  constructor() {
    super();
    this.style = {};
    this.dataset = {};
    this.attributes = {};
    this.classes = new Set();
    this.children = [];
    this.hidden = false;
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
      contains: name => this.classes.has(name),
      toggle: (name, state) => state ? this.classes.add(name) : this.classes.delete(name),
    };
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  append(node) { this.children.push(node); node.parentElement = this; }
  closest() { return this.scene; }
}

function fixture({ active = true, reduced = false, providePause = true } = {}) {
  const scene = new Element();
  const win = new Element(); win.scene = scene;
  const label = new Element();
  const progress = new Element();
  const caption = new Element(); caption.append(label);
  const pause = providePause ? new Element() : null;
  const keys = ['left', 'right', 'top', 'bottom', 'center', 'enter'].map(name => {
    const element = new Element(); element.dataset.showcaseKey = name; return element;
  });
  const demo = { dataset: { mode: active ? 'shortcut' : 'compare' } };
  const elements = { 'showcase-window': win, 'showcase-label': label, 'showcase-progress': progress, 'showcase-pause': pause };
  const document = new EventTarget();
  document.hidden = false;
  document.getElementById = id => elements[id];
  document.querySelector = selector => selector === '#workspace-demo' ? demo : null;
  document.querySelectorAll = () => keys;
  document.createElement = () => new Element();
  const motion = new EventTarget(); motion.matches = reduced;
  let clock = 0, timerId = 0, observe;
  const timers = new Map();
  class Observer {
    constructor(callback) { observe = callback; }
    observe() {}
    disconnect() {}
  }
  const window = { matchMedia: () => motion, IntersectionObserver: Observer };
  vm.runInNewContext(source, {
    document, window, IntersectionObserver: Observer, AbortController,
    getComputedStyle: element => ({ getPropertyValue: property => element.style[property] || '' }),
    setTimeout: (callback, delay) => {
      const id = ++timerId; timers.set(id, { callback, at: clock + delay }); return id;
    },
    clearTimeout: id => timers.delete(id),
  });
  return {
    win, label, progress, keys, pause: pause || caption.children.at(-1), timers,
    api: window.WorkspaceShowcase,
    advance(ms) {
      const until = clock + ms;
      for (;;) {
        const next = [...timers.entries()].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        clock = next[1].at; timers.delete(next[0]); next[1].callback();
      }
      clock = until;
    },
    visible(value) { observe([{ isIntersecting: value }]); },
    hidden(value) { document.hidden = value; document.dispatchEvent(new Event('visibilitychange')); },
    reduced(value) { motion.matches = value; motion.dispatchEvent(new Event('change')); },
  };
}

function box(f) { return ['left', 'top', 'width', 'height'].map(property => parseFloat(f.win.style[property])); }
function click(element) { element.dispatchEvent(new Event('click')); }

test('active mode starts immediately and pulses the first key for 180ms', () => {
  const f = fixture();
  assert.equal(f.label.textContent, 'Left · one third');
  assert.equal(f.progress.textContent, '1 / 15');
  assert.ok(f.keys[0].classes.has('is-active'));
  f.advance(179);
  assert.ok(f.keys[0].classes.has('is-active'));
  f.advance(1);
  assert.ok(f.keys.every(key => !key.classes.has('is-active')));
  assert.equal(f.timers.size, 1);
});

test('all fifteen moves follow the requested order, stay in bounds, and loop after a pause', () => {
  const f = fixture();
  const labels = [
    'Left · one third', 'Left · one half', 'Left · two thirds',
    'Right · one third', 'Right · one half', 'Right · two thirds',
    'Top · one third', 'Top · one half', 'Top · two thirds',
    'Bottom · one third', 'Bottom · one half', 'Bottom · two thirds',
    'Centered', 'Fill display', 'Center · restored',
  ];
  const holds = [...Array(12).fill(1100), 1350, 1350, 2600];
  const expectedKeys = ['left', 'left', 'left', 'right', 'right', 'right', 'top', 'top', 'top', 'bottom', 'bottom', 'bottom', 'center', 'enter', 'enter'];
  labels.forEach((label, index) => {
    assert.equal(f.label.textContent, label);
    assert.equal(f.progress.textContent, `${index + 1} / 15`);
    assert.ok(f.keys.find(key => key.dataset.showcaseKey === expectedKeys[index]).classes.has('is-active'));
    const [x, y, width, height] = box(f);
    assert.ok(x >= 3 - 1e-8 && x + width <= 97 + 1e-8);
    assert.ok(y >= 9 - 1e-8 && y + height <= 80 + 1e-8);
    if (index >= 6 && index <= 11) {
      assert.equal(x, 3);
      assert.equal(width, 94);
      const fraction = [1 / 3, 1 / 2, 2 / 3][index % 3];
      assert.ok(Math.abs(height - 71 * fraction) < 1e-8);
      if (index <= 8) assert.equal(y, 9);
      else assert.ok(Math.abs(y + height - 80) < 1e-8);
    }
    if (index === 13) assert.deepEqual(box(f), [3, 9, 94, 71]);
    if (index === 14) assert.deepEqual(box(f), [24, 14, 52, 62]);
    f.advance(holds[index] - 1);
    assert.equal(f.label.textContent, label);
    f.advance(1);
  });
  assert.equal(f.label.textContent, labels[0]);
  assert.equal(f.timers.size, 2, 'one step timer and one key pulse, with no accumulated timers');
});

test('inactive mode has no timers and repeated activation cannot duplicate the loop', () => {
  const f = fixture({ active: false });
  assert.equal(f.timers.size, 0);
  assert.deepEqual(box(f), [24, 14, 52, 62]);
  f.api.setActive(true);
  f.api.setActive(true);
  assert.equal(f.timers.size, 2);
  f.api.setActive(false);
  assert.equal(f.timers.size, 0);
  f.advance(60000);
  assert.equal(f.label.textContent, 'Centered');
});

test('Pause cancels motion work; Resume continues the same step', () => {
  const f = fixture();
  f.advance(1200);
  click(f.pause);
  const caption = f.label.textContent;
  assert.equal(f.pause.textContent, 'Resume');
  assert.equal(f.timers.size, 0);
  assert.ok(f.win.classes.has('showcase-still'));
  f.advance(60000);
  assert.equal(f.label.textContent, caption);
  click(f.pause);
  assert.equal(f.pause.textContent, 'Pause');
  assert.equal(f.label.textContent, caption);
  f.advance(1100);
  assert.equal(f.label.textContent, 'Left · two thirds');
});

test('offscreen and hidden states pause without catch-up or leaked timers', () => {
  for (const method of ['visible', 'hidden']) {
    const f = fixture();
    f[method](method === 'hidden');
    assert.equal(f.timers.size, 0);
    f.advance(30000);
    assert.equal(f.label.textContent, 'Left · one third');
    f[method](method !== 'hidden');
    assert.equal(f.timers.size, 1);
    f.advance(1100);
    assert.equal(f.label.textContent, 'Left · one half');
  }
});

test('reduced motion stays centered without timers and responds to preference changes', () => {
  const f = fixture({ reduced: true });
  assert.deepEqual(box(f), [24, 14, 52, 62]);
  assert.equal(f.progress.textContent, 'Reduced motion');
  assert.equal(f.pause.hidden, true);
  assert.equal(f.timers.size, 0);
  f.reduced(false);
  assert.equal(f.pause.hidden, false);
  assert.equal(f.label.textContent, 'Left · one third');
  f.reduced(true);
  assert.equal(f.timers.size, 0);
  assert.deepEqual(box(f), [24, 14, 52, 62]);
});

test('manual pause persists across mode changes and automatic visibility changes', () => {
  const f = fixture();
  click(f.pause);
  f.api.setActive(false); f.api.setActive(true);
  f.hidden(true); f.hidden(false);
  f.visible(false); f.visible(true);
  assert.equal(f.timers.size, 0);
  assert.equal(f.pause.textContent, 'Resume');
  click(f.pause);
  assert.equal(f.label.textContent, 'Left · one third');
});

test('a missing pause button is created as the sole motion control', () => {
  const f = fixture({ providePause: false });
  assert.equal(f.pause.id, 'showcase-pause');
  assert.equal(f.pause.type, 'button');
  assert.equal(f.pause.attributes['aria-controls'], 'showcase-window');
  assert.equal(f.pause.attributes['aria-label'], 'Pause automatic window showcase');
  assert.equal(f.label.attributes['aria-live'], 'off');
});

test('destroy cancels both timers and prevents restarting', () => {
  const f = fixture();
  f.api.destroy(); f.api.destroy();
  f.api.setActive(true);
  assert.equal(f.timers.size, 0);
  f.advance(60000);
  assert.equal(f.label.textContent, 'Centered');
});
