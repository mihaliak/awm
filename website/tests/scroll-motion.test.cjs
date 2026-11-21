'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'scroll-motion.js'), 'utf8');

class Element {
  constructor(id, top = 1000, attributes = {}) {
    this.id = id;
    this.attributes = { 'data-reveal': '', ...attributes };
    this.classes = new Set();
    this.values = new Map();
    this.children = [];
    this.rect = { top, height: 120, width: 360 };
    this.classList = {
      add: (...names) => names.forEach(name => this.classes.add(name)),
      remove: (...names) => names.forEach(name => this.classes.delete(name)),
    };
    this.style = {
      setProperty: (name, value) => this.values.set(name, value),
      removeProperty: name => this.values.delete(name),
    };
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  getBoundingClientRect() { return this.rect; }
  append(child) { this.children.push(child); child.parent = this; }
  contains(node) { return node === this || this.children.some(child => child.contains(node)); }
  closest() { return this.getAttribute('href') ? this : this.parent?.closest() || null; }
}

function send(target, type, properties = {}) {
  const event = new Event(type, { cancelable: true });
  for (const [key, value] of Object.entries(properties)) Object.defineProperty(event, key, { value });
  target.dispatchEvent(event);
  return event;
}

function fixture({ blocks = [new Element('later')], extra = [], hash = '', reduced = false, io = true, fail = '', focused = null } = {}) {
  const document = new EventTarget();
  const all = [...blocks, ...extra];
  document.activeElement = focused;
  document.documentElement = { clientHeight: 800 };
  document.querySelectorAll = () => blocks;
  document.getElementById = id => all.find(element => element.id === id) || null;
  document.getElementsByName = () => [];
  const motion = new EventTarget(); motion.matches = reduced;
  const window = new EventTarget();
  Object.assign(window, { innerHeight: 800, location: new URL(`https://example.test/app/index.html${hash}`), matchMedia: () => motion });
  let observer;
  class Observer {
    constructor(callback, options) {
      if (fail === 'constructor') throw new Error('Unavailable observer');
      observer = this; this.callback = callback; this.options = options; this.targets = new Set(); this.disconnected = false;
    }
    observe(element) { if (fail === 'observe') throw new Error('Observation failed'); this.targets.add(element); }
    unobserve(element) { this.targets.delete(element); }
    disconnect() { this.targets.clear(); this.disconnected = true; }
  }
  if (io) window.IntersectionObserver = Observer;
  vm.runInNewContext(source, { document, window, IntersectionObserver: Observer, AbortController, URL });
  return {
    blocks, window, document,
    get observer() { return observer; },
    intersect(element, isIntersecting = true) { observer.callback([{ target: element, isIntersecting }]); },
    focus(element) { document.activeElement = element; return send(document, 'focusin', { target: element }); },
    end(element) { send(document, 'animationend', { target: element, animationName: 'workspace-reveal-in' }); },
    hash(value) { window.location.hash = value; send(window, 'hashchange'); },
    reduced(value) { motion.matches = value; send(motion, 'change'); },
  };
}

test('initially visible, above-viewport, zero-size, and focused content never becomes hidden', () => {
  const above = new Element('above', -300), visible = new Element('visible', 700);
  const zero = new Element('zero'); zero.rect.height = 0;
  const focused = new Element('focused');
  const later = new Element('later');
  const f = fixture({ blocks: [above, visible, zero, focused, later], focused });
  for (const block of [above, visible, zero, focused]) assert.equal(block.classes.size, 0);
  assert.ok(later.classes.has('reveal-pending'));
  assert.equal(f.observer.options.threshold, 0);
  assert.equal(f.observer.options.rootMargin, '0px 0px -24px 0px');
});

test('one intersecting edge reveals a large block once and cleans up after animation', () => {
  const block = new Element('large'); block.rect.height = 4000;
  const f = fixture({ blocks: [block] });
  f.intersect(block, false);
  assert.ok(block.classes.has('reveal-pending'));
  f.intersect(block);
  assert.equal(block.classes.has('reveal-pending'), false);
  assert.ok(block.classes.has('reveal-entering'));
  assert.equal(f.observer.targets.size, 0);
  f.end(block);
  assert.equal(block.classes.size, 0);
  assert.equal(block.values.size, 0);
  f.intersect(block);
  assert.equal(block.classes.size, 0, 'repeat observer delivery cannot restart a finished reveal');
});

test('optional stagger is bounded to 180ms and malformed delays do not block content', () => {
  for (const [requested, expected] of [['90', '90ms'], ['9999', '180ms'], ['-20', '0ms'], ['invalid', '0ms']]) {
    const block = new Element('later', 1000, { 'data-reveal-delay': requested });
    const f = fixture({ blocks: [block] });
    f.intersect(block);
    assert.equal(block.values.get('--reveal-delay'), expected);
    f.end(block);
  }
});

test('keyboard focus immediately exposes its containing block without taking focus', () => {
  const block = new Element('card'), child = new Element('link'); block.append(child);
  const f = fixture({ blocks: [block], extra: [child] });
  const event = f.focus(child);
  assert.equal(event.defaultPrevented, false);
  assert.equal(block.classes.size, 0);
  assert.equal(f.document.activeElement, child);
  const animated = new Element('animated'), button = new Element('button'); animated.append(button);
  const other = fixture({ blocks: [animated], extra: [button] });
  other.intersect(animated);
  other.focus(button);
  assert.equal(animated.classes.size, 0, 'focus also finishes an animation already in progress');
});

test('initial hash destinations and their contained cards remain visible before anchor scrolling', () => {
  const section = new Element('feature section'), card = new Element('card'); section.append(card);
  const elsewhere = new Element('elsewhere');
  fixture({ blocks: [section, card, elsewhere], hash: '#feature%20section' });
  assert.equal(section.classes.size, 0);
  assert.equal(card.classes.size, 0);
  assert.ok(elsewhere.classes.has('reveal-pending'));
});

test('same-page links and hash changes reveal destinations without replacing navigation', () => {
  const target = new Element('target'), malformed = new Element('%');
  const f = fixture({ blocks: [target, malformed] });
  const external = new Element('external', 0, { href: 'https://elsewhere.test/#target' });
  send(f.document, 'click', { target: external, button: 0 });
  assert.ok(target.classes.has('reveal-pending'));
  const link = new Element('link', 0, { href: './index.html#target' });
  const click = send(f.document, 'click', { target: link, button: 0 });
  assert.equal(click.defaultPrevented, false);
  assert.equal(target.classes.size, 0);
  f.hash('#%');
  assert.equal(malformed.classes.size, 0);
});

test('reduced motion is visible from the start and immediately clears pending/active reveals', () => {
  const initial = fixture({ reduced: true });
  assert.equal(initial.blocks[0].classes.size, 0);
  assert.equal(initial.observer, undefined);
  const first = new Element('first'), second = new Element('second');
  const f = fixture({ blocks: [first, second] });
  f.intersect(first);
  f.reduced(true);
  assert.equal(first.classes.size, 0);
  assert.equal(second.classes.size, 0);
  assert.equal(f.observer.disconnected, true);
  f.reduced(false);
  assert.equal(second.classes.size, 0, 'removing reduced motion never re-hides content');
});

test('missing or failing observers always leave content visible', () => {
  for (const options of [{ io: false }, { fail: 'constructor' }, { fail: 'observe' }]) {
    const f = fixture(options);
    assert.equal(f.blocks[0].classes.size, 0);
    assert.equal(f.blocks[0].values.size, 0);
  }
});

test('page restoration, printing, and destruction fail open without stranded hidden blocks', () => {
  const first = new Element('first'), second = new Element('second');
  const f = fixture({ blocks: [first, second] });
  first.rect.top = 200;
  send(f.window, 'pageshow');
  assert.equal(first.classes.size, 0);
  assert.ok(second.classes.has('reveal-pending'));
  send(f.window, 'beforeprint');
  assert.equal(second.classes.size, 0);
  assert.equal(f.observer.disconnected, true);
  const other = fixture();
  other.window.WorkspaceScrollMotion.destroy();
  other.window.WorkspaceScrollMotion.destroy();
  assert.equal(other.blocks[0].classes.size, 0);
  assert.equal(other.observer.disconnected, true);
});
