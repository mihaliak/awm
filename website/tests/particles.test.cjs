'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'particles.js'), 'utf8');

// The canvas fixture records mask placement and particle geometry.
class Element extends EventTarget {
  constructor(tag = 'div') {
    super();
    this.tag = tag;
    this.style = { position: '', visibility: '' };
    this.attributes = new Map();
    this.classes = new Set();
    this.children = [];
    this.bounds = { left: 0, top: 0, width: 240, height: 100 };
    this.classList = { add: name => this.classes.add(name), remove: name => this.classes.delete(name) };
  }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  setAttribute(name, value) {
    this.attributes.set(name, String(value));
    if (name === 'style') {
      this.style = { position: '', visibility: '' };
      for (const declaration of String(value).split(';')) {
        const [property, entry] = declaration.split(':');
        if (property?.trim() && entry?.trim()) this.style[property.trim()] = entry.trim();
      }
    }
  }
  removeAttribute(name) {
    this.attributes.delete(name);
    if (name === 'style') this.style = { position: '', visibility: '' };
  }
  getBoundingClientRect() { return this.bounds; }
  querySelector(selector) {
    if (selector === 'canvas') return this.canvas || null;
    if (selector === '.particle-fallback') return this.fallback || null;
    if (selector === '[data-particle-text]') return this.textSlot || null;
    if (selector === '.intro-logo') return this.logo || null;
    return null;
  }
}

class CanvasContext {
  constructor(canvas, empty = false) {
    this.canvas = canvas;
    this.empty = empty;
    this.texts = [];
    this.textOrigins = [];
    this.images = [];
    this.dots = [];
    this.draws = 0;
    this.frameArcs = 0;
    this.maxArcs = 0;
  }
  clearRect(...bounds) { this.clearBounds = bounds; this.draws++; this.frameArcs = 0; this.dots = []; }
  setTransform(...values) { assert.ok(values.every(Number.isFinite)); this.transform = values; }
  beginPath() { this.arcs = []; }
  moveTo(...values) { assert.ok(values.every(Number.isFinite)); }
  arc(...values) {
    assert.ok(values.every(Number.isFinite));
    assert.ok(values[2] > 0);
    this.arcs.push(values.slice(0, 3));
    this.frameArcs++;
    this.maxArcs = Math.max(this.maxArcs, this.frameArcs);
  }
  fill() { this.dots.push(...this.arcs.map(arc => [...arc, this.fillStyle])); }
  fillText(text, x, y) { this.texts.push(text); this.textOrigins.push([x, y]); }
  drawImage(image, ...bounds) {
    if (image.drawFails) throw new Error('The image cannot be drawn');
    this.images.push({ image, bounds });
  }
  measureText(text) { return { width: text.length * 55 }; }
  getImageData(x, y, width, height) {
    const data = new Uint8ClampedArray(width * height * 4);
    function paint(left, top, right, bottom) {
      for (let py = Math.max(0, Math.ceil(top)); py < Math.min(height, bottom); py++) {
        for (let px = Math.max(0, Math.ceil(left)); px < Math.min(width, right); px++) data[(py * width + px) * 4 + 3] = 255;
      }
    }
    if (!this.empty) {
      for (const [cx, cy] of this.textOrigins) paint(cx - width / 4, cy - 6, cx + width / 4, cy + 6);
      for (const { image, bounds: [left, top, w, h] } of this.images) {
        if (!image.transparent) paint(left + 2, top + 2, left + w - 2, top + h - 2);
      }
    }
    return { data };
  }
}

class Canvas extends Element {
  constructor({ supported = true, empty = false } = {}) {
    super('canvas');
    this.width = 300;
    this.height = 150;
    this.context = supported ? new CanvasContext(this, empty) : null;
  }
  getContext() { return this.context; }
}

function event(type, values = {}) {
  const result = new Event(type, { cancelable: true });
  for (const [name, value] of Object.entries(values)) Object.defineProperty(result, name, { value });
  return result;
}

