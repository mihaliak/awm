'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'app-windows.js'), 'utf8');
const fixtures = {
  browser: ['safari', [2704, 1628], [112, 76, 2480, 1404]],
  code: ['coding-terminal', [1920, 1035], [280, 50, 1360, 935]],
  notes: ['notes', [814, 540], [0, 0, 814, 540]],
  calendar: ['calendar', [814, 522], [0, 0, 814, 522]],
  files: ['finder', [1144, 726], [0, 0, 1144, 726]],
  music: ['music', [1306, 780], [144, 91, 1015, 616]],
  terminal: ['terminal', [1304, 740], [0, 0, 1304, 740]],
};

function render() {
  const types = Object.keys(fixtures);
  const windows = [...types, ...types, 'showcase'].map((type, index) => ({
    id: type === 'showcase' ? 'showcase-window' : '',
    dataset: type === 'showcase' ? {} : { window: type },
    hidden: index % 3 === 0,
    style: { left: `${index}%`, width: '42%' },
    classList: { values: new Set(['app-window']), add(...names) { names.forEach(name => this.values.add(name)); } },
    attributes: {},
    setAttribute(key, value) { this.attributes[key] = String(value); },
    innerHTML: '<div>Previous illustration</div>',
  }));
  const original = windows.map(win => ({ node: win, id: win.id, type: win.dataset.window, hidden: win.hidden, style: { ...win.style } }));
  vm.runInNewContext(source, { document: { querySelectorAll: selector => selector === '.app-window' ? windows : [] } });
  return { windows, original };
}

function webpDimensions(buffer) {
  assert.equal(buffer.toString('ascii', 0, 4), 'RIFF');
  assert.equal(buffer.toString('ascii', 8, 12), 'WEBP');
  for (let offset = 12; offset + 8 < buffer.length;) {
    const chunk = buffer.toString('ascii', offset, offset + 4);
    const length = buffer.readUInt32LE(offset + 4);
    if (chunk === 'VP8X') return [buffer.readUIntLE(offset + 12, 3) + 1, buffer.readUIntLE(offset + 15, 3) + 1];
    if (chunk === 'VP8L') {
      assert.equal(buffer[offset + 8], 0x2f);
      const bits = buffer.readUInt32LE(offset + 9);
      return [(bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1];
    }
    offset += 8 + length + (length % 2);
  }
  throw new Error('Screenshot is missing a lossless WebP dimension header');
}

test('screenshot rendering preserves every outer window node, workspace state and geometry', () => {
  const { windows, original } = render();
  assert.equal(windows.length, 15);
  windows.forEach((win, index) => {
    assert.equal(win, original[index].node);
    assert.equal(win.id, original[index].id);
    assert.equal(win.dataset.window, original[index].type);
    assert.equal(win.hidden, original[index].hidden);
    assert.deepEqual(win.style, original[index].style);
    assert.equal(win.classList.values.has('native-app'), true);
    assert.match(win.attributes['aria-label'], /screenshot$/);
  });
  assert.equal(windows[14].dataset.nativeApp, 'Safari');
  assert.equal(windows[14].innerHTML, windows[0].innerHTML);
});

test('every app renders its actual local screenshot with valid source dimensions and exact viewport crop', () => {
  const { windows } = render();
  for (const win of windows) {
    const [file, dimensions, crop] = fixtures[win.dataset.window || 'browser'];
    assert.ok(win.innerHTML.includes(`href="./assets/screenshots/${file}.webp"`));
    assert.ok(win.innerHTML.includes(`viewBox="${crop.join(' ')}"`));
    assert.ok(win.innerHTML.includes(`width="${dimensions[0]}" height="${dimensions[1]}"`));
    const bitmap = fs.readFileSync(path.join(root, 'assets', 'screenshots', `${file}.webp`));
    assert.deepEqual(webpDimensions(bitmap), dimensions);
    const [x, y, width, height] = crop;
    assert.ok(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= dimensions[0] && y + height <= dimensions[1]);
  }
});

test('interiors contain only one uniformly scaled bitmap and no recreated app chrome', () => {
  const { windows } = render();
  for (const win of windows) {
    const tags = [...win.innerHTML.matchAll(/<\/?([a-z][\w-]*)\b/gi)].map(match => match[1]);
    assert.deepEqual([...new Set(tags)].sort(), ['image', 'svg', 'title']);
    assert.equal((win.innerHTML.match(/<image\b/g) || []).length, 1);
    assert.match(win.innerHTML, /^<svg[^>]+preserveAspectRatio="xMinYMin slice"/);
    assert.match(win.innerHTML, /<image[^>]+preserveAspectRatio="xMinYMin meet"/);
    assert.doesNotMatch(win.innerHTML, /native-topbar|native-traffic|native-shell|Workspace\.swift|<canvas\b|<iframe\b/);
  }
});
