/* Particle wordmarks with static text and an optional logo. */
(() => {
  'use strict';

  if (window.WorkspaceParticles?.init) {
    window.WorkspaceParticles.init();
    return;
  }

  function createParticles(host, onDestroy) {
    const canvas = host.querySelector('canvas');
    const fallback = host.querySelector('.particle-fallback');
    if (!canvas || !fallback) return null;

    const context = canvas.getContext('2d', { alpha: true });
    if (!context) return null;
    const textSlot = host.querySelector('[data-particle-text]') || host;
    const logo = host.querySelector('.intro-logo');

    let lines = ['Another Window', 'Management'];
    const customLines = host.getAttribute('data-lines');
    if (customLines) {
      let parsed;
      try { parsed = JSON.parse(customLines); }
      catch { parsed = customLines.split(/\n|\|/); }
      if (Array.isArray(parsed)) {
        const valid = parsed.filter(line => typeof line === 'string').map(line => line.trim()).filter(Boolean).slice(0, 3);
        if (valid.length) lines = valid;
      }
    }

    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
    const lifetime = new AbortController();
    const { signal } = lifetime;
    const colors = ['#eeeae7', '#b2adb5', '#faf6f2', '#7a5cff'];
    const original = {
      role: host.getAttribute('role'),
      tabindex: host.getAttribute('tabindex'),
      label: host.getAttribute('aria-label'),
      fallbackHidden: fallback.getAttribute('aria-hidden'),
      fallbackVisibility: fallback.style.visibility,
      logoVisibility: logo?.style.visibility,
      canvasStyle: canvas.getAttribute('style'),
      canvasWidth: canvas.getAttribute('width'),
      canvasHeight: canvas.getAttribute('height'),
      position: host.style.position,
    };
    let particles = [];
    let width = 0;
    let height = 0;
    let overscan = 0;
    let frame = 0;
    let resizeFrame = 0;
    let previousTime = 0;
    let quietFrames = 0;
    let moving = false;
    let destroyed = false;
    let ready = false;
    let visible = false;
    let dirty = true;
    const pointer = { x: 0, y: 0, active: false };

    if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
    Object.assign(canvas.style, {
      position: 'absolute', inset: '0 auto auto 0', width: '100%', height: '100%',
      pointerEvents: 'none', visibility: 'hidden',
    });

    function restoreAttribute(element, name, value) {
      if (value === null) element.removeAttribute(name);
      else element.setAttribute(name, value);
    }

    function showFallback() {
      ready = false;
      host.classList.remove('particles-ready');
      canvas.style.visibility = 'hidden';
      fallback.style.visibility = original.fallbackVisibility;
      if (logo) logo.style.visibility = original.logoVisibility;
      restoreAttribute(fallback, 'aria-hidden', original.fallbackHidden);
      restoreAttribute(host, 'role', original.role);
      restoreAttribute(host, 'tabindex', original.tabindex);
      restoreAttribute(host, 'aria-label', original.label);
    }

    function showCanvas(logoSampled) {
      ready = true;
      canvas.style.visibility = 'visible';
      fallback.style.visibility = 'hidden';
      if (logo) logo.style.visibility = logoSampled ? 'hidden' : original.logoVisibility;
      fallback.setAttribute('aria-hidden', 'true');
      host.classList.add('particles-ready');
      host.setAttribute('role', 'button');
      host.setAttribute('tabindex', '0');
      host.setAttribute('aria-label', `${lines.join(' ')}. Move your pointer to play; click or press Enter or Space to scatter the particles.`);
    }

    function draw() {
      context.clearRect(-overscan, -overscan, width + overscan * 2, height + overscan * 2);
      // Four batched paths avoid changing fill style for every individual dot.
      for (let color = 0; color < colors.length; color += 1) {
        context.beginPath();
        for (const particle of particles) {
          if (particle.color !== color) continue;
          context.moveTo(particle.x + particle.radius, particle.y);
          context.arc(particle.x, particle.y, particle.radius, 0, Math.PI * 2);
        }
        context.fillStyle = colors[color];
        context.fill();
      }
    }

    function stop() {
      cancelAnimationFrame(frame);
      frame = 0;
      previousTime = 0;
    }

    function requestFrame() {
      if (frame || destroyed || !ready || reducedMotion.matches || !visible || document.hidden || !moving) return;
      frame = requestAnimationFrame(tick);
    }

    function wake() {
      quietFrames = 0;
      moving = true;
      requestFrame();
    }

    function tick(time) {
      frame = 0;
      if (destroyed || reducedMotion.matches || !visible || document.hidden || !moving) {
        previousTime = 0;
        return;
      }

      const delta = previousTime ? Math.min((time - previousTime) / 16.667, 2) : 1;
      previousTime = time;
      const friction = Math.pow(0.85, delta);
      const radius = Math.max(62, Math.min(150, width * 0.12));
      const radiusSquared = radius * radius;
      let maxSpeed = 0;

      for (const particle of particles) {
        let forceX = (particle.homeX - particle.x) * 0.021;
        let forceY = (particle.homeY - particle.y) * 0.021;
        if (pointer.active) {
          const dx = particle.x - pointer.x;
          const dy = particle.y - pointer.y;
          const distanceSquared = dx * dx + dy * dy;
          if (distanceSquared < radiusSquared) {
            const distance = Math.max(0.1, Math.sqrt(distanceSquared));
            const force = Math.pow(1 - distance / radius, 2) * 2.4;
            forceX += (dx / distance) * force;
            forceY += (dy / distance) * force;
          }
        }
        particle.vx = (particle.vx + forceX * delta) * friction;
        particle.vy = (particle.vy + forceY * delta) * friction;
        particle.x += particle.vx * delta;
        particle.y += particle.vy * delta;
        maxSpeed = Math.max(maxSpeed, Math.abs(particle.vx), Math.abs(particle.vy));
      }

      quietFrames = maxSpeed < 0.035 ? quietFrames + 1 : 0;
      if (quietFrames > 16) {
        moving = false;
        previousTime = 0;
        // Finish exactly on the letterform rather than accumulating subpixel drift.
        if (!pointer.active) {
          for (const particle of particles) {
            particle.x = particle.homeX;
            particle.y = particle.homeY;
            particle.vx = 0;
            particle.vy = 0;
          }
        }
      }
      draw();
      requestFrame();
    }

    function rebuild() {
      if (destroyed) return;
      if (reducedMotion.matches || document.hidden) { dirty = true; return; }
      const bounds = host.getBoundingClientRect();
      const textBounds = textSlot === host ? bounds : textSlot.getBoundingClientRect();
      const nextWidth = Math.floor(bounds.width);
      const nextHeight = Math.floor(bounds.height);
      const textWidth = Math.floor(textBounds.width);
      const textHeight = Math.floor(textBounds.height);
      if (nextWidth < 50 || nextHeight < 30 || textWidth < 50 || textHeight < 30) {
        stop();
        pointer.active = false;
        moving = false;
        dirty = true;
        showFallback();
        particles = [];
        canvas.width = canvas.height = 0;
        return;
      }
      stop();
      dirty = false;
      width = nextWidth;
      height = nextHeight;
      // Keep the mask and interaction coordinates host-local. Only the canvas
      // on screen extends beyond the slot so scattered dots can travel freely.
      overscan = logo ? Math.round(Math.min(120, Math.max(96, width * 0.12))) : 0;
      const displayWidth = width + overscan * 2;
      const displayHeight = height + overscan * 2;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      Object.assign(canvas.style, {
        left: `${-overscan}px`, top: `${-overscan}px`,
        width: `${displayWidth}px`, height: `${displayHeight}px`,
      });
      canvas.width = Math.round(displayWidth * dpr);
      canvas.height = Math.round(displayHeight * dpr);
      context.setTransform(dpr, 0, 0, dpr, overscan * dpr, overscan * dpr);

      const mask = document.createElement('canvas');
      mask.width = width;
      mask.height = height;
      const maskContext = mask.getContext('2d', { willReadFrequently: true });
      if (!maskContext) {
        dirty = true;
        showFallback();
        return;
      }

      const family = getComputedStyle(fallback).fontFamily || 'Arial, sans-serif';
      maskContext.font = `600 100px ${family}`;
      const textRatio = Math.max(...lines.map(line => maskContext.measureText(line).width)) / 100;
      const fontSize = Math.min(textWidth * 0.94 / Math.max(textRatio, 0.1), textHeight * 0.8 / (lines.length * 1.05));
      const textLeft = textBounds.left - bounds.left;
      const textTop = textBounds.top - bounds.top;
      function drawTextMask() {
        maskContext.font = `600 ${fontSize}px ${family}`;
        maskContext.textAlign = 'center';
        maskContext.textBaseline = 'middle';
        maskContext.fillStyle = '#fff';
        lines.forEach((line, index) => {
          maskContext.fillText(
            line,
            textLeft + textWidth / 2,
            textTop + textHeight / 2 + (index - (lines.length - 1) / 2) * fontSize * 1.12,
          );
        });
      }
      drawTextMask();

      let logoRect;
      let pixels;
      if (logo?.complete && logo.naturalWidth && logo.naturalHeight) {
        const logoBounds = logo.getBoundingClientRect();
        const scale = Math.min(logoBounds.width / logo.naturalWidth, logoBounds.height / logo.naturalHeight);
        if (scale > 0) {
          const logoWidth = logo.naturalWidth * scale;
          const logoHeight = logo.naturalHeight * scale;
          const x = logoBounds.left - bounds.left + (logoBounds.width - logoWidth) / 2;
          const y = logoBounds.top - bounds.top + (logoBounds.height - logoHeight) / 2;
          try {
            maskContext.drawImage(logo, x, y, logoWidth, logoHeight);
            pixels = maskContext.getImageData(0, 0, width, height).data;
            logoRect = {
              left: Math.floor(x), top: Math.floor(y),
              right: Math.ceil(x + logoWidth), bottom: Math.ceil(y + logoHeight),
            };
          } catch {
            // Reset the mask if the image cannot be drawn or read back.
            mask.width = width;
            drawTextMask();
          }
        }
      }
      if (!pixels) pixels = maskContext.getImageData(0, 0, width, height).data;

      function sample(step) {
        const points = [];
        for (let y = step / 2; y < height; y += step) {
          for (let x = step / 2; x < width; x += step) {
            const offset = (Math.floor(y) * width + Math.floor(x)) * 4;
            if (pixels[offset + 3] > 110) points.push([x, y]);
          }
        }
        return points;
      }

      let spacing = Math.max(2.15, Math.sqrt(textWidth * textHeight / 24000));
      let points = sample(spacing);
      if (points.length > 3600) {
        spacing *= Math.sqrt(points.length / 3500);
        points = sample(spacing);
      }
      // Cap all viewport sizes, including very large external displays.
      const count = Math.min(points.length, 3800);
      particles = [];
      for (let index = 0; index < count; index += 1) {
        const [x, y] = points[Math.floor(index * points.length / count)];
        const seed = (Math.floor(x) * 73 + Math.floor(y) * 97) % 100;
        particles.push({
          homeX: x, homeY: y, x, y, vx: 0, vy: 0,
          radius: Math.max(0.8, Math.min(1.45, spacing * (seed % 3 === 0 ? 0.31 : 0.25))),
          color: seed < 5 ? 3 : seed < 16 ? 2 : seed < 37 ? 1 : 0,
        });
      }

      if (!particles.some(particle => particle.homeY >= textTop && particle.homeY < textTop + textHeight)) {
        showFallback();
        return;
      }
      const logoSampled = Boolean(logoRect && particles.some(({ homeX, homeY }) =>
        homeX >= logoRect.left && homeX < logoRect.right && homeY >= logoRect.top && homeY < logoRect.bottom
      ));
      pointer.active = false;
      moving = false;
      draw();
      showCanvas(logoSampled);
    }

    function scheduleRebuild() {
      dirty = true;
      cancelAnimationFrame(resizeFrame);
      resizeFrame = 0;
      if (destroyed || reducedMotion.matches || document.hidden || !visible) return;
      resizeFrame = requestAnimationFrame(() => {
        resizeFrame = 0;
        rebuild();
      });
    }

    logo?.addEventListener('load', scheduleRebuild, { signal });
    logo?.addEventListener('error', scheduleRebuild, { signal });

    function disperse(x = width / 2, y = height / 2) {
      if (!ready || reducedMotion.matches || destroyed || !visible || document.hidden) return;
      const reach = Math.max(width * 0.72, height * 1.15);
      for (const particle of particles) {
        const dx = particle.x - x;
        const dy = particle.y - y;
        const distance = Math.max(1, Math.hypot(dx, dy));
        const strength = Math.max(0, 1 - distance / reach) * 19;
        particle.vx += dx / distance * strength;
        particle.vy += dy / distance * strength;
      }
      wake();
    }

    host.addEventListener('pointermove', event => {
      if (!ready || !visible || document.hidden || event.pointerType === 'touch') return;
      const bounds = host.getBoundingClientRect();
      pointer.x = event.clientX - bounds.left;
      pointer.y = event.clientY - bounds.top;
      pointer.active = true;
      wake();
    }, { passive: true, signal });

    function releasePointer() {
      if (!pointer.active) return;
      pointer.active = false;
      wake();
    }
    host.addEventListener('pointerleave', releasePointer, { passive: true, signal });
    host.addEventListener('pointercancel', releasePointer, { passive: true, signal });
    host.addEventListener('blur', releasePointer, { signal });
    window.addEventListener('blur', releasePointer, { signal });
    host.addEventListener('click', event => {
      const bounds = host.getBoundingClientRect();
      if (event.detail === 0) disperse();
      else disperse(event.clientX - bounds.left, event.clientY - bounds.top);
    }, { signal });
    host.addEventListener('keydown', event => {
      if (event.target !== host || event.isComposing || !ready || (event.key !== 'Enter' && event.key !== ' ')) return;
      event.preventDefault();
      if (!event.repeat) disperse();
    }, { signal });

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        releasePointer();
        stop();
        cancelAnimationFrame(resizeFrame);
        resizeFrame = 0;
      }
      else if (visible && dirty) rebuild();
      else requestFrame();
    }, { signal });

    const intersectionObserver = 'IntersectionObserver' in window
      ? new IntersectionObserver(entries => {
        visible = entries[0].isIntersecting;
        if (!visible) {
          releasePointer();
          stop();
          cancelAnimationFrame(resizeFrame);
          resizeFrame = 0;
        } else if (dirty || !ready) rebuild();
        else requestFrame();
      }, { threshold: 0 })
      : null;
    if (intersectionObserver) intersectionObserver.observe(host);
    else visible = true;

    const resizeObserver = 'ResizeObserver' in window ? new ResizeObserver(scheduleRebuild) : null;
    if (resizeObserver) resizeObserver.observe(host);
    else window.addEventListener('resize', scheduleRebuild, { passive: true, signal });

    reducedMotion.addEventListener('change', () => {
      stop();
      cancelAnimationFrame(resizeFrame);
      resizeFrame = 0;
      pointer.active = false;
      moving = false;
      dirty = true;
      if (reducedMotion.matches) showFallback();
      else if (visible && !document.hidden) rebuild();
    }, { signal });

    if (!reducedMotion.matches) rebuild();
    if (document.fonts?.ready) document.fonts.ready.then(() => {
      if (!destroyed && !reducedMotion.matches) scheduleRebuild();
    });

    const instance = Object.freeze({
      host,
      canvas,
      disperse,
      destroy() {
        if (destroyed) return;
        destroyed = true;
        stop();
        cancelAnimationFrame(resizeFrame);
        lifetime.abort();
        intersectionObserver?.disconnect();
        resizeObserver?.disconnect();
        showFallback();
        host.style.position = original.position;
        restoreAttribute(canvas, 'style', original.canvasStyle);
        restoreAttribute(canvas, 'width', original.canvasWidth);
        restoreAttribute(canvas, 'height', original.canvasHeight);
        particles = [];
        onDestroy(instance);
      },
    });
    return instance;
  }

  const instances = new Map();
  function remove(instance) {
    if (instances.get(instance.host) === instance) instances.delete(instance.host);
    if (window.AWMParticles === instance) delete window.AWMParticles;
  }
  function init() {
    const hosts = new Set(document.querySelectorAll('[data-particle-wordmark], #particle-wordmark'));
    for (const host of hosts) {
      if (instances.has(host)) continue;
      const instance = createParticles(host, remove);
      if (instance) instances.set(host, instance);
    }
    const footer = document.getElementById('particle-wordmark');
    if (footer && instances.has(footer)) window.AWMParticles = instances.get(footer);
    return Object.freeze([...instances.values()]);
  }
  window.WorkspaceParticles = Object.freeze({
    get instances() { return Object.freeze([...instances.values()]); },
    init,
    destroy() { [...instances.values()].forEach(instance => instance.destroy()); },
  });
  init();
})();