function fixture({ reduced = false, hiddenFooter = false, unsupportedHero = false, emptyMasks = false, logoState, pixelRatio = 2 } = {}) {
  function host(id) {
    const element = new Element();
    element.id = id;
    element.canvas = new Canvas({ supported: id !== 'hero-particle-wordmark' || !unsupportedHero });
    element.fallback = new Element('p');
    element.canvas.setAttribute('style', 'opacity: 0.75');
    return element;
  }
  const hero = host('hero-particle-wordmark');
  hero.setAttribute('data-particle-wordmark', '');
  if (logoState) {
    hero.bounds = { left: 23, top: 17, width: 280, height: 172 };
    hero.textSlot = new Element();
    hero.textSlot.bounds = { left: 43, top: 17, width: 240, height: 100 };
    hero.logo = new Element('img');
    hero.logo.bounds = { left: 118, top: 139, width: 90, height: 50 };
    Object.assign(hero.logo, {
      complete: logoState !== 'loading',
      naturalWidth: logoState === 'failed' ? 0 : 28,
      naturalHeight: logoState === 'failed' ? 0 : 12,
      transparent: logoState === 'transparent',
      drawFails: logoState === 'undrawable',
    });
  }
  const footer = host('particle-wordmark');
  footer.canvas.id = 'particle-canvas';
  if (hiddenFooter) footer.bounds = { left: 0, top: 0, width: 0, height: 0 };
  const hosts = [hero, footer];
  const document = new EventTarget();
  document.hidden = false;
  document.getElementById = id => hosts.find(element => element.id === id) || null;
  document.querySelectorAll = () => hosts;
  const masks = [];
  document.createElement = () => {
    const canvas = new Canvas({ empty: emptyMasks }); masks.push(canvas); return canvas;
  };
  const motion = new EventTarget(); motion.matches = reduced;
  const intersections = new Map();
  const resizes = new Map();
  class IntersectionObserver {
    constructor(callback) { this.callback = callback; }
    observe(element) { this.element = element; intersections.set(element, this); }
    disconnect() { intersections.delete(this.element); }
  }
  class ResizeObserver {
    constructor(callback) { this.callback = callback; }
    observe(element) { this.element = element; resizes.set(element, this); }
    disconnect() { resizes.delete(this.element); }
  }
  const window = new EventTarget();
  Object.assign(window, { matchMedia: () => motion, devicePixelRatio: pixelRatio, IntersectionObserver, ResizeObserver });
  const frames = new Map();
  let frameId = 0, time = 0;
  const context = vm.createContext({
    document, window, AbortController, IntersectionObserver, ResizeObserver,
    getComputedStyle: element => ({ position: element.style.position || 'static', fontFamily: 'Arial, sans-serif' }),
    requestAnimationFrame: callback => { const id = ++frameId; frames.set(id, callback); return id; },
    cancelAnimationFrame: id => frames.delete(id),
  });
  vm.runInContext(source, context);
  return {
    window, hero, footer, frames, masks, intersections, resizes,
    get api() { return window.WorkspaceParticles; },
    visible(element, value) { intersections.get(element)?.callback([{ isIntersecting: value }]); },
    resize(element) { resizes.get(element)?.callback([]); },
    hidden(value) { document.hidden = value; document.dispatchEvent(new Event('visibilitychange')); },
    reduced(value) { motion.matches = value; motion.dispatchEvent(new Event('change')); },
    advance(count = 1) {
      for (let index = 0; index < count; index++) {
        time += 16.667;
        const pending = [...frames.values()]; frames.clear(); pending.forEach(callback => callback(time));
      }
    },
    reload() { vm.runInContext(source, context); },
  };
}

test('hero and legacy footer initialize independently without duplicate instances', () => {
  const f = fixture();
  assert.equal(f.api.instances.length, 2);
  assert.notEqual(f.api.instances[0], f.api.instances[1]);
  assert.equal(f.window.AWMParticles.host, f.footer);
  assert.ok(f.hero.classes.has('particles-ready'));
  assert.ok(f.footer.classes.has('particles-ready'));
  assert.equal(f.frames.size, 0, 'idle wordmarks do not animate');
  const first = f.api.instances[0];
  f.api.init(); f.reload();
  assert.equal(f.api.instances.length, 2);
  assert.equal(f.api.instances[0], first);
  assert.equal(f.intersections.size, 2);
  assert.equal(f.resizes.size, 2);
});

test('each instance has independent animation and offscreen suspension', () => {
  const f = fixture();
  f.visible(f.hero, true); f.visible(f.footer, true);
  f.hero.dispatchEvent(event('keydown', { key: 'Enter' }));
  assert.equal(f.frames.size, 1);
  const footerDraws = f.footer.canvas.context.draws;
  f.advance();
  assert.equal(f.footer.canvas.context.draws, footerDraws);
  f.footer.dispatchEvent(event('click', { detail: 0 }));
  assert.equal(f.frames.size, 2);
  f.visible(f.hero, false);
  assert.equal(f.frames.size, 1);
  f.hidden(true);
  assert.equal(f.frames.size, 0);
  f.hidden(false);
  assert.equal(f.frames.size, 1, 'only the visible footer resumes');
});

