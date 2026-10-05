'use strict';
/* global SSMT */
// Qtrl, the show control center (App/SSMT/Show/ShowWorkspace.swift, CueListView.swift, ShowPanels.swift): GO and
// "standing by" on top, the cue toolbar (Edit), the cue list with the sidebar (lists, one-shot, active), the
// timeline and the inspector, and the status bar with Edit / Show. The engine's Qtrl module (SSMTCore) owns the show;
// this file draws what it reports and sends what the person does.

(function () {
  const { t, esc, icon } = SSMT;
  const Q = SSMT.qtrl;
  const { st, ui, cmd, showTime, kindName, label } = Q;

  // MARK: - GO and standing by (QtrlGoBar)

  function goBar() {
    const c = Q.cue(Q.playhead());
    const anyPaused = st.live.running.some((r) => r.paused);
    const ready = !!c;
    const next = c
      ? `<div class="next-cue"><span class="num">${esc(c.number)}</span><span class="name">${esc(c.name || kindName(c.kind))}</span></div>`
      : `<div class="end">${esc(t('show.endOfList'))}</div>`;
    return `<div class="glass q-gobar">
      <button class="q-go ${ready ? 'ready' : ''} ${st.live.goGuarded ? 'guarded' : ''}" data-act="go" title="${esc(t('show.go.help'))}"${ready ? '' : ' disabled'}>
        <b>GO</b><span>${esc(t('show.go.hint'))}</span></button>
      <div class="standby"><div class="cap">${esc(t('show.next').toUpperCase())}</div>${next}</div>
      <div class="vrule"></div>
      <div class="notes">${esc(c ? c.notes : '')}</div>
      <div class="buttons">
        <button class="btn secondary ${anyPaused ? 'active' : ''}" data-act="${anyPaused ? 'resumeAll' : 'pauseAll'}"${st.live.running.length ? '' : ' disabled'}>${icon(anyPaused ? 'play.fill' : 'pause.fill', 13)}${esc(t(anyPaused ? 'show.resumeAll' : 'show.pauseAll'))}</button>
        <button class="btn danger" data-act="panic" title="${esc(t('show.panic.help'))}">${icon('stop.fill', 13)}${esc(t('show.panic'))}</button>
      </div></div>`;
  }

  // MARK: - Toolbar (QtrlToolbar)

  function toolbar() {
    if (!st.show || st.show.showMode) return '';
    const sel = Q.selection();
    const none = sel.size === 0;
    const anyGroup = [...sel].some((id) => (Q.cue(id) || {}).kind === 'group');
    const kinds = Q.MEDIA_KINDS.filter((k) => k !== 'audio' && k !== 'fade').concat(Q.CONTROL_KINDS);
    return `<div class="q-toolbar glass-12">
      <button class="btn primary" data-act="chooseAudio" title="${esc(t('show.addAudio.help'))}">${icon('plus', 13)}${esc(kindName('audio'))}</button>
      ${Q.tool('chart.line.uptrend.xyaxis', t('show.fadeIn.help'), 'addFade', '1')}
      ${Q.tool('chart.line.downtrend.xyaxis', t('show.fadeOut.help'), 'addFade', '0')}
      ${kinds.map((k) => Q.tool(Q.KIND_ICON[k], k === 'group' ? t('show.group.help') : kindName(k), 'add', k)).join('')}
      <div class="spacer"></div>
      ${Q.tool('plus.square.on.square', t('action.duplicate'), 'duplicate', undefined, { disabled: none })}
      ${Q.tool('arrow.up', t('show.up'), 'moveSel', '-1', { disabled: none })}
      ${Q.tool('arrow.down', t('show.down'), 'moveSel', '1', { disabled: none })}
      ${Q.tool('square.stack.3d.up.slash', t('show.ungroup'), 'ungroup', undefined, { disabled: !anyGroup })}
      ${Q.tool('list.number', t('show.renumber'), 'renumber')}
      ${Q.tool('trash', t('action.delete'), 'delete', undefined, { disabled: none })}
    </div>`;
  }

  // MARK: - Cue list (CueListView, CueRow)

  function flattened(cues, depth, out, collapsed) {
    for (const c of cues || []) {
      out.push({ cue: c, depth });
      if (!collapsed.has(c.id)) flattened(c.children, depth + 1, out, collapsed);
    }
    return out;
  }
  const rowsOf = () => {
    const l = Q.currentList();
    return l ? flattened(l.cues, 0, [], new Set(st.show.collapsed)) : [];
  };

  function listHeader() {
    return `<div class="q-list-head"><span style="width:40px"></span><span style="width:54px">${esc(t('show.col.number'))}</span><span style="width:26px"></span>
      <span class="grow">${esc(t('show.col.name'))}</span><span class="r" style="width:64px">${esc(t('show.col.pre'))}</span>
      <span class="r" style="width:76px">${esc(t('show.col.action'))}</span><span class="r" style="width:64px">${esc(t('show.col.post'))}</span><span style="width:34px"></span></div>`;
  }

  function problemOf(c) {
    if (c.kind === 'audio') {
      const p = Q.pathOf(c.id);
      if (!p || st.show.missing.includes(p)) return 'show.fileMissing';
      if (st.show.unreadable[p] !== undefined) return 'show.fileUnreadable';
    }
    return st.live.problems[c.id] || null;
  }

  function actionText(c) {
    switch (c.kind) {
      case 'audio': {
        if (!c.audio || Q.fileLength(c.id) === null) return '';
        return showTime(Q.audioLength(c.id));
      }
      case 'wait': return showTime(c.duration);
      case 'fade': return showTime(c.fade ? c.fade.duration : null);
      case 'stop': return c.stopFade > 0 ? showTime(c.stopFade) : '';
      default: return '';
    }
  }

  function rowTitle(c) {
    if (c.name) return c.name;
    if (Q.NEEDS_TARGET.has(c.kind)) {
      const tg = Q.cue(c.target);
      if (tg) return kindName(c.kind) + ' → ' + (tg.name || tg.number);
    }
    return kindName(c.kind);
  }

  function rowSubtitle(c, problem) {
    if (c.kind === 'audio') {
      if (problem) return t(problem);
      return c.audio ? Q.basename(c.audio.file) : null;
    }
    if (Q.NEEDS_TARGET.has(c.kind)) {
      const tg = Q.cue(c.target);
      if (!tg) return t('show.noTarget');
      return '→ ' + [tg.number, tg.name].filter((x) => x).join(' · ');
    }
    if (c.kind === 'group') return t('group.mode.' + (c.groupMode || 'sequence'));
    if (c.notes) return c.notes;
    return null;
  }

  function cueRow(c, depth, ph, sel, r) {
    const problem = problemOf(c);
    const hasProblem = problem !== null && problem !== 'error.show.notReady';
    const isPh = c.id === ph;
    const armed = c.armed !== false;
    const sub = rowSubtitle(c, problem);
    const subColor = hasProblem ? 'var(--status-warning)' : problem ? 'var(--data-blue)' : 'var(--text-secondary)';
    let state = '';
    if (r) {
      const ic = r.paused ? 'pause.circle.fill' : r.phase === 'preWait' ? 'clock.fill' : 'play.circle.fill';
      const col = r.paused ? 'var(--signal-yellow)' : r.phase === 'preWait' ? 'var(--data-blue)' : 'var(--accent)';
      state = `<span class="state filled" style="color:${col}">${icon(ic, 14)}</span>`;
    } else if (hasProblem) {
      state = `<span class="state" style="color:var(--status-warning)">${icon('exclamationmark.triangle.fill', 11)}</span>`;
    }
    const time = (text, w, live) => `<span class="time${live !== null ? ' live' : ''}" style="width:${w}px">${esc(live !== null ? '−' + showTime(live) : text)}</span>`;
    const pre = r && r.phase === 'preWait' ? Q.remaining(r) : null;
    const act = r && r.phase === 'running' ? Q.remaining(r) : null;
    const prog = r ? Q.progress(r) : null;
    const collapsed = st.show.collapsed.includes(c.id);
    const glyph = c.continueMode === 'autoContinue'
      ? `<span style="color:var(--data-blue)" title="${esc(t('continue.autoContinue'))}">${icon('arrow.down.to.line.compact', 12)}</span>`
      : c.continueMode === 'autoFollow' ? `<span style="color:var(--accent)" title="${esc(t('continue.autoFollow'))}">${icon('arrow.turn.right.down', 12)}</span>` : '';
    const color = Q.COLORS[c.color || ''];
    return `<div class="q-row${sel ? ' sel' : ''}${isPh ? ' ph' : ''}" data-k="${c.id}" data-act="row" data-arg="${c.id}" draggable="true">
      ${r && prog !== null ? `<div class="prog" style="width:${(prog * 100).toFixed(2)}%;background:${r.phase === 'preWait' ? 'rgba(100,210,255,0.12)' : 'rgba(46,229,157,0.12)'}"></div>` : ''}
      ${color && color !== 'transparent' ? `<div class="tag" style="background:${color}"></div>` : ''}
      <span class="mark">${isPh ? icon('arrowtriangle.right.fill', 11, 'filled') : ''}</span>
      <span class="st">${state}</span>
      <span class="number">${esc(c.number)}</span>
      <span class="namecell"><span style="width:${depth * 16}px;flex:none"></span>
        ${c.kind === 'group' ? `<button class="chev" data-act="collapse" data-arg="${c.id}">${icon(collapsed ? 'chevron.right' : 'chevron.down', 10)}</button>` : ''}
        <span class="kind" style="color:${armed ? 'var(--text-secondary)' : 'var(--text-muted)'}">${icon(Q.KIND_ICON[c.kind], 12)}</span>
        <span class="titles"><span class="title${isPh ? ' b' : ''}${armed ? '' : ' off'}">${esc(rowTitle(c))}</span>${sub !== null ? `<span class="sub" style="color:${subColor}">${esc(sub)}</span>` : ''}</span>
        ${c.hotkey ? `<span class="hotkey">${esc(c.hotkey.toUpperCase())}</span>` : ''}
      </span>
      ${time(c.preWait > 0 ? showTime(c.preWait) : '', 64, pre)}
      ${time(actionText(c), 76, act)}
      ${time(c.continueMode === 'autoContinue' ? showTime(c.postWait) : '', 64, null)}
      <span class="glyph">${glyph}</span></div>`;
  }

  function cueList() {
    const rows = rowsOf();
    const ph = Q.playhead();
    const sel = Q.selection();
    const run = Q.running();
    const body = rows.map((r) => cueRow(r.cue, r.depth, ph, sel.has(r.cue.id), run.get(r.cue.id))).join('');
    const empty = rows.length ? '' : `<div class="q-empty">${icon('waveform.badge.plus', 34)}<span>${esc(t('show.empty'))}</span></div>`;
    return `<div class="glass q-list">${listHeader()}<div class="q-rows" id="q-rows" data-keep-scroll>${body}<div class="q-dropzone" data-act="clearSel"></div>${empty}</div></div>`;
  }

  // MARK: - Sidebar (QtrlSidebar, PadGridView, RunningCuesPanel, OutputMeters)

  function sidebar() {
    if (!ui.sidebar) return '';
    const n = st.live.running.length;
    const tabs = Q.segmented('sidebarTab', [['lists', esc(t('show.lists'))], ['pads', esc(t('show.oneShot'))], ['active', esc(t('show.sidebar.active', n))]], ui.sidebarTab, { cls: 'full' });
    let body;
    if (ui.sidebarTab === 'lists') body = listsTab();
    else if (ui.sidebarTab === 'pads') body = pads();
    else body = `<div class="q-running">${runningPanel()}</div>${meters()}`;
    return `<div class="glass q-sidebar">${tabs}${body}</div>`;
  }

  function listsTab() {
    const showMode = st.show.showMode;
    const rows = Q.idx.cueLists.map((l) => {
      const on = l.id === (Q.currentList() || {}).id;
      return `<button class="q-listrow${on ? ' on' : ''}" data-act="selectList" data-arg="${l.id}" data-menu="list:${l.id}">
        <span style="color:${on ? 'var(--accent)' : 'var(--text-muted)'}">${icon('list.bullet', 11)}</span><span class="n">${esc(l.name)}</span><span class="c">${(l.cues || []).length}</span></button>`;
    }).join('');
    return `<div class="q-lists">${rows}${showMode ? '' : `<button class="q-link" data-act="addList">${icon('plus', 12)}${esc(t('show.list.add'))}</button>`}</div>`;
  }

  function pads() {
    const bank = Q.currentBank();
    const run = Q.running();
    const sel = Q.selection();
    const banks = Q.idx.banks.map((b) => `<button class="q-bank${b.id === (bank || {}).id ? ' on' : ''}" data-act="bank" data-arg="${b.id}">${esc(b.name)}</button>`).join('');
    const plus = st.show.showMode ? '' : `<button class="q-plain" data-act="padMenu" title="${esc(t('show.pad.add'))}">${icon('plus', 14)}</button>`;
    let grid;
    if (bank && (bank.cues || []).length) {
      grid = `<div class="q-pads" data-keep-scroll id="q-pads">${bank.cues.map((c) => pad(c, run.get(c.id), sel.has(c.id))).join('')}</div>`;
    } else {
      grid = `<div class="q-pads-empty">${icon('square.grid.3x3.square', 26)}<span>${esc(t('show.pad.empty'))}</span></div>`;
    }
    return `<div class="q-padhead"><div class="spacer"></div><div class="q-banks">${banks}</div>${plus}</div>${grid}`;
  }

  function pad(c, r, sel) {
    const playing = !!r;
    const len = Q.audioLength(c.id);
    const length = len === undefined || len === null ? (c.audio && c.audio.plays === 0 ? '∞' : '') : showTime(len);
    const p = r ? Q.progress(r) : null;
    const badge = c.padMode === 'hold' ? `<span class="badge">${icon('hand.point.up', 9)}</span>`
      : c.audio && c.audio.plays === 0 ? `<span class="badge" style="color:var(--data-blue)">${icon('repeat', 9)}</span>` : '';
    return `<div class="q-pad${playing ? ' playing' : ''}${sel ? ' sel' : ''}" data-k="${c.id}" data-pad="${c.id}" data-menu="pad:${c.id}">
      <span class="name">${esc(c.name || kindName(c.kind))}</span><span class="foot"><span class="key">${esc(c.hotkey || '')}</span>
      <span class="len${playing ? ' live' : ''}">${esc(playing ? '−' + showTime(Q.remaining(r)) : length)}</span></span>
      ${p !== null ? `<span class="bar" style="width:${(p * 100).toFixed(2)}%"></span>` : ''}${badge}</div>`;
  }

  function runningPanel() {
    const list = st.live.running;
    const none = list.length ? '' : `<div class="q-none">${esc(t('show.running.none'))}</div>`;
    const tiles = list.map((r) => {
      const c = Q.cue(r.id);
      const tint = r.paused ? 'var(--signal-yellow)' : r.phase === 'preWait' ? 'var(--data-blue)' : r.phase === 'stopping' ? 'var(--status-error)' : 'var(--accent)';
      const p = Q.progress(r);
      const name = [c ? c.number : '', c ? c.name : ''].filter((x) => x).join(' · ');
      return `<div class="q-tile"><div class="line"><span style="color:${tint}" class="ic">${icon(c ? Q.KIND_ICON[c.kind] : 'questionmark', 11)}</span>
        <span class="n">${esc(name)}</span>${r.iteration !== null && r.iteration !== undefined ? `<span class="it">×${r.iteration}</span>` : ''}
        <span class="rem" style="color:${tint}">${esc((r.phase === 'preWait' ? '▸ ' : '−') + showTime(Q.remaining(r)))}</span>
        <button class="q-mini" data-act="togglePause" data-arg="${r.id}">${icon(r.paused ? 'play.fill' : 'pause.fill', 10, 'filled')}</button>
        <button class="q-mini" data-act="stopCue" data-arg="${r.id}">${icon('stop.fill', 10, 'filled')}</button></div>
        <div class="track"><div style="width:${((p === null ? 1 : p) * 100).toFixed(2)}%;background:${tint};opacity:${p === null ? 0.35 : 1}"></div></div></div>`;
    }).join('');
    return `${none}<div class="q-tiles" data-keep-scroll id="q-tiles">${tiles}</div>`;
  }

  function meters() {
    const outs = (st.doc ? st.doc.outputs : []).slice(0, 16);
    const bars = outs.map((o, i) => {
      const peak = i < st.live.meters.length ? st.live.meters[i] : 0;
      const db = peak > 0 ? 20 * Math.log10(peak) : -100;
      const fill = Math.max(0, Math.min(1, (db + 60) / 60));
      const clip = i < st.live.clipping.length && st.live.clipping[i];
      const col = clip ? 'var(--status-error)' : db > -12 ? 'var(--signal-yellow)' : 'var(--accent)';
      return `<div class="q-meter" title="${db > -99 ? db.toFixed(1) + ' dBFS' : '−∞'}"><div class="lamp${clip ? ' on' : ''}"></div>
        <div class="well"><div style="height:${(54 * fill).toFixed(1)}px;background:${col}"></div></div><span>${esc(o.name)}</span></div>`;
    }).join('');
    return `<div class="q-meters"><div class="cap">${esc(t('show.outputs').toUpperCase())}</div><div class="row">${bars}</div></div>`;
  }

  // MARK: - Status bar (QtrlStatusBar)

  function statusBar() {
    const s = st.show;
    const showMode = s.showMode;
    const out = s.output;
    const chip = (ic, text, tint, extra = '') => `<span class="q-chip" style="color:${tint}"${extra}>${icon(ic, 10)}<span>${esc(text)}</span></span>`;
    let chips = out.error === null || out.error === undefined
      ? chip('hifispeaker', `${out.name} · ${Math.trunc(out.sampleRate / 1000)} kHz`, 'var(--text-secondary)')
      : chip('exclamationmark.triangle.fill', t('show.output.error'), 'var(--status-error)', ` title="${esc(out.error)}"`);
    if (s.memory > 0) chips += chip('memorychip', `${Math.trunc(s.memory / 1048576)} MB`, 'var(--text-secondary)', ` title="${esc(t('show.memory.help'))}"`);
    if (s.missing.length) chips += `<button class="q-plainbtn" data-act="relink" title="${esc(t('show.relink.help'))}">${chip('questionmark.folder', t('show.missing', s.missing.length), 'var(--status-warning)')}</button>`;
    const tg = (ic, help, on, act) => `<button class="q-tool${on ? ' lit' : ''}" data-act="${act}" title="${esc(help)}">${icon(ic, 13)}</button>`;
    return `<div class="q-status glass-12">
      ${Q.segmented('showMode', [['0', esc(t('show.mode.edit'))], ['1', esc(t('show.mode.show'))]], showMode ? '1' : '0', { cls: 'mode' })}
      <input class="q-showname" id="q-showname" placeholder="${esc(t('show.name.placeholder'))}" value="${esc(st.doc.name)}" data-input="showName"${showMode ? ' disabled' : ''}>
      <div class="spacer"></div><div class="q-chips">${chips}</div>
      ${tg('checklist', t('show.check'), false, 'popIssues')}
      <div class="vrule"></div>
      ${tg('timeline.selection', t('show.timeline'), ui.timeline, 'toggleTimeline')}
      ${showMode ? '' : tg('rectangle.bottomthird.inset.filled', t('show.view.inspector'), ui.inspector, 'toggleInspector')}
      ${tg('sidebar.right', t('show.view.sidebar'), ui.sidebar, 'toggleSidebar')}
      <div class="vrule"></div>
      ${tg('keyboard', t('show.keys.title'), false, 'popKeys')}
      ${tg('antenna.radiowaves.left.and.right', t('osc.title'), false, 'openOSC')}
      ${tg('gearshape', t('show.settings'), false, 'openSettings')}
    </div>`;
  }

  function errorBanner() {
    const e = st.show && st.show.error;
    if (!e) return '';
    const text = e.text !== undefined ? e.text : t(e.key, ...(e.args || [])) + (e.suffix || '');
    return `<div class="error-banner">${icon('exclamationmark.triangle.fill', 14)}<span class="text">${esc(text)}</span>
      <button class="btn plain" data-act="dismissError">${icon('xmark', 13)}</button></div>`;
  }

  // MARK: - Regions

  /** Each region of the screen is rebuilt only when its markup changed (while something plays, ~25 times a second). */
  const REGIONS = {
    gobar: goBar,
    error: errorBanner,
    toolbar,
    list: cueList,
    timeline: () => (ui.timeline ? Q.timelineCard() : ''),
    inspector: () => (!st.show.showMode && ui.inspector ? Q.inspector() : ''),
    sidebar,
    status: statusBar,
    overlay: () => Q.overlay(),
  };
  const cache = {};
  let pressing = false;
  let pendingDraw = false;

  function skeleton() {
    return `<div class="qtrl" id="qtrl">
      <div class="q-r" data-r="gobar"></div><div class="q-r" data-r="error"></div><div class="q-r" data-r="toolbar"></div>
      <div class="q-main"><div class="q-col"><div class="q-r list" data-r="list"></div><div class="q-r timeline" data-r="timeline"></div>
      <div class="q-r inspector" data-r="inspector"></div></div><div class="q-r side" data-r="sidebar"></div></div>
      <div class="q-r" data-r="status"></div></div><div class="q-r" data-r="overlay"></div>`;
  }

  /** Replaces a region, keeping scroll positions and the text being typed. */
  function patch(el, html, name) {
    if (cache[name] === html) return false;
    if (name === 'list' && cache.list !== undefined && patchRows(el, html)) { cache.list = html; return true; }
    cache[name] = html;
    const scrolls = {};
    el.querySelectorAll('[data-keep-scroll]').forEach((s) => { if (s.id) scrolls[s.id] = [s.scrollTop, s.scrollLeft]; });
    const a = document.activeElement;
    const typing = a && el.contains(a) && a.id && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') ? { id: a.id, value: a.value } : null;
    el.innerHTML = html;
    for (const id in scrolls) { const s = document.getElementById(id); if (s) { s.scrollTop = scrolls[id][0]; s.scrollLeft = scrolls[id][1]; } }
    if (typing) { const f = document.getElementById(typing.id); if (f && f.value !== typing.value) f.value = typing.value; }
    return true;
  }

  /** The cue list: only the rows that changed are replaced (so a click on a row is not lost to a redraw). */
  function patchRows(el, html) {
    const tpl = document.createElement('template');
    tpl.innerHTML = html;
    const oldRows = el.querySelector('#q-rows');
    const newRows = tpl.content.querySelector('#q-rows');
    if (!oldRows || !newRows || oldRows.children.length !== newRows.children.length) return false;
    const oldHead = el.querySelector('.q-list-head');
    const newHead = tpl.content.querySelector('.q-list-head');
    if (!oldHead || oldHead.outerHTML !== newHead.outerHTML) return false;
    for (let i = 0; i < newRows.children.length; i++) {
      const o = oldRows.children[i], n = newRows.children[i];
      if (o.getAttribute('data-k') !== n.getAttribute('data-k')) return false;
    }
    for (let i = 0; i < newRows.children.length; i++) {
      const o = oldRows.children[i], n = newRows.children[i];
      if (o.outerHTML !== n.outerHTML) o.replaceWith(n.cloneNode(true));
    }
    return true;
  }

  function update(pane) {
    if (!st.show || !st.doc) return;
    if (pressing) { pendingDraw = true; return; }
    if (!pane.querySelector('#qtrl')) { pane.innerHTML = skeleton(); for (const k in cache) delete cache[k]; }
    const root = pane.querySelector('#qtrl');
    root.classList.toggle('solo', !!ui.solo);
    for (const name in REGIONS) {
      const el = pane.querySelector(`[data-r="${name}"]`);
      const html = ui.solo && name !== 'overlay' ? '' : REGIONS[name]();
      patch(el, html, name);
      el.style.display = html ? '' : 'none';
    }
    if (Q.drawCanvases) Q.drawCanvases(pane);
  }

  // MARK: - Engine events

  function onEvent(ev) {
    switch (ev.event) {
      case 'show': {
        const first = !st.show;
        const prevKind = st.show && st.show.selected ? (Q.cue(st.show.selected.id) || {}).kind : null;
        const prevSel = st.show && st.show.selected ? st.show.selected.id : null;
        st.show = ev;
        st.doc = ev.doc;
        Q.reindex();
        // Another type of cue selected: the inspector opens on its own settings (waveform, fade, multitrack…).
        const sel = ev.selected ? Q.cue(ev.selected.id) : null;
        if (sel && !first && (sel.kind !== prevKind) && prevSel !== null) ui.inspectorTab = Q.primaryTab(sel);
        if (ui.oscPage === 'list' && ui.oscDraft && !ui.sheet) ui.oscDraft = null;
        break;
      }
      case 'showLive': st.live = ev; st.liveAt = performance.now(); break;
      case 'showStatic': st.statics = ev; break;
      case 'showWave': st.waves[ev.path] = ev.peaks; break;
      case 'showWaveSlice': st.slices[ev.key] = ev.peaks; break;
      case 'showEnv': st.envs[ev.key] = ev.db; break;
      case 'showOSC': st.osc = ev; break;
      case 'showDecode': if (Q.decode) Q.decode(ev); return;
      default: return;
    }
    if (SSMT.S.section === 'show') SSMT.render();
  }

  // MARK: - Actions

  const sendSel = (ids, playhead) => cmd('select', { ids, playhead });
  let lastClick = { id: null, at: 0 };

  function selectRow(id, e) {
    // Leave any text field of the inspector, so Space is GO again and not a typed space.
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    const now = performance.now();
    const double = lastClick.id === id && now - lastClick.at < 400;
    lastClick = { id, at: now };
    if (double) { openCueSettings(id); return; }
    const sel = Q.selection();
    const rows = rowsOf();
    if (e && (e.ctrlKey || e.metaKey)) {
      if (sel.has(id)) sel.delete(id); else sel.add(id);
      ui.anchor = id;
      sendSel([...sel]);
    } else if (e && e.shiftKey && ui.anchor) {
      const i = rows.findIndex((r) => r.cue.id === ui.anchor), j = rows.findIndex((r) => r.cue.id === id);
      if (i >= 0 && j >= 0) sendSel(rows.slice(Math.min(i, j), Math.max(i, j) + 1).map((r) => r.cue.id));
    } else {
      ui.anchor = id;
      // The clicked cue is the next one for GO (a cue that is playing is only selected).
      const playing = st.live.running.some((r) => r.id === id);
      sendSel([id], playing ? undefined : id);
    }
  }

  /** Double click on a cue: selected, the inspector opens on its own settings; in Show mode it is only stood by. */
  function openCueSettings(id) {
    const c = Q.cue(id);
    if (!c) return;
    if (st.show.showMode) { cmd('setPlayhead', { id }); return; }
    sendSel([id]);
    ui.inspectorTab = Q.primaryTab(c);
    ui.inspector = true;
    Q.saveUI();
    SSMT.render();
  }

  async function chooseAudio(after, group) {
    const api = window.ssmt;
    if (!api || !api.openFile) return;
    const paths = await api.openFile({ multiple: true, filters: [{ name: 'Audio', extensions: AUDIO_EXT }] });
    if (paths && paths.length) cmd('addAudio', { paths, after, group });
  }
  const AUDIO_EXT = ['wav', 'wave', 'aif', 'aiff', 'aifc', 'mp3', 'm4a', 'aac', 'caf', 'flac', 'ogg', 'opus', 'mp4', 'mov', 'm4v', 'webm'];

  async function openShow() {
    const api = window.ssmt;
    if (!api || !api.openFile) return;
    const p = await api.openFile({ filters: [{ name: 'SSMT Show', extensions: ['ssmtshow', 'json'] }] });
    if (p && p[0]) cmd('open', { path: p[0] });
  }
  async function saveShow(as) {
    const api = window.ssmt;
    if (!as && st.show && st.show.file) { cmd('save'); return; }
    if (!api || !api.saveFile) return;
    const p = await api.saveFile({ defaultName: (st.doc.name || 'Show') + '.ssmtshow', filters: [{ name: 'SSMT Show', extensions: ['ssmtshow'] }] });
    if (p) cmd('save', { path: p });
  }
  async function relink() {
    const api = window.ssmt;
    if (!api || !api.openFile) return;
    const p = await api.openFile({ directory: true });
    if (p && p[0]) cmd('relink', { folder: p[0] });
  }
  async function choosePads() {
    const api = window.ssmt;
    if (!api || !api.openFile) return;
    const paths = await api.openFile({ multiple: true, filters: [{ name: 'Audio', extensions: AUDIO_EXT }] });
    if (paths && paths.length) cmd('addPads', { paths, bankWord: t('show.bank') });
  }

  const actions = {
    go: () => cmd('go'),
    panic: () => cmd('panic'),
    pauseAll: () => cmd('pauseAll'),
    resumeAll: () => cmd('resumeAll'),
    chooseAudio: () => chooseAudio(),
    addFade: (a) => cmd('addFade', { fadeIn: a === '1', name: '' }),
    add: (k) => cmd('add', { kind: k }),
    duplicate: () => cmd('duplicate'),
    moveSel: (d) => cmd('moveSel', { delta: Number(d) }),
    ungroup: () => cmd('ungroup'),
    renumber: () => cmd('renumber'),
    delete: () => cmd('delete'),
    row: (id, el, e) => { if (e.target.closest('.chev')) return; selectRow(id, e); },
    collapse: (id) => cmd('collapse', { id }),
    clearSel: () => sendSel([]),
    sidebarTab: (v) => { ui.sidebarTab = v; Q.saveUI(); SSMT.render(); },
    selectList: (id) => cmd('selectList', { id }),
    addList: () => cmd('addList', { listWord: t('show.list') }),
    bank: (id) => cmd('bank', { id }),
    padMenu: (a, el, e) => {
      const r = el.getBoundingClientRect();
      Q.openMenu(r.left, r.bottom + 4, [[t('show.pad.add'), choosePads], [t('show.bank.add'), () => cmd('addBank', { bankWord: t('show.bank') })]]);
    },
    togglePause: (id) => cmd('togglePause', { id }),
    stopCue: (id) => cmd('stop', { id }),
    showMode: (v) => cmd('showMode', { on: v === '1' }),
    relink: () => relink(),
    toggleTimeline: () => { ui.timeline = !ui.timeline; Q.saveUI(); SSMT.render(); },
    toggleInspector: () => { ui.inspector = !ui.inspector; Q.saveUI(); SSMT.render(); },
    toggleSidebar: () => { ui.sidebar = !ui.sidebar; Q.saveUI(); SSMT.render(); },
    popIssues: () => { ui.pop = ui.pop === 'issues' ? null : 'issues'; SSMT.render(); },
    popKeys: () => { ui.pop = ui.pop === 'keys' ? null : 'keys'; SSMT.render(); },
    openOSC: () => Q.openOSC(),
    openSettings: () => Q.openSettings(),
    dismissError: () => cmd('dismissError'),
    newShow: () => cmd('new'),
    openShow: () => openShow(),
    saveShow: () => saveShow(false),
    saveShowAs: () => saveShow(true),
  };
  const inputs = {
    showName: (v) => cmd('name', { value: v }),
  };

  // MARK: - Keyboard (ShowStore.handleKey, by physical key so any layout works)

  const FKEYS = new Set(['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12']);
  let lastStop = 0;

  function keys(e) {
    if (ui.prompt || ui.sheet || ui.menu) return; // a sheet or a dialog has the keys
    if (!st.show) return;
    const showMode = st.show.showMode;
    const ctrl = e.ctrlKey || e.metaKey;
    const done = () => { e.preventDefault(); e.stopPropagation(); };
    if (ctrl && !e.altKey) { if (commandKey(e, showMode)) done(); return; }
    if (e.altKey && !ctrl) {
      if (!showMode && (e.code === 'ArrowLeft' || e.code === 'ArrowRight')) { cmd('nudge', { delta: e.code === 'ArrowRight' ? 0.1 : -0.1 }); done(); }
      return;
    }
    if (e.altKey) return;
    if (FKEYS.has(e.key)) {
      done();
      if (!e.repeat) cmd('fkey', { key: e.key, down: true });
      return;
    }
    if (e.code === 'Space') { done(); if (!e.repeat) cmd('go'); return; }
    if (e.code === 'Escape') { done(); if (ui.pop) { ui.pop = null; SSMT.render(); return; } cmd('panic'); return; }
    const ch = (e.key || '').toLowerCase();
    // Hotkeys the person gave to cues come first.
    if (ch.length === 1 && st.doc && Q.idx && [...Q.idx.byId.values()].some((x) => (x.cue.hotkey || '').toLowerCase() === ch)) {
      done(); cmd('hotkey', { key: ch }); return;
    }
    if (plainKey(e, showMode)) done();
  }

  function plainKey(e, showMode) {
    const shift = e.shiftKey;
    switch (e.code) {
      case 'BracketLeft': cmd('pauseAll'); return true;
      case 'BracketRight': cmd('resumeAll'); return true;
      case 'KeyP': cmd('pauseSelected'); return true;
      case 'KeyS': cmd('stopSelected'); lastStop = Date.now(); return true;
      case 'KeyL': cmd('loadSelected'); return true;
      case 'KeyV': cmd('startSelected'); return true;
      case 'ArrowUp': if (!shift) { cmd('moveCursor', { delta: -1 }); return true; } break;
      case 'ArrowDown': if (!shift) { cmd('moveCursor', { delta: 1 }); return true; } break;
      default: break;
    }
    if (showMode) return false;
    switch (e.code) {
      case 'Backspace': case 'Delete':
        if (!Q.selection().size) return false;
        cmd('delete'); return true;
      case 'KeyN': editField('number'); return true;
      case 'KeyQ': editField('name'); return true;
      case 'KeyE': editField('preWait'); return true;
      case 'KeyD': editField('duration'); return true;
      case 'KeyW': editField('postWait'); return true;
      case 'KeyC': cmd('continueCycle'); return true;
      case 'KeyT': {
        const c = Q.cue([...Q.selection()][0]);
        ui.inspectorTab = c && c.kind === 'fade' ? 'fade' : 'action';
        ui.inspector = true; Q.saveUI(); SSMT.render();
        return true;
      }
      default: return false;
    }
  }

  function commandKey(e, showMode) {
    const shift = e.shiftKey;
    switch (e.code) {
      case 'BracketRight': cmd('showMode', { on: true }); return true;
      case 'BracketLeft': cmd('showMode', { on: false }); return true;
      case 'KeyI': ui.inspector = !ui.inspector; Q.saveUI(); SSMT.render(); return true;
      case 'KeyL': ui.sidebar = !ui.sidebar; Q.saveUI(); SSMT.render(); return true;
      case 'KeyJ': Q.prompt(t('show.key.jump'), '', (v) => cmd('jump', { number: v })); return true;
      case 'KeyT': loadToTime(); return true;
      case 'Equal': ui.span = Math.max(5, ui.span / 1.5); Q.saveUI(); SSMT.render(); return true;
      case 'Minus': ui.span = Math.min(600, ui.span * 1.5); Q.saveUI(); SSMT.render(); return true;
      case 'ArrowUp': if (shift) { cmd('movePlayhead', { delta: -1 }); return true; } break;
      case 'ArrowDown': if (shift) { cmd('movePlayhead', { delta: 1 }); return true; } break;
      // Documents (the Mac app menu: ⌘O, ⌘S, ⇧⌘S; ⌘Z / ⇧⌘Z undo and redo).
      case 'KeyO': openShow(); return true;
      case 'KeyS': saveShow(shift); return true;
      case 'KeyZ': if (!showMode) cmd(shift ? 'redo' : 'undo'); return true;
      case 'KeyY': if (!showMode) cmd('redo'); return true;
      default: break;
    }
    if (showMode) return false;
    switch (e.code) {
      case 'Digit0': cmd('add', { kind: 'group' }); return true;
      case 'Digit1': chooseAudio(); return true;
      case 'Digit7': cmd('addFade', { fadeIn: false, name: '' }); return true;
      case 'Digit8': cmd('add', { kind: 'network' }); return true;
      case 'KeyR': cmd('renumber'); return true;
      case 'KeyD': cmd('duplicate'); return true;
      case 'KeyA': cmd('selectAll'); return true;
      case 'KeyC': cmd('copy'); return true;
      case 'KeyX': cmd('cut'); return true;
      case 'KeyV': cmd('paste'); return true;
      default: return false;
    }
  }

  /** N Q E D W: the field of the single selected cue, in a small dialog (ShowStore.editSelected). */
  function editField(f) {
    const sel = [...Q.selection()];
    if (sel.length !== 1) return;
    const c = Q.cue(sel[0]);
    if (!c) return;
    const str = (v) => String(Number(v || 0));
    let title, value;
    switch (f) {
      case 'number': title = t('show.key.number'); value = c.number; break;
      case 'name': title = t('show.key.name'); value = c.name; break;
      case 'preWait': title = t('show.key.preWait'); value = str(c.preWait); break;
      case 'duration':
        if (c.kind !== 'wait' && c.kind !== 'fade') { ui.inspectorTab = c.kind === 'audio' ? 'wave' : 'main'; ui.inspector = true; Q.saveUI(); SSMT.render(); return; }
        title = t('show.key.duration'); value = str(c.kind === 'fade' ? (c.fade || {}).duration : c.duration); break;
      default: title = t('show.key.postWait'); value = str(c.postWait);
    }
    Q.prompt(title, value, (v) => cmd('editField', { field: f, value: v }));
  }

  function loadToTime() {
    const sel = [...Q.selection()];
    const c = sel.length === 1 ? Q.cue(sel[0]) : null;
    if (!c || !(c.kind === 'audio' || (c.kind === 'group' && c.groupMode === 'simultaneous'))) return;
    Q.prompt(t('show.key.loadToTime'), '0', (v) => cmd('loadToTime', { value: v }));
  }

  // Key release: F-keys (pads that play while held). Esc ends typing in a field (the next Esc is Stop all).
  document.addEventListener('keyup', (e) => {
    if (SSMT.S.section !== 'show' || ui.prompt || ui.sheet) return;
    if (e.target.closest && e.target.closest('input, textarea, select')) return;
    if (FKEYS.has(e.key)) { e.preventDefault(); cmd('fkey', { key: e.key, down: false }); }
  });
  document.addEventListener('keydown', (e) => {
    if (SSMT.S.section !== 'show' || ui.prompt) return;
    if (e.key === 'Escape' && e.target.closest && e.target.closest('#pane-show input, #pane-show textarea')) { e.target.blur(); e.preventDefault(); }
  }, true);

  // Pads: in Show mode a press fires the pad (release matters for "hold" pads); in Edit mode a click selects and a
  // double click fires.
  let padDown = null;
  let lastPad = { id: null, at: 0 };
  document.addEventListener('pointerdown', (e) => {
    if (!e.target.closest || !e.target.closest('#pane-show')) return;
    if (e.button === 0) pressing = true;
    const p = e.target.closest('[data-pad]');
    if (!p || e.button !== 0) return;
    const id = p.dataset.pad;
    if (st.show.showMode) { padDown = id; cmd('pad', { id, pressed: true }); return; }
    const now = performance.now();
    if (lastPad.id === id && now - lastPad.at < 400) { cmd('pad', { id, pressed: true }); lastPad = { id: null, at: 0 }; return; }
    lastPad = { id, at: now };
    sendSel([id]);
  });
  document.addEventListener('pointerup', () => {
    if (padDown) { cmd('pad', { id: padDown, pressed: false }); padDown = null; }
    if (pressing) {
      pressing = false;
      // After the click has been delivered to the element under the pointer.
      setTimeout(() => { if (pendingDraw) { pendingDraw = false; SSMT.render(); } }, 0);
    }
  });

  // Context menus of rows, pads and lists.
  document.addEventListener('contextmenu', (e) => {
    if (!e.target.closest || !e.target.closest('#pane-show')) return;
    const row = e.target.closest('.q-row');
    const p = e.target.closest('[data-menu]');
    const showMode = st.show && st.show.showMode;
    let items = null;
    if (row) {
      const id = row.dataset.k;
      const c = Q.cue(id);
      const sel = Q.selection();
      items = [
        [t('show.openSettings'), () => openCueSettings(id), showMode],
        [t('show.setPlayhead'), () => cmd('setPlayhead', { id })],
        [t('show.playNow'), () => cmd('start', { id })],
        [t('show.stopCue'), () => cmd('stop', { id })],
      ];
      if (!showMode) {
        items.push(null);
        items.push([t('action.duplicate'), () => { if (!sel.has(id)) sendSel([id]); cmd('duplicate'); }]);
        if (sel.size > 1 && sel.has(id)) items.push([t('show.groupSelection'), () => cmd('add', { kind: 'group' })]);
        if (c && c.kind === 'group') items.push([t('show.addAudioToGroup'), () => chooseAudio(undefined, id)]);
        items.push([t('action.delete'), () => { if (!sel.has(id)) sendSel([id]); cmd('delete'); }, false, true]);
      }
    } else if (p && p.dataset.menu.startsWith('pad:')) {
      const id = p.dataset.menu.slice(4);
      items = [[t('show.playNow'), () => cmd('pad', { id, pressed: true })], [t('show.stopCue'), () => cmd('stop', { id })]];
      if (!showMode) items.push([t('action.delete'), () => cmd('deleteCue', { id }), false, true]);
    } else if (p && p.dataset.menu.startsWith('list:') && !showMode) {
      const id = p.dataset.menu.slice(5);
      const l = st.doc.lists.find((x) => x.id === id);
      items = [[t('show.list.rename'), () => Q.prompt(t('show.list.rename'), l ? l.name : '', (v) => cmd('renameList', { id, name: v }))]];
      if (Q.idx.cueLists.length > 1) items.push([t('action.delete'), () => cmd('deleteList', { id }), false, true]);
    }
    if (!items) return;
    e.preventDefault();
    Q.openMenu(e.clientX, e.clientY, items);
  });

  // Drag and drop: cues to reorder (into a group on the lower half of a group row), audio files to add.
  let dragIDs = null;
  document.addEventListener('dragstart', (e) => {
    const row = e.target.closest && e.target.closest('#pane-show .q-row');
    if (!row || st.show.showMode) { if (row) e.preventDefault(); return; }
    const id = row.dataset.k;
    const sel = Q.selection();
    dragIDs = sel.has(id) ? rowsOf().map((r) => r.cue.id).filter((x) => sel.has(x)) : [id];
    e.dataTransfer.setData('text/plain', id);
    e.dataTransfer.effectAllowed = 'move';
  });
  document.addEventListener('dragover', (e) => {
    if (e.target.closest && e.target.closest('#pane-show .q-rows, #pane-show .q-sidebar')) e.preventDefault();
  });
  document.addEventListener('drop', (e) => {
    const zone = e.target.closest && e.target.closest('#pane-show .q-rows, #pane-show .q-sidebar');
    if (!zone || !st.show || st.show.showMode) return;
    e.preventDefault();
    const files = [...(e.dataTransfer.files || [])].map((f) => f.path || (window.ssmt && window.ssmt.pathForFile ? window.ssmt.pathForFile(f) : '')).filter((p) => p && AUDIO_EXT.includes(p.split('.').pop().toLowerCase()));
    if (zone.classList.contains('q-sidebar')) { if (files.length && ui.sidebarTab === 'pads') cmd('addPads', { paths: files, bankWord: t('show.bank') }); return; }
    const row = e.target.closest('.q-row');
    const target = row ? Q.cue(row.dataset.k) : null;
    const into = target && target.kind === 'group' && e.offsetY > 14 && e.target === row ? target.id : (target && target.kind === 'group' && e.clientY - row.getBoundingClientRect().top > 14 ? target.id : null);
    if (files.length) {
      if (into) { cmd('addAudio', { paths: files, group: into }); cmd('expand', { id: into }); return; }
      let after;
      if (target) {
        const flat = flattenedAll();
        const i = flat.indexOf(target.id);
        after = i > 0 ? flat[i - 1] : undefined;
      } else {
        const l = Q.currentList();
        after = l && l.cues.length ? l.cues[l.cues.length - 1].id : undefined;
      }
      cmd('addAudio', { paths: files, after });
      return;
    }
    if (!dragIDs) return;
    if (into) { if (!dragIDs.includes(into)) { cmd('move', { ids: dragIDs, into }); cmd('expand', { id: into }); } }
    else if (!target || target.id !== dragIDs[0]) cmd('move', { ids: dragIDs, before: target ? target.id : undefined });
    dragIDs = null;
  });
  const flattenedAll = () => { const l = Q.currentList(); return l ? flattened(l.cues, 0, [], new Set()).map((r) => r.cue.id) : []; };

  // MARK: - Section

  let opened = false;
  SSMT.section({
    id: 'show',
    render() {
      if (!opened) {
        opened = true;
        cmd('hello');
        if (Q.openOutput) Q.openOutput();
      }
      if (!st.show) return `<div class="qtrl-wait"></div>`;
      return null;
    },
    after(pane) {
      if (st.show && pane.querySelector('.qtrl-wait')) pane.innerHTML = '';
      update(pane);
    },
    sidebar() {
      const row = (ic, key, act) => `<button class="utility-row" data-act="${act}">${icon(ic, 15)}<span>${esc(t(key))}</span></button>`;
      return `<div class="items">${row('doc', 'show.new', 'newShow')}${row('folder', 'show.open', 'openShow')}${row('square.and.arrow.down', 'show.save', 'saveShow')}
        ${row('square.and.arrow.down.on.square', 'il.saveAs', 'saveShowAs')}<div class="rule"></div>
        ${row('waveform.badge.plus', 'show.addAudio', 'chooseAudio')}${row('questionmark.folder', 'show.relink', 'relink')}
        ${row('hifispeaker.2', 'show.settings', 'openSettings')}${row('antenna.radiowaves.left.and.right', 'osc.title', 'openOSC')}</div><div class="spacer"></div>`;
    },
    actions,
    inputs,
    keys,
    onEvent,
  });

  Object.assign(Q, { actions, inputs, rowsOf, openCueSettings, chooseAudio, AUDIO_EXT, label });
})();
