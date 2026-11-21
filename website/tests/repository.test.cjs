'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'repository.js'), 'utf8');
const NOW = 1_800_000_000_000;
const TTL = 3_600_000;
const KEY = 'awm:github-stars:example/awm';

class Element {
  constructor() { this.hidden = true; this.attributes = {}; this.textContent = ''; }
  setAttribute(name, value) { this.attributes[name] = value; }
}

function fixture({ url = 'https://github.com/Example/AWM', cache, status = 200,
  body = { stargazers_count: 1234 }, fail = false, badJSON = false,
  blockedStorage = false, pending = false, missingLink = false } = {}) {
  const link = new Element();
  const badge = new Element();
  const count = new Element();
  const elements = { 'github-link': missingLink ? null : link, 'github-stars': badge, 'github-star-count': count };
  const storage = new Map(cache === undefined ? [] : [[KEY, typeof cache === 'string' ? cache : JSON.stringify(cache)]]);
  const requests = [];
  const timers = new Map();
  let nextTimer = 0;
  const window = {
    AWM_CONFIG: { repositoryUrl: url },
    localStorage: {
      getItem(key) { if (blockedStorage) throw new Error('Storage blocked'); return storage.get(key) ?? null; },
      setItem(key, value) { if (blockedStorage) throw new Error('Storage blocked'); storage.set(key, value); },
    },
  };
  vm.runInNewContext(source, {
    window,
    document: { getElementById: id => elements[id] },
    Date: { now: () => NOW },
    AbortController,
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    async fetch(url, options) {
      requests.push({ url, options });
      if (pending) await new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('Aborted')), { once: true }));
      if (fail) throw new Error('Network error');
      return { ok: status >= 200 && status < 300, async json() {
        if (badJSON) throw new Error('Invalid JSON');
        return body;
      } };
    },
  });
  return { link, badge, count, requests, storage, timers,
    async settle() { for (let i = 0; i < 8; i += 1) await Promise.resolve(); },
    timeout() { for (const [id, timer] of timers) { timers.delete(id); timer.callback(); } },
  };
}

test('missing or invalid repository URLs stay hidden and never fetch', async () => {
  for (const url of [null, '', 0, 'http://github.com/example/awm',
    'https://github.com.evil.test/example/awm', 'https://github.com:443/example/awm',
    'https://user:token@github.com/example/awm', 'https://github.com/example',
    'https://github.com/example/awm//', 'https://github.com/example/awm/releases',
    'https://github.com/example/awm?tab=readme', 'https://github.com/example/awm#readme',
    'https://github.com/example/../awm', 'https://github.com/example/%61wm',
    'https://github.com/example/..', 'https://github.com/example/.',
    'https://github.com/-example/awm', 'https://github.com/example_/awm',
    'https://github.com/example/awm\n']) {
    const f = fixture({ url });
    await f.settle();
    assert.equal(f.link.hidden, true, String(url));
    assert.equal(f.badge.hidden, true, String(url));
    assert.equal(f.requests.length, 0, String(url));
  }
  const absent = new Element();
  absent.hidden = false;
  assert.doesNotThrow(() => vm.runInNewContext(source, {
    window: {}, document: { getElementById: () => absent },
  }));
  assert.equal(absent.hidden, true);
  assert.doesNotThrow(() => fixture({ missingLink: true }));
});

test('valid repository appears immediately and fetches anonymously with a five-second abort', async () => {
  const f = fixture();
  assert.equal(f.link.hidden, false);
  assert.equal(f.link.href, 'https://github.com/Example/AWM');
  assert.equal(f.badge.hidden, true);
  assert.equal(f.requests[0].url, 'https://api.github.com/repos/Example/AWM');
  assert.equal(f.requests[0].options.credentials, 'omit');
  assert.equal(f.requests[0].options.headers.Authorization, undefined);
  assert.equal([...f.timers.values()][0].delay, 5000);
  await f.settle();
  assert.equal(f.badge.hidden, false);
  assert.equal(f.count.textContent, '1.2K');
  assert.equal(f.badge.title, '1,234 GitHub stars');
  assert.equal(f.badge.attributes['aria-label'], '1,234 GitHub stars');
  assert.equal(f.link.attributes['aria-label'], 'View the project on GitHub, 1,234 stars');
  assert.deepEqual(JSON.parse(f.storage.get(KEY)), { count: 1234, savedAt: NOW });
  assert.equal(f.timers.size, 0);
});

