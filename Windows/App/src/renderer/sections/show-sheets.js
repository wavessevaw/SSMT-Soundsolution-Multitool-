'use strict';
/* global SSMT */
// Qtrl's sheets, popovers and dialogs: OSC devices (App/SSMT/Show/OSCDevicesView.swift), outputs and audio interface
// (ShowSettingsView.swift), the pre-show check and the keyboard shortcuts (ShowWorkspace.swift), the small text
// dialog of the N / Q / E / D / W / Ctrl+J / Ctrl+T keys and the context menus.

(function () {
  const { t, esc, icon } = SSMT;
  const Q = SSMT.qtrl;
  const { st, ui, cmd, num } = Q;

  // MARK: Overlay region

  function overlay() {
    if (!st.show) return '';
    let html = '';
    if (ui.solo === 'waveform') {
      const c = Q.cue(ui.soloCue);
      html += c ? `<div class="q-solo wave">${Q.waveEditor(c, false)}</div>` : '';
    } else if (ui.solo === 'osc') {
      html += `<div class="q-solo osc">${oscView()}</div>`;
    }
    if (ui.sheet === 'osc') html += sheet(oscView(), 'osc');
    else if (ui.sheet === 'settings') html += sheet(settingsView(), 'settings');
    else if (ui.sheet && ui.sheet.wave) {
      const c = Q.cue(ui.sheet.wave);
      if (c) {
        html += sheet(`<div class="q-sheet-head"><b class="h17">${esc([c.number, c.name].filter((x) => x).join(' · '))}</b><span class="spacer"></span>
          <button class="btn primary" data-act="closeSheet">${esc(t('settings.done'))}</button></div>${Q.waveEditor(c, false)}`, 'bigwave');
      }
    }
    if (ui.pop === 'issues') html += popover(issuesView(), 'issues');
    else if (ui.pop === 'keys') html += popover(keysView(), 'keys');
    if (ui.menu) html += menuView();
    if (ui.prompt) html += promptView();
    return html;
  }

  const sheet = (body, cls) => `<div class="q-modal-back" data-act="sheetBack"></div><div class="q-sheet ${cls}">${body}</div>`;
  const popover = (body, cls) => `<div class="q-pop-back" data-act="closePop"></div><div class="q-pop ${cls}">${body}</div>`;

  // MARK: OSC devices

  function newDevice(kind, name) {
    const port = (((st.statics || {}).kinds || {})[kind] || {}).port || 8000;
    const id = (window.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Date.now())).toUpperCase();
    // Media servers usually run on this computer; consoles never do, so their address starts empty.
    return { id, name, kind, host: kind === 'resolume' ? '127.0.0.1' : '', port, prefix: 'gma3' };
  }

  function oscView() {
    const page = ui.oscPage;
    const d = ui.oscDraft;
    const title = page === 'list' ? t('osc.title') : page === 'choose' ? t('osc.choose') : page === 'setup' && d ? t('osc.kind.' + d.kind) : t('osc.monitor');
    const back = page !== 'list' ? `<button class="q-plain back" data-act="oscPage" data-arg="list">${icon('chevron.left', 14)}</button>` : '';
    let body = '';
    if (page === 'list') body = oscList();
    else if (page === 'choose') body = oscChoose();
    else if (page === 'setup') body = oscSetup();
    else body = oscMonitor();
    return `<div class="q-osc"><div class="q-sheet-head">${back}<b class="h17">${esc(title)}</b><span class="spacer"></span>
      <button class="btn primary" data-act="closeSheet">${esc(t('settings.done'))}</button></div>${body}</div>`;
  }

  const osc = () => st.osc || { log: [], interfaces: [], subnet: {}, test: {}, listening: null };

  function oscList() {
    const devices = st.doc.devices || [];
    const rows = devices.map((d) => `<div class="q-devrow"><span class="ic">${icon(Q.DEVICE_ICON[d.kind] || 'antenna.radiowaves.left.and.right', 15)}</span>
      <span class="titles"><b>${esc(d.name)}</b><span>${esc(t('osc.kind.' + d.kind))} · ${esc(d.host)}:${d.port}</span></span><span class="spacer"></span>
      ${osc().subnet[d.id] === false ? `<span class="q-subwarn">${icon('exclamationmark.triangle.fill', 11)}${esc(t('osc.subnet.short'))}</span>` : ''}
      <button class="q-tool text" data-act="oscEdit" data-arg="${d.id}"><span>${esc(t('osc.edit'))}</span></button>
      <button class="q-tool" data-act="oscDelete" data-arg="${d.id}">${icon('trash', 13)}</button></div>`).join('');
    const ifs = osc().interfaces || [];
    return `<div class="q-osclist"><span class="q-intro">${esc(t('osc.intro'))}</span>
      ${devices.length ? '' : `<span class="q-none2">${esc(t('osc.none'))}</span>`}
      <div class="q-devs">${rows}</div>
      <div class="hrow"><button class="btn primary" data-act="oscPage" data-arg="choose">${icon('plus', 13)}${esc(t('osc.add'))}</button>
        <button class="btn secondary" data-act="oscPage" data-arg="monitor">${icon('waveform.path.ecg.rectangle', 13)}${esc(t('osc.monitor'))}</button></div>
      <div class="q-myip"><b>${esc(t('osc.myip'))}</b>${ifs.length ? '' : `<span class="warn">${esc(t('osc.noNetwork'))}</span>`}
        ${ifs.map((i) => `<span class="addr">${esc(i.address)}  ·  ${esc(i.name)}</span>`).join('')}</div></div>`;
  }

  function oscChoose() {
    const kinds = (st.statics || {}).kindOrder || ['resolume', 'eos', 'grandMA3', 'magicQ', 'x32', 'generic'];
    return `<div class="q-kinds">${kinds.map((k) => `<button class="q-kind" data-act="oscStart" data-arg="${k}"><span class="ic">${icon(Q.DEVICE_ICON[k], 20)}</span>
      <span class="titles"><b>${esc(t('osc.kind.' + k))}</b><span>${esc(t('osc.kind.' + k + '.hint'))}</span></span></button>`).join('')}</div>`;
  }

  const step = (n, title, body) => `<div class="q-step"><span class="n">${n}</span><div class="body"><b>${esc(title)}</b>${body}</div></div>`;
  const labeled = (title, body, style = '') => `<div class="q-fieldbox"${style ? ` style="${style}"` : ''}><span class="q-cap">${esc(title)}</span>${body}</div>`;

  function oscSetup() {
    const d = ui.oscDraft;
    if (!d) return '';
    const o = osc();
    const kinds = (st.statics || {}).kinds || {};
    const probe = (kinds[d.kind] || {}).probe;
    const ip = (o.interfaces || [])[0];
    let s1 = `<span class="q-howto">${esc(t('osc.howto.' + d.kind))}</span>`;
    if (d.kind === 'eos' || d.kind === 'grandMA3') s1 += `<span class="q-yourip">${esc(t('osc.yourip', ip ? ip.address : '—'))}</span>`;
    let s2 = `<div class="hrow">${labeled(t('osc.name'), `<input class="q-field" id="qo-name" data-input="oscDraft" data-key="name" value="${esc(d.name)}">`, 'flex:1')}</div>
      <div class="hrow bottom g10">${labeled(t('osc.host'), `<div class="hrow center"><input class="q-field" id="qo-host" placeholder="192.168.1.30" data-input="oscDraft" data-key="host" value="${esc(d.host)}" style="flex:1">
        <button class="q-tool text" data-act="oscThisMac" title="${esc(t('osc.thisMac.help'))}"><span>${esc(t('osc.thisMac'))}</span></button></div>`, 'flex:1')}
        ${labeled(t('osc.port'), `<input class="q-field" id="qo-port" style="width:80px" data-change="oscPort" value="${d.port}">`)}
        ${d.kind === 'grandMA3' ? labeled(t('osc.prefix'), `<input class="q-field" id="qo-prefix" style="width:90px" placeholder="gma3" data-input="oscDraft" data-key="prefix" value="${esc(d.prefix)}">`) : ''}</div>`;
    if (o.draftHost === d.host && o.draftSubnet === false) s2 += `<span class="q-subwarn big">${icon('exclamationmark.triangle.fill', 12)}${esc(t('osc.subnet.warning'))}</span>`;
    let s3;
    if (probe) {
      const r = (o.test || {})[d.id];
      s3 = `<div class="hrow center g10"><button class="btn secondary" data-act="oscTest"${r === 'testing' || !d.host ? ' disabled' : ''}>${icon('bolt.horizontal', 13)}${esc(t('osc.test'))}</button>
        ${r === 'testing' ? '<span class="q-spin"></span>' : ''}
        ${r === 'answered' || r === 'noAnswer' ? `<span class="q-testres ${r === 'answered' ? 'ok' : 'fail'}">${icon(r === 'answered' ? 'checkmark.circle.fill' : 'xmark.circle.fill', 13)}${esc(t(r === 'answered' ? 'osc.test.ok' : 'osc.test.fail'))}</span>` : ''}</div>
        ${r === 'noAnswer' ? `<span class="q-hint">${esc(t('osc.test.fail.hint'))}</span>` : ''}`;
    } else {
      const first = (((st.statics || {}).presets || {})[d.kind] || [])[0];
      s3 = `<span class="q-hint">${esc(t('osc.test.udp'))}</span>${first ? `<div><button class="btn secondary" data-act="oscTestSend">${icon('paperplane', 13)}${esc(t('osc.test.send', t('osc.preset.' + first.id)))}</button></div>` : ''}`;
    }
    return `<div class="q-oscsetup" id="q-oscsetup" data-keep-scroll>${step(1, t('osc.step.device'), s1)}${step(2, t('osc.step.address'), s2)}${step(3, t('osc.step.test'), s3)}
      <span class="q-find">${esc(t('osc.find.' + d.kind))}</span>
      <div class="hrow"><span class="spacer"></span><button class="btn primary" data-act="oscSave"${!d.host || !d.name ? ' disabled' : ''}>${esc(t(ui.oscIsNew ? 'osc.save.new' : 'osc.save'))}</button></div></div>`;
  }

  function oscMonitor() {
    const o = osc();
    const time = (ms) => { const d = new Date(ms); return d.toLocaleTimeString(SSMT.S.lang === 'ru' ? 'ru-RU' : 'en-US'); };
    const rows = [...(o.log || [])].reverse().map((e) => `<div class="q-logrow"><span class="tm">${esc(time(e.time))}</span><span class="from">${esc(e.from)}</span>
      <span class="msg">${esc(e.text)}</span><span class="spacer"></span><button class="q-link sm" data-act="oscMakeCue" data-arg="${e.id}">${esc(t('osc.monitor.makeCue'))}</button></div>`).join('');
    const listening = o.listening !== null && o.listening !== undefined;
    return `<div class="q-monitor"><span class="q-hint12">${esc(t('osc.monitor.hint'))}</span>
      <div class="hrow center g10"><span class="sm12">${esc(t('osc.port'))}</span><input class="q-field" id="qo-monport" style="width:80px" data-input="monitorPort" value="${esc(ui.monitorPort)}">
        ${listening ? `<button class="btn secondary" data-act="oscStopListening">${esc(t('osc.monitor.stop'))}</button><span class="q-listening">${icon('dot.radiowaves.left.and.right', 12)}${esc(t('osc.monitor.on', o.listening))}</span>`
    : `<button class="btn primary" data-act="oscListen">${esc(t('osc.monitor.start'))}</button>`}
        <span class="spacer"></span><button class="q-link" data-act="oscClear">${esc(t('osc.monitor.clear'))}</button></div>
      ${o.listenError ? `<span class="xs" style="color:var(--status-error)">${esc(o.listenError)}</span>` : ''}
      <div class="q-log" id="q-oscl" data-keep-scroll>${rows}</div></div>`;
  }

  // MARK: Outputs and audio interface (ShowSettingsView)

  let devices = null;
  function loadDevices() {
    if (!SSMT.audio || !SSMT.audio.devices) { devices = { outputs: [] }; return; }
    SSMT.audio.devices().then((d) => { devices = d || { outputs: [] }; SSMT.render(); }).catch(() => { devices = { outputs: [] }; });
  }

  function settingsView() {
    const doc = st.doc;
    const outs = doc.outputs;
    const list = (devices && devices.outputs) || [];
    const devOpts = [['', t('show.device.default')]].concat(list.map((d) => [d.id, d.channels ? `${d.label} · ${d.channels} out` : d.label]));
    const dev = list.find((d) => d.id === doc.deviceUID);
    const devChannels = (dev && dev.channels) || 2;
    const rows = outs.map((o, i) => {
      const n = Math.max(devChannels, (o.deviceChannel !== undefined && o.deviceChannel !== null ? o.deviceChannel : 0) + 1);
      const opts = [['-1', '—']].concat(Array.from({ length: n }, (_, ch) => [String(ch), t('show.channel', ch + 1)]));
      return `<div class="q-outrow"><span class="i">${i + 1}</span><input class="q-field" id="qs-out${i}" data-input="outName" data-index="${i}" value="${esc(o.name)}">
        <span class="arrow">${icon('arrow.right', 13)}</span>${Q.select('outChannel', opts, o.deviceChannel === undefined || o.deviceChannel === null ? '-1' : String(o.deviceChannel), { style: 'width:130px' }).replace('<select ', `<select data-index="${i}" `)}</div>`;
    }).join('');
    const stepper = (text, act) => `<span class="q-stepper"><span>${esc(text)}</span><span class="arrows"><button data-act="${act}" data-arg="1">▴</button><button data-act="${act}" data-arg="-1">▾</button></span></span>`;
    const sr = st.show.output.sampleRate || 48000;
    const buf = [128, 256, 512, 1024, 2048].map((n) => [String(n), t('show.buffer.value', n, n / Math.max(1, sr) * 1000)]);
    return `<div class="q-settings"><div class="q-sheet-head"><b class="h17">${esc(t('show.settings'))}</b><span class="spacer"></span>
      <button class="btn primary" data-act="settingsDone">${esc(t('settings.done'))}</button></div>
      <div class="vcol g6"><span class="q-cap12">${esc(t('setup.interface'))}</span>${Q.select('outDevice', devOpts, doc.deviceUID || '')}</div>
      <div class="hrow center">${stepper(t('show.outputs.count', outs.length), 'outCount')}</div>
      <div class="q-outs" id="q-outs" data-keep-scroll>${rows}</div>
      <div class="hrow g16">${stepper(t('show.panicFade', doc.panicFade), 'panicFade')}${stepper(t('show.goGuard', doc.doubleGoGuard), 'goGuard')}</div>
      <div class="hrow center g10"><span class="sm13">${esc(t('show.buffer'))}</span>${Q.select('buffer', buf, String(st.show.buffer), { style: 'width:200px' })}</div>
      <span class="q-hint">${esc(t('show.buffer.hint'))}</span><span class="q-hint">${esc(t('show.settings.hint'))}</span></div>`;
  }

  // MARK: Pre-show check (ShowIssuesView)

  function issuesView() {
    const s = st.show;
    const issues = s.issues || [];
    const text = (i) => {
      const lb = Q.label(Q.cue(i.id)) || '?';
      switch (i.type) {
        case 'target': return t('show.issue.target', lb);
        case 'file': return t('show.issue.file', lb);
        case 'number': return t('show.issue.number', i.value);
        case 'hotkey': return t('show.issue.hotkey', String(i.value).toUpperCase());
        case 'emptyGroup': return t('show.issue.emptyGroup', lb);
        case 'region': return t('show.issue.region', lb);
        default: return t('show.issue.device', lb);
      }
    };
    const unreadable = Object.keys(s.unreadable || {}).sort();
    const err = s.output.error !== null && s.output.error !== undefined;
    let html = `<b class="h15">${esc(t('show.check'))}</b>`;
    if (!issues.length && s.loading === 0 && !unreadable.length && !err) html += `<span class="q-ok">${icon('checkmark.circle.fill', 14)}${esc(t('show.check.ok'))}</span>`;
    html += issues.map((i) => `<div class="q-issue"${i.id ? ` data-act="issueSelect" data-arg="${i.id}"` : ''}><span style="color:var(--status-warning)">${icon('exclamationmark.triangle.fill', 13)}</span><span>${esc(text(i))}</span></div>`).join('');
    if (err) html += `<span class="q-lab err">${icon('hifispeaker.slash', 13)}${esc(t('show.output.error'))}</span>`;
    if (s.loading > 0) html += `<span class="q-lab warn sm">${icon('hourglass', 12)}${esc(t('show.check.loading', s.loading))}</span>`;
    html += unreadable.map((p) => `<span class="q-lab err sm" title="${esc(s.unreadable[p])}">${icon('xmark.octagon.fill', 12)}${esc(t('show.check.unreadable', Q.basename(p)))}</span>`).join('');
    if (s.output.interruptions > 0) html += `<span class="q-lab warn sm">${icon('exclamationmark.triangle.fill', 12)}${esc(t('show.check.interruptions', s.output.interruptions))}</span>`;
    return `<div class="q-issues">${html}</div>`;
  }

  // MARK: Keyboard shortcuts (QtrlShortcutsView); Ctrl stands for the Mac's Command key.

  const KEYS = [
    ['Space', 'show.keys.go'], ['Esc', 'show.keys.panic'], ['[  /  ]', 'show.keys.pauseResumeAll'],
    ['P', 'show.keys.pauseSelected'], ['S', 'show.keys.stopSelected'], ['L', 'show.keys.load'], ['V', 'show.keys.preview'],
    ['↑  /  ↓', 'show.keys.cursor'], ['Ctrl+Shift+↑  /  ↓', 'show.keys.playhead'], ['Ctrl+J', 'show.keys.jump'],
    ['Ctrl+T', 'show.keys.loadToTime'], ['Alt+←  /  Alt+→', 'show.keys.nudge'], ['Ctrl+=  /  Ctrl+−', 'show.keys.zoom'],
    ['Ctrl+]  /  Ctrl+[', 'show.keys.mode'], ['Ctrl+I  /  Ctrl+L', 'show.keys.panels'],
    ['Ctrl+1 · 0 · 7 · 8', 'show.keys.newCue'], ['N · Q · E · D · W', 'show.keys.fields'], ['C', 'show.keys.continue'],
    ['T', 'show.keys.target'], ['Ctrl+R', 'show.keys.renumber'], ['Ctrl+D', 'show.keys.duplicate'],
    ['Ctrl+C · X · V · A', 'show.keys.clipboard'], ['Backspace', 'show.keys.delete'], ['F1…F12', 'show.keys.pads'],
  ];
  function keysView() {
    return `<div class="q-keys"><b class="h15">${esc(t('show.keys.title'))}</b><div class="grid">${KEYS.map(([k, key]) => `<span class="k">${esc(k)}</span><span class="d">${esc(t(key))}</span>`).join('')}</div>
      <span class="note">${esc(t('show.keys.note'))}</span></div>`;
  }

  // MARK: Dialog and menus

  function promptView() {
    const p = ui.prompt;
    return `<div class="q-modal-back"></div><div class="q-alert"><b>${esc(p.title)}</b><input class="q-field" id="q-prompt" value="${esc(p.value)}">
      <div class="hrow"><span class="spacer"></span><button class="btn secondary" data-act="promptCancel">${esc(t('action.cancel'))}</button>
      <button class="btn primary" data-act="promptOK">OK</button></div></div>`;
  }
  function prompt(title, value, done) {
    ui.prompt = { title, value, done };
    SSMT.render();
    requestAnimationFrame(() => requestAnimationFrame(() => { const f = document.getElementById('q-prompt'); if (f) { f.focus(); f.select(); } }));
  }
  function closePrompt(ok) {
    const p = ui.prompt;
    if (!p) return;
    const f = document.getElementById('q-prompt');
    const v = f ? f.value : p.value;
    ui.prompt = null;
    SSMT.render();
    if (ok) p.done(v);
  }
  document.addEventListener('keydown', (e) => {
    if (!ui.prompt || SSMT.S.section !== 'show') return;
    if (e.key === 'Enter') { e.preventDefault(); closePrompt(true); }
    if (e.key === 'Escape') { e.preventDefault(); closePrompt(false); }
  }, true);

  let menuItems = [];
  function menuView() {
    const m = ui.menu;
    menuItems = m.items;
    const rows = m.items.map((it, i) => (it === null ? '<div class="sep"></div>'
      : `<button class="${it[3] ? 'danger' : ''}" data-act="menuPick" data-arg="${i}"${it[2] ? ' disabled' : ''}>${esc(it[0])}</button>`)).join('');
    return `<div class="q-pop-back" data-act="closeMenu"></div><div class="q-menu" style="left:${m.x}px;top:${m.y}px">${rows}</div>`;
  }
  function openMenu(x, y, items) {
    ui.menu = { x: Math.min(x, window.innerWidth - 240), y: Math.min(y, window.innerHeight - 24 * items.length - 16), items };
    SSMT.render();
  }

  // MARK: Actions

  function openOSC() { ui.sheet = 'osc'; ui.oscPage = 'list'; ui.oscDraft = null; cmd('oscRefresh'); SSMT.render(); }
  function openSettings() { ui.sheet = 'settings'; loadDevices(); SSMT.render(); }
  const draftChanged = () => { if (ui.oscDraft) cmd('oscDraftHost', { host: ui.oscDraft.host }); };

  Object.assign(Q.actions, {
    closeSheet: () => { ui.sheet = null; SSMT.render(); },
    sheetBack: () => {},
    closePop: () => { ui.pop = null; SSMT.render(); },
    closeMenu: () => { ui.menu = null; SSMT.render(); },
    menuPick: (i) => { const it = menuItems[Number(i)]; ui.menu = null; SSMT.render(); if (it && it[1]) it[1](); },
    promptOK: () => closePrompt(true),
    promptCancel: () => closePrompt(false),
    issueSelect: (id) => cmd('select', { ids: [id] }),
    oscPage: (p) => { ui.oscPage = p; if (p === 'list') ui.oscDraft = null; SSMT.render(); },
    oscStart: (k) => { ui.oscDraft = newDevice(k, t('osc.kind.' + k)); ui.oscIsNew = true; ui.oscPage = 'setup'; draftChanged(); SSMT.render(); },
    oscEdit: (id) => {
      const d = (st.doc.devices || []).find((x) => x.id === id);
      if (!d) return;
      ui.oscDraft = Object.assign({}, d); ui.oscIsNew = false; ui.oscPage = 'setup'; draftChanged(); SSMT.render();
    },
    oscDelete: (id) => cmd('deleteDevice', { id }),
    oscThisMac: () => { ui.oscDraft.host = '127.0.0.1'; draftChanged(); SSMT.render(); },
    oscPort: (v) => { const n = parseInt(v, 10); ui.oscDraft.port = Math.max(0, Math.min(65535, Number.isFinite(n) ? n : 0)); SSMT.render(); },
    oscTest: () => cmd('oscTest', { device: ui.oscDraft }),
    oscTestSend: () => cmd('oscTestSend', { device: ui.oscDraft }),
    oscSave: () => { cmd('saveDevice', { device: ui.oscDraft }); ui.oscPage = 'list'; ui.oscDraft = null; SSMT.render(); },
    oscListen: () => cmd('oscListen', { port: parseInt(ui.monitorPort, 10) || 53535 }),
    oscStopListening: () => cmd('oscStopListening'),
    oscClear: () => cmd('oscClear'),
    oscMakeCue: (id) => cmd('addNetworkFromLog', { id }),
    settingsDone: () => { ui.sheet = null; cmd('restartOutput'); if (Q.openOutput) Q.openOutput(); SSMT.render(); },
    outDevice: (v) => cmd('device', { uid: v }),
    outCount: (d) => cmd('outputs', { count: st.doc.outputs.length + Number(d) }),
    outChannel: (v, el) => cmd('outputChannel', { index: Number(el.dataset.index), channel: Number(v) }),
    panicFade: (d) => cmd('panicFade', { value: Math.round((st.doc.panicFade + 0.5 * Number(d)) * 10) / 10 }),
    goGuard: (d) => cmd('goGuard', { value: Math.round((st.doc.doubleGoGuard + 0.1 * Number(d)) * 10) / 10 }),
    buffer: (v) => { cmd('buffer', { frames: Number(v) }); },
  });
  Object.assign(Q.inputs, {
    oscDraft: (v, el) => { ui.oscDraft[el.dataset.key] = v; if (el.dataset.key === 'host') draftChanged(); SSMT.render(); },
    monitorPort: (v) => { ui.monitorPort = v; },
    outName: (v, el) => cmd('outputName', { index: Number(el.dataset.index), name: v }),
  });

  /** OSCDevicesView(startWith:): the setup of a new device of that kind, named after the product. */
  function oscStartWith(kind) {
    ui.oscDraft = newDevice(kind, Q.BRAND[kind]);
    ui.oscIsNew = true;
    ui.oscPage = 'setup';
    draftChanged();
  }

  Object.assign(Q, { overlay, prompt, openMenu, openOSC, openSettings, oscStartWith, num });
})();