test('a zero-size hidden footer stays static and can initialize when revealed', () => {
  const f = fixture({ hiddenFooter: true });
  assert.equal(f.api.instances.length, 2);
  assert.equal(f.footer.classes.has('particles-ready'), false);
  assert.equal(f.footer.getAttribute('role'), null);
  assert.equal(f.footer.fallback.style.visibility, '');
  assert.equal(f.footer.canvas.width, 0);
  assert.equal(f.frames.size, 0);
  f.resize(f.footer);
  assert.equal(f.frames.size, 0);
  f.footer.bounds = { left: 0, top: 0, width: 240, height: 100 };
  f.visible(f.footer, true);
  assert.ok(f.footer.classes.has('particles-ready'));
  assert.equal(f.footer.getAttribute('role'), 'button');
  assert.equal(f.frames.size, 0);
});

test('reduced motion preserves static fallback and stops every instance', () => {
  const f = fixture({ reduced: true });
  f.visible(f.hero, true); f.visible(f.footer, true);
  assert.equal(f.masks.length, 0);
  assert.equal(f.hero.fallback.style.visibility, '');
  assert.equal(f.hero.getAttribute('tabindex'), null);
  assert.equal(f.frames.size, 0);
  f.reduced(false);
  assert.ok(f.hero.classes.has('particles-ready'));
  f.hero.dispatchEvent(event('keydown', { key: ' ' }));
  f.footer.dispatchEvent(event('click', { detail: 0 }));
  assert.equal(f.frames.size, 2);
  f.reduced(true);
  assert.equal(f.frames.size, 0);
  assert.equal(f.hero.fallback.getAttribute('aria-hidden'), null);
  assert.equal(f.footer.fallback.style.visibility, '');
  const space = event('keydown', { key: ' ' });
  f.hero.dispatchEvent(space);
  assert.equal(space.defaultPrevented, false);
});

test('keyboard activation is limited to the focused host and never traps unrelated keys', () => {
  const f = fixture(); f.visible(f.hero, true);
  for (const values of [{ key: 'Tab' }, { key: 'Enter', isComposing: true }, { key: 'Enter', target: new Element('button') }]) {
    const key = event('keydown', values);
    f.hero.dispatchEvent(key);
    assert.equal(key.defaultPrevented, false);
  }
  assert.equal(f.frames.size, 0);
  const repeat = event('keydown', { key: 'Enter', repeat: true });
  f.hero.dispatchEvent(repeat);
  assert.equal(f.frames.size, 0);
  const enter = event('keydown', { key: 'Enter', repeat: false });
  f.hero.dispatchEvent(enter);
  assert.equal(enter.defaultPrevented, true);
  assert.equal(f.frames.size, 1);
});

test('touch movement does not animate; a touch-style click can scatter', () => {
  const f = fixture(); f.visible(f.hero, true);
  f.hero.dispatchEvent(event('pointermove', { pointerType: 'touch', clientX: 90, clientY: 40 }));
  assert.equal(f.frames.size, 0);
  f.hero.dispatchEvent(event('click', { detail: 1, clientX: 90, clientY: 40 }));
  assert.equal(f.frames.size, 1);
});

test('particles settle to idle with finite geometry and bounded point counts', () => {
  const f = fixture(); f.visible(f.hero, true);
  f.api.instances.find(instance => instance.host === f.hero).disperse();
  f.advance(500);
  assert.equal(f.frames.size, 0);
  assert.ok(f.hero.canvas.context.maxArcs > 0);
  assert.ok(f.hero.canvas.context.maxArcs <= 3800);
});

