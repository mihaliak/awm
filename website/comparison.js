/*
 * MIT License
 *
 * Copyright (c) 2026 Lorenzo Cabra
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
'use strict';

(() => {
  const desktop = document.querySelector('#interactive-desktop');
  const range = document.querySelector('#comparison-range');
  const handle = document.querySelector('#comparison-handle');
  const beforePath = document.querySelector('#comparison-before-path');
  const afterPath = document.querySelector('#comparison-after-path');
  const curve = document.querySelector('#comparison-curve');
  if (![desktop, range, handle, beforePath, afterPath, curve].every(Boolean)) return;

  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
  const MAX_BEND = 9 / 270; // Reference cap is 9px in a 270px-wide component.
  let current = 0.5, target = null, frame = 0, previousTime = 0;
  let active = true, drag = null;
  const ends = { x: 0.5, velocity: 0 };

  function paint() {
    const bend = active ? clamp((current - ends.x) * 0.5, -MAX_BEND, MAX_BEND) : 0;
    const position = active ? current : 0;
    const edge = (position - bend).toFixed(6);
    const control = (position + bend).toFixed(6);
    // Complementary masks meet on exactly the same quadratic boundary. Clipping
    // both scenes prevents shadows on the bottom scene showing through the top.
    const boundary = `M ${edge} 0 Q ${control} 0.5 ${edge} 1`;
    curve.setAttribute('d', boundary);
    beforePath.setAttribute('d', `M 0 0 L ${edge} 0 Q ${control} 0.5 ${edge} 1 L 0 1 Z`);
    afterPath.setAttribute('d', `${boundary} L 1 1 L 1 0 Z`);
    const percent = current * 100;
    desktop.style.setProperty('--split', `${percent}%`);
    handle.style.left = `${percent}%`;
    range.value = String(percent);
    range.setAttribute('aria-valuenow', String(Math.round(percent)));
    range.setAttribute('aria-valuetext', `${Math.round(percent)} percent before, ${Math.round(100 - percent)} percent organized`);
    desktop.dataset.comparison = !active || current === 0 ? 'after' : current === 1 ? 'before' : 'split';
  }

  function stopMotion() {
    cancelAnimationFrame(frame);
    frame = 0; previousTime = 0; target = null;
    ends.x = current; ends.velocity = 0;
    paint();
  }

  function canAnimate() { return active && !motion.matches && !document.hidden; }

  function tick(time) {
    frame = 0;
    if (!canAnimate()) { stopMotion(); return; }
    const dt = Math.min(0.033, Math.max(0, (time - previousTime) / 1000));
    previousTime = time;
    if (target !== null) {
      current += (target - current) * (1 - Math.pow(0.0004, dt));
      if (Math.abs(target - current) < 0.0005) { current = target; target = null; }
    }
    ends.velocity += ((current - ends.x) * 620 - ends.velocity * 44) * dt;
    ends.x += ends.velocity * dt;
    const still = target === null && Math.abs(current - ends.x) < 0.0006 && Math.abs(ends.velocity) < 0.002;
    if (still) {
      ends.x = current; ends.velocity = 0; previousTime = 0;
      paint();
      return;
    }
    paint();
    frame = requestAnimationFrame(tick);
  }

  function startLoop() {
    if (frame || !canAnimate()) return;
    previousTime = performance.now();
    frame = requestAnimationFrame(tick);
  }

  function place(value) {
    current = clamp(value, 0, 1); target = null;
    if (!canAnimate()) { stopMotion(); return; }
    paint(); startLoop();
  }

  function glide(value) {
    value = clamp(value, 0, 1);
    if (!canAnimate()) { current = value; stopMotion(); return; }
    target = value;
    startLoop();
  }

  function releaseDrag() {
    const pointerId = drag?.id;
    drag = null;
    desktop.classList.remove('is-comparing');
    if (pointerId !== undefined && range.hasPointerCapture(pointerId)) {
      try { range.releasePointerCapture(pointerId); } catch { /* Capture already ended. */ }
    }
  }

  function setValue(percent, { immediate = false } = {}) {
    const value = Number(percent);
    if (!Number.isFinite(value)) return;
    releaseDrag();
    if (immediate || !canAnimate()) {
      current = clamp(value / 100, 0, 1);
      stopMotion();
    } else glide(value / 100);
  }

  function setActive(value) {
    releaseDrag();
    active = Boolean(value);
    range.disabled = !active;
    range.hidden = !active;
    range.tabIndex = active ? 0 : -1;
    handle.hidden = !active;
    curve.style.display = active ? '' : 'none';
    stopMotion();
  }

  function at(clientX) {
    const bounds = desktop.getBoundingClientRect();
    return bounds.width > 0 ? clamp((clientX - bounds.left) / bounds.width, 0, 1) : current;
  }

  range.addEventListener('pointerdown', event => {
    if (!active || drag || event.isPrimary === false || (event.pointerType === 'mouse' && event.button !== 0)) return;
    event.preventDefault();
    const value = at(event.clientX);
    drag = { id: event.pointerId, velocity: 0, time: performance.now(), last: value };
    try { range.setPointerCapture(event.pointerId); } catch { /* Synthetic pointer or capture unavailable. */ }
    range.focus({ preventScroll: true });
    desktop.classList.add('is-comparing');
    glide(value);
  });

  range.addEventListener('pointermove', event => {
    if (!active || !drag || drag.id !== event.pointerId) return;
    const value = at(event.clientX), now = performance.now();
    drag.velocity = (value - drag.last) / Math.max(1, now - drag.time);
    drag.time = now; drag.last = value;
    place(value);
  });

  range.addEventListener('pointerup', event => {
    if (!drag || drag.id !== event.pointerId) return;
    const lastDrag = drag;
    // Browsers may deliver the last coordinate only with pointerup. Commit a
    // changed sample; a click ending where it began keeps its click-to-glide.
    const finalValue = Number.isFinite(event.clientX) ? at(event.clientX) : lastDrag.last;
    if (Math.abs(finalValue - lastDrag.last) > 1e-7) {
      const now = performance.now();
      lastDrag.velocity = (finalValue - lastDrag.last) / Math.max(1, now - lastDrag.time);
      lastDrag.time = now; lastDrag.last = finalValue;
      place(finalValue);
    }
    releaseDrag();
    // Use only recent drag velocity so a paused drag cannot fling to an edge.
    if (performance.now() - lastDrag.time < 120 && Math.abs(lastDrag.velocity) > 0.0025) {
      glide(lastDrag.velocity > 0 ? 1 : 0);
    }
  });

  range.addEventListener('pointercancel', event => {
    if (!drag || drag.id !== event.pointerId) return;
    releaseDrag(); target = null;
    if (!canAnimate()) stopMotion();
  });
  range.addEventListener('lostpointercapture', event => {
    if (drag?.id === event.pointerId) {
      drag = null;
      desktop.classList.remove('is-comparing');
    }
  });
  range.addEventListener('input', () => { if (active) setValue(range.value, { immediate: true }); });
  range.addEventListener('keydown', event => {
    if (!active) return;
    const step = event.shiftKey ? 0.1 : 0.01;
    const value = target ?? current;
    const values = { ArrowLeft: value - step, ArrowDown: value - step, ArrowRight: value + step, ArrowUp: value + step, Home: 0, End: 1 };
    if (!(event.key in values)) return;
    event.preventDefault(); releaseDrag(); glide(values[event.key]);
  });
  motion.addEventListener('change', () => {
    if (!motion.matches) return;
    releaseDrag();
    if (target !== null) current = target;
    stopMotion();
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { releaseDrag(); stopMotion(); }
  });

  window.WorkspaceCompare = Object.freeze({ setValue, setActive, getValue: () => current * 100 });
  setActive(true);
})();
