'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { loadApp } = require('./helpers/dom-harness.cjs');
const root = path.resolve(__dirname, '..');
let temporary, output;
const pages = new Map();

// Exercise the real build in an isolated fixture, including on a clean checkout
// where npm test runs before dist exists. No browser or network is involved.
test.before(() => {
  temporary = fs.mkdtempSync(path.join(__dirname, '.variant-build-'));
  const fixture = path.join(temporary, 'website');
  fs.mkdirSync(fixture);
  fs.mkdirSync(path.join(temporary, 'docs'));
  fs.copyFileSync(path.join(root, '../docs/workspace-hero.png'), path.join(temporary, 'docs/workspace-hero.png'));
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if ((entry.isFile() && /\.(?:js|css|html|md|txt|xml)$/.test(entry.name)) || ['assets', 'scripts'].includes(entry.name)) {
      fs.cpSync(path.join(root, entry.name), path.join(fixture, entry.name), { recursive: true });
    }
  }
  execFileSync(process.execPath, [path.join(fixture, 'scripts/build.mjs')], {
    env: { ...process.env, AWM_REPOSITORY_URL: '' }, stdio: 'pipe',
  });
  output = path.join(fixture, 'dist');
  for (const name of ['index.html', 'glow.html', 'particles.html', 'plain.html']) pages.set(name, fs.readFileSync(path.join(output, name), 'utf8'));
});
test.after(() => { if (temporary) fs.rmSync(temporary, { recursive: true, force: true }); });

