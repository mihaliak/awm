'use strict';

(() => {
  const motion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const demo = document.querySelector('#workspace-demo');
  const desktop = document.querySelector('#interactive-desktop');
  const before = document.querySelector('.before-scene');
  const after = document.querySelector('.after-scene');
  const shortcut = document.querySelector('#shortcut-scene');
  const handle = document.querySelector('#comparison-range');
  const status = document.querySelector('#demo-status');
  const tabs = [...document.querySelectorAll('[role="tab"][data-mode]')];
  const workspaceButtons = document.querySelectorAll('[data-workspace]');
  const compare = window.WorkspaceCompare;
  const showcase = window.WorkspaceShowcase;
  let mode = 'compare';
  let workspace = 'focus';
  let desktopVisible = false;
  let workspaceCycleStopped = false;
  let workspaceTimer = 0;

  // Each example has its own included apps and geometry. No shared parked column.
  const workspaces = {
    focus: {
      before: {browser:[6,13,52,60],code:[32,8,55,55],notes:[53,34,39,45],calendar:[3,44,40,35],files:[57,22,39,38],music:[20,61,42,21],terminal:[27,31,43,34]},
      after: {browser:[4,10,55,69],notes:[61,10,35,38],music:[61,51,35,28]},
    },
    vibing: {
      before: {browser:[42,17,49,57],code:[8,12,58,62],notes:[60,42,34,36],calendar:[40,8,41,37],files:[4,39,43,39],music:[53,61,40,20],terminal:[24,35,48,37]},
      after: {code:[4,10,55,69],browser:[61,10,35,35],files:[61,48,35,31]},
    },
    planning: {
      before: {browser:[3,22,55,56],code:[39,15,51,54],notes:[24,8,47,54],calendar:[34,32,58,47],files:[8,11,40,42],music:[10,60,43,21],terminal:[52,44,42,35]},
      after: {calendar:[4,10,55,69],notes:[61,10,35,34],browser:[61,47,35,32]},
    },
  };
  const workspaceOrder = Object.keys(workspaces);
  function renderScene(scene, layout) {
    scene.querySelectorAll('.app-window').forEach(win => {
      const values = layout[win.dataset.window];
      win.hidden = !values;
      if (values) ['left','top','width','height'].forEach((property,index) => { win.style[property] = `${values[index]}%`; });
    });
  }
  function renderWorkspace() {
    before.dataset.layout = workspace;
    after.dataset.layout = workspace;
    renderScene(before, workspaces[workspace].before);
    renderScene(after, workspaces[workspace].after);
  }
  function setWorkspace(value, announce = true) {
    if (!Object.hasOwn(workspaces,value)) return;
    workspace = value;
    renderWorkspace();
    workspaceButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.workspace === workspace)));
    if (announce) status.textContent = `${value[0].toUpperCase()+value.slice(1)} workspace. ${Object.keys(workspaces[value].after).length} included windows shown after.`;
  }
  function canCycleWorkspaces() {
    return !workspaceCycleStopped && desktopVisible && mode === 'compare' && !document.hidden && !motion.matches;
  }
  function updateWorkspaceCycle() {
    if (!canCycleWorkspaces()) {
      clearTimeout(workspaceTimer);
      workspaceTimer = 0;
    } else if (!workspaceTimer) {
      workspaceTimer = setTimeout(() => {
        workspaceTimer = 0;
        if (!canCycleWorkspaces()) return;
        const next = (workspaceOrder.indexOf(workspace) + 1) % workspaceOrder.length;
        setWorkspace(workspaceOrder[next], false);
        updateWorkspaceCycle();
      }, 2000);
    }
  }
  const cycleObserver = 'IntersectionObserver' in window ? new IntersectionObserver(([entry]) => {
    desktopVisible = entry.isIntersecting;
    updateWorkspaceCycle();
  }, { threshold: 0 }) : null;
  function stopWorkspaceCycle() {
    if (workspaceCycleStopped) return;
    workspaceCycleStopped = true;
    cycleObserver?.disconnect();
    updateWorkspaceCycle();
  }
  function setMode(value, focus = false) {
    if (!['compare','shortcut'].includes(value)) return;
    mode = value;
    demo.dataset.mode = mode;
    const isCompare = mode === 'compare';
    tabs.forEach(tab => {
      const selected = tab.dataset.mode === mode;
      tab.setAttribute('aria-selected',String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focus) tab.focus();
    });
    before.hidden = !isCompare;
    after.hidden = !isCompare;
    shortcut.hidden = isCompare;
    document.querySelector('.screen-workspaces').hidden = !isCompare;
    document.querySelector('#compare-controls').hidden = !isCompare;
    document.querySelector('#shortcut-controls').hidden = isCompare;
    desktop.setAttribute('aria-describedby', isCompare ? 'demo-help' : 'shortcut-help');
    compare.setActive(isCompare);
    showcase.setActive(!isCompare);
    if (isCompare) {
      renderWorkspace();
      status.textContent = 'Workspace comparison. Drag the divider or use its arrow keys.';
    } else {
      status.textContent = 'Automatic shortcut showcase. Left, right, top, and bottom size cycles, then center, fill, and restore.';
    }
    updateWorkspaceCycle();
  }
  tabs.forEach((tab,index) => {
    tab.addEventListener('click', () => setMode(tab.dataset.mode));
    tab.addEventListener('keydown', event => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
      event.preventDefault();
      stopWorkspaceCycle();
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length-1 : (index+(event.key === 'ArrowRight'?1:-1)+tabs.length)%tabs.length;
      setMode(tabs[next].dataset.mode,true);
    });
  });
  workspaceButtons.forEach(button => button.addEventListener('click', () => setWorkspace(button.dataset.workspace)));
  demo.addEventListener('click', stopWorkspaceCycle);
  // Comparison handles its gestures before this controller sees the events.
  for (const type of ['pointerdown', 'keydown']) {
    handle.addEventListener(type, event => {
      if (event.defaultPrevented) stopWorkspaceCycle();
    });
  }
  handle.addEventListener('input', stopWorkspaceCycle);
  document.addEventListener('visibilitychange', updateWorkspaceCycle);
  motion.addEventListener('change', updateWorkspaceCycle);
  cycleObserver?.observe(desktop);
  document.querySelectorAll('[data-demo-link]').forEach(link => link.addEventListener('click', () => setMode(link.dataset.demoLink)));
  compare.setValue(50,{immediate:true});
  setWorkspace('focus',false);
  setMode('compare');

  const config = window.AWM_CONFIG || {};
  function safeHttps(value) {
    if (!value) return '';
    try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.href.replace(/\/$/, '') : ''; }
    catch { return ''; }
  }
  const repositoryUrl = safeHttps(config.repositoryUrl);
  const releasesUrl = repositoryUrl ? `${repositoryUrl}/releases` : '';
  const directDownloadUrl = safeHttps(config.downloadUrl);
  const downloadUrl = directDownloadUrl || releasesUrl;
  const dialog = document.querySelector('#install-dialog');
  if (downloadUrl) {
    const releaseLink = document.querySelector('#release-link');
    releaseLink.href = downloadUrl;
    if (directDownloadUrl) releaseLink.textContent = 'Download app';
    releaseLink.hidden = false;
  }
  if (repositoryUrl) {
    const setupReleaseLink = document.querySelector('#setup-release-link');
    setupReleaseLink.href = releasesUrl;
    setupReleaseLink.hidden = false;
    const sourceLink = document.querySelector('[data-source-link]');
    sourceLink.href = repositoryUrl; sourceLink.textContent = 'GitHub';
  }
  function dismissInstallDialog(afterClose) {
    if (!dialog.open || dialog.classList.contains('is-closing')) return;

    function finish() {
      dialog.close();
      dialog.classList.remove('is-closing');
      afterClose?.();
    }

    if (motion.matches || !dialog.getAnimations) {
      finish();
      return;
    }

    dialog.classList.add('is-closing');
    const fade = dialog.getAnimations().find(animation => animation.animationName === 'install-fade-out');
    if (fade) fade.finished.then(finish, finish);
    else finish();
  }

  document.querySelectorAll('[data-install]').forEach(button => button.addEventListener('click', () => dialog.showModal()));
  document.querySelector('.dialog-close').addEventListener('click', () => dismissInstallDialog());
  dialog.addEventListener('cancel', event => {
    event.preventDefault();
    dismissInstallDialog();
  });
  dialog.addEventListener('click', event => {
    const rect = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dismissInstallDialog();
  });
  document.querySelector('.dialog-demo').addEventListener('click', () => dismissInstallDialog(() => {
    setMode('compare');
    demo.scrollIntoView({ behavior: motion.matches ? 'instant' : 'smooth' });
    handle.focus({ preventScroll: true });
  }));
})();
