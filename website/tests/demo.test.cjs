'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadApp } = require('./helpers/dom-harness.cjs');

const allApps = ['browser', 'calendar', 'code', 'files', 'music', 'notes', 'terminal'];
const includedApps = {
  focus: ['browser', 'music', 'notes'],
  vibing: ['browser', 'code', 'files'],
  planning: ['browser', 'calendar', 'notes'],
};

function geometry(element) {
  return ['left', 'top', 'width', 'height'].map(property => element.style[property]);
}
function windows(app, scene) { return app.find(scene).querySelectorAll('.app-window'); }
function visibleApps(app, scene = '.after-scene') {
  return windows(app, scene).filter(win => !win.hidden).map(win => win.dataset.window).sort();
}
function snapshot(app, scene = '.after-scene') {
  return Object.fromEntries(windows(app, scene).map(win => [win.dataset.window, {
    hidden: win.hidden, geometry: geometry(win),
  }]));
}
function assertWorkspace(app, workspace) {
  assert.equal(app.find('.before-scene').dataset.layout, workspace);
  assert.equal(app.find('.after-scene').dataset.layout, workspace);
  assert.deepEqual(visibleApps(app), includedApps[workspace]);
  assert.deepEqual(visibleApps(app, '.before-scene'), allApps);
  const pressed = app.all('[data-workspace]').filter(button => button.getAttribute('aria-pressed') === 'true');
  assert.equal(pressed.length, 1);
  assert.equal(pressed[0].dataset.workspace, workspace);
}
function assertMode(app, mode) {
  const isCompare = mode === 'compare';
  assert.equal(app.find('#workspace-demo').dataset.mode, mode);
  assert.equal(app.find('.before-scene').hidden, !isCompare);
  assert.equal(app.find('.after-scene').hidden, !isCompare);
  assert.equal(app.find('#shortcut-scene').hidden, isCompare);
  assert.equal(app.find('.screen-workspaces').hidden, !isCompare);
  assert.equal(app.find('#compare-controls').hidden, !isCompare);
  assert.equal(app.find('#shortcut-controls').hidden, isCompare);
  assert.equal(app.modules.compare.active, isCompare);
  assert.equal(app.modules.showcase.active, !isCompare);
  assert.equal(app.find('#interactive-desktop').getAttribute('aria-describedby'), isCompare ? 'demo-help' : 'shortcut-help');
  for (const tab of app.all('[role="tab"][data-mode]')) {
    assert.equal(tab.getAttribute('aria-selected'), String(tab.dataset.mode === mode));
    assert.equal(tab.tabIndex, tab.dataset.mode === mode ? 0 : -1);
  }
}

test('comparison and shortcut scenes are sibling layers with independent windows', () => {
  const app = loadApp();
  const desktop = app.find('#interactive-desktop');
  for (const selector of ['.before-scene', '.after-scene', '#shortcut-scene']) {
    const scene = app.find(selector);
    assert.equal(scene.parentElement, desktop, `${selector} must be a direct desktop child`);
    const layer = scene.querySelector('.window-layer');
    assert.ok(layer, `${selector} has a window layer`);
    assert.equal(layer.parentElement, scene);
    for (const win of scene.querySelectorAll('.app-window')) assert.equal(win.parentElement, layer);
  }
  for (const selector of ['.before-scene', '.after-scene']) {
    const list = windows(app, selector);
    assert.equal(list.length, 7);
    assert.deepEqual(list.map(win => win.dataset.window).sort(), allApps);
  }
  const shortcutWindows = windows(app, '#shortcut-scene');
  assert.equal(shortcutWindows.length, 1);
  assert.equal(shortcutWindows[0], app.find('#showcase-window'));
  assert.equal(shortcutWindows[0].classList.contains('browser-window'), true);
});

