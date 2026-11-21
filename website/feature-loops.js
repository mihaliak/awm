/* Quiet, automatic spacing and display illustrations. */
(() => {
  'use strict';
  const gap = document.getElementById('gap-preview');
  const gapValue = document.getElementById('gap-value');
  const displays = document.querySelector('.displays-card');
  const displayState = document.getElementById('display-state');
  const pause = document.getElementById('feature-motion-pause');
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const lifecycle = new AbortController();
  const { signal } = lifecycle;
  const loops = [];
  let userPaused = false;
  let destroyed = false;

  function addLoop(node, controls) {
    loops.push({ node, visible: !('IntersectionObserver' in window), ...controls });
  }

  function makeGapLoop() {
    const values = [0, 8, 16, 24, 16, 8];
    const stepDuration = 1500;
    const travelDuration = 850;
    let elapsed = 0;
    let resumedAt = null;
    let frame = 0;
    let timer = 0;
    let lastFrameEnd = 0;

    function render(value) {
      gap.style.setProperty('--gap-offset', `${(value / 2).toFixed(3)}px`);
      const label = `${Math.round(value)} pt`;
      if (gapValue.textContent !== label) gapValue.textContent = label;
    }

    function sample(time) {
      const step = Math.floor(time / stepDuration);
      const phase = time % stepDuration;
      const target = values[step % values.length];
      const from = step === 0 ? target : values[(step - 1) % values.length];
      if (from === target || phase >= travelDuration) {
        render(target);
        const remaining = stepDuration - phase;
        lastFrameEnd = time + remaining;
        timer = setTimeout(() => {
          timer = 0;
          frame = requestAnimationFrame(tick);
        }, remaining);
      } else {
        const progress = 1 - (1 - phase / travelDuration) ** 3;
        render(from + (target - from) * progress);
        lastFrameEnd = time;
        frame = requestAnimationFrame(tick);
      }
    }

    function tick(now) {
      frame = 0;
      sample(elapsed + now - resumedAt);
    }

    gapValue.setAttribute('aria-live', 'off');
    render(motion.matches ? 12 : 0);
    return {
      start() {
        if (resumedAt !== null) return;
        resumedAt = performance.now();
        sample(elapsed);
      },
      stop() {
        if (resumedAt === null) return;
        // Advance through a static hold, or freeze at the last visible travel frame.
        elapsed = Math.min(lastFrameEnd, elapsed + performance.now() - resumedAt);
        resumedAt = null;
        clearTimeout(timer);
        cancelAnimationFrame(frame);
        timer = frame = 0;
      },
      reduce() {
        elapsed = 0;
        render(12);
      },
      reset() {
        render(0);
      },
    };
  }

  function makeDisplayLoop() {
    const node = displays;
    const still = 'feature-loop-still';
    const moving = [...node.querySelectorAll('.external-monitor, .mini-laptop, .mini-laptop > div > i')];
    const properties = ['transform', 'opacity', 'width'];
    let connected = true;
    let running = false;
    let timer = 0;
    let frozen = [];

    function render() {
      node.classList.toggle('disconnected', !connected);
      displayState.textContent = connected ? 'Desk setup' : 'On the go';
    }

    function releaseFrozen() {
      for (const { element, values } of frozen) {
        for (const { property, inline } of values) {
          if (inline) element.style.setProperty(property, inline);
          else element.style.removeProperty(property);
        }
      }
      frozen = [];
    }

    function schedule() {
      timer = setTimeout(() => {
        timer = 0;
        if (document.hidden || motion.matches) { reconcile(); return; }
        connected = !connected;
        render();
        schedule();
      }, 4200);
    }

    displayState.setAttribute('aria-live', 'off');
    node.classList.add(still);
    render();
    return {
      start() {
        if (running) return;
        // Commit the frozen geometry, then continue toward the same target state.
        if (frozen.length) void node.offsetWidth;
        node.classList.remove(still);
        releaseFrozen();
        running = true;
        schedule();
      },
      stop() {
        if (!running) return;
        clearTimeout(timer);
        timer = 0;
        running = false;
        frozen = moving.map(element => {
          const computed = getComputedStyle(element);
          return {
            element,
            values: properties.map(property => ({
              property,
              current: computed.getPropertyValue(property),
              inline: element.style.getPropertyValue(property),
            })),
          };
        });
        node.classList.add(still);
        for (const { element, values } of frozen) {
          for (const { property, current } of values) {
            if (current) element.style.setProperty(property, current);
          }
        }
      },
      reduce() {
        releaseFrozen();
        connected = true;
        render();
      },
    };
  }

  if (gap && gapValue) addLoop(gap, makeGapLoop());
  if (displays && displayState) addLoop(displays, makeDisplayLoop());
  if (!loops.length) return;

  function reconcile() {
    if (pause) {
      pause.hidden = motion.matches;
      pause.textContent = userPaused ? 'Resume animations' : 'Pause animations';
      pause.setAttribute('aria-label', `${userPaused ? 'Resume' : 'Pause'} spacing and display animations`);
    }
    for (const loop of loops) {
      if (!destroyed && !userPaused && !motion.matches && !document.hidden && loop.visible) {
        loop.start();
      } else {
        loop.stop();
        if (motion.matches) loop.reduce();
      }
    }
  }

  function setPaused(value) {
    if (destroyed) return;
    userPaused = Boolean(value);
    reconcile();
  }

  pause?.addEventListener('click', () => setPaused(!userPaused), { signal });
  document.addEventListener('visibilitychange', reconcile, { signal });
  motion.addEventListener('change', () => {
    if (!motion.matches) for (const loop of loops) loop.reset?.();
    reconcile();
  }, { signal });
  const observer = 'IntersectionObserver' in window
    ? new IntersectionObserver(entries => {
      for (const entry of entries) {
        const loop = loops.find(item => item.node === entry.target);
        if (loop) loop.visible = entry.isIntersecting;
      }
      reconcile();
    })
    : null;
  for (const loop of loops) observer?.observe(loop.node);

  window.FeatureLoops = Object.freeze({
    setPaused,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      loops.forEach(loop => loop.stop());
      lifecycle.abort();
      observer?.disconnect();
    },
  });
  reconcile();
})();