function tags(html) {
  return [...html.matchAll(/<([a-z][\w:-]*)\b([^<>]*?)\/?\s*>/gi)].map(match => {
    const attrs = {};
    for (const entry of match[2].matchAll(/([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
      attrs[entry[1]] = entry[2] ?? entry[3] ?? entry[4] ?? '';
    }
    return { tag: match[1].toLowerCase(), attrs };
  });
}

const hasClass = (element, name) => (element.attrs.class || '').split(/\s+/).includes(name);

test('every alias advertises the canonical app and original README banner in its static head', () => {
  const canonical = 'https://awm.mihaliak.com/';
  const imageUrl = `${canonical}assets/workspace-hero.png`;
  const banner = fs.readFileSync(path.join(output, new URL(imageUrl).pathname.slice(1)));
  assert.deepEqual(banner, fs.readFileSync(path.join(root, '../docs/workspace-hero.png')));
  assert.equal(banner.toString('ascii', 12, 16), 'IHDR');
  for (const [name, html] of pages) {
    const head = html.match(/<head>([\s\S]*?)<\/head>/)?.[1];
    assert.ok(head, `${name}: static head missing`);
    const elements = tags(head);
    const canonicalLinks = elements.filter(element => element.tag === 'link' && element.attrs.rel === 'canonical');
    assert.deepEqual(canonicalLinks.map(element => element.attrs.href), [canonical]);
    const meta = key => {
      const matches = elements.filter(({ tag, attrs }) => tag === 'meta' && (attrs.name === key || attrs.property === key));
      assert.equal(matches.length, 1, `${name}: expected exactly one ${key}`);
      assert.ok(matches[0].attrs.content, `${name}: ${key} must have content`);
      return matches[0].attrs.content;
    };
    const title = head.match(/<title>([^<]+)<\/title>/)?.[1];
    assert.match(title, /Another Window Management \(AWM\).*macOS Window Manager/);
    const description = meta('description');
    assert.match(description, /across displays.*configurable shortcuts/);
    assert.equal(meta('og:type'), 'website');
    assert.equal(meta('og:site_name'), 'Another Window Management');
    assert.equal(meta('og:url'), canonical);
    assert.equal(meta('og:image:type'), 'image/png');
    assert.equal(Number(meta('og:image:width')), banner.readUInt32BE(16));
    assert.equal(Number(meta('og:image:height')), banner.readUInt32BE(20));
    assert.equal(meta('twitter:card'), 'summary_large_image');
    for (const prefix of ['og', 'twitter']) {
      assert.equal(meta(`${prefix}:title`), title);
      assert.equal(meta(`${prefix}:description`), description);
      assert.equal(meta(`${prefix}:image`), imageUrl);
      assert.match(meta(`${prefix}:image:alt`), /macOS menu bar popover showing three saved workspaces/);
    }
    const structured = JSON.parse(head.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
    assert.equal(structured['@context'], 'https://schema.org');
    assert.equal(structured['@type'], 'SoftwareApplication');
    assert.equal(structured['@id'], `${canonical}#software`);
    assert.equal(structured.name, meta('og:site_name'));
    assert.equal(structured.alternateName, 'AWM');
    assert.equal(structured.url, canonical);
    assert.equal(structured.description, description);
    assert.equal(structured.operatingSystem, 'macOS 13 or later');
    assert.equal(structured.applicationCategory, 'UtilitiesApplication');
    assert.equal(structured.image, imageUrl);
    assert.ok(structured.featureList.length >= 3);
    for (const key of ['offers', 'review', 'aggregateRating', 'downloadUrl']) assert.ok(!(key in structured));
  }
});

test('llms.txt points to shipped sections and the sitemap lists only the canonical home page', () => {
  const canonical = 'https://awm.mihaliak.com/';
  const summary = fs.readFileSync(path.join(output, 'llms.txt'), 'utf8');
  assert.match(summary, /^# Another Window Management \(AWM\)\n\n> .*macOS 13 or later/);
  const links = [...summary.matchAll(/\]\(([^)]+)\)/g)].map(([, url]) => new URL(url));
  assert.deepEqual(links.map(url => url.hash), ['#features', '#workspace-demo', '#setup']);
  const homeIds = new Set(tags(pages.get('index.html')).map(element => element.attrs.id).filter(Boolean));
  for (const url of links) {
    assert.equal(`${url.origin}${url.pathname}`, canonical);
    assert.ok(homeIds.has(url.hash.slice(1)), `llms.txt: missing ${url.hash}`);
  }
  const sitemap = fs.readFileSync(path.join(output, 'sitemap.xml'), 'utf8');
  assert.deepEqual([...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(([, url]) => url), [canonical]);
});

test('main, aliases, and plain alternative have one headline, unique IDs, and resolved ARIA references', () => {
  for (const [name, html] of pages) {
    const elements = tags(html);
    const ids = elements.map(element => element.attrs.id).filter(Boolean);
    assert.equal(ids.length, new Set(ids).size, `${name}: duplicate ID`);
    assert.equal(elements.filter(element => element.tag === 'html').length, 1);
    assert.equal(elements.filter(element => element.tag === 'body').length, 1);
    assert.equal(elements.filter(element => element.tag === 'h1').length, 1);
    assert.equal(ids.filter(id => id === 'hero-title').length, 1);
    for (const { attrs } of elements) {
      for (const attribute of ['aria-labelledby', 'aria-describedby', 'aria-controls']) {
        for (const id of (attrs[attribute] || '').split(/\s+/).filter(Boolean)) assert.ok(ids.includes(id), `${name}: unresolved ${attribute}=${id}`);
      }
    }
    const body = elements.find(element => element.tag === 'body');
    assert.equal(body.attrs['data-hero'], 'combined');
    assert.equal(body.attrs['data-atmosphere'], name === 'plain.html' ? 'plain' : 'glow');
  }
});

test('the intro contains its header, wordmark, logo, and a direct scroll link to the classic hero', () => {
  for (const [name, html] of pages) {
    const introMatch = html.match(/<section\b[^>]*class="brand-intro"[^>]*>[\s\S]*?<\/section>/);
    assert.ok(introMatch, `${name}: intro missing`);
    const intro = introMatch[0];
    const introTags = tags(intro);
    const elements = tags(html);
    assert.equal(introTags[1].tag, 'header', `${name}: header is the first intro element`);
    assert.ok(hasClass(introTags[1], 'site-header'));
    assert.ok(!('data-reveal' in introTags[1].attrs), `${name}: intro header cannot depend on scrolling`);
    const wordmarks = elements.filter(element => 'data-particle-wordmark' in element.attrs);
    assert.equal(wordmarks.length, 1, `${name}: only the intro has a particle wordmark`);
    assert.equal(wordmarks[0].attrs.id, 'hero-particle-wordmark');
    assert.ok(hasClass(wordmarks[0], 'brand-intro-content'));
    const field = intro.match(/<div\b[^>]*\bdata-particle-wordmark[^>]*>([\s\S]*?<\/div>\s*<img\b[^>]*>)\s*<\/div>/)?.[1];
    assert.ok(field, `${name}: the title and logo share the particle field`);
    const fieldTags = tags(field);
    const [canvas, title, , , logo] = fieldTags;
    assert.equal(canvas.attrs.id, 'hero-particle-canvas');
    assert.equal(canvas.attrs['aria-hidden'], 'true');
    assert.ok('data-particle-text' in title.attrs);
    assert.equal(logo.tag, 'img');
    assert.ok(hasClass(logo, 'intro-logo'));
    assert.equal(logo.attrs.src, './assets/logo.svg');
    assert.equal(logo.attrs.alt, '');
    assert.equal(logo.attrs['aria-hidden'], 'true');
    assert.ok(!('tabindex' in logo.attrs));
    assert.equal(introTags.filter(element => hasClass(element, 'intro-logo')).length, 1);
    assert.equal(introTags.filter(element => hasClass(element, 'particle-fallback')).length, 1);
    const fallback = intro.match(/<p\b[^>]*class="particle-fallback"[^>]*>([\s\S]*?)<\/p>/)?.[1];
    assert.ok(fallback, `${name}: readable wordmark fallback`);
    assert.equal(fallback.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(), 'Another Window Management');
    assert.ok(!introTags.some(element => /^h[1-6]$/.test(element.tag)), `${name}: product headline remains below the intro`);
    assert.ok(!introTags.some(element => 'data-reveal' in element.attrs), `${name}: initial branding cannot await a scroll reveal`);
    assert.ok(!elements.some(element => hasClass(element, 'hero-logo')), `${name}: classic hero has no repeated logo`);
    assert.ok(!elements.some(element => element.attrs.id === 'particle-wordmark' || hasClass(element, 'particle-hint')), `${name}: old footer particles removed`);

    const main = html.indexOf('<main id="main"');
    const classic = html.indexOf('<section class="hero"');
    assert.ok(introMatch.index + intro.length <= main && main < classic, `${name}: intro → main → classic hero order`);
    const cue = introTags.find(element => hasClass(element, 'intro-scroll'));
    assert.ok(cue, `${name}: scroll cue missing`);
    assert.equal(cue.tag, 'a');
    assert.equal(cue.attrs.href, '#hero-title', `${name}: cue targets only the classic headline, not all main content`);
    const cueMarkup = intro.match(/<a\b[^>]*class="[^"]*\bintro-scroll\b[^"]*"[^>]*>([\s\S]*?)<\/a>/)?.[1];
    assert.match(cueMarkup.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' '), /Scroll to explore/);
    assert.ok(html.indexOf('id="hero-title"') > classic, `${name}: cue destination is inside the classic hero`);
    const skip = elements.find(element => hasClass(element, 'skip-link'));
    assert.equal(skip.attrs.href, '#main');
    assert.ok(html.indexOf('class="skip-link"') < introMatch.index);
    assert.ok(elements.some(element => 'data-reveal' in element.attrs), `${name}: reveal hooks preserved below intro`);
    assert.ok(!elements.some(element => hasClass(element, 'reveal-pending')), `${name}: content starts visible without JavaScript`);
  }
});

test('local assets, SVG fragments, stylesheets, and screenshot files resolve for every built page', () => {
  for (const [name, html] of pages) {
    const elements = tags(html);
    const ids = new Set(elements.map(element => element.attrs.id).filter(Boolean));
    const check = (reference, base = output) => {
      if (!reference || /^(?:https?:|data:|mailto:)/i.test(reference)) return;
      if (reference.startsWith('#')) {
        if (reference.length > 1) assert.ok(ids.has(reference.slice(1)), `${name}: missing ${reference}`);
        return;
      }
      assert.ok(!reference.startsWith('/'), `${name}: root-absolute asset ${reference}`);
      assert.ok(fs.existsSync(path.resolve(base, reference.split(/[?#]/)[0])), `${name}: missing ${reference}`);
    };
    for (const { tag, attrs } of elements) {
      check(attrs.href); check(attrs.src);
      if (tag === 'link' && attrs.rel === 'stylesheet') {
        const file = path.resolve(output, attrs.href);
        for (const match of fs.readFileSync(file, 'utf8').matchAll(/url\(\s*['"]?([^)'"\s]+)['"]?\s*\)/g)) check(match[1], path.dirname(file));
      }
    }
  }
  for (const match of fs.readFileSync(path.join(output, 'app-windows.js'), 'utf8').matchAll(/file:\s*'([^']+)'/g)) {
    assert.ok(fs.existsSync(path.join(output, 'assets/screenshots', `${match[1]}.webp`)));
  }
  assert.ok(fs.existsSync(path.join(output, '.nojekyll')));
});

test('glow and particle URLs alias the main page while plain changes only its atmosphere', () => {
  assert.equal(pages.get('glow.html'), pages.get('index.html'));
  assert.equal(pages.get('particles.html'), pages.get('index.html'));
  assert.equal(pages.get('plain.html'), pages.get('index.html').replace('data-atmosphere="glow"', 'data-atmosphere="plain"'));
  assert.ok(!fs.existsSync(path.join(output, 'variants')), 'no removed hero fragment is required or shipped');
});

test('all pages retain GitHub and installation actions without the removed top navigation', () => {
  for (const [name, html] of pages) {
    const header = html.match(/<header class="site-header"[^>]*>([\s\S]*?)<\/header>/)?.[1];
    assert.ok(header, `${name}: main header missing`);
    assert.doesNotMatch(header, /<nav\b/);
    assert.match(header, /id="github-link"/);
    assert.match(header, /data-install/);
  }
});

test('the shipped setup action opens the configured GitHub releases in a new tab', () => {
  const settings = { window: {} };
  vm.runInNewContext(fs.readFileSync(path.join(output, 'site-config.js'), 'utf8'), settings);
  const config = settings.window.AWM_CONFIG;
  const app = loadApp({ config });
  const link = app.find('#setup-release-link');
  assert.equal(link.hidden, false);
  assert.equal(link.href, `${config.repositoryUrl.replace(/\/$/, '')}/releases`);
  assert.equal(new URL(link.href).hostname, 'github.com');
  for (const [name, html] of pages) {
    const setup = tags(html).find(element => element.attrs.id === 'setup-release-link');
    assert.equal(setup?.tag, 'a', `${name}: setup uses a native anchor`);
    assert.equal(setup.attrs.target, '_blank');
    const rel = (setup.attrs.rel || '').split(/\s+/);
    assert.ok(rel.includes('noopener') && rel.includes('noreferrer'));
    assert.ok(!('data-install' in setup.attrs), `${name}: setup bypasses the guide`);
    assert.doesNotMatch(html, /release-example-note/);
  }
});

test('screenshot captions omit full-size labels and retain source credits', () => {
  for (const [name, html] of pages) {
    assert.doesNotMatch(html.replace(/<[^>]*>/g, ' '), /View full size/i,
      `${name}: no visible full-size caption remains`);
    const credits = html.match(/<p\b[^>]*class="[^"]*\bscreenshot-credits\b[^"]*"[^>]*>([\s\S]*?)<\/p>/)?.[1];
    assert.ok(credits, `${name}: screenshot credits missing`);
    const links = tags(credits).filter(element => element.tag === 'a');
    assert.deepEqual(links.map(link => new URL(link.attrs.href).hostname).sort(),
      ['support.apple.com', 'www.anthropic.com']);
    assert.match(credits.replace(/<[^>]*>/g, ' '), /Apple[\s\S]*Anthropic/);
  }
});

test('every built footer includes the accessible maker credit and campaign link', () => {
  for (const [name, html] of pages) {
    const footer = html.match(/<footer class="site-footer"[^>]*>([\s\S]*?)<\/footer>/)?.[1];
    assert.ok(footer, `${name}: site footer missing`);
    const credit = footer.match(/<p\b[^>]*class="[^"]*\bmaker-credit\b[^"]*"[^>]*>([\s\S]*?)<\/p>/)?.[1];
    assert.ok(credit, `${name}: maker credit missing`);
    assert.equal(tags(footer).filter(element => hasClass(element, 'maker-credit')).length, 1);
    assert.equal(tags(footer).filter(element => hasClass(element, 'screenshot-credits')).length, 1);
    assert.ok(footer.indexOf('class="maker-credit') < footer.indexOf('class="screenshot-credits'), `${name}: maker precedes screenshot attribution`);
    const elements = tags(credit);
    const links = elements.filter(element => element.tag === 'a');
    assert.deepEqual(links.map(link => link.attrs.href),
      ['https://mihaliak.com/?utm_source=awm&amp;utm_medium=website&amp;utm_campaign=awm']);
    assert.match(credit, />Andrej Mihaliak<\/a>/);
    assert.equal(elements.find(element => element.tag === 'svg')?.attrs['aria-hidden'], 'true');
    assert.match(credit, /<span class="sr-only">love<\/span>/);
    assert.equal(credit.replace(/<[^>]*>/g, ''), 'Made with love by Andrej Mihaliak');
  }
});
