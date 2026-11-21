/* One window, fifteen automatic moves. No action controls or background windows. */
(() => {
  'use strict';

  const win = document.getElementById('showcase-window');
  const label = document.getElementById('showcase-label');
  const progress = document.getElementById('showcase-progress');
  if (!win || !label || !progress) return;
  const scene = win.closest('.shortcut-scene') || win.parentElement;
  const keys = [...document.querySelectorAll('[data-showcase-key]')];
  let pause = document.getElementById('showcase-pause');
  if (!pause) {
    pause = document.createElement('button');
    pause.id = 'showcase-pause';
    pause.type = 'button';
    label.parentElement.append(pause);
  }
  pause.setAttribute('aria-controls', 'showcase-window');
  label.setAttribute('aria-live', 'off');
  progress.setAttribute('aria-live', 'off');

  const center = [24, 14, 52, 62];
  const steps = [
    { key: 'left', label: 'Left · one third', box: [3, 9, 94 / 3, 71], hold: 1100 },
    { key: 'left', label: 'Left · one half', box: [3, 9, 47, 71], hold: 1100 },
    { key: 'left', label: 'Left · two thirds', box: [3, 9, 188 / 3, 71], hold: 1100 },
    { key: 'right', label: 'Right · one third', box: [97 - 94 / 3, 9, 94 / 3, 71], hold: 1100 },
    { key: 'right', label: 'Right · one half', box: [50, 9, 47, 71], hold: 1100 },
    { key: 'right', label: 'Right · two thirds', box: [97 - 188 / 3, 9, 188 / 3, 71], hold: 1100 },
    { key: 'top', label: 'Top · one third', box: [3, 9, 94, 71 / 3], hold: 1100 },
    { key: 'top', label: 'Top · one half', box: [3, 9, 94, 71 / 2], hold: 1100 },
    { key: 'top', label: 'Top · two thirds', box: [3, 9, 94, 142 / 3], hold: 1100 },
    { key: 'bottom', label: 'Bottom · one third', box: [3, 80 - 71 / 3, 94, 71 / 3], hold: 1100 },
    { key: 'bottom', label: 'Bottom · one half', box: [3, 80 - 71 / 2, 94, 71 / 2], hold: 1100 },
    { key: 'bottom', label: 'Bottom · two thirds', box: [3, 80 - 142 / 3, 94, 142 / 3], hold: 1100 },
    { key: 'center', label: 'Centered', box: center, hold: 1350 },
    { key: 'enter', label: 'Fill display', box: [3, 9, 94, 71], hold: 1350 },
    { key: 'enter', label: 'Center · restored', box: center, hold: 2600 },
  ];
  const properties = ['left', 'top', 'width', 'height'];
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const lifecycle = new AbortController();
  const { signal } = lifecycle;
  let enabled = false;
  let userPaused = false;
  let visible = true;
  let running = false;
  let destroyed = false;
  let index = -1;
  let stepTimer = 0;
  let pulseTimer = 0;

  function geometry(box) {
    properties.forEach((property, offset) => { win.style[property] = `${box[offset]}%`; });
  }
  function clearPulse() {
    clearTimeout(pulseTimer);
    pulseTimer = 0;
    keys.forEach(key => key.classList.remove('is-active'));
  }
  function clearTimers() {
    clearTimeout(stepTimer);
    stepTimer = 0;
    clearPulse();
  }
  function freeze() {
    // Capture an in-flight CSS transition before switching it off.
    const computed = getComputedStyle(win);
    const current = properties.map(property => computed.getPropertyValue(property));
    win.classList.add('showcase-still');
    properties.forEach((property, offset) => {
      if (current[offset]) win.style[property] = current[offset];
    });
  }
  function staticCenter() {
    win.classList.add('showcase-still');
    geometry(center);
    label.textContent = 'Centered';
    progress.textContent = motion.matches ? 'Reduced motion' : 'Automatic preview';
  }
  function updatePause() {
    pause.hidden = motion.matches;
    pause.textContent = userPaused ? 'Resume' : 'Pause';
    pause.setAttribute('aria-label', `${userPaused ? 'Resume' : 'Pause'} automatic window showcase`);
  }
  function canRun() {
    return enabled && !userPaused && visible && !document.hidden && !motion.matches && !destroyed;
  }
  function showStep(next, pulse = true) {
    if (!canRun()) return;
    index = next;
    const step = steps[index];
    // Commit the centered or paused geometry before resuming transitions.
    if (win.classList.contains('showcase-still')) void win.offsetWidth;
    win.classList.remove('showcase-still');
    geometry(step.box);
    label.textContent = step.label;
    progress.textContent = `${index + 1} / ${steps.length}`;
    clearPulse();
    if (pulse) {
      keys.forEach(key => key.classList.toggle('is-active', key.dataset.showcaseKey === step.key));
      pulseTimer = setTimeout(clearPulse, 180);
    }
    stepTimer = setTimeout(() => {
      stepTimer = 0;
      showStep((index + 1) % steps.length);
    }, step.hold);
  }
  function reconcile() {
    updatePause();
    if (!canRun()) {
      if (running) freeze();
      running = false;
      clearTimers();
      if (motion.matches) staticCenter();
      return;
    }
    if (running) return;
    running = true;
    showStep(index < 0 ? 0 : index, index < 0);
  }
  function setActive(value) {
    if (destroyed || enabled === Boolean(value)) return;
    enabled = Boolean(value);
    if (!enabled) {
      running = false;
      clearTimers();
      index = -1;
      staticCenter();
      updatePause();
    } else reconcile();
  }

  pause.addEventListener('click', () => {
    if (motion.matches) return;
    userPaused = !userPaused;
    reconcile();
  }, { signal });
  document.addEventListener('visibilitychange', reconcile, { signal });
  motion.addEventListener('change', () => {
    if (motion.matches) index = -1;
    reconcile();
  }, { signal });
  const observer = 'IntersectionObserver' in window
    ? new IntersectionObserver(entries => {
      visible = entries[0].isIntersecting;
      reconcile();
    })
    : null;
  observer?.observe(scene);

  staticCenter();
  updatePause();
  window.WorkspaceShowcase = Object.freeze({
    setActive,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      running = false;
      clearTimers();
      lifecycle.abort();
      observer?.disconnect();
      staticCenter();
    },
  });
  // App mode may have initialized before this deferred script loads.
  setActive(document.querySelector('#workspace-demo')?.dataset.mode === 'shortcut');
})();