test('fresh cache is scoped to the canonical repository and avoids a request', async () => {
  const f = fixture({ cache: { count: 72, savedAt: NOW - TTL + 1 } });
  await f.settle();
  assert.equal(f.count.textContent, '72');
  assert.equal(f.badge.hidden, false);
  assert.equal(f.requests.length, 0);
  const other = fixture({ url: 'https://github.com/Example/other', cache: { count: 72, savedAt: NOW }, fail: true });
  await other.settle();
  assert.equal(other.requests.length, 1);
  assert.equal(other.badge.hidden, true);
});

test('one trailing slash normalizes to the same link, API endpoint, and cache key', async () => {
  const f = fixture({ url: 'https://github.com/Example/AWM/' });
  await f.settle();
  assert.equal(f.link.hidden, false);
  assert.equal(f.link.href, 'https://github.com/Example/AWM');
  assert.equal(f.requests[0].url, 'https://api.github.com/repos/Example/AWM');
  assert.deepEqual(JSON.parse(f.storage.get(KEY)), { count: 1234, savedAt: NOW });
  const cached = fixture({ url: 'https://github.com/Example/AWM/', cache: { count: 47, savedAt: NOW } });
  await cached.settle();
  assert.equal(cached.count.textContent, '47');
  assert.equal(cached.requests.length, 0);
});

test('cache expires exactly at one hour and updates after a successful fetch', async () => {
  const f = fixture({ cache: { count: 72, savedAt: NOW - TTL }, body: { stargazers_count: 81 } });
  assert.equal(f.count.textContent, '72');
  assert.equal(f.requests.length, 1);
  await f.settle();
  assert.equal(f.count.textContent, '81');
  assert.deepEqual(JSON.parse(f.storage.get(KEY)), { count: 81, savedAt: NOW });
});

test('network, HTTP, and JSON failures preserve stale verified cache without extending its life', async () => {
  for (const failure of [{ fail: true }, { status: 403 }, { status: 404 }, { badJSON: true }]) {
    const cache = { count: 35, savedAt: NOW - TTL * 2 };
    const f = fixture({ cache, ...failure });
    await f.settle();
    assert.equal(f.badge.hidden, false);
    assert.equal(f.count.textContent, '35');
    assert.deepEqual(JSON.parse(f.storage.get(KEY)), cache);
    assert.equal(f.timers.size, 0);
    const empty = fixture(failure);
    await empty.settle();
    assert.equal(empty.badge.hidden, true);
    assert.equal(empty.count.textContent, '');
  }
});

test('malformed API counts never invent a count or overwrite valid cache', async () => {
  for (const value of [undefined, null, '12', -1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    const f = fixture({ body: { stargazers_count: value } });
    await f.settle();
    assert.equal(f.badge.hidden, true, String(value));
    assert.equal(f.storage.has(KEY), false);
    const stale = { count: 4, savedAt: NOW - TTL };
    const fallback = fixture({ cache: stale, body: { stargazers_count: value } });
    await fallback.settle();
    assert.equal(fallback.count.textContent, '4');
    assert.deepEqual(JSON.parse(fallback.storage.get(KEY)), stale);
  }
});

test('malformed, future-dated, or invalid cache is ignored', async () => {
  for (const cache of ['not JSON', 'null', { count: '6', savedAt: NOW },
    { count: -1, savedAt: NOW }, { count: 6 }, { count: 6, savedAt: 'today' },
    { count: 6, savedAt: -1 }, { count: 6, savedAt: NOW + 1 }]) {
    const f = fixture({ cache, fail: true });
    await f.settle();
    assert.equal(f.requests.length, 1);
    assert.equal(f.badge.hidden, true);
  }
});

test('confirmed zero, singular, and compact counts retain full accessible labels', async () => {
  for (const [value, display, label] of [[0, '0', '0 GitHub stars'], [1, '1', '1 GitHub star'],
    [999, '999', '999 GitHub stars'], [1000, '1K', '1,000 GitHub stars'],
    [1_234_567, '1.2M', '1,234,567 GitHub stars']]) {
    const f = fixture({ body: { stargazers_count: value }, blockedStorage: true });
    await f.settle();
    assert.equal(f.count.textContent, display);
    assert.equal(f.badge.title, label);
    assert.equal(f.badge.hidden, false);
  }
});

test('timeout aborts the request and leaves no invented count or active timer', async () => {
  const f = fixture({ pending: true });
  f.timeout();
  await f.settle();
  assert.equal(f.requests[0].options.signal.aborted, true);
  assert.equal(f.badge.hidden, true);
  assert.equal(f.storage.has(KEY), false);
  assert.equal(f.timers.size, 0);
});
