(() => {
  'use strict';

  const screenshots = {
    browser: { app: 'Safari', file: 'safari', size: [2704, 1628], crop: [112, 76, 2480, 1404] },
    code: { app: 'Coding terminal', file: 'coding-terminal', size: [1920, 1035], crop: [280, 50, 1360, 935] },
    notes: { app: 'Notes', file: 'notes', size: [814, 540], crop: [0, 0, 814, 540] },
    calendar: { app: 'Calendar', file: 'calendar', size: [814, 522], crop: [0, 0, 814, 522] },
    files: { app: 'Finder', file: 'finder', size: [1144, 726], crop: [0, 0, 1144, 726] },
    music: { app: 'Music', file: 'music', size: [1306, 780], crop: [144, 91, 1015, 616] },
    terminal: { app: 'Terminal', file: 'terminal', size: [1304, 740], crop: [0, 0, 1304, 740] },
  };

  document.querySelectorAll('.app-window').forEach(win => {
    const type = win.dataset.window || (win.id === 'showcase-window' ? 'browser' : '');
    const screenshot = screenshots[type];
    if (!screenshot) return;

    const [width, height] = screenshot.size;
    win.classList.add('native-app', `native-app-${type}`);
    win.dataset.nativeApp = screenshot.app;
    win.setAttribute('aria-label', `${screenshot.app} screenshot`);
    // The SVG viewport frames the original bitmap without changing its pixels.
    // Uniform top-left scaling preserves readable chrome as the window resizes.
    win.innerHTML = `<svg class="native-screenshot" viewBox="${screenshot.crop.join(' ')}" preserveAspectRatio="xMinYMin slice" role="img" aria-label="${screenshot.app} screenshot" xmlns="http://www.w3.org/2000/svg"><title>${screenshot.app} — official product screenshot</title><image href="./assets/screenshots/${screenshot.file}.webp" x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="xMinYMin meet"/></svg>`;
  });
})();
