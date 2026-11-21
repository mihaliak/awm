'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { loadApp } = require('./helpers/dom-harness.cjs');

function openGuide(options) {
  const app = loadApp(options);
  const dialog = app.find('#install-dialog');
  app.click('[data-install]');
  assert.equal(dialog.open, true);
  return { app, dialog };
}

function mockFade(dialog) {
  let finish, cancel;
  const finished = new Promise((resolve, reject) => {
    finish = resolve;
    cancel = reject;
  });
  let animationChecks = 0;
  dialog.getAnimations = () => {
    assert.ok(dialog.classList.contains('is-closing'));
    animationChecks++;
    return [
      { animationName: 'install-fade-in' },
      { animationName: 'install-fade-out', finished },
    ];
  };
  return { finished, finish, cancel, checks: () => animationChecks };
}

test('Close, Escape and backdrop clicks keep the guide modal through one exit fade', async () => {
  const close = (app) => app.click('.dialog-close');
  const escape = (_app, dialog) => assert.ok(dialog.dispatch('cancel').defaultPrevented);
  const backdrop = (_app, dialog) => dialog.dispatch('click', { clientX: 0, clientY: 0 });

  for (const dismiss of [close, escape, backdrop]) {
    const { app, dialog } = openGuide();
    const fade = mockFade(dialog);
    dialog.dispatch('click', { clientX: 150, clientY: 100 });
    assert.equal(fade.checks(), 0);
    dismiss(app, dialog);
    assert.equal(dialog.open, true);
    escape(app, dialog);
    assert.equal(fade.checks(), 1);

    fade.finish();
    await fade.finished;
    assert.equal(dialog.open, false);
    assert.equal(dialog.classList.contains('is-closing'), false);
    app.click('[data-install]');
    assert.equal(dialog.open, true);
  }
});

test('Explore switches modes and focuses the comparison only after the guide closes', async () => {
  const { app, dialog } = openGuide();
  const fade = mockFade(dialog);
  const demo = app.find('#workspace-demo');
  const comparison = app.find('#comparison-range');
  app.click('#shortcut-tab');
  app.find('.dialog-demo').focus();
  app.click('.dialog-demo');
  app.click('.dialog-demo');
  assert.equal(fade.checks(), 1);
  assert.equal(dialog.open, true);
  assert.equal(demo.dataset.mode, 'shortcut');
  assert.equal(demo.scrollOptions, undefined);
  assert.equal(app.document.activeElement, app.find('.dialog-demo'));

  fade.finish();
  await fade.finished;
  assert.equal(dialog.open, false);
  assert.equal(demo.dataset.mode, 'compare');
  assert.equal(demo.scrollOptions.behavior, 'smooth');
  assert.equal(app.document.activeElement, comparison);
});

test('cancelling the exit animation still closes the guide', async () => {
  const { app, dialog } = openGuide();
  const fade = mockFade(dialog);
  app.click('.dialog-close');
  fade.cancel(new Error('Animation cancelled'));
  await assert.rejects(fade.finished);
  assert.equal(dialog.open, false);
  assert.equal(dialog.classList.contains('is-closing'), false);
});

test('reduced motion and unavailable animations close the guide immediately', () => {
  const scenarios = [
    { options: { reducedMotion: true }, getAnimations: () => assert.fail('reduced motion skips the fade') },
    { getAnimations: undefined },
    { getAnimations: () => [] },
  ];

  for (const { options, getAnimations } of scenarios) {
    const { app, dialog } = openGuide(options);
    dialog.getAnimations = getAnimations;
    app.click('.dialog-close');
    assert.equal(dialog.open, false);
    assert.equal(dialog.classList.contains('is-closing'), false);
  }
});
