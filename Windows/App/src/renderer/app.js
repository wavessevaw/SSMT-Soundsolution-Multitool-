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

  function workspace() {
    const sec = sections[S.section];
    const top = sec && sec.topBar ? sec.topBar() : '';
    const err = S.lastError ? `<div class="error-banner">${icon('exclamationmark.triangle.fill', 14)}<span class="text">${esc(S.lastError)}</span>
      <button class="btn plain" data-shell="dismissError">${icon('xmark', 13)}</button></div>` : '';
    return top + err;
  }

  function draw() {
    const root = document.getElementById('app');
    if (!root.firstChild) {
      root.innerHTML = `<aside class="glass sidebar" id="sidebar"></aside>
        <div class="workspace"><div id="workspace-head"></div><div class="screen" id="screen"></div></div>`;
    }
    // Keep the focused field and its cursor across the redraw.
    const a = document.activeElement;
    const focus = a && a.id ? { id: a.id, start: a.selectionStart, end: a.selectionEnd } : null;
    document.getElementById('sidebar').innerHTML = sidebar();
    document.getElementById('workspace-head').innerHTML = workspace();
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
    document.documentElement.lang = S.lang;
    if (focus) {
      const el = document.getElementById(focus.id);
      if (el) { el.focus(); try { el.setSelectionRange(focus.start, focus.end); } catch (_) { /* not a text field */ } }
    }
  }
  SSMT.draw = draw;

  const shell = {
    section(id) { S.section = id; SSMT.store.set('section', id); SSMT.render(); },
    dismissError() { S.lastError = null; SSMT.render(); },
    brand() { if (SSMT.brand) SSMT.brand.brandTapped(); },
  };

  // Events go to the shell (data-shell) or to the section that owns the element's pane or the sidebar.
  const owner = (el) => {
    const pane = el.closest('.pane');
    return sections[pane ? pane.id.slice(5) : S.section];
  };
  document.addEventListener('click', (e) => {
    const sh = e.target.closest('[data-shell]');
    if (sh) { shell[sh.dataset.shell] && shell[sh.dataset.shell](sh.dataset.arg); return; }
    const el = e.target.closest('[data-act]');
    if (!el || el.disabled || el.closest('#pane-assist')) return;
    const sec = owner(el);
    const fn = sec && sec.actions && sec.actions[el.dataset.act];
    if (fn) fn(el.dataset.arg, el, e);
  });
  document.addEventListener('input', (e) => {
    const k = e.target.dataset && e.target.dataset.input;
    if (!k || e.target.closest('#pane-assist')) return;
    const sec = owner(e.target);
    if (sec && sec.inputs && sec.inputs[k]) sec.inputs[k](e.target.type === 'checkbox' ? e.target.checked : e.target.value, e.target);
  });
  document.addEventListener('change', (e) => {
    const k = e.target.dataset && e.target.dataset.change;
    if (!k || e.target.closest('#pane-assist')) return;
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
  SSMT.render();
})();