test('deferred animation modules load before the app controller', () => {
  const app = loadApp();
  const scripts = app.all('script').filter(script => script.hasAttribute('src'));
  const sources = scripts.map(script => script.getAttribute('src'));
  const appIndex = sources.indexOf('./app.js');
  assert.ok(appIndex >= 0);
  for (const source of ['./comparison.js', './showcase.js']) {
    const index = sources.indexOf(source);
    assert.ok(index >= 0 && index < appIndex, `${source} must initialize before app.js`);
    assert.equal(scripts[index].hasAttribute('defer'), true);
  }
  assert.equal(scripts[appIndex].hasAttribute('defer'), true);
});

test('initial state shows Focus at a centered comparison with shortcut playback inactive', () => {
  const app = loadApp();
  assertWorkspace(app, 'focus');
  assertMode(app, 'compare');
  assert.equal(app.modules.compare.value, 50);
  assert.deepEqual(app.modules.compare.calls.filter(call => call.method === 'setValue').at(-1).options, { immediate: true });
  assert.equal(app.clock.count(), 0);
});

test('visible comparison cycles all workspaces every two seconds without touching the divider, focus or status', () => {
  const app = loadApp();
  const status = app.find('#demo-status').textContent;
  const focus = app.find('#comparison-range');
  focus.focus();
  app.modules.compare.value = 72;
  const callCount = app.moduleCalls.length;
  app.click('.site-header');
  app.clock.advance(6000);
  assertWorkspace(app, 'focus');
  app.intersect('#interactive-desktop');
  app.intersect('#interactive-desktop');
  assert.equal(app.clock.count('timeout'), 1);

  let previous = 'focus';
  for (const workspace of ['vibing', 'planning', 'focus']) {
    app.clock.advance(1999);
    assertWorkspace(app, previous);
    app.clock.advance(1);
    assertWorkspace(app, workspace);
    previous = workspace;
  }
  assert.equal(app.clock.count('timeout'), 1);
  assert.equal(app.modules.compare.value, 72);
  assert.equal(app.moduleCalls.length, callCount);
  assert.equal(app.document.activeElement, focus);
  assert.equal(app.find('#demo-status').textContent, status);
});

test('returning from offscreen, a hidden tab, shortcut mode or reduced motion starts a fresh two seconds', () => {
  const pauses = [
    [app => app.intersect('#interactive-desktop', false), app => app.intersect('#interactive-desktop')],
    [app => app.setHidden(true), app => app.setHidden(false)],
    [app => app.click('[data-demo-link="shortcut"]'), app => app.click('[data-demo-link="compare"]')],
    [app => app.setReducedMotion(true), app => app.setReducedMotion(false)],
  ];
  for (const [pause, resume] of pauses) {
    const app = loadApp();
    app.intersect('#interactive-desktop');
    app.clock.advance(1300);
    pause(app);
    assert.equal(app.clock.count('timeout'), 0);
    app.clock.advance(8000);
    assertWorkspace(app, 'focus');
    resume(app);
    app.clock.advance(1999);
    assertWorkspace(app, 'focus');
    app.clock.advance(1);
    assertWorkspace(app, 'vibing');
  }
});

test('a click on the selected workspace or a keyboard mode change permanently stops workspace cycling', () => {
  for (const interact of [
    app => app.click('[data-workspace="focus"]'),
    app => app.click('#interactive-desktop'),
    app => {
      app.key('#compare-tab', 'ArrowRight');
      app.click('[data-demo-link="compare"]');
    },
  ]) {
    const app = loadApp();
    app.intersect('#interactive-desktop');
    app.clock.advance(1999);
    interact(app);
    app.intersect('#interactive-desktop', false);
    app.intersect('#interactive-desktop');
    app.setHidden(true);
    app.setHidden(false);
    app.setReducedMotion(true);
    app.setReducedMotion(false);
    app.clock.advance(8000);
    assertWorkspace(app, 'focus');
    assert.equal(app.clock.count('timeout'), 0);
  }
});