test('the hero samples the title and SVG in their own slots with one palette and dot size', () => {
  const f = fixture({ logoState: 'loaded', pixelRatio: 3 });
  const { hero } = f;
  const mask = f.masks[0];
  assert.equal(mask.width, 280);
  assert.equal(mask.height, 172);
  assert.equal(hero.canvas.width, (mask.width + 192) * 2);
  assert.equal(hero.canvas.height, (mask.height + 192) * 2);
  assert.ok(mask.context.textOrigins.every(([x, y]) => x === 140 && y >= 0 && y < 100));
  const [{ image, bounds: [x, y, width, height] }] = mask.context.images;
  assert.equal(image, hero.logo);
  assert.equal(x, 95);
  assert.equal(width, 90);
  assert.ok(Math.abs(width / height - 28 / 12) < 1e-9);
  assert.equal(y, 122 + (50 - height) / 2);

  const { dots } = hero.canvas.context;
  const title = dots.filter(([, dotY]) => dotY < 100);
  const logo = dots.filter(([dotX, dotY]) => dotX >= x && dotX <= x + width && dotY >= y && dotY <= y + height);
  assert.ok(title.length > 0 && logo.length > 0);
  assert.equal(title.length + logo.length, dots.length);
  assert.ok(dots.length <= 3800);
  const palette = points => [...new Set(points.map(point => point[3]))].sort();
  assert.deepEqual(palette(logo), palette(title));
  assert.equal(palette(title).length, 4);
  assert.ok(dots.every(([, , radius]) => radius === 0.8));
  assert.equal(hero.logo.style.visibility, 'hidden');
  assert.equal(hero.getAttribute('tabindex'), '0');
  assert.equal(hero.logo.getAttribute('tabindex'), null);
});

test('the displayed canvas clears and paints beyond the compact mask at both pixel densities', () => {
  for (const pixelRatio of [1, 2]) {
    const f = fixture({ logoState: 'loaded', pixelRatio });
    const { hero } = f;
    const { canvas } = hero;
    f.visible(hero, true);
    assert.equal(canvas.style.left, '-96px');
    assert.equal(canvas.style.top, '-96px');
    assert.equal(canvas.style.width, '472px');
    assert.equal(canvas.style.height, '364px');
    assert.equal(canvas.style.pointerEvents, 'none');
    assert.deepEqual(canvas.context.transform, [pixelRatio, 0, 0, pixelRatio, 96 * pixelRatio, 96 * pixelRatio]);
    assert.deepEqual(canvas.context.clearBounds, [-96, -96, 472, 364]);
    assert.equal(canvas.width, 472 * pixelRatio);
    assert.equal(canvas.height, 364 * pixelRatio);

    hero.dispatchEvent(event('click', { detail: 1, clientX: hero.bounds.left + 140, clientY: hero.bounds.top + 100 }));
    const scattered = [];
    for (let frame = 0; frame < 16; frame += 1) {
      f.advance();
      scattered.push(...canvas.context.dots);
    }
    assert.ok(scattered.some(([, y]) => y < 0));
    assert.ok(scattered.some(([, y]) => y > hero.bounds.height));
    assert.ok(scattered.every(([x, y, radius]) =>
      x - radius > -96 && x + radius < 376 && y - radius > -96 && y + radius < 268));
  }
});

test('a late logo joins the existing particle field in one draw and leaves it idle', () => {
  const f = fixture({ logoState: 'loading' });
  const { hero } = f;
  const { context } = hero.canvas;
  f.visible(hero, true);
  const initialTitle = context.dots;
  const initialDraws = context.draws;
  hero.logo.complete = true;
  hero.logo.dispatchEvent(event('load'));
  assert.equal(f.frames.size, 1);
  f.advance();
  assert.deepEqual(context.dots.filter(([, y]) => y < 100), initialTitle);
  assert.ok(context.dots.some(([, y]) => y >= 122));
  assert.equal(hero.logo.style.visibility, 'hidden');
  assert.equal(f.frames.size, 0);
  f.advance(30);
  assert.equal(context.draws, initialDraws + 1);
});

test('hover at the logo repels its dots and click or keyboard scatters both shapes', () => {
  const f = fixture({ logoState: 'loaded' });
  const { hero } = f;
  f.visible(hero, true);
  const canvas = hero.canvas.context;
  const settled = canvas.dots;
  const x = hero.logo.bounds.left + hero.logo.bounds.width / 2;
  const y = hero.logo.bounds.top + hero.logo.bounds.height / 2;
  const movedIn = (from, to) => settled.some(([homeX, homeY], index) =>
    homeY >= from && homeY < to && (canvas.dots[index][0] !== homeX || canvas.dots[index][1] !== homeY)
  );

  hero.dispatchEvent(event('pointermove', { pointerType: 'mouse', clientX: x, clientY: y }));
  f.advance();
  assert.ok(movedIn(122, 172));
  assert.equal(movedIn(0, 100), false);
  hero.dispatchEvent(event('pointerleave'));
  f.advance(500);
  assert.deepEqual(canvas.dots, settled);

  for (const trigger of [
    event('click', { detail: 1, clientX: x, clientY: y }),
    event('keydown', { key: 'Enter' }),
    event('keydown', { key: ' ' }),
  ]) {
    hero.dispatchEvent(trigger);
    f.advance();
    assert.ok(movedIn(0, 100) && movedIn(122, 172));
    f.advance(500);
    assert.equal(f.frames.size, 0);
    assert.deepEqual(canvas.dots, settled);
  }
});

