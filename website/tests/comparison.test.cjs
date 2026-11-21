'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Controller integration only: no browser, CSS renderer, or native hit testing.
class Element {
  constructor() {
    this.attributes = new Map(); this.listeners = new Map(); this.captures = new Set();
    this.dataset = {}; this.style = { setProperty(name, value) { this[name] = value; } };
    this.classes = new Set(); this.classList = { add: name => this.classes.add(name), remove: name => this.classes.delete(name) };
    this.bounds = { left: 100, width: 900, top: 0, height: 600 };
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name); }
  addEventListener(type, callback) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(callback);
  }
  emit(type, values = {}) {
    const event = { type, pointerId: 1, pointerType: 'mouse', button: 0, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...values };
    for (const listener of this.listeners.get(type) || []) listener(event);
    return event;
  }
  getBoundingClientRect() { return this.bounds; }
  setPointerCapture(id) { this.captures.add(id); }
  hasPointerCapture(id) { return this.captures.has(id); }
  releasePointerCapture(id) { if (this.captures.delete(id)) this.emit('lostpointercapture', { pointerId: id }); }
  focus() { this.focused = true; }
}

function fixture({ reduced = false } = {}) {
  const ids = ['interactive-desktop', 'comparison-range', 'comparison-handle', 'comparison-before-path', 'comparison-after-path', 'comparison-curve'];
  const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
  const document = new Element();
  document.hidden = false;
  document.querySelector = selector => nodes[selector.slice(1)] || null;
  const media = new Element(); media.matches = reduced;
  let now = 0, id = 0;
  const frames = new Map();
  const window = { matchMedia: () => media };
  const context = vm.createContext({
    window, document, performance: { now: () => now },
    requestAnimationFrame: fn => { frames.set(++id, fn); return id; },
    cancelAnimationFrame: token => frames.delete(token),
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../comparison.js'), 'utf8'), context, { filename: 'comparison.js' });
  const step = (milliseconds = 16) => {
    now += milliseconds;
    const current = [...frames.values()]; frames.clear();
    for (const callback of current) callback(now);
  };
  const settle = () => {
    let count = 0;
    while (frames.size && count++ < 500) step();
    assert.equal(frames.size, 0, 'spring should stop requesting frames');
  };
  const range = nodes['comparison-range'];
  return { nodes, range, document, media, api: window.WorkspaceCompare, step, settle,
    frames: () => frames.size,
    pointer: (type, fraction, extra = {}) => range.emit(type, { clientX: nodes['interactive-desktop'].bounds.left + fraction * nodes['interactive-desktop'].bounds.width, ...extra }),
  };
}

function curveGeometry(f) {
  const d = f.nodes['comparison-curve'].getAttribute('d');
  const values = d.match(/-?\d+(?:\.\d+)?/g).map(Number);
  return { edge: values[0], control: values[2], end: values[4] };
}
function assertSharedBoundary(f) {
  const line = f.nodes['comparison-curve'].getAttribute('d');
  const before = f.nodes['comparison-before-path'].getAttribute('d');
  const after = f.nodes['comparison-after-path'].getAttribute('d');
  assert.equal(before, `M 0 0 L ${line.slice(2)} L 0 1 Z`);
  assert.equal(after, `${line} L 1 1 L 1 0 Z`);
}
function close(actual, expected, tolerance = 1e-6) { assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} should be approximately ${expected}`); }

test('initial midpoint and endpoint masks share the exact same boundary', () => {
  const f = fixture();
  assert.equal(f.api.getValue(), 50);
  assertSharedBoundary(f);
  for (const value of [0, 17.25, 50, 100]) {
    f.api.setValue(value, { immediate: true });
    close(curveGeometry(f).edge, value / 100);
    close(curveGeometry(f).control, value / 100);
    assertSharedBoundary(f);
    assert.equal(f.frames(), 0);
    assert.equal(Number(f.range.value), value);
  }
});

test('fast dragging bends both masks while the curve midpoint remains under the handle', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5);
  f.step();
  f.pointer('pointermove', 0.8);
  const geometry = curveGeometry(f);
  assert.ok(geometry.edge < 0.8);
  assert.ok(geometry.control > 0.8);
  close((geometry.edge + geometry.control) / 2, 0.8);
  close(0.8 - geometry.edge, 9 / 270, 1e-6);
  assertSharedBoundary(f);
  f.pointer('pointercancel', 0.8);
  f.settle();
  close(curveGeometry(f).edge, 0.8);
  close(curveGeometry(f).control, 0.8);
  assert.equal(f.range.hasPointerCapture(1), false);
});

test('the 620/44 spring matches the reference integration step', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5);
  f.step();
  f.pointer('pointermove', 0.52);
  f.step();
  const endVelocity = (0.02 * 620) * 0.016;
  const endPosition = 0.5 + endVelocity * 0.016;
  const bend = (0.52 - endPosition) * 0.5;
  close(curveGeometry(f).edge, 0.52 - bend);
  close(curveGeometry(f).control, 0.52 + bend);
});

test('flicks use the reference threshold and glide to their respective edges', () => {
  for (const destination of [0.2, 0.8]) {
    const f = fixture();
    f.pointer('pointerdown', 0.5); f.step();
    f.pointer('pointermove', destination);
    f.pointer('pointerup', destination);
    assert.equal(f.range.hasPointerCapture(1), false);
    f.settle();
    assert.equal(f.api.getValue(), destination < 0.5 ? 0 : 100);
    assertSharedBoundary(f);
  }
});

test('a paused drag does not reuse stale flick velocity', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5); f.step();
  f.pointer('pointermove', 0.8); f.step(150);
  f.pointer('pointerup', 0.8); f.settle();
  assert.equal(f.api.getValue(), 80);
});

test('release coordinates are committed even when no pointermove was delivered', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5);
  f.step(200);
  f.pointer('pointerup', 0.6);
  assert.equal(f.api.getValue(), 60);
  assert.equal(f.range.hasPointerCapture(1), false);
  f.settle();
  close(curveGeometry(f).edge, 0.6);
  assertSharedBoundary(f);
});

test('a final changed release sample replaces the previous drag velocity', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5); f.step();
  f.pointer('pointermove', 0.7); f.step(150);
  f.pointer('pointerup', 0.69);
  f.settle();
  close(f.api.getValue(), 69);
});

test('click-to-glide is not snapped by a stationary pointerup', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.8); f.step();
  const midGlide = f.api.getValue();
  assert.ok(midGlide > 50 && midGlide < 80);
  f.pointer('pointerup', 0.8);
  assert.equal(f.api.getValue(), midGlide);
  f.settle();
  assert.equal(f.api.getValue(), 80);
});

test('programmatic immediate values cancel drag and pending spring frames', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5); f.step();
  f.pointer('pointermove', 0.8);
  f.api.setValue(0, { immediate: true });
  assert.equal(f.frames(), 0);
  assert.equal(f.range.hasPointerCapture(1), false);
  close(curveGeometry(f).edge, 0);
  f.pointer('pointermove', 0.4); f.step(1000);
  assert.equal(f.api.getValue(), 0);
});

test('inactive shortcut mode shows only After and remembers the comparison position', () => {
  const f = fixture();
  f.api.setValue(63, { immediate: true });
  f.pointer('pointerdown', 0.7); f.step();
  const saved = f.api.getValue();
  f.api.setActive(false);
  assert.equal(f.frames(), 0);
  assert.equal(f.range.hidden, true);
  assert.equal(f.range.disabled, true);
  assert.equal(f.range.tabIndex, -1);
  assert.equal(f.range.hasPointerCapture(1), false);
  close(curveGeometry(f).edge, 0);
  assertSharedBoundary(f);
  f.pointer('pointerdown', 0.1);
  f.range.emit('keydown', { key: 'End' });
  assert.equal(f.api.getValue(), saved);
  f.api.setActive(true);
  close(curveGeometry(f).edge, saved / 100);
  assert.equal(f.range.hidden, false);
  assert.equal(f.range.disabled, false);
});

test('native range input and keyboard endpoints retain accessible value feedback', () => {
  const f = fixture();
  f.range.value = '22'; f.range.emit('input');
  assert.equal(f.api.getValue(), 22);
  assert.equal(f.range.getAttribute('aria-valuetext'), '22 percent before, 78 percent organized');
  f.range.emit('keydown', { key: 'ArrowRight', shiftKey: true });
  f.range.emit('keydown', { key: 'ArrowRight' });
  f.settle(); close(f.api.getValue(), 33);
  f.range.emit('keydown', { key: 'Home' }); f.settle();
  assert.equal(f.api.getValue(), 0);
  f.range.emit('keydown', { key: 'End' }); f.settle();
  assert.equal(f.api.getValue(), 100);
});

test('reduced motion settles immediately and never schedules motion frames', () => {
  const f = fixture({ reduced: true });
  f.pointer('pointerdown', 0.7);
  f.pointer('pointermove', 0.8);
  assert.equal(f.api.getValue(), 80);
  close(curveGeometry(f).edge, 0.8);
  f.pointer('pointercancel', 0.8);
  f.range.emit('keydown', { key: 'Home' });
  assert.equal(f.api.getValue(), 0);
  assert.equal(f.frames(), 0);
});

test('motion-preference changes and hidden tabs stop animation and release capture', () => {
  const f = fixture();
  f.api.setValue(100); f.step();
  f.media.matches = true; f.media.emit('change');
  assert.equal(f.api.getValue(), 100);
  assert.equal(f.frames(), 0);
  f.media.matches = false;
  f.pointer('pointerdown', 0.5); f.step();
  f.pointer('pointermove', 0.7);
  f.document.hidden = true; f.document.emit('visibilitychange');
  assert.equal(f.frames(), 0);
  assert.equal(f.range.hasPointerCapture(1), false);
  close(curveGeometry(f).edge, 0.7);
});

test('normalized curve coordinates survive viewport size changes without pixel masks', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.5); f.step(); f.pointer('pointermove', 0.75);
  const pathBeforeResize = f.nodes['comparison-before-path'].getAttribute('d');
  f.nodes['interactive-desktop'].bounds.width = 270;
  assert.equal(f.nodes['comparison-before-path'].getAttribute('d'), pathBeforeResize);
  f.pointer('pointermove', 0.8);
  close(f.api.getValue(), 80);
  assertSharedBoundary(f);
});

test('unrelated pointers and right clicks cannot hijack comparison', () => {
  const f = fixture();
  f.pointer('pointerdown', 0.2, { pointerId: 3, pointerType: 'touch', isPrimary: false });
  assert.equal(f.range.hasPointerCapture(3), false);
  assert.equal(f.frames(), 0);
  f.pointer('pointerdown', 0.2, { button: 2 });
  assert.equal(f.frames(), 0);
  f.pointer('pointerdown', 0.5, { pointerId: 4 }); f.step();
  f.pointer('pointerdown', 0.1, { pointerId: 5 });
  f.pointer('pointermove', 0.9, { pointerId: 5 });
  f.pointer('pointercancel', 0.9, { pointerId: 5 });
  assert.equal(f.range.hasPointerCapture(4), true);
  assert.equal(f.api.getValue(), 50);
  f.pointer('pointercancel', 0.5, { pointerId: 4 }); f.settle();
  assert.equal(f.range.hasPointerCapture(4), false);
});