test('divider pointer, keyboard and input controls stop playback before a workspace can change', () => {
  for (const interact of [
    app => app.find('#comparison-range').dispatch('pointerdown', { clientX: 800 }),
    app => app.key('#comparison-range', 'ArrowRight'),
    app => app.input('#comparison-range', 82),
  ]) {
    const app = loadApp({ realModules: true });
    app.intersect('#interactive-desktop');
    app.clock.advance(1999);
    interact(app);
    assert.equal(app.clock.count('timeout'), 0);
    app.clock.advance(8000);
    assertWorkspace(app, 'focus');
    assert.ok(app.modules.compare.getValue() > 50);
  }
});

test('comparison starts static when reduced motion is already enabled', () => {
  const app = loadApp({ reducedMotion: true });
  app.intersect('#interactive-desktop');
  app.clock.advance(6000);
  assertWorkspace(app, 'focus');
  assert.equal(app.clock.count('timeout'), 0);
});

for (const workspace of Object.keys(includedApps)) {
  test(`${workspace} shows only its included apps and preserves the selected divider position`, () => {
    const app = loadApp();
    // Start from other app sets to expose stale visibility from earlier workspaces.
    for (const previous of Object.keys(includedApps).filter(value => value !== workspace)) app.click(`[data-workspace="${previous}"]`);
    app.modules.compare.value = 83;
    const countBefore = app.moduleCalls.length;
    app.click(`[data-workspace="${workspace}"]`);
    assertWorkspace(app, workspace);
    assertMode(app, 'compare');
    assert.deepEqual(app.moduleCalls.slice(countBefore), []);
    assert.equal(app.modules.compare.value, 83);
    assert.match(app.find('#demo-status').textContent, new RegExp(`${includedApps[workspace].length} included windows shown after`));
    const expected = snapshot(app);
    app.clock.advance(10000);
    assert.deepEqual(snapshot(app), expected, 'no delayed restoration overwrites the selected workspace');
    assert.equal(app.clock.count(), 0);
  });
}

test('every crowded window changes geometry across workspaces, including apps absent after', () => {
  const app = loadApp();
  const layouts = [];
  for (const workspace of Object.keys(includedApps)) {
    app.click(`[data-workspace="${workspace}"]`);
    layouts.push(snapshot(app, '.before-scene'));
  }
  for (const name of allApps) {
    assert.equal(new Set(layouts.map(layout => layout[name].geometry.join(','))).size, 3,
      `${name} must move in every crowded workspace instead of staying in a parked column`);
  }
});

test('shared organized apps have distinct positions, and each organized layout fits without overlap', () => {
  const app = loadApp();
  const previous = new Map();
  for (const workspace of Object.keys(includedApps)) {
    app.click(`[data-workspace="${workspace}"]`);
    const active = windows(app, '.after-scene').filter(win => !win.hidden);
    for (const win of active) {
      const values = geometry(win);
      assert.ok(values.every(value => /^\d+(?:\.\d+)?%$/.test(value)), `${workspace}/${win.dataset.window} uses responsive percentage geometry`);
      const [left, top, width, height] = values.map(parseFloat);
      assert.ok(left >= 0 && top >= 0 && width > 0 && height > 0 && left + width <= 100 && top + height <= 100,
        `${workspace}/${win.dataset.window} fits inside the desktop`);
      const key = values.join(',');
      const seen = previous.get(win.dataset.window) || new Set();
      assert.equal(seen.has(key), false, `${win.dataset.window} should have a distinct organized position for ${workspace}`);
      seen.add(key); previous.set(win.dataset.window, seen);
    }
    for (let first = 0; first < active.length; first += 1) {
      for (let second = first + 1; second < active.length; second += 1) {
        const [x1, y1, w1, h1] = geometry(active[first]).map(parseFloat);
        const [x2, y2, w2, h2] = geometry(active[second]).map(parseFloat);
        assert.ok(x1 + w1 <= x2 || x2 + w2 <= x1 || y1 + h1 <= y2 || y2 + h2 <= y1,
          `${workspace}: ${active[first].dataset.window} and ${active[second].dataset.window} should not overlap`);
      }
    }
  }
});

