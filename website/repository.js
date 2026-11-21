(() => {
  'use strict';

  const link = document.getElementById('github-link');
  const badge = document.getElementById('github-stars');
  const countElement = document.getElementById('github-star-count');
  if (!link) return;

  link.hidden = true;
  if (badge) badge.hidden = true;

  function parseRepository(value) {
    // Validate the original string so URL normalization cannot conceal extra paths.
    const match = typeof value === 'string' && value.match(
      /^https:\/\/github\.com\/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)\/([A-Za-z0-9._-]{1,100})\/?$/,
    );
    if (!match || match[0] !== value || match[2] === '.' || match[2] === '..') return null;
    return `${match[1]}/${match[2]}`;
  }

  const repo = parseRepository(window.AWM_CONFIG?.repositoryUrl);
  if (!repo) return;
  const linkLabel = 'View the project on GitHub';
  link.href = `https://github.com/${repo}`;
  link.title = `${repo} on GitHub`;
  link.setAttribute('aria-label', linkLabel);
  link.hidden = false;
  if (!badge || !countElement) return;

  const key = `awm:github-stars:${repo.toLowerCase()}`;
  const ttl = 60 * 60 * 1000;
  const now = Date.now();
  const validCount = count => Number.isSafeInteger(count) && count >= 0;

  function showCount(count) {
    const fullCount = count.toLocaleString('en-US');
    countElement.textContent = count < 1000
      ? String(count)
      : new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 }).format(count);
    badge.title = `${fullCount} GitHub ${count === 1 ? 'star' : 'stars'}`;
    badge.setAttribute('aria-label', badge.title);
    link.setAttribute('aria-label', `${linkLabel}, ${fullCount} ${count === 1 ? 'star' : 'stars'}`);
    badge.hidden = false;
  }

  let cached;
  try {
    const value = JSON.parse(window.localStorage.getItem(key));
    if (value && validCount(value.count) && Number.isSafeInteger(value.savedAt)
      && value.savedAt >= 0 && value.savedAt <= now) cached = value;
  } catch { /* Storage may be unavailable or contain an older, incompatible entry. */ }

  if (cached) {
    showCount(cached.count);
    if (now - cached.savedAt < ttl) return;
  }
  if (typeof fetch !== 'function' || typeof AbortController !== 'function') return;

  async function refresh() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(`https://api.github.com/repos/${repo}`, {
        credentials: 'omit',
        headers: { Accept: 'application/vnd.github+json' },
        signal: controller.signal,
      });
      if (!response.ok) return;
      const result = await response.json();
      if (controller.signal.aborted || !validCount(result?.stargazers_count)) return;
      const count = result.stargazers_count;
      showCount(count);
      try {
        window.localStorage.setItem(key, JSON.stringify({ count, savedAt: Date.now() }));
      } catch { /* The live count remains useful when storage is unavailable. */ }
    } catch { /* Keep a previously verified count; otherwise leave the badge hidden. */ }
    finally { clearTimeout(timeout); }
  }

  void refresh();
})();
