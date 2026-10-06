'use strict';
/* global SSMT */
// The main window (App/SSMT/Views/MainView.swift + AppSidebar.swift): the sidebar with the brand, the switch between
// the five functions and the current function's items, and the workspace showing that function's screen. A function's
// screen is built once and then only hidden and shown, as on the Mac.

(function () {
  const { S, t, esc, icon, UI, sections } = SSMT;
  const ORDER = [
    { id: 'setup', icon: 'dial.medium', title: 'section.setup' },
    { id: 'inputList', icon: 'list.bullet.rectangle', title: 'section.inputList', subtitle: 'section.inputList.subtitle' },
    { id: 'show', icon: 'play.rectangle.on.rectangle', title: 'section.show', subtitleText: 'Show Control Center' },
    { id: 'assist', icon: 'slider.vertical.3', title: 'section.assist', subtitle: 'section.assist.subtitle' },
    { id: 'handbook', icon: 'book', title: 'section.handbook', subtitle: 'section.handbook.subtitle' },
  ];
  const mounted = new Set();

  function sidebar() {
    const sec = sections[S.section];
    const rows = ORDER.map((r) => {
      const sub = r.subtitle ? t(r.subtitle) : r.subtitleText;
      return `<button class="section-row ${S.section === r.id ? 'on' : ''}" data-shell="section" data-arg="${r.id}">${icon(r.icon, 15)}
        <span class="titles"><b>${esc(t(r.title))}</b>${sub ? `<span>${esc(sub)}</span>` : ''}</span></button>`;
    }).join('');
    const items = sec && sec.sidebar ? sec.sidebar() : '<div class="spacer"></div>';
    return `<div class="brand" data-shell="brand" title="${esc(t('about.title'))}"><img src="brand/BrandMark.png" alt=""><div><b>SSMT</b><span>SoundSolution Multi Tool</span></div></div>
      <div id="profile-badge-slot">${SSMT.profileBadge ? SSMT.profileBadge() : ''}</div>
      <nav class="section-switch">${rows}</nav>${items}`;
  }

  /** The setup TopBar shows above system setup and Ptch, not above Qtrl, FOH Assist or the handbook (MainView). */
  const hasTopBar = () => S.section !== 'show' && S.section !== 'assist' && S.section !== 'handbook';
  const setupUI = () => SSMT.setupUI || {};

  function workspace() {
    const top = hasTopBar() && SSMT.setupTopBar ? SSMT.setupTopBar() : '';
    const err = S.lastError ? `<div class="error-banner">${icon('exclamationmark.triangle.fill', 14)}<span class="text">${esc(S.lastError)}</span>
      <button class="btn plain" data-shell="dismissError">${icon('xmark', 13)}</button></div>` : '';
    return top + err;
  }

  let lastOverlay = '';

  function draw() {
    const root = document.getElementById('app');
    if (!root.firstChild) {
      root.innerHTML = `<aside class="glass sidebar" id="sidebar"></aside>
        <div class="workspace"><div id="workspace-head"></div><div class="screen" id="screen"></div></div>`;
      const host = document.createElement('div');
      host.id = 'app-overlay';
      document.body.appendChild(host);
    }
    // Keep the focused field and its cursor across the redraw.
    const a = document.activeElement;
    const focus = a && a.id ? { id: a.id, start: a.selectionStart, end: a.selectionEnd } : null;
    // Stage mode hides the sidebar in every function (MainView: `if !model.stageMode { AppSidebar() }`).
    const side = document.getElementById('sidebar');
    side.style.display = setupUI().stage ? 'none' : '';
    side.innerHTML = sidebar();
    const head = document.getElementById('workspace-head');
    head.innerHTML = workspace();
    // Nothing above the screen (Qtrl, FOH Assist, handbook without an error): no gap either, as in the Mac VStack.
    head.style.display = head.firstChild ? '' : 'none';
    document.body.classList.toggle('reduced', !!setupUI().reduced);
    mounted.add(S.section);
    const screen = document.getElementById('screen');
    for (const id of mounted) {
      let pane = document.getElementById('pane-' + id);
      if (!pane) {
        pane = document.createElement('div');
        pane.id = 'pane-' + id;
        pane.className = 'pane';
        screen.appendChild(pane);
      }
      const on = id === S.section;
      pane.hidden = !on;
      if (on && sections[id]) {
        const html = sections[id].render();
        if (html !== null && html !== undefined) pane.innerHTML = html;
        if (sections[id].after) sections[id].after(pane);
      }
    }
    // The setup sheets (settings, target editor) cover the whole window whichever function is open (MainView .sheet).
    const overlay = document.getElementById('app-overlay');
    const ov = SSMT.setupOverlays ? SSMT.setupOverlays() : '';
    if (ov !== lastOverlay) { overlay.innerHTML = ov; lastOverlay = ov; }
    if (ov && SSMT.setupPaint) SSMT.setupPaint(overlay);
    document.documentElement.lang = S.lang;
    if (focus) {
      const el = document.getElementById(focus.id);
      if (el) { el.focus(); try { el.setSelectionRange(focus.start, focus.end); } catch (_) { /* not a text field */ } }
    }
  }
  SSMT.draw = () => {
    draw();
    if (SSMT.sectionShown) SSMT.sectionShown(S.section);
    updateMenu();
  };

  const shell = {
    section(id) { S.section = id; SSMT.store.set('section', id); SSMT.render(); },
    dismissError() { S.lastError = null; SSMT.render(); },
    brand() { if (SSMT.brand) SSMT.brand.brandTapped(); },
  };

  // Events go to the shell (data-shell) or to the section that owns the element's pane or the sidebar.
  const owner = (el) => {
    // The TopBar and the setup sheets belong to system setup, whichever function is open.
    if (el.closest('#workspace-head, #app-overlay')) return sections.setup;
    const pane = el.closest('.pane');
    return sections[pane ? pane.id.slice(5) : S.section];
  };
  document.addEventListener('click', (e) => {
    const sh = e.target.closest('[data-shell]');
    if (sh) { shell[sh.dataset.shell] && shell[sh.dataset.shell](sh.dataset.arg); return; }
    const el = e.target.closest('[data-act]');
    if (!el || el.disabled) return;
    const sec = owner(el);
    const fn = sec && sec.actions && sec.actions[el.dataset.act];
    if (fn) fn(el.dataset.arg, el, e);
  });
  document.addEventListener('input', (e) => {
    const k = e.target.dataset && e.target.dataset.input;
    if (!k) return;
    const sec = owner(e.target);
    if (sec && sec.inputs && sec.inputs[k]) sec.inputs[k](e.target.type === 'checkbox' ? e.target.checked : e.target.value, e.target);
  });
  document.addEventListener('change', (e) => {
    const k = e.target.dataset && e.target.dataset.change;
    if (!k) return;
    const sec = owner(e.target);
    const fn = sec && sec.actions && sec.actions[k];
    if (fn) fn(e.target.type === 'checkbox' ? e.target.checked : e.target.value, e.target, e);
  });
  document.addEventListener('keydown', (e) => {
    const sec = sections[S.section];
    if (sec && sec.keys && !e.target.closest('input, textarea, select')) sec.keys(e);
  });

  SSMT.onEngine((ev) => {
    if (ev.event === 'error' && ev.key !== 'unknownCommand') { S.lastError = ev.detail ? `${ev.key}: ${ev.detail}` : ev.key; SSMT.render(); }
    for (const id in sections) if (sections[id].onEvent) sections[id].onEvent(ev);
  });
  // MARK: menu bar and keyboard shortcuts (SSMTApp.commands and AppDelegate)

  const api = window.ssmt;
  const act = (sec, name, arg) => { const s = sections[sec]; const fn = s && s.actions && s.actions[name]; if (fn) fn(arg); };
  /** The Mac menu commands. File acts on the open function's document, SSMT on system setup. */
  const COMMANDS = {
    open() {
      if (S.section === 'show') act('show', 'openShow');
      else if (S.section === 'inputList') act('inputList', 'open');
      else act('setup', 'openSession');
    },
    save() {
      if (S.section === 'show') act('show', 'saveShow');
      else if (S.section === 'inputList') act('inputList', 'saveDoc');
      else act('setup', 'saveSession');
    },
    saveAs() { if (S.section === 'show') act('show', 'saveShowAs'); else if (S.section === 'inputList') act('inputList', 'saveAs'); },
    showNew() { act('show', 'newShow'); },
    addAudio() { act('show', 'chooseAudio'); },
    ilNew() { act('inputList', 'newDocument'); },
    ilPDF() { act('inputList', 'exportKind', 'pdf'); },
    reportPDF() { act('setup', 'reportPDF'); },
    reportPNG() { act('setup', 'reportPNG'); },
    reportCopy() {
      const r = SSMT.setupData && SSMT.setupData.s && SSMT.setupData.s.report;
      if (r && r.plainText != null && navigator.clipboard) navigator.clipboard.writeText(r.plainText).catch(() => {});
    },
    stop() { act('setup', 'stop'); },
    noise() { act('setup', 'toggleNoise'); },
    delay() { act('setup', 'findDelay'); },
    wizard() { act('setup', 'mode', 'wizard'); },
    expert() { act('setup', 'mode', 'expert'); },
    stage() { act('setup', 'stageMode'); },
    begin() { act('setup', 'wizardStart'); },
    mini() { act('setup', 'mini'); },
    clickThroughOff() { SSMT.store.set('mini.clickThrough', '0'); if (api && api.mini) api.mini('clickThrough', false); },
    minimize() { if (api && api.window) api.window('minimize'); },
    quit() { if (api && api.window) api.window('quit'); },
  };
  SSMT.command = (id) => { if (COMMANDS[id]) COMMANDS[id](); };

  /** The menu bar as on the Mac (labels follow the open function and the language). */
  function menuModel() {
    const sec = S.section;
    const item = (id, key, accel) => ({ id, label: t(key), accel });
    const file = [
      item('open', sec === 'show' ? 'show.open' : sec === 'inputList' ? 'il.open' : 'session.open', 'Ctrl+O'),
      item('save', sec === 'show' ? 'show.save' : sec === 'inputList' ? 'il.save' : 'session.save', 'Ctrl+S'),
    ];
    if (sec === 'show') file.push(item('saveAs', 'il.saveAs', 'Ctrl+Shift+S'), item('showNew', 'show.new'), item('addAudio', 'show.addAudio', 'Ctrl+1'));
    if (sec === 'inputList') file.push(item('saveAs', 'il.saveAs', 'Ctrl+Shift+S'), item('ilNew', 'il.new'), item('ilPDF', 'il.export.pdf', 'Ctrl+E'));
    file.push({ divider: true }, item('reportPDF', 'report.pdf', 'Ctrl+Shift+P'), item('reportPNG', 'report.png'), item('reportCopy', 'report.copy'),
      { divider: true }, item('quit', 'menu.quit', 'Ctrl+Q'));
    const ssmt = [item('stop', 'action.stop', 'Esc')];
    if (sec === 'setup') {
      ssmt.push(item('noise', 'noise.toggle', 'Ctrl+N'), item('delay', 'delay.find', 'Ctrl+D'), { divider: true },
        item('wizard', 'mode.wizard', 'Ctrl+1'), item('expert', 'mode.expert', 'Ctrl+E'), item('stage', 'mode.stage', 'Ctrl+L'), { divider: true },
        item('begin', 'wizard.begin', 'Ctrl+B'), { divider: true });
    }
    ssmt.push(item('mini', 'mini.toggle', 'Ctrl+Shift+M'), item('clickThroughOff', 'mini.clickThroughOff'));
    return [{ label: t('menu.file'), items: file }, { label: 'SSMT', items: ssmt },
      { label: t('menu.window'), items: [item('minimize', 'menu.minimize', 'Ctrl+M')] }];
  }
  let lastMenu = '';
  function updateMenu() {
    if (!api || !api.setMenu) return;
    const m = menuModel();
    const key = JSON.stringify(m);
    if (key === lastMenu) return;
    lastMenu = key;
    api.setMenu(m);
  }
  if (api && api.onMenu) api.onMenu((id) => SSMT.command(id));

  // The menu's key equivalents, by physical key (any keyboard layout), while typing too. The sections handle their
  // own (Ptch and Qtrl: open, save, add audio, export…); these are the ones the Mac menu adds for every function.
  document.addEventListener('keydown', (e) => {
    const mod = e.ctrlKey || e.metaKey;
    // Esc = STOP everywhere, even in a text field (AppDelegate); the key still reaches the screen (menus, Qtrl panic).
    if (e.key === 'Escape' && !mod && !e.altKey && !e.shiftKey) { COMMANDS.stop(); return; }
    if (!mod || e.altKey || e.repeat) return;
    const shift = e.shiftKey, sec = S.section, code = e.code;
    let id = null;
    if (shift && code === 'KeyM') id = 'mini';
    else if (shift && code === 'KeyP') id = 'reportPDF';
    else if (!shift && code === 'KeyQ') id = 'quit';
    else if (!shift && code === 'KeyM') id = 'minimize';
    else if (!shift && (code === 'KeyO' || code === 'KeyS') && sec !== 'show' && sec !== 'inputList') id = code === 'KeyO' ? 'open' : 'save';
    else if (!shift && sec === 'setup') {
      id = { KeyN: 'noise', KeyD: 'delay', Digit1: 'wizard', KeyE: 'expert', KeyL: 'stage', KeyB: 'begin' }[code] || null;
    }
    if (!id) return;
    e.preventDefault();
    e.stopPropagation();
    COMMANDS[id]();
  }, true);
  // Space toggles the noise wherever the TopBar is shown (its button's shortcut), unless a field has the keys.
  document.addEventListener('keydown', (e) => {
    if (S.section !== 'inputList' || e.code !== 'Space' || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey || e.defaultPrevented) return;
    if (e.target.closest && e.target.closest('input, textarea, select, [contenteditable]')) return;
    e.preventDefault();
    COMMANDS.noise();
  });

  SSMT.render();
})();