test('shortcut mode hides the full comparison and activates only the independent showcase', () => {
  const app = loadApp();
  app.click('[data-workspace="planning"]');
  const before = snapshot(app, '.before-scene');
  const after = snapshot(app);
  const shortcutGeometry = geometry(app.find('#showcase-window'));
  const callStart = app.moduleCalls.length;
  app.click('#shortcut-tab');
  assertMode(app, 'shortcut');
  assert.deepEqual(app.moduleCalls.slice(callStart), [
    { module: 'compare', method: 'setActive', active: false },
    { module: 'showcase', method: 'setActive', active: true },
  ]);
  assert.deepEqual(snapshot(app, '.before-scene'), before);
  assert.deepEqual(snapshot(app), after);
  assert.deepEqual(geometry(app.find('#showcase-window')), shortcutGeometry, 'app.js leaves shortcut geometry to the showcase module');
  app.clock.advance(10000);
  assertMode(app, 'shortcut');
  assert.equal(app.clock.count(), 0);
});

test('mode roundtrips preserve the workspace and independently managed shortcut window', () => {
  const app = loadApp();
  const shortcut = app.find('#showcase-window');
  ['left', 'top', 'width', 'height'].forEach((property, index) => { shortcut.style[property] = ['57%', '11%', '31%', '67%'][index]; });
  const shortcutGeometry = geometry(shortcut);
  for (const workspace of ['planning', 'focus', 'vibing', 'planning', 'vibing', 'focus']) {
    app.modules.compare.value = 73;
    app.click(`[data-workspace="${workspace}"]`);
    const expected = snapshot(app);
    app.click('#shortcut-tab');
    assertMode(app, 'shortcut');
    app.click('#shortcut-tab');
    assertMode(app, 'shortcut');
    app.click('#compare-tab');
    assertMode(app, 'compare');
    assertWorkspace(app, workspace);
    assert.deepEqual(snapshot(app), expected);
    assert.deepEqual(geometry(shortcut), shortcutGeometry);
    assert.equal(app.modules.compare.value, 73);
  }
  app.clock.advance(10000);
  assert.equal(app.clock.count(), 0);
});

test('workspace and mode changes remain stable when reduced-motion or page visibility changes', () => {
  const app = loadApp({ reducedMotion: true });
  app.click('[data-workspace="vibing"]');
  const expected = snapshot(app);
  app.setHidden(true);
  app.setReducedMotion(false);
  app.clock.advance(10000);
  app.setHidden(false);
  assertWorkspace(app, 'vibing');
  assert.deepEqual(snapshot(app), expected);
  app.click('#shortcut-tab');
  app.setReducedMotion(true);
  app.setHidden(true);
  app.setHidden(false);
  assertMode(app, 'shortcut');
  app.click('#compare-tab');
  assertWorkspace(app, 'vibing');
  assert.deepEqual(snapshot(app), expected);
  assert.equal(app.clock.count(), 0);
});

test('mode tabs use roving focus with wrapping arrows and Home/End', () => {
  const app = loadApp();
  const steps = [
    ['#compare-tab', 'ArrowRight', 'shortcut'],
    ['#shortcut-tab', 'ArrowRight', 'compare'],
    ['#compare-tab', 'ArrowLeft', 'shortcut'],
    ['#shortcut-tab', 'Home', 'compare'],
    ['#compare-tab', 'End', 'shortcut'],
  ];
  for (const [selector, key, mode] of steps) {
    const event = app.key(selector, key);
    assert.equal(event.defaultPrevented, true);
    assertMode(app, mode);
    assert.equal(app.document.activeElement, app.find(`#${mode}-tab`));
  }
  const ignored = app.key('#shortcut-tab', 'ArrowUp');
  assert.equal(ignored.defaultPrevented, false);
  assertMode(app, 'shortcut');
});

