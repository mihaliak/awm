/* Once-only reveals. Content stays visible unless observation is available. */
(() => {
  'use strict';
  if (window.WorkspaceScrollMotion) return;
  const blocks = [...document.querySelectorAll('[data-reveal]')];
  if (!blocks.length) return;
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const lifetime = new AbortController();
  const { signal } = lifetime;
  const pending = new Set();
  const entering = new Set();
  let observer;
  let stopped = false;

  function clean(block) {
    block.classList.remove('reveal-pending', 'reveal-entering');
    block.style.removeProperty('--reveal-delay');
    pending.delete(block);
    entering.delete(block);
    observer?.unobserve(block);
  }
  function finishIfDone() {
    if (!pending.size) observer?.disconnect();
    if (!pending.size && !entering.size) lifetime.abort();
  }
  function stop() {
    stopped = true;
    blocks.forEach(clean);
    observer?.disconnect();
    lifetime.abort();
  }
  function reveal(block, animate = false) {
    if (!pending.has(block) && !entering.has(block)) return;
    if (!animate || motion.matches) clean(block);
    else if (pending.delete(block)) {
      const delay = Math.min(180, Math.max(0, Number(block.getAttribute('data-reveal-delay')) || 0));
      block.style.setProperty('--reveal-delay', `${delay}ms`);
      block.classList.add('reveal-entering');
      block.classList.remove('reveal-pending');
      entering.add(block);
      observer?.unobserve(block);
    }
    finishIfDone();
  }
  function revealTarget(target, includeChildren = false) {
    if (!target) return;
    for (const block of blocks) {
      if (block === target || block.contains(target) || (includeChildren && target.contains(block))) reveal(block);
    }
  }
  function hashTarget(hash = window.location.hash) {
    if (!hash || hash === '#') return null;
    let id = hash.slice(1).split(':~:text=')[0];
    try { id = decodeURIComponent(id); } catch { /* A literal malformed ID may still exist. */ }
    return document.getElementById(id) || document.getElementsByName?.(id)?.[0] || null;
  }
  function revealVisible() {
    const bottom = window.innerHeight || document.documentElement.clientHeight;
    for (const block of pending) {
      if (block.getBoundingClientRect().top < bottom) reveal(block);
    }
    revealTarget(hashTarget(), true);
  }

  window.WorkspaceScrollMotion = Object.freeze({ destroy: stop });
  if (motion.matches || !('IntersectionObserver' in window)) { stop(); return; }

  try {
    observer = new IntersectionObserver(entries => {
      if (stopped) return;
      try {
        for (const entry of entries) if (entry.isIntersecting) reveal(entry.target, true);
      } catch { stop(); }
    }, { threshold: 0, rootMargin: '0px 0px -24px 0px' });

    const bottom = window.innerHeight || document.documentElement.clientHeight;
    const anchor = hashTarget();
    for (const block of blocks) {
      const rect = block.getBoundingClientRect();
      // Never hide content already in view, above it, focused, or targeted by a link.
      if (rect.top < bottom || !rect.height || !rect.width || block.contains(document.activeElement)
        || (anchor && (block === anchor || block.contains(anchor) || anchor.contains(block)))) continue;
      pending.add(block);
      block.classList.add('reveal-pending');
      observer.observe(block);
    }
    if (!pending.size) { stop(); return; }

    document.addEventListener('focusin', event => revealTarget(event.target), { signal });
    document.addEventListener('click', event => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || (event.button && event.button !== 0)) return;
      const link = event.target.closest?.('a[href]');
      if (!link) return;
      try {
        const url = new URL(link.getAttribute('href'), window.location.href);
        const current = new URL(window.location.href);
        if (url.origin === current.origin && url.pathname === current.pathname && url.search === current.search) revealTarget(hashTarget(url.hash), true);
      } catch { /* Leave unknown link types to the browser. */ }
    }, { signal });
    document.addEventListener('animationend', event => {
      if (event.animationName === 'workspace-reveal-in' && entering.has(event.target)) {
        clean(event.target);
        finishIfDone();
      }
    }, { signal });
    window.addEventListener('hashchange', () => revealTarget(hashTarget(), true), { signal });
    window.addEventListener('pageshow', revealVisible, { signal });
    window.addEventListener('beforeprint', stop, { signal });
    motion.addEventListener('change', () => { if (motion.matches) stop(); }, { signal });
  } catch { stop(); }
})();