test('a loading or unusable logo retains its fallback while the title remains interactive', () => {
  for (const logoState of ['loading', 'failed', 'transparent', 'undrawable']) {
    const f = fixture({ logoState });
    assert.equal(f.hero.logo.style.visibility, '');
    assert.ok(f.hero.classes.has('particles-ready'));
    assert.ok(f.hero.canvas.context.dots.length > 0);
    assert.ok(f.hero.canvas.context.dots.every(([, y]) => y < 100));
  }
});

test('logo load, resize, reduced motion and destruction update or restore the same field', () => {
  const f = fixture({ logoState: 'loading' });
  const { hero } = f;
  f.visible(hero, true);
  f.hidden(true);
  hero.logo.complete = true;
  hero.logo.dispatchEvent(event('load'));
  assert.equal(f.frames.size, 0);
  assert.equal(hero.logo.style.visibility, '');
  f.hidden(false);
  assert.equal(hero.logo.style.visibility, 'hidden');

  hero.bounds.height += 30;
  hero.logo.bounds.top += 30;
  f.resize(hero);
  f.advance();
  assert.ok(hero.canvas.context.dots.some(([, y]) => y >= 152));
  f.reduced(true);
  assert.equal(hero.logo.style.visibility, '');
  assert.equal(hero.fallback.style.visibility, '');
  assert.equal(hero.getAttribute('tabindex'), null);
  assert.equal(f.frames.size, 0);
  f.reduced(false);
  assert.equal(hero.logo.style.visibility, 'hidden');
  f.api.destroy();
  assert.equal(hero.logo.style.visibility, '');
  hero.logo.dispatchEvent(event('load'));
  assert.equal(f.frames.size, 0);
});

test('individual and global destruction restore attributes and cancel lifecycle work', () => {
  const f = fixture(); f.visible(f.hero, true); f.visible(f.footer, true);
  f.api.instances.forEach(instance => instance.disperse());
  f.resize(f.hero);
  assert.ok(f.frames.size >= 2);
  const hero = f.api.instances.find(instance => instance.host === f.hero);
  hero.destroy(); hero.destroy();
  assert.equal(f.api.instances.length, 1);
  assert.equal(f.hero.getAttribute('role'), null);
  assert.equal(f.hero.style.position, '');
  assert.equal(f.hero.canvas.getAttribute('style'), 'opacity: 0.75');
  assert.equal(f.hero.canvas.getAttribute('width'), null);
  assert.equal(f.hero.canvas.getAttribute('height'), null);
  assert.equal(f.hero.fallback.getAttribute('aria-hidden'), null);
  assert.equal(f.window.AWMParticles.host, f.footer);
  f.api.destroy();
  assert.equal(f.api.instances.length, 0);
  assert.equal(f.frames.size, 0);
  assert.equal(f.intersections.size, 0);
  assert.equal(f.resizes.size, 0);
  assert.equal(f.window.AWMParticles, undefined);
  const key = event('keydown', { key: 'Enter' });
  f.hero.dispatchEvent(key);
  assert.equal(key.defaultPrevented, false);
});

test('unsupported or empty canvases retain readable fallback without animation', () => {
  const unsupported = fixture({ unsupportedHero: true });
  assert.equal(unsupported.api.instances.length, 1);
  assert.equal(unsupported.hero.getAttribute('role'), null);
  assert.equal(unsupported.hero.fallback.style.visibility, '');
  const empty = fixture({ emptyMasks: true });
  empty.visible(empty.hero, true);
  assert.equal(empty.hero.classes.has('particles-ready'), false);
  assert.equal(empty.hero.fallback.style.visibility, '');
  assert.equal(empty.frames.size, 0);
});

test('data-lines can customize one host without changing the other', () => {
  const f = fixture();
  const hero = f.api.instances.find(instance => instance.host === f.hero);
  hero.destroy();
  f.hero.setAttribute('data-lines', '["Another Window","Management","For Mac"]');
  f.api.init();
  assert.match(f.hero.getAttribute('aria-label'), /Another Window Management For Mac/);
  assert.doesNotMatch(f.footer.getAttribute('aria-label'), /For Mac/);
  assert.deepEqual(f.masks.at(-1).context.texts, ['Another Window', 'Management', 'For Mac']);
});