test('feature links and installation dialog route to the same mode controller', () => {
  const app = loadApp();
  app.click('[data-demo-link="shortcut"]');
  assertMode(app, 'shortcut');
  app.click('[data-demo-link="compare"]');
  assertMode(app, 'compare');
  app.click('#shortcut-tab');
  app.click('[data-install]');
  assert.equal(app.find('#install-dialog').open, true);
  app.click('.dialog-demo');
  assert.equal(app.find('#install-dialog').open, false);
  assertMode(app, 'compare');
  assert.equal(app.document.activeElement, app.find('#comparison-range'));
});

test('manual restore/reset and shortcut action buttons are absent from the demo', () => {
  const app = loadApp();
  const demo = app.find('#workspace-demo');
  const obsolete = demo.querySelectorAll('button').filter(button => {
    const label = `${button.textContent} ${button.getAttribute('aria-label') || ''}`;
    return /\b(restore|reset|replay)\b/i.test(label) || button.hasAttribute('data-position');
  });
  assert.equal(obsolete.length, 0);
  assert.equal(app.find('.after-scene').classList.contains('restoring'), false);
  assert.equal(app.clock.count(), 0);
});

// These two smoke tests load the shipped modules together. The fixture covers
// DOM state, events and scheduling, while browser QA covers actual rendering.
test('real modules preserve the shared curve and hand off between comparison and showcase', () => {
  const app = loadApp({ realModules: true });
  const range = app.find('#comparison-range');
  app.input('#comparison-range', 82);
  assert.equal(range.value, '82');
  app.click('[data-workspace="vibing"]');
  assert.equal(range.value, '82');
  assert.equal(app.find('#interactive-desktop').style.getPropertyValue('--split'), '82%');
  assert.equal(app.find('#comparison-curve').getAttribute('d'), 'M 0.820000 0 Q 0.820000 0.5 0.820000 1');
  assert.equal(app.find('#comparison-before-path').getAttribute('d'), 'M 0 0 L 0.820000 0 Q 0.820000 0.5 0.820000 1 L 0 1 Z');
  assert.equal(app.find('#comparison-after-path').getAttribute('d'), 'M 0.820000 0 Q 0.820000 0.5 0.820000 1 L 1 1 L 1 0 Z');
  assertWorkspace(app, 'vibing');

  app.modules.compare.setValue(85); // Mode switching must stop an ongoing glide.
  assert.ok(app.clock.count('raf') > 0);
  app.click('#shortcut-tab');
  assert.equal(app.clock.count('raf'), 0);
  assert.equal(range.hidden, true);
  assert.equal(range.disabled, true);
  assert.equal(app.find('.before-scene').hidden, true);
  assert.equal(app.find('.after-scene').hidden, true);
  assert.equal(app.find('#shortcut-scene').hidden, false);
  assert.equal(app.find('#showcase-progress').textContent, '1 / 15');
  const firstStep = geometry(app.find('#showcase-window'));
  app.clock.advance(1100);
  assert.equal(app.find('#showcase-progress').textContent, '2 / 15');
  assert.notDeepEqual(geometry(app.find('#showcase-window')), firstStep);

  app.click('#compare-tab');
  assert.equal(app.clock.count(), 0, 'returning to comparison cancels showcase timers');
  assert.equal(range.hidden, false);
  assert.equal(range.disabled, false);
  assert.equal(range.value, '82');
  assert.equal(app.find('#shortcut-scene').hidden, true);
  assertWorkspace(app, 'vibing');
  const stopped = geometry(app.find('#showcase-window'));
  app.clock.advance(10000);
  assert.deepEqual(geometry(app.find('#showcase-window')), stopped);
  assert.equal(app.clock.count(), 0);
});

