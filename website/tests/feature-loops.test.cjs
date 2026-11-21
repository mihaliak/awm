'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'feature-loops.js'), 'utf8');

class Element extends EventTarget {
  constructor() {
    super();
    this.values = new Map();
    this.style = {
      setProperty: (property, value) => this.values.set(property, value),
      getPropertyValue: property => this.values.get(property) || '',
      removeProperty: property => this.values.delete(property),
    };
    this.computed = {};
    this.classes = new Set();
    this.attributes = {};
    this.classList = {
      add: value => this.classes.add(value),
      remove: value => this.classes.delete(value),
      toggle: (value, enabled) => enabled ? this.classes.add(value) : this.classes.delete(value),
    };
  }
  setAttribute(name, value) { this.attributes[name] = value; }
}

function fixture({ reduced = false, gapPresent = true, pausePresent = true } = {}) {
  const gap = new Element();
  const gapValue = new Element();
  const displays = new Element();
  const displayState = new Element();
  const pause = new Element();
  const moving = [new Element(), new Element(), new Element(), new Element()];
  displays.querySelectorAll = () => moving;
  const document = new EventTarget();
  document.hidden = false;
  document.getElementById = id => ({
    'gap-preview': gapPresent ? gap : null,
    'gap-value': gapValue,
    'display-state': displayState,
    'feature-motion-pause': pausePresent ? pause : null,
  })[id];
  document.querySelector = () => displays;
  const motion = new EventTarget(); motion.matches = reduced;
  let clock = 0, id = 0, observe;
  const timers = new Map();
  const frames = new Set();
  const schedule = (callback, at) => {
    const handle = ++id;
    timers.set(handle, { callback, at });
    return handle;
  };
  class Observer {
    constructor(callback) { observe = callback; }
    observe() {}
    disconnect() {}
  }
  const window = { matchMedia: () => motion, IntersectionObserver: Observer };
  vm.runInNewContext(source, {
    document, window, IntersectionObserver: Observer, AbortController,
    getComputedStyle: element => {
      assert.notEqual(element, gap, 'the gap animation must never measure layout');
      return {
        getPropertyValue: property => element.computed[property] ?? (element.style.getPropertyValue(property)
          || ({ width: '100px', opacity: '1', transform: 'none' })[property] || ''),
      };
    },
    performance: { now: () => clock },
    setTimeout: (callback, delay) => schedule(callback, clock + delay),
    clearTimeout: timer => timers.delete(timer),
    requestAnimationFrame(callback) {
      const frame = schedule(() => { frames.delete(frame); callback(clock); }, (Math.floor(clock / 10) + 1) * 10);
      frames.add(frame);
      return frame;
    },
    cancelAnimationFrame(frame) { frames.delete(frame); timers.delete(frame); },
  });
  return {
    gapValue, displays, displayState, pause, moving, timers, frames, api: window.FeatureLoops,
    distance: () => 2 * parseFloat(gap.style.getPropertyValue('--gap-offset')),
    advance(ms) {
      const until = clock + ms;
      for (;;) {
        const next = [...timers.entries()].filter(([, item]) => item.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        clock = next[1].at; timers.delete(next[0]); next[1].callback();
      }
      clock = until;
    },
    visible(name, value) { observe([{ target: name === 'gap' ? gap : displays, isIntersecting: value }]); },
    allVisible() { observe([{ target: gap, isIntersecting: true }, { target: displays, isIntersecting: true }]); },
    hidden(value) { document.hidden = value; document.dispatchEvent(new Event('visibilitychange')); },
    reduced(value) { motion.matches = value; motion.dispatchEvent(new Event('change')); },
  };
}

test('illustrations start static and wait for visibility without live-region chatter', () => {
  const f = fixture();
  assert.equal(f.timers.size, 0);
  assert.equal(f.gapValue.textContent, '0 pt');
  assert.equal(f.displayState.textContent, 'Desk setup');
  assert.equal(f.gapValue.attributes['aria-live'], 'off');
  assert.equal(f.displayState.attributes['aria-live'], 'off');
  assert.equal(f.pause.textContent, 'Pause animations');
});

test('each spacing stage moves continuously, reads its drawn gap and holds without animation frames', () => {
  const f = fixture();
  f.visible('gap', true);
  f.advance(1500);
  assert.equal(f.distance(), 0);
  let from = 0;
  for (const target of [8, 16, 24, 16, 8, 0]) {
    let previous = from;
    const direction = Math.sign(target - from);
    for (let frame = 1; frame <= 85; frame++) {
      f.advance(10);
      const distance = f.distance();
      assert.ok((distance - previous) * direction >= 0, `frame ${frame} must move toward ${target}`);
      assert.ok(Math.abs(distance - previous) < 1, 'a frame should never jump a full point');
      assert.ok(Math.abs(distance - parseInt(f.gapValue.textContent, 10)) <= 0.501);
      if (frame === 20) assert.ok((distance - from) * direction > 0 && (target - distance) * direction > 0);
      previous = distance;
    }
    assert.equal(f.distance(), target);
    assert.equal(f.gapValue.textContent, `${target} pt`);
    assert.equal(f.frames.size, 0);
    f.advance(649);
    assert.equal(f.distance(), target);
    assert.equal(f.frames.size, 0);
    f.advance(1);
    from = target;
  }
  f.advance(240);
  assert.ok(f.distance() > 0 && f.distance() < 8, 'the next cycle starts from zero');
  assert.equal(f.timers.size, 1);
  assert.equal(f.displayState.textContent, 'Desk setup');
});

test('display arrangement disconnects and reconnects on an 8.4 second loop', () => {
  const f = fixture();
  f.visible('displays', true);
  f.advance(4199);
  assert.equal(f.displays.classes.has('disconnected'), false);
  f.advance(1);
  assert.equal(f.displays.classes.has('disconnected'), true);
  assert.equal(f.displayState.textContent, 'On the go');
  f.advance(4200);
  assert.equal(f.displays.classes.has('disconnected'), false);
  assert.equal(f.displayState.textContent, 'Desk setup');
  assert.equal(f.timers.size, 1);
});

test('shared Pause freezes both illustrations and Resume continues from the same gap frame', () => {
  const f = fixture();
  f.allVisible();
  f.advance(1707);
  const before = f.distance();
  assert.ok(before > 0 && before < 8);
  f.moving[0].computed.transform = 'matrix(1, 0, 0, 1, 8, 0)';
  f.pause.dispatchEvent(new Event('click'));
  assert.equal(f.timers.size, 0);
  assert.equal(f.frames.size, 0);
  assert.equal(f.pause.textContent, 'Resume animations');
  assert.equal(f.distance(), before);
  assert.equal(f.moving[0].style.getPropertyValue('transform'), 'matrix(1, 0, 0, 1, 8, 0)');
  f.advance(30000);
  assert.equal(f.distance(), before);
  f.pause.dispatchEvent(new Event('click'));
  assert.equal(f.distance(), before);
  assert.equal(f.moving[0].style.getPropertyValue('transform'), '');
  assert.equal(f.timers.size, 2);
  f.advance(100);
  assert.ok(f.distance() > before && f.distance() < 8);
});

test('each illustration independently stops offscreen without catching up on return', () => {
  const f = fixture();
  f.allVisible();
  f.advance(2700);
  assert.equal(f.distance(), 8);
  f.visible('gap', false);
  assert.equal(f.timers.size, 1);
  f.advance(9000);
  assert.equal(f.gapValue.textContent, '8 pt');
  f.visible('gap', true);
  assert.equal(f.timers.size, 2);
  f.advance(299);
  assert.equal(f.distance(), 8, 'resuming preserves the unspent part of the hold');
  f.advance(201);
  assert.ok(f.distance() > 8 && f.distance() < 16);
});

test('hidden tabs stop both loops, and manual pause survives visibility changes', () => {
  const f = fixture();
  f.allVisible();
  f.advance(1750);
  const before = f.distance();
  f.hidden(true);
  assert.equal(f.timers.size, 0);
  f.advance(20000);
  assert.equal(f.distance(), before);
  f.hidden(false);
  assert.equal(f.timers.size, 2);
  assert.equal(f.distance(), before);
  f.api.setPaused(true);
  f.hidden(true); f.hidden(false); f.allVisible();
  assert.equal(f.timers.size, 0);
  assert.equal(f.pause.textContent, 'Resume animations');
});

test('reduced motion uses a static 12-point gap and connected displays', () => {
  const f = fixture({ reduced: true });
  f.allVisible();
  assert.equal(f.timers.size, 0);
  assert.equal(f.gapValue.textContent, '12 pt');
  assert.equal(f.distance(), 12);
  assert.equal(f.displayState.textContent, 'Desk setup');
  assert.equal(f.pause.hidden, true);
  f.reduced(false);
  assert.equal(f.gapValue.textContent, '0 pt');
  assert.equal(f.timers.size, 2);
  f.advance(4700);
  assert.equal(f.displayState.textContent, 'On the go');
  assert.equal(f.frames.size, 1);
  f.reduced(true);
  assert.equal(f.timers.size, 0);
  assert.equal(f.gapValue.textContent, '12 pt');
  assert.equal(f.distance(), 12);
  assert.equal(f.displayState.textContent, 'Desk setup');
});

test('repeated resume and observer updates do not duplicate timers; destroy clears them', () => {
  const f = fixture();
  f.allVisible(); f.allVisible();
  f.api.setPaused(false); f.api.setPaused(false);
  assert.equal(f.timers.size, 2);
  f.advance(1800);
  assert.equal(f.frames.size, 1);
  f.api.destroy(); f.api.destroy();
  f.api.setPaused(false);
  f.advance(60000);
  assert.equal(f.timers.size, 0);
  assert.equal(f.frames.size, 0);
});

test('a missing spacing example or optional button does not break the display loop', () => {
  const f = fixture({ gapPresent: false, pausePresent: false });
  f.visible('displays', true);
  f.advance(4200);
  assert.equal(f.displayState.textContent, 'On the go');
  assert.equal(f.timers.size, 1);
});