test('real modules keep reduced-motion showcase static and cancel animation when enabled', () => {
  const app = loadApp({ realModules: true, reducedMotion: true });
  app.click('#shortcut-tab');
  const center = geometry(app.find('#showcase-window'));
  assert.deepEqual(center, ['24%', '14%', '52%', '62%']);
  assert.equal(app.find('#showcase-progress').textContent, 'Reduced motion');
  assert.equal(app.find('#showcase-pause').hidden, true);
  assert.equal(app.clock.count(), 0);
  app.clock.advance(10000);
  assert.deepEqual(geometry(app.find('#showcase-window')), center);

  app.setReducedMotion(false);
  app.clock.advance(1100);
  assert.equal(app.find('#showcase-progress').textContent, '2 / 15');
  assert.ok(app.clock.count() > 0);
  app.setReducedMotion(true);
  assert.deepEqual(geometry(app.find('#showcase-window')), center);
  assert.equal(app.clock.count(), 0);
  app.click('#compare-tab');
  app.input('#comparison-range', 90);
  app.click('[data-workspace="planning"]');
  assert.equal(app.find('#comparison-range').value, '90');
  assertWorkspace(app, 'planning');
  assert.equal(app.clock.count(), 0);
});


test('Get started opens the guide even with a valid release destination', () => {
  const app = loadApp({ config: { repositoryUrl: 'https://github.com/example/window-tool' } });
  app.click('[data-install]');
  assert.equal(app.find('#install-dialog').open, true);
  assert.deepEqual(app.navigations, []);
  assert.equal(app.find('#release-link').hidden, false);
  assert.equal(app.find('#release-link').href, 'https://github.com/example/window-tool/releases');
  app.click('.dialog-close');
  assert.equal(app.find('#install-dialog').open, false);
});

test('configured direct release downloads remain intact in the installation guide', () => {
  const url = 'https://example.com/downloads/app.dmg';
  const app = loadApp({ config: { repositoryUrl: 'https://github.com/example/window-tool', downloadUrl: url } });
  assert.equal(app.find('#release-link').href, url);
  assert.equal(app.find('#release-link').hidden, false);
});

test('setup opens GitHub releases natively while the other installation buttons retain the guide', () => {
  const repositoryUrl = 'https://github.com/example/window-tool';
  const releasesUrl = `${repositoryUrl}/releases`;
  for (const downloadUrl of ['', 'https://example.com/downloads/app.dmg']) {
    const app = loadApp({ config: { repositoryUrl, downloadUrl } });
    const setupLink = app.find('#setup-release-link');
    const dialog = app.find('#install-dialog');
    assert.equal(setupLink.tagName, 'A');
    assert.equal(setupLink.hidden, false);
    assert.equal(setupLink.href, releasesUrl, 'setup always opens the configured repository releases');
    assert.equal(setupLink.getAttribute('target'), '_blank');
    const rel = setupLink.getAttribute('rel').split(/\s+/);
    assert.ok(rel.includes('noopener') && rel.includes('noreferrer'));
    assert.equal(setupLink.hasAttribute('data-install'), false);
    assert.equal(app.document.querySelector('#release-example-note'), null);

    const event = app.click('#setup-release-link');
    assert.equal(event.defaultPrevented, false, 'native new-tab navigation is not intercepted');
    assert.equal(Boolean(dialog.open), false, 'setup does not open the installation guide');
    assert.deepEqual(app.navigations, [], 'no script substitutes navigation for the native link');

    const buttons = app.all('[data-install]');
    assert.equal(buttons.length, 2, 'header and closing installation buttons remain');
    for (const button of buttons) {
      assert.equal(button.tagName, 'BUTTON');
      button.dispatch('click');
      assert.equal(dialog.open, true);
      assert.equal(app.find('#release-link').href, downloadUrl || releasesUrl,
        'the guide still honors a configured direct download');
      app.click('.dialog-close');
      assert.equal(dialog.open, false);
    }
  }
});
