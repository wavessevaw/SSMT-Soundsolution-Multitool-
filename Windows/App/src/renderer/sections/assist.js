'use strict';
/* global SSMT */
// Function #4: FOH Assist. A one-to-one copy of App/SSMT/Assist (AssistWorkspace.swift, LearnScreen.swift): the
// console choice and discovery until a console is connected; then one header for all modes (mode switch, console /
// hall / profile chips, settings in a sheet), soundcheck as channel list + selected channel, show with the guard's
// state first, the console test with the fader wave, and learning. The behaviour (AssistStore.swift) lives in the
// engine (Windows/Engine: main.swift, Assist.swift); this file keeps only what the Mac keeps in its views and in the
// store's interface state (mode, selected channel, range, test settings, the language model's fields).

(function () {
  const { t, esc, icon, UI, format } = SSMT;
  const api = SSMT.api;
  const store = SSMT.store;

  const FAMILIES = ['x32', 'xAir', 'simulator', 'wing', 'yamaha', 'allenHeath'];
  const IMPLEMENTED = new Set(['x32', 'xAir', 'simulator']);
  const PORTS = { x32: 10023, xAir: 10024, wing: 2223, yamaha: 49280, allenHeath: 51325, simulator: 0 };
  const CHARACTERS = ['musical', 'rock', 'classical', 'speech'];
  const SCENARIOS = [['musical', 20], ['rock', 14], ['orchestra', 12]];
  const FAMILY_ORDER = ['drums', 'band', 'vocals', 'choir', 'strings', 'woodwinds', 'brass', 'other'];
  const KIND_FAMILY = {
    kick: 'drums', snare: 'drums', tom: 'drums', hiHat: 'drums', overhead: 'drums', percussion: 'drums',
    bassGuitar: 'band', electricGuitar: 'band', acousticGuitar: 'band', keys: 'band', piano: 'band',
    maleVocal: 'vocals', femaleVocal: 'vocals', backingVocal: 'vocals', speech: 'vocals', choir: 'choir',
    violin: 'strings', viola: 'strings', cello: 'strings', doubleBass: 'strings', harp: 'strings',
    flute: 'woodwinds', clarinet: 'woodwinds', oboe: 'woodwinds', bassoon: 'woodwinds', saxophone: 'woodwinds',
    trumpet: 'brass', trombone: 'brass', frenchHorn: 'brass', tuba: 'brass', playback: 'other', unknown: 'other',
  };
  const ROUTINGS = ['local', 'aes50A', 'aes50B', 'auto'];

  // MARK: state (the store's interface part; everything else arrives from the engine)

  const A = {
    mode: 'soundcheck',
    family: 'simulator',
    host: store.get('assist.host', '192.168.1.64'),
    manualIP: null,
    routing: store.get('assist.routing', 'local'),
    autoScan: true,
    discovered: [],
    scanning: false,
    st: null,
    meters: { channels: [], buses: [] },
    log: [],
    learn: { recording: false },
    learnTitle: '',
    recordings: { items: [], target: 20, dir: '' },
    summary: '',
    dataset: null,
    llm: { url: store.get('llm.url', 'http://localhost:11434'), model: store.get('llm.model', 'qwen2.5:1.5b'), question: '', answer: '', status: '', asking: false },
    selectedChannel: null,
    rangeFrom: 1,
    rangeTo: 8,
    showSettings: false,
    message: null,
    testScenario: 'musical',
    testFirst: 1,
    testMuteMain: true,
    waveCycle: 4,
    waveStartedAt: 0,
    rehearsalSceneSeconds: 20,
    simOpen: false,
    menu: null,
    curve: null,
    curveKey: '',
    // Connection settings of a real console (AssistSettingsSheet).
    signalSource: 'network',
    inputDevice: '',
    inputDevices: [],
    firstInput: 1,
    micInput: 0,
    stageMicInput: 0,
    character: 'musical',
    tap: 'preEQ',
    compactHeader: false,
    stackedActions: false,
    scroll: {},
    visible: false,
  };

  // MARK: helpers

  const st = () => A.st || {};
  const isConnected = () => st().status === 'connected';
  const strips = () => st().strips || [];
  const buses = () => st().buses || [];
  const stripOf = (id) => strips().find((s) => s.id === id);
  const readOnly = () => !!st().readOnly;
  const locked = (m) => readOnly() && m !== 'learn';
  const running = () => !!st().running;
  const f0 = (v) => format('%.0f', v);
  const f1 = (v) => format('%.1f', v);
  const label = (f) => {
    const trim = (x) => { let s = Number(x).toFixed(2); while (s.includes('.') && (s.endsWith('0') || s.endsWith('.'))) s = s.slice(0, -1); return s; };
    return f >= 1000 ? trim(f / 1000) + ' kHz' : trim(f) + ' Hz';
  };
  const clock = (sec, hours) => {
    const s = Math.max(0, Math.trunc(sec || 0));
    const p = (n) => String(n).padStart(2, '0');
    return hours ? `${p(Math.trunc(s / 3600))}:${p(Math.trunc(s / 60) % 60)}:${p(s % 60)}` : `${p(Math.trunc(s / 60))}:${p(s % 60)}`;
  };
  const learnClock = (sec) => {
    const s = Math.max(0, Math.trunc(sec || 0));
    const p = (n) => String(n).padStart(2, '0');
    return s >= 3600 ? `${Math.trunc(s / 3600)}:${p(Math.trunc(s / 60) % 60)}:${p(s % 60)}` : `${Math.trunc(s / 60)}:${p(s % 60)}`;
  };
  const send = (cmd) => SSMT.send(cmd);
  const attr = UI.attrs;

  function name(ch) { const s = stripOf(ch); return s && s.name ? s.name : `Ch ${ch}`; }
  function busName(id) { const b = buses().find((x) => x.id === id); return b && b.name ? b.name : `Bus ${id}`; }
  const stateOf = (ch) => (st().states || {})[ch];
  const kindOf = (ch) => (st().kinds || {})[ch];
  const featureOf = (ch) => (st().features || {})[ch];

  function failure(reason) {
    if (reason === 'not supported yet') return t('assist.soon');
    if (reason === 'noAnswer') return format(t('assist.noAnswer'), `${A.host}:${PORTS[A.family] || 0}`);
    return reason;
  }

  // MARK: shared pieces

  /** Glass card with a title row and edge-to-edge content (AssistWorkspace.Card). */
  function card(title, tint, accessory, content, { cls = '', style = '' } = {}) {
    return `<section class="glass as-card ${cls}"${style ? ` style="${style}"` : ''}>
      <div class="as-card-head"><span class="bar" style="background:${tint}"></span><h3>${esc(title)}</h3><span class="sp"></span>${accessory || ''}</div>
      <div class="as-hair"></div>${content}</section>`;
  }

  /** Panel (Components.Panel): glass card, padding 18, title with a coloured bar. */
  function panel(title, tint, body, cls = '') {
    return UI.panel(title, body, { tint, cls: 'as-panel ' + cls });
  }

  function button(text, { kind = 'secondary', act, arg, disabled, ic, cls = '', title } = {}) {
    return `<button ${attr({ class: `btn ${kind} ${cls}`, 'data-act': act, 'data-arg': arg, disabled, title })}>${ic ? icon(ic, 14) : ''}${text ? `<span>${esc(text)}</span>` : ''}</button>`;
  }

  /** macOS Stepper: the label, then the small up / down arrows. */
  function stepper(text, key, value, min, max, step = 1, { disabled, cls = '' } = {}) {
    return `<span class="as-stepper ${cls} ${disabled ? 'disabled' : ''}"><span class="lbl">${esc(text)}</span><span class="arrows">
      <button ${attr({ 'data-act': 'step', 'data-arg': `${key}:${step}:${min}:${max}`, disabled: disabled || value >= max })}>${icon('chevron.up', 9)}</button>
      <button ${attr({ 'data-act': 'step', 'data-arg': `${key}:${-step}:${min}:${max}`, disabled: disabled || value <= min })}>${icon('chevron.down', 9)}</button></span></span>`;
  }

  /** macOS pop-up picker with its label on the left. */
  function picker(labelText, change, options, value, { width, disabled, id } = {}) {
    const opts = options.map(([v, l]) => `<option value="${esc(v)}" ${String(v) === String(value) ? 'selected' : ''}>${esc(l)}</option>`).join('');
    return `<label class="as-picker"${width ? ` style="width:${width}px"` : ''}>${labelText ? `<span class="lbl">${esc(labelText)}</span>` : ''}<select ${attr({ class: 'field', 'data-change': change, disabled, id })}>${opts}</select></label>`;
  }

  function stateBadge(s) {
    switch (s) {
      case 'done': return UI.statusBadge('good', t('assist.state.done'));
      case 'listening': return UI.statusBadge('warning', t('assist.state.listening'));
      case 'tuning': return UI.statusBadge('warning', t('assist.state.tuning'));
      default: return UI.statusBadge('idle', t('assist.state.idle'));
    }
  }

  function linkLamp(on, size = 9) {
    return `<span class="as-lamp ${on ? 'on' : ''}" style="width:${size}px;height:${size}px"></span>`;
  }

  function levelColor(db) { return db > -3 ? 'var(--status-error)' : db > -10 ? 'var(--signal-yellow)' : 'var(--accent)'; }
  const levelWidth = (db) => Math.max(0, Math.min(1, (db + 60) / 60)) * 100;
  function levelBar(id, bus = false) {
    const db = (bus ? A.meters.buses : A.meters.channels)[id - 1];
    const v = db == null ? -120 : db;
    return `<span class="as-level" data-${bus ? 'bus' : 'ch'}="${id}"><i style="width:${levelWidth(v)}%;background:${levelColor(v)}"></i></span>`;
  }

  // MARK: the assistant's words (AssistWorkspace.Wording)

  function note(n) {
    if (!n || typeof n !== 'object') return '';
    const k = Object.keys(n)[0];
    const v = n[k] || {};
    switch (k) {
      case 'waitingForSignal': return t('assist.note.waiting');
      case 'recognised': return t('assist.note.recognised', t('assist.kind.' + v._0), Math.trunc((v.confidence || 0) * 100));
      case 'gain': return t('assist.note.gain', v.fromDB, v.toDB);
      case 'clipRisk': return t('assist.note.clip', v.peakDB);
      case 'highPass': return t('assist.note.hpf', v.hz);
      case 'eqBand': {
        const type = v.type === 'peaking' ? format('Q %.1f', v.q) : t(v.type === 'lowShelf' ? 'assist.lowShelf' : 'assist.highShelf');
        return t('assist.note.eq', v.index + 1, label(v.frequency), v.gainDB, type);
      }
      case 'compressor': return t('assist.note.comp', v.thresholdDB, v.ratio, v.attackMS, v.releaseMS, v.gainReductionDB);
      case 'compressorOff': return t('assist.note.compOff');
      case 'fader': return t('assist.note.fader', v.toDB);
      case 'feedback': return t('assist.note.feedback', label(v.frequency), v.notchDB);
      case 'polarityChecking': return t('assist.note.polChecking', name(v.against));
      case 'polarity': return t(v.inverted ? 'assist.note.polInverted' : 'assist.note.polKept', v.differenceDB);
      case 'polarityUnclear': return t('assist.note.polUnclear', v.differenceDB);
      case 'done': return t('assist.note.done', v.remainingDeviationDB);
      case 'gaveUp': return t(v.reason === 'no signal' ? 'assist.note.noSignal' : 'assist.note.unsettled');
      default: return k;
    }
  }

  function noteColor(n) {
    const k = n && typeof n === 'object' ? Object.keys(n)[0] : '';
    if (k === 'done' || k === 'polarity') return 'var(--status-good)';
    if (k === 'feedback' || k === 'clipRisk' || k === 'gaveUp' || k === 'polarityUnclear') return 'var(--status-warning)';
    return 'var(--text-primary)';
  }

  function action(a) {
    const k = Object.keys(a || {})[0];
    const v = (a || {})[k] || {};
    switch (k) {
      case 'notch': return t('assist.g.notch', name(v.channel), label(v.frequency), v.depthDB);
      case 'notchReleased': return t('assist.g.notchReleased', name(v.channel));
      case 'monitorDip': return t('assist.g.dip', busName(v.bus), v.byDB);
      case 'monitorRestored': return t('assist.g.restored', busName(v.bus));
      case 'monitorHeld': return t('assist.g.held', busName(v.bus), v.belowDB);
      case 'unmask': return t('assist.g.unmask', name(v.channel), label(v.frequency), v.offsetDB);
      case 'unmaskReleased': return t('assist.g.unmaskReleased', name(v.channel));
      case 'tonalHold': return t('assist.g.tonal', name(v.channel), label(v.frequency), v.offsetDB);
      case 'tonalReleased': return t('assist.g.tonalReleased', name(v.channel));
      case 'yielded': return t('assist.g.yielded', v.channel != null ? name(v.channel) : v.bus != null ? busName(v.bus) : '');
      default: return k || '';
    }
  }

  // MARK: connect screen (AssistConnectScreen)

  function statusText() {
    const s = st();
    if (s.status === 'connecting') return format(t('assist.connect.connecting'), A.host);
    if (s.status === 'failed') return t('assist.connect.failed') + ': ' + failure(s.failure);
    return t('assist.link.none');
  }

  function step(n, title) {
    return `<div class="as-step"><span class="n">${n}</span><span class="t">${esc(title)}</span></div>`;
  }

  function familyCard(f) {
    const on = A.family === f;
    const impl = IMPLEMENTED.has(f);
    const sub = impl ? (f === 'simulator' ? t('assist.connect.simHint') : t('assist.connect.wifi')) : t('assist.soon');
    return `<button ${attr({ class: `as-fam ${on ? 'on' : ''}`, 'data-act': 'family', 'data-arg': f, disabled: !impl })}>
      ${icon(f === 'simulator' ? 'desktopcomputer' : 'slider.vertical.3', 18)}
      <b>${esc(t('assist.family.' + f))}</b><span>${esc(sub)}</span></button>`;
  }

  function connectScreen() {
    const s = st();
    const connecting = s.status === 'connecting';
    let body = '';
    if (A.family === 'simulator') {
      body = step(2, t('assist.connect.sim')) + `<div>${button(t('assist.connect.simGo'), { kind: 'primary', act: 'connect', ic: 'play.fill' })}</div>`;
    } else if (IMPLEMENTED.has(A.family)) {
      const list = A.discovered.filter((c) => c.family === A.family);
      const rows = list.map((c) => `<div class="as-found">
          <span class="tile">${icon('slider.vertical.3', 16)}</span>
          <div class="titles"><b>${esc(c.model)} · ${esc(c.name)}</b><span>${esc(c.ip + (c.firmware ? ' · ' + format(t('assist.connect.fw'), c.firmware) : ''))}</span></div>
          <span class="sp"></span>${connecting && A.host === c.ip ? '<span class="as-spinner"></span>' : ''}
          ${button(t('assist.connect'), { kind: 'primary', act: 'connectTo', arg: c.ip, disabled: connecting })}</div>`).join('');
      const manual = A.manualIP == null ? A.host : A.manualIP;
      body = `<div class="as-row">${step(2, t('assist.connect.found'))}<span class="sp"></span>${A.scanning ? '<span class="as-spinner"></span>' : ''}
          ${button(t('assist.connect.rescan'), { act: 'scan', ic: 'arrow.clockwise', disabled: A.scanning })}</div>
        ${list.length ? '' : `<p class="as-none">${esc(t(A.scanning ? 'assist.connect.searching' : 'assist.connect.none'))}</p>`}${rows}
        <div class="as-manual"><span class="lbl">${esc(t('assist.connect.manual'))}</span>
          <input id="assist-manual" class="field" data-input="manualIP" value="${esc(manual)}" placeholder="192.168.1.64" spellcheck="false">
          ${button(t('assist.connect'), { act: 'connectManual', disabled: !manual.trim() || connecting })}</div>`;
    }
    return `<div class="as-scroll" data-scroll="connect"><div class="glass as-connect">
      <div class="as-connect-head"><h1>FOH Assist</h1><span class="sp"></span>
        <span class="as-conn-status ${connecting ? 'warn' : ''}">${linkLamp(false)}<span>${esc(statusText())}</span></span></div>
      <p class="as-intro">${esc(t('assist.nc.text'))}</p>
      ${step(1, t('assist.connect.console'))}
      <div class="as-fams">${FAMILIES.map(familyCard).join('')}</div>
      ${body}
      <p class="as-after">${esc(t('assist.connect.after'))}</p>
    </div></div>`;
  }

  // MARK: header (AssistHeader)

  function consoleName() {
    const f = st().family || A.family;
    if (f === 'x32') return 'X32 / M32';
    if (f === 'xAir') return 'X Air / MR';
    if (f === 'simulator') return t('assist.chip.sim');
    return t('assist.family.' + f);
  }

  function connectionText() {
    const s = st();
    switch (s.status) {
      case 'connecting': return t('assist.connecting');
      case 'connected': return s.connection || '';
      case 'failed': return failure(s.failure);
      default: return t('assist.offline');
    }
  }

  function header() {
    const s = st();
    const full = !A.compactHeader;
    const alive = !!s.alive;
    const seg = ['soundcheck', 'show', 'test', 'learn'].map((m) =>
      `<button class="${A.mode === m ? 'on' : ''}" data-act="mode" data-arg="${m}">${esc(t('assist.mode.' + m))}</button>`).join('');
    const chips = [
      `<button class="as-chip" data-act="settings" title="${esc(connectionText())}">${linkLamp(alive)}<b>${esc(consoleName())}</b>${full && s.family !== 'simulator' ? `<span class="mono">${esc(s.host || A.host)}</span>` : ''}<span style="color:${alive ? 'var(--status-good)' : 'var(--status-error)'}">${esc(t(alive ? 'assist.link.ok' : 'assist.link.lost'))}</span></button>`,
      full && s.micLevel != null ? `<span class="as-chip"><span>${esc(t('assist.chip.hall'))}</span><b class="mono">${esc(format(s.micCalibrated ? '%.0f dB(A)' : '%.0f dBFS(A)', s.micLevel))}</b></span>` : '',
      full ? `<span class="as-chip"><span>${esc(t('assist.chip.profile'))}</span><b>${esc(t('assist.char.' + (s.character || A.character)))}</b></span>` : '',
      `<button class="as-chip" data-act="settings" title="${esc(t('assist.settings'))}">${icon('gearshape', 13)}</button>`,
    ].join('');
    return `<div class="as-header"><h1>FOH Assist</h1><div class="as-seg">${seg}</div><span class="sp"></span><div class="as-chips">${chips}</div></div>`;
  }

  // MARK: soundcheck (SoundcheckScreen)

  function jobText() {
    const s = st();
    if (s.groupPhase) return t('assist.phase.' + s.groupPhase);
    const job = s.job || 'none';
    if (job.startsWith('channel:')) return name(Number(job.slice(8))) + ' · ' + t('assist.state.tuning');
    if (job === 'polarity') return t('assist.polarity');
    return t('assist.state.tuning');
  }

  function soundcheckActions() {
    const off = !isConnected() || running();
    const n = Math.max(1, strips().length);
    const tools = `<div class="as-tools">
      ${button(t('assist.orchestra'), { kind: 'primary', act: 'tuneGroup', arg: 'orchestra', ic: 'music.quarternote.3', disabled: off })}
      ${button(t('assist.choir'), { kind: 'primary', act: 'tuneGroup', arg: 'choir', ic: 'person.3.fill', disabled: off })}
      <span class="as-vrule"></span>
      <span class="lbl">${esc(t('assist.range'))}</span>
      ${stepper(String(A.rangeFrom), 'rangeFrom', A.rangeFrom, 1, n, 1, { disabled: off, cls: 'mono' })}
      <span class="dash">—</span>
      ${stepper(String(A.rangeTo), 'rangeTo', A.rangeTo, 1, n, 1, { disabled: off, cls: 'mono' })}
      ${button(t('assist.rangeGo'), { act: 'tuneRange', disabled: off })}
      <span class="as-vrule"></span>
      ${button(t('assist.polarity'), { act: 'polarity', ic: 'plusminus.circle', disabled: off })}</div>`;
    const s = st();
    const job = `<div class="as-job">
      ${running() ? `<span class="as-spinner"></span><span class="txt">${esc(jobText())}</span>${button(t('assist.stop'), { kind: 'danger', act: 'stopJob' })}`
        : s.groupPhase === 'done' ? UI.statusBadge('good', t('assist.phase.done')) : ''}
      ${button(t('assist.undoAll'), { act: 'undoAll', disabled: !isConnected() })}</div>`;
    return `<div class="glass as-actions ${A.stackedActions ? 'stacked' : ''}">${tools}${A.stackedActions ? `<div class="as-job-row"><span class="sp"></span>${job}</div>` : `<span class="sp"></span>${job}`}</div>`;
  }

  function notConnectedCard() {
    return `<div class="glass as-nc">${UI.iconTile('wifi', { tint: 'var(--accent)', size: 56 })}
      <h2>${esc(t('assist.nc.title'))}</h2><p>${esc(t('assist.nc.text'))}</p>
      <div class="as-row gap10">${button(t('assist.connect'), { kind: 'primary', act: 'connect', disabled: !IMPLEMENTED.has(A.family) || isConnected() })}
      ${button(t('assist.settings'), { act: 'settings' })}</div></div>`;
  }

  /** The chosen channel, else the one being tuned, else the first one with a state or a name. */
  function selectedChannel() {
    const list = strips();
    if (A.selectedChannel != null && list.some((s) => s.id === A.selectedChannel)) return A.selectedChannel;
    const job = st().job || '';
    if (job.startsWith('channel:') && running()) return Number(job.slice(8));
    const a = list.find((s) => stateOf(s.id) != null);
    if (a) return a.id;
    const b = list.find((s) => s.name);
    return b ? b.id : null;
  }

  function channelList() {
    const shown = strips().filter((s) => s.name || stateOf(s.id) != null || (featureOf(s.id) && featureOf(s.id).signal));
    const done = shown.filter((s) => stateOf(s.id) === 'done').length;
    const by = {};
    for (const s of shown) { const f = KIND_FAMILY[kindOf(s.id)] || 'other'; (by[f] = by[f] || []).push(s); }
    const sel = selectedChannel();
    const groups = FAMILY_ORDER.filter((f) => by[f]).map((f) => `<div class="as-group">${esc(t('assist.group.' + f).toUpperCase())}</div>`
      + by[f].map((s) => channelRow(s, sel === s.id)).join('')).join('');
    const hidden = strips().length > shown.length ? `<p class="as-hidden">${esc(t('assist.list.hidden', strips().length - shown.length))}</p>` : '';
    return card(t('assist.channels'), 'var(--accent)', `<span class="as-acc mono">${esc(t('assist.list.count', done, shown.length))}</span>`,
      `<div class="as-scroll-y" data-scroll="channels">${groups}${hidden}</div>`, { cls: 'as-channels' });
  }

  function channelRow(s, selected) {
    const k = kindOf(s.id);
    const parts = [k ? t('assist.kind.' + k) : '—', f0(s.gainDB) + ' dB'];
    if (s.highPassOn) parts.push('HPF ' + f0(s.highPassHz));
    if (s.compressor && s.compressor.enabled) parts.push(f1(s.compressor.ratio) + ':1');
    return `<div class="as-chrow ${selected ? 'sel' : ''}" data-act="select" data-arg="${s.id}">
      <span class="id mono">${s.id}</span>
      <div class="titles"><div class="nm"><b>${esc(s.name || `Ch ${s.id}`)}</b>${s.polarityInverted ? '<span class="ph">Ø</span>' : ''}</div><span>${esc(parts.join(' · '))}</span></div>
      <span class="sp"></span>${levelBar(s.id)}${stateBadge(stateOf(s.id))}</div>`;
  }

  function valueTile(title, value, sub = '') {
    return `<div class="as-tile"><span class="t">${esc(title)}</span><b class="mono">${esc(value)}</b><span class="s">${sub ? esc(sub) : '&nbsp;'}</span></div>`;
  }

  function channelDetail() {
    const id = selectedChannel();
    const s = id != null ? stripOf(id) : null;
    if (!s) return `<div class="glass as-detail empty"><span>${esc(t('assist.detail.empty'))}</span></div>`;
    const entries = A.log.filter((e) => e.channel === s.id);
    let dev = null;
    for (let i = entries.length - 1; i >= 0; i--) { const n = entries[i].note; if (n && n.done) { dev = n.done.remainingDeviationDB; break; } }
    const c = s.compressor || {};
    const k = kindOf(s.id);
    const bands = (s.eq || []).map((b, i) => {
      const type = b.type === 'peaking' ? format('Q %.1f', b.q) : t(b.type === 'lowShelf' ? 'assist.lowShelf' : 'assist.highShelf');
      const col = !s.eqOn || Math.abs(b.gainDB) < 0.5 ? 'var(--text-muted)' : b.gainDB > 0 ? 'var(--accent)' : 'var(--signal-yellow)';
      return `<div class="as-band"><span class="t">${esc(t('assist.band', i + 1) + ' · ' + type)}</span><b class="mono">${esc(label(b.frequency))}</b><span class="mono g" style="color:${col}">${esc(format('%+.1f dB', b.gainDB))}</span></div>`;
    }).join('');
    const log = entries.length ? entries.slice(-7).reverse().map((e) => `<p class="as-note" style="color:${noteColor(e.note)}">${esc(note(e.note))}</p>`).join('')
      : `<p class="as-nolog">${esc(t('assist.detail.nolog'))}</p>`;
    return `<div class="glass as-detail">
      <div class="as-dhead"><div><h2>${esc(`${s.id} · ${name(s.id)}`)}</h2><span>${esc(k ? t('assist.kind.' + k) : '—')}</span></div><span class="sp"></span>${stateBadge(stateOf(s.id))}</div>
      <div class="as-tiles">
        ${valueTile(t('assist.tile.gain'), f1(s.gainDB) + ' dB', s.polarityInverted ? t('assist.tile.inverted') : '')}
        ${valueTile(t('assist.tile.hpf'), s.highPassOn ? f0(s.highPassHz) + ' Hz' : t('assist.off'))}
        ${valueTile(t('assist.tile.comp'), c.enabled ? f1(c.ratio) + ':1' : t('assist.off'), c.enabled ? f0(c.thresholdDB) + ' dB' : '')}
        ${valueTile(t('assist.tile.deviation'), dev != null ? format('±%.1f dB', dev) : '—')}</div>
      <div class="as-eq">
        <div class="as-eq-head"><span class="lbl">${esc(t('assist.detail.eq'))}</span><span class="sp"></span>
          <span class="as-legend"><i style="background:var(--accent)"></i>${esc(t('assist.detail.curve'))}</span>
          <span class="as-legend"><i style="background:rgba(100,210,255,0.7)"></i>${esc(t('assist.detail.spectrum'))}</span></div>
        <canvas class="as-curve" data-curve="${s.id}"></canvas>
        <div class="as-bands">${bands}</div></div>
      <div class="as-log"><span class="lbl">${esc(t('assist.detail.log'))}</span>${log}</div>
      <span class="grow"></span>
      <div>${button(t('assist.tuneOne'), { kind: 'primary', act: 'tuneOne', arg: s.id, ic: 'wand.and.stars', disabled: !isConnected() || running() })}</div>
    </div>`;
  }

  function soundcheckScreen() {
    if (!strips().length) return `<div class="as-sc">${soundcheckActions()}${notConnectedCard()}</div>`;
    return `<div class="as-sc">${soundcheckActions()}<div class="as-sc-body">${channelList()}${channelDetail()}</div></div>`;
  }

  // MARK: show (ShowScreen)

  function guardBanner() {
    const s = st();
    const on = !!(s.guarding || s.rehearsing);
    const total = (s.guardLog || []).filter((e) => ['notch', 'monitorDip', 'unmask', 'tonalHold'].includes(Object.keys(e.a || {})[0])).length;
    const stat = (v, l) => `<div class="as-stat"><b class="mono">${esc(v)}</b><span>${esc(l)}</span></div>`;
    let buttons;
    if (s.rehearsing) {
      buttons = button(t('assist.sim.stop'), { kind: 'danger', act: 'rehearsalStop', ic: 'stop.fill' });
    } else {
      buttons = `<span class="as-pop-anchor">${button(t('assist.sim.title'), { act: 'simOpen', ic: 'play.fill', disabled: !isConnected() || s.guarding })}${A.simOpen ? rehearsalControls() : ''}</span>`
        + (s.guarding ? button(t('assist.guard.off'), { kind: 'danger', act: 'guardStop', ic: 'shield.slash' })
          : button(t('assist.guard.on'), { kind: 'primary', act: 'guardStart', ic: 'shield.lefthalf.filled', disabled: !isConnected() }));
    }
    return `<div class="glass as-banner ${on ? 'on' : ''}">
      <span class="as-shield">${icon(on ? 'shield.lefthalf.filled' : 'shield.slash', 20)}</span>
      <div class="titles"><div class="row"><b>${esc(t(on ? 'assist.banner.on' : 'assist.banner.off'))}</b>${s.rehearsing && s.rehearsalScene ? UI.statusBadge('warning', t('assist.sim.scene.' + s.rehearsalScene)) : ''}</div>
        <span>${esc(t(on ? 'assist.banner.text' : 'assist.banner.textoff'))}</span></div>
      <span class="sp"></span>
      ${on ? `<div class="as-stats">${stat(String((s.corrections || []).length), t('assist.stat.active'))}${stat(String(total), t('assist.stat.total'))}${stat(clock(s.guardElapsed, true), t('assist.stat.time'))}</div>` : ''}
      <div class="as-bbuttons">${buttons}</div></div>`;
  }

  function rehearsalControls() {
    const s = st();
    const reh = !!s.rehearsing;
    const fam = s.family;
    return `<div class="glass as-popover" data-stop="1">
      <span class="lbl">${esc(t('assist.sim.title'))}</span>
      <p class="hint">${esc(t('assist.sim.hint'))}</p>
      <div class="as-row gap8">${picker('', 'testScenario', SCENARIOS.map(([id]) => [id, t('assist.scenario.' + id)]), A.testScenario, { width: 170, disabled: reh })}
        ${stepper(format(t('assist.sim.scene'), Math.trunc(A.rehearsalSceneSeconds)), 'rehearsalSceneSeconds', A.rehearsalSceneSeconds, 10, 60, 5, { disabled: reh })}</div>
      <div class="as-row gap8">${reh ? button(t('assist.sim.stop'), { kind: 'danger', act: 'rehearsalStop', ic: 'stop.fill' }) + (s.rehearsalScene ? UI.statusBadge('warning', t('assist.sim.scene.' + s.rehearsalScene)) : '')
        : button(t('assist.sim.start'), { kind: 'primary', act: 'rehearsalStart', ic: 'play.fill', disabled: !isConnected() || s.guarding })}</div>
      ${fam === 'x32' || fam === 'xAir' ? `<span class="as-warn">${icon('exclamationmark.triangle.fill', 11)}${esc(t('assist.sim.warning'))}</span>` : ''}</div>`;
  }

  function monitorStrip() {
    const s = st();
    const monIds = s.monitorBuses || [];
    const mons = buses().filter((b) => monIds.includes(b.id));
    const others = buses().filter((b) => !monIds.includes(b.id));
    const corr = s.corrections || [];
    const cards = mons.map((b) => {
      const dip = corr.find((c) => c.kind === 'monitorDip' && c.target === b.id);
      const right = dip ? `<span class="dip">${esc(dip.restoreIn != null ? t('assist.mon.restore', Math.ceil(dip.restoreIn)) : t('assist.mon.holding'))}</span>`
        : `<span class="ok">${esc(t('assist.mon.ok'))}</span>`;
      return `<div class="glass as-mon ${dip ? 'dip' : ''}"><div class="row"><b>${esc(b.name || `Bus ${b.id}`)}</b><span class="sp"></span>
        ${s.guardian ? `<button class="as-x" data-act="setMonitor" data-arg="${b.id}:0">${icon('xmark', 9)}</button>` : ''}</div>
        ${levelBar(b.id, true)}
        <div class="row"><span class="mono f">${esc(b.faderDB <= -90 ? '−∞' : format('%+.1f dB', b.faderDB))}</span><span class="sp"></span>${right}</div></div>`;
    }).join('');
    const add = s.guardian && others.length ? `<span class="as-pop-anchor"><button class="as-mon-add" data-act="menu" data-arg="mon"><b>${esc(t('assist.mon.add'))}</b><span>${esc(t('assist.mon.addhint'))}</span></button>
      ${A.menu === 'mon' ? `<div class="as-menu" data-stop="1">${others.map((b) => `<button data-act="setMonitor" data-arg="${b.id}:1">${esc(b.name || `Bus ${b.id}`)}</button>`).join('')}</div>` : ''}</span>` : '';
    const none = mons.length ? '' : `<p class="as-mon-none">${esc(t('assist.mon.none'))}</p>`;
    return `<div class="as-mons">${cards}${add}${none}</div>`;
  }

  function correctionsCard() {
    const s = st();
    const corr = s.corrections || [];
    const rows = corr.map((c) => {
      const f = c.frequency != null ? label(c.frequency) : '';
      let title, text, when, ic, tint;
      switch (c.kind) {
        case 'monitorDip':
          title = format(t('assist.corr.dip.title'), busName(c.target)); text = t('assist.corr.dip.text');
          when = c.restoreIn != null ? t('assist.mon.restore', Math.ceil(c.restoreIn)) : t('assist.corr.untilquiet');
          ic = 'speaker.wave.3.fill'; tint = '255,214,10'; break;
        case 'notch':
          title = format(t('assist.corr.notch.title'), name(c.target), f); text = t('assist.corr.notch.text'); when = t('assist.corr.untilquiet');
          ic = 'waveform.path.badge.minus'; tint = '255,69,58'; break;
        case 'unmask':
          title = format(t('assist.corr.unmask.title'), name(c.target)); text = format(t('assist.corr.unmask.text'), f); when = t('assist.corr.untilscene');
          ic = 'person.wave.2.fill'; tint = '100,210,255'; break;
        default:
          title = format(t('assist.corr.tonal.title'), name(c.target)); text = format(t('assist.corr.tonal.text'), f); when = t('assist.corr.untilquiet');
          ic = 'dial.low'; tint = '46,229,157';
      }
      return `<div class="as-corr"><span class="ic" style="color:rgb(${tint});background:rgba(${tint},0.14)">${icon(ic, 14)}</span>
        <div class="titles"><b>${esc(title)}</b><span>${esc(text)}</span></div><span class="sp"></span>
        <div class="amt"><b class="mono">${esc(format('%+.0f dB', c.amountDB))}</b><span>${esc(when)}</span></div>
        ${button(t('assist.corr.cancel'), { act: 'cancelCorrection', arg: c.id })}</div>`;
    }).join('');
    const empty = corr.length ? '' : `<p class="as-corr-empty">${icon('checkmark.circle', 13)}${esc(t('assist.corr.empty'))}</p>`;
    return card(t('assist.corr.title'), 'var(--signal-yellow)', `<span class="as-acc small">${esc(t('assist.corr.hint'))}</span>`,
      `<div class="as-scroll-y grow" data-scroll="corr">${empty}${rows}</div><div class="as-hair"></div><div class="as-leads">${leadsRow()}</div>`, { cls: 'as-corrs' });
  }

  function leadsRow() {
    const s = st();
    const leads = s.leads || [];
    const named = strips().filter((x) => x.name);
    const chips = named.filter((x) => leads.includes(x.id)).map((x) => `<button class="as-lead" data-act="setLead" data-arg="${x.id}:0">${esc(x.name)}${icon('xmark', 8)}</button>`).join('');
    const add = s.guardian ? `<span class="as-pop-anchor"><button class="as-lead-add" data-act="menu" data-arg="lead">${esc(t('assist.leads.add'))}</button>
        ${A.menu === 'lead' ? `<div class="as-menu" data-stop="1">${named.filter((x) => !leads.includes(x.id)).map((x) => `<button data-act="setLead" data-arg="${x.id}:1">${esc(x.name)}</button>`).join('')}</div>` : ''}</span>`
      : `<span class="as-leads-off">${esc(t('assist.leads.off'))}</span>`;
    return `<span class="lbl">${esc(t('assist.guard.leads'))}</span><div class="as-lead-row">${chips}${add}</div>`;
  }

  function showLogCard() {
    const s = st();
    const out = [];
    for (const e of (s.guardLog || []).slice(-60)) {
      const k = Object.keys(e.a || {})[0];
      out.push({ time: e.t, text: action(e.a), color: k === 'yielded' ? 'var(--data-blue)' : 'var(--text-primary)' });
    }
    for (const e of (s.rehearsalLog || []).slice(-40)) {
      if (e.scene) out.push({ time: e.t, text: '▶ ' + t('assist.sim.scene.' + e.scene), color: 'var(--text-secondary)' });
      else if (e.fader != null) out.push({ time: e.t, text: format(t('assist.sim.fader'), name(e.fader), e.db), color: 'var(--data-blue)' });
      else if (e.bus != null) out.push({ time: e.t, text: format(t('assist.sim.bus'), busName(e.bus), e.db), color: 'var(--data-blue)' });
    }
    const lines = out.map((l, i) => [l, i]).sort((a, b) => (b[0].time - a[0].time) || (b[1] - a[1])).map(([l]) => l);
    const body = lines.length ? lines.map((l) => `<div class="as-logline"><span class="mono tm">${clock(l.time)}</span><span style="color:${l.color}">${esc(l.text)}</span></div>`).join('')
      : `<p class="as-nolog">${esc(t('assist.guard.empty'))}</p>`;
    const acc = `<span class="as-acc small"><span class="muted">${esc(t('assist.journal.assistant'))}</span><span class="muted"> · </span><span style="color:var(--data-blue)">${esc(t('assist.journal.you'))}</span></span>`;
    return card(t('assist.journal'), 'var(--data-secondary)', acc, `<div class="as-scroll-y" data-scroll="journal"><div class="as-journal">${body}</div></div>`, { cls: 'as-journal-card' });
  }

  function showScreen() {
    return `<div class="as-show">${guardBanner()}${monitorStrip()}<div class="as-show-body">${correctionsCard()}${showLogCard()}</div></div>`;
  }

  // MARK: console test (ConsoleTestScreen)

  function linkDiagnostics() {
    const s = st();
    const ls = s.linkStats || {};
    const n = (k) => Number(ls[k] || 0);
    const rate = (x) => (x >= 10 ? 'good' : x > 0 ? 'warn' : 'bad');
    const per = (x) => format(t('assist.diag.perSecond'), x);
    const row = (title, value, ok) => `<div class="as-diag-row"><i class="${ok}"></i><span class="t">${esc(title)}</span><span class="sp"></span><span class="mono v">${esc(value)}</span></div>`;
    const model = ls.model || '';
    const heard = n('paramsHeard'), expected = n('paramsExpected'), gk = n('gainKnown'), chs = n('channels');
    let x32 = '';
    if (s.family === 'x32') {
      x32 = `<div class="as-row"><span class="t small">${esc(t('assist.diag.routing'))}</span><span class="sp"></span>${picker('', 'routing', ROUTINGS.map((r) => [r, t('assist.routing.' + r)]), A.routing, { width: 230 })}</div>`
        + (gk < chs && A.routing === 'auto' ? `<p class="as-gain-hint">${esc(t('assist.diag.gainHint'))}</p>` : '');
    }
    return `<div class="as-diag">${row(t('assist.diag.console'), model ? model : t('assist.diag.noInfo'), model ? 'good' : 'bad')}
      ${row(t('assist.diag.levels'), per(n('channelFrames')), rate(n('channelFrames')))}
      ${row(t('assist.diag.buses'), per(n('busFrames')), rate(n('busFrames')))}
      ${row(t('assist.diag.rta'), per(n('rtaFrames')), rate(n('rtaFrames')))}
      ${row(t('assist.diag.params'), `${heard} / ${expected}`, expected === 0 ? 'bad' : heard >= Math.trunc(expected * 95 / 100) ? 'good' : heard > 0 ? 'warn' : 'bad')}
      ${row(t('assist.diag.gain'), `${gk} / ${chs}`, gk === chs ? 'good' : gk > 0 ? 'warn' : 'bad')}${x32}</div>`;
  }

  function consoleTestPanel() {
    const s = st();
    const testing = !!s.testing;
    return `<div class="as-testp"><p class="hint">${esc(t('assist.test.hint'))}</p>
      ${picker(t('assist.test.scenario'), 'testScenario', SCENARIOS.map(([id, n]) => [id, t('assist.scenario.' + id) + ` · ${n} ch`]), A.testScenario, { width: 400 })}
      ${stepper(format(t('assist.test.first'), A.testFirst), 'testFirst', A.testFirst, 1, 32)}
      <label class="as-check"><input type="checkbox" data-change="testMuteMain" ${A.testMuteMain ? 'checked' : ''}><span>${esc(t('assist.test.muteMain'))}</span></label>
      <span class="as-warn">${icon('exclamationmark.triangle.fill', 11)}${esc(t('assist.test.warning'))}</span>
      <div class="as-row gap8">${button(testing ? t('assist.test.running') : t('assist.test.run'), { kind: 'primary', act: 'testRun', ic: 'checklist', disabled: testing || (s.family !== 'simulator' && !isConnected()) })}${testing ? '<span class="as-spinner"></span>' : ''}</div></div>`;
  }

  function faderWavePanel() {
    const s = st();
    const waving = !!s.waving;
    const ticks = Array.from({ length: 23 }, () => '<i></i>').join('');
    return `<div class="as-wave"><p class="hint">${esc(t('assist.wave.hint'))}</p>
      <canvas class="as-wave-canvas"></canvas>
      <div class="as-row gap10"><span class="t">${esc(t('assist.wave.cycle'))}</span>
        <span class="as-slider"><span class="ticks">${ticks}</span><input type="range" min="1" max="12" step="0.5" value="${A.waveCycle}" data-input="waveCycle" data-change="waveCycleSet"></span>
        <span class="mono v" id="assist-wave-cycle">${esc(format('%.1f s', A.waveCycle))}</span></div>
      ${button(t(waving ? 'assist.wave.stop' : 'assist.wave.start'), { kind: waving ? 'danger' : 'primary', act: waving ? 'waveStop' : 'waveStart', ic: waving ? 'stop.fill' : 'water.waves', cls: 'wide', disabled: !!s.testing })}
      <p class="safety">${esc(t('assist.wave.safety'))}</p></div>`;
  }

  function testStepper() {
    const checks = st().testChecks || [];
    if (!checks.length) return `<p class="as-nolog">${esc(t('assist.test.empty'))}</p>`;
    const color = { ok: 'var(--status-good)', warning: 'var(--status-warning)', running: 'var(--status-warning)', failed: 'var(--status-error)' };
    return checks.map((c, i) => {
      let mark;
      if (c.status === 'ok') mark = UI.checkDot(true);
      else if (c.status === 'failed') mark = UI.checkDot(false, true);
      else if (c.status === 'warning') mark = `<span class="as-warnmark">${icon('exclamationmark', 11)}</span>`;
      else mark = '<span class="as-spinner sized"></span>';
      return `<div class="as-tstep"><div class="rail">${mark}${i < checks.length - 1 ? '<span class="line"></span>' : ''}</div>
        <div class="body"><div class="row"><b>${esc(t('assist.test.step.' + c.id))}</b><span style="color:${color[c.status]}">${esc(t('assist.test.status.' + c.status))}</span></div>
        <p>${esc(c.detail)}</p></div></div>`;
    }).join('');
  }

  function testScreen() {
    const s = st();
    const left = (s.family !== 'simulator' ? panel(t('assist.diag'), 'var(--data-blue)', linkDiagnostics()) : '')
      + panel(t('assist.test'), 'var(--signal-yellow)', consoleTestPanel())
      + panel(t('assist.wave'), 'var(--accent)', faderWavePanel());
    return `<div class="as-test"><div class="as-test-left">${left}</div>
      ${card(t('assist.test.report'), 'var(--data-secondary)', '', `<div class="as-scroll-y" data-scroll="report"><div class="as-report">${testStepper()}</div></div>`, { cls: 'as-report-card' })}</div>`;
  }

  // MARK: learning (LearnScreen.swift)

  function recordPanel() {
    const s = st();
    const L = A.learn || {};
    const stat = (v, l) => `<div class="as-lstat"><b class="mono">${esc(v)}</b><span>${esc(l)}</span></div>`;
    const lock = `<span class="as-ro">${icon('lock.shield', 12)}${esc(t(s.family === 'simulator' ? 'assist.learn.simNote' : 'assist.learn.readOnly'))}</span>`;
    const hint = `<p class="hint">${esc(t('assist.learn.hint'))}</p>`;
    if (L.recording) {
      return `<div class="as-rec">${lock}${hint}
        <div class="as-rec-live"><span class="dot"></span><b>${esc(t('assist.learn.recording') + ': ' + (L.title || A.learnTitle))}</b><span class="sp"></span><span class="mono clock">${esc(learnClock(L.seconds))}</span></div>
        <div class="as-lstats">${stat(String(L.frames || 0), t('assist.learn.frames'))}${stat(String(L.changes || 0), t('assist.learn.changes'))}${stat(String(L.params || 0), t('assist.learn.params'))}</div>
        ${button(t('assist.learn.stop'), { kind: 'danger', act: 'learnStop', ic: 'stop.fill', cls: 'wide' })}</div>`;
    }
    return `<div class="as-rec">${lock}${hint}
      <input id="assist-learn-title" class="field" data-input="learnTitle" value="${esc(A.learnTitle)}" placeholder="${esc(t('assist.learn.titlePlaceholder'))}">
      ${button(t('assist.learn.start'), { kind: 'primary', act: 'learnStart', ic: 'record.circle', cls: 'wide', disabled: !isConnected() })}</div>`;
  }

  function dateText(sec) {
    const d = new Date(sec * 1000);
    return SSMT.S.lang === 'ru'
      ? d.toLocaleString('ru-RU', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
      : d.toLocaleString('en-US', { day: 'numeric', month: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });
  }

  function progressPanel() {
    const R = A.recordings || { items: [] };
    const items = R.items || [];
    const events = items.filter((r) => r.event).length;
    const target = R.target || 20;
    const rec = !!(A.learn && A.learn.recording);
    const list = items.slice(0, 12).map((r) => `<div class="as-recrow"><div class="titles"><b>${esc(r.title)}</b>
        <span>${esc(dateText(r.startedAt) + ' · ' + learnClock(r.duration) + (r.event ? '' : ' · ' + t('assist.learn.trial')))}</span></div><span class="sp"></span>
        <button ${attr({ class: 'as-trash', 'data-act': 'deleteRecording', 'data-arg': r.file, disabled: rec, title: t('assist.learn.delete') })}>${icon('trash', 13)}</button></div>`).join('');
    const d = A.dataset;
    const dataset = items.length ? `<div>${button(t('assist.learn.dataset'), { act: 'exportDataset', ic: 'tray.and.arrow.down', disabled: rec, title: t('assist.learn.datasetHint') })}</div>
      ${d ? `<p class="hint small">${esc(format(t('assist.learn.datasetDone'), d.rows, d.recordings, String(d.path || '').split(/[\\/]/).pop()))}</p>` : ''}` : '';
    return `<div class="as-progress"><div class="as-row"><b class="ev">${esc(t('assist.learn.events', events, target))}</b><span class="sp"></span>
        ${button('', { act: 'openFolder', ic: 'folder', title: t('assist.learn.openFolder'), cls: 'icon-only' })}</div>
      <div class="as-pbar"><i style="width:${Math.min(events, target) / target * 100}%"></i></div>
      <p class="hint small">${esc(t('assist.learn.progressHint'))}</p>
      ${items.length ? '' : `<p class="as-nolog">${esc(t('assist.learn.empty'))}</p>`}${list}${dataset}</div>`;
  }

  function patternsPanel() {
    if (A.summary && (A.recordings.items || []).length) return `<pre class="as-patterns">${esc(A.summary)}</pre>`;
    return `<p class="as-nolog">${esc(t('assist.learn.noPatterns'))}</p>`;
  }

  function modelPanel() {
    const L = A.llm;
    return `<div class="as-llm"><p class="hint small">${esc(t('assist.llm.hint'))}</p>
      <div class="as-row gap8"><input id="assist-llm-url" class="field grow" data-input="llmURL" value="${esc(L.url)}" placeholder="http://localhost:11434" spellcheck="false">
        <input id="assist-llm-model" class="field" style="width:130px" data-input="llmModel" value="${esc(L.model)}" placeholder="qwen2.5:1.5b" spellcheck="false">
        ${button(t('assist.llm.check'), { act: 'checkModel' })}</div>
      ${L.status ? `<p class="hint small">${esc(L.status)}</p>` : ''}
      <textarea id="assist-llm-question" class="field" rows="2" data-input="llmQuestion" placeholder="${esc(t('assist.llm.questionPlaceholder'))}">${esc(L.question)}</textarea>
      ${button(t(L.asking ? 'assist.llm.asking' : 'assist.llm.ask'), { kind: 'primary', act: 'ask', ic: 'sparkles', cls: 'wide', disabled: L.asking || !L.question.trim() })}
      ${L.answer ? `<div class="as-answer">${esc(L.answer)}</div>` : ''}</div>`;
  }

  function liveConsole() {
    const rows = strips().map((s) => `<div class="as-live"><span class="mono id">${s.id}</span><b>${esc(s.name || '—')}</b>
      <span class="mono g">${esc(f1(s.gainDB) + ' dB')}</span>
      <span class="mono f" style="color:${s.muted ? 'var(--status-error)' : 'var(--text-primary)'}">${esc(s.muted ? 'MUTE' : s.faderDB <= -90 ? '−∞' : format('%+.1f', s.faderDB))}</span>
      ${liveMeter(s.id)}</div><div class="as-hair"></div>`).join('');
    return `<div class="as-scroll-y" data-scroll="live">${rows}</div>`;
  }

  function liveMeter(id) {
    const db = A.meters.channels[id - 1];
    const v = db == null ? -120 : db;
    return `<span class="as-level live" data-live="${id}"><i style="width:${levelWidth(v)}%;background:${v > -3 ? 'var(--status-error)' : 'var(--accent)'}"></i></span>`;
  }

  function learnScreen() {
    const s = st();
    const rec = !!(A.learn && A.learn.recording);
    return `<div class="as-learn"><div class="as-learn-left">
        ${panel(t('assist.learn.record'), rec ? 'var(--status-error)' : 'var(--accent)', recordPanel())}
        ${panel(t('assist.learn.live'), 'var(--data-blue)', liveConsole(), 'as-live-panel')}</div>
      <div class="as-scroll-y as-learn-right" data-scroll="learn">
        ${panel(t('assist.learn.progress'), 'var(--data-secondary)', progressPanel())}
        ${panel(t('assist.learn.patterns'), 'var(--signal-yellow)', patternsPanel())}
        ${panel(t('assist.llm.title'), 'var(--accent)', modelPanel())}
        ${s.family !== 'simulator' ? panel(t('assist.diag'), 'var(--data-blue)', linkDiagnostics()) : ''}</div></div>`;
  }

  /** A function that is off on a real console in this version (ComingSoonScreen). */
  function comingSoon(mode) {
    return `<div class="as-soon-wrap"><div class="glass as-soon"><span class="badge">${esc(t('assist.soon.badge'))}</span>
      <h2>${esc(t('assist.soon.title.' + mode))}</h2><p>${esc(t('assist.soon.text.' + mode))}</p>
      <div class="as-row gap10">${button(t('assist.soon.toLearn'), { kind: 'primary', act: 'mode', arg: 'learn' })}${button(t('assist.soon.toSim'), { act: 'toSim', arg: mode })}</div></div></div>`;
  }

  // MARK: settings sheet (AssistSettingsSheet, ConnectionPanel)

  function settingsSheet() {
    const s = st();
    const fam = A.family;
    const connected = isConnected();
    let status;
    switch (s.status) {
      case 'connecting': status = UI.statusBadge('warning', t('assist.connecting')); break;
      case 'connected': status = UI.statusBadge('good', s.connection || ''); break;
      case 'failed': status = UI.statusBadge('error', failure(s.failure)); break;
      default: status = UI.statusBadge('idle', t('assist.offline'));
    }
    const fams = ['x32', 'xAir', 'wing', 'yamaha', 'allenHeath', 'simulator'].map((f) => [f, t('assist.family.' + f) + (IMPLEMENTED.has(f) ? '' : ' — ' + t('assist.soon'))]);
    let real = '';
    if (fam !== 'simulator') {
      const devs = [['', t('assist.systemInput')], ...A.inputDevices.map((d) => [d.id, d.label])];
      real = `<div class="as-seg wide">${['network', 'interface'].map((v) => `<button class="${A.signalSource === v ? 'on' : ''}" data-act="signalSource" data-arg="${v}">${esc(t('assist.source.' + v))}</button>`).join('')}</div>
        <div class="as-row gap10 small">${picker(t('assist.audioIn'), 'inputDevice', devs, A.inputDevice, { width: 330 })}
          ${A.signalSource === 'interface' ? stepper(format(t('assist.firstInput'), A.firstInput), 'firstInput', A.firstInput, 1, 64) : ''}
          ${stepper(A.micInput === 0 ? t('assist.noMic') : format(t('assist.micInput'), A.micInput), 'micInput', A.micInput, 0, 64)}
          ${stepper(A.stageMicInput === 0 ? t('assist.noStageMic') : format(t('assist.stageMicInput'), A.stageMicInput), 'stageMicInput', A.stageMicInput, 0, 64)}</div>
        <p class="hint small muted">${esc(t(A.signalSource === 'network' ? 'assist.networkHint' : 'assist.audioHint'))}</p>`;
    }
    const chars = `<div class="as-pick-seg"><span class="lbl">${esc(t('assist.character'))}</span><div class="as-seg" style="width:${420 - 70}px">${CHARACTERS.map((c) => `<button class="${(s.character || A.character) === c ? 'on' : ''}" data-act="character" data-arg="${c}">${esc(t('assist.char.' + c))}</button>`).join('')}</div></div>`;
    const panelHTML = `<div class="as-conn-panel">
      <div class="as-row gap10">${picker(t('assist.mixer'), 'family', fams, fam, { width: 330 })}
        ${fam !== 'simulator' ? `<input id="assist-host" class="field" style="width:140px" data-input="host" value="${esc(A.host)}" placeholder="192.168.1.64" spellcheck="false">` : ''}
        ${button(connected ? t('assist.disconnect') : t('assist.connect'), { kind: connected ? 'secondary' : 'primary', act: connected ? 'disconnect' : 'connect', disabled: !IMPLEMENTED.has(fam) })}
        ${status}</div>
      ${real}
      <div class="as-row gap10">${picker(t('assist.measMic'), 'micID', [['', t('assist.measMic.fromSetup')]], '', { width: 420 })}
        ${s.micLevel != null ? `<span class="hint mono">${esc(format(s.micCalibrated ? '%.0f dB(A)' : '%.0f dBFS(A)', s.micLevel))}</span>` : ''}</div>
      <div class="as-row gap10">${chars}${picker(t('assist.tap'), 'tap', [['preEQ', t('assist.tap.preEQ')], ['postEQ', t('assist.tap.postEQ')]], s.tap || A.tap, { width: 260 })}</div>
      <p class="hint small">${esc(t('assist.char.' + (s.character || A.character) + '.hint'))}</p></div>`;
    return `<div class="as-sheet-veil"><div class="as-sheet"><div class="as-sheet-head"><h2>${esc(t('assist.settings'))}</h2><span class="sp"></span>
      ${button(t('settings.done'), { kind: 'primary', act: 'closeSettings' })}</div><div class="as-hair"></div>
      <div class="as-sheet-body">${connected && fam !== 'simulator' ? linkDiagnostics() : ''}${panelHTML}</div></div></div>`;
  }

  // MARK: workspace

  function workspace() {
    let banner = '';
    if (A.message) {
      const m = A.message;
      const text = m === 'nothing found' ? t('assist.nothingFound') : m.startsWith('assist.') ? t(m) : m;
      banner = `<div class="as-error">${icon('exclamationmark.octagon.fill', 14)}<span class="text">${esc(text)}</span><button class="btn plain" data-act="dismiss">${icon('xmark', 13)}</button></div>`;
    }
    let content;
    if (locked(A.mode)) content = comingSoon(A.mode);
    else if (A.mode === 'show') content = showScreen();
    else if (A.mode === 'test') content = testScreen();
    else if (A.mode === 'learn') content = learnScreen();
    else content = soundcheckScreen();
    return `<div class="as-ws">${header()}${banner}${content}</div>${A.showSettings ? settingsSheet() : ''}`;
  }

  function render() {
    // Scroll positions of the inner scroll areas survive the redraw.
    document.querySelectorAll('#pane-assist [data-scroll]').forEach((el) => { A.scroll[el.dataset.scroll] = el.scrollTop; });
    return `<div class="assist-root">${isConnected() ? workspace() : connectScreen()}</div>`;
  }

  // MARK: drawing after the markup (EQ curve, fader wave) and the measured layouts (ViewThatFits)

  function after(pane) {
    pane.querySelectorAll('[data-scroll]').forEach((el) => { if (A.scroll[el.dataset.scroll]) el.scrollTop = A.scroll[el.dataset.scroll]; });
    // ViewThatFits: the full chips or the short ones; the actions in one row or two.
    const head = pane.querySelector('.as-header');
    if (head) {
      const over = head.scrollWidth > head.clientWidth + 1;
      if (over && !A.compactHeader) { A.compactHeader = true; SSMT.render(); return; }
    }
    const acts = pane.querySelector('.as-actions');
    if (acts && !A.stackedActions && acts.scrollWidth > acts.clientWidth + 1) { A.stackedActions = true; SSMT.render(); return; }
    drawCurve(pane);
    drawWave(pane);
    if (!A.visible) { A.visible = true; autoScan(); }
  }

  function drawCurve(pane) {
    const c = pane.querySelector('canvas.as-curve');
    if (!c) return;
    const id = Number(c.dataset.curve);
    const s = stripOf(id);
    const key = id + ':' + JSON.stringify(s && [s.eq, s.eqOn, s.highPassOn, s.highPassHz]);
    if (key !== A.curveKey) { A.curveKey = key; send({ cmd: 'curve', channel: id }); }
    const W = c.clientWidth, H = c.clientHeight, dpr = window.devicePixelRatio || 1;
    c.width = W * dpr; c.height = H * dpr;
    const g = c.getContext('2d');
    g.scale(dpr, dpr);
    const fMin = 20, fMax = 20000, range = 15;
    const x = (f) => Math.log10(f / fMin) / Math.log10(fMax / fMin) * W;
    const y = (db) => (range - Math.max(-range, Math.min(range, db))) / (2 * range) * H;
    const line = (x0, y0, x1, y1, col) => { g.strokeStyle = col; g.lineWidth = 1; g.beginPath(); g.moveTo(x0, y0); g.lineTo(x1, y1); g.stroke(); };
    for (const f of [50, 100, 200, 500, 1000, 2000, 5000, 10000]) line(x(f), 0, x(f), H, 'rgba(255,255,255,0.06)');
    for (const db of [-12, -6, 0, 6, 12]) line(0, y(db), W, y(db), `rgba(255,255,255,${db === 0 ? 0.16 : 0.06})`);
    const centers = st().thirdOctaves || [];
    const feat = featureOf(id);
    if (feat && feat.bands && feat.bands.length === centers.length) {
      const sp = feat.bands;
      const mid = centers.map((f, i) => i).filter((i) => centers[i] >= 100 && centers[i] <= 8000);
      const ref = mid.reduce((a, i) => a + sp[i], 0) / Math.max(1, mid.length);
      g.strokeStyle = 'rgba(100,210,255,0.55)'; g.lineWidth = 1.2; g.setLineDash([3, 3]); g.beginPath();
      let first = true;
      centers.forEach((f, i) => { if (sp[i] > -110) { const px = x(f), py = y((sp[i] - ref) * 0.5); if (first) { g.moveTo(px, py); first = false; } else g.lineTo(px, py); } });
      g.stroke(); g.setLineDash([]);
    }
    const cv = A.curve && A.curve.channel === id ? A.curve : null;
    if (cv && cv.db) {
      const n = cv.db.length - 1;
      const pts = cv.db.map((db, i) => [x(fMin * Math.pow(fMax / fMin, i / n)), y(db)]);
      g.beginPath(); pts.forEach(([px, py], i) => (i ? g.lineTo(px, py) : g.moveTo(px, py)));
      g.lineTo(W, y(0)); g.lineTo(0, y(0)); g.closePath(); g.fillStyle = 'rgba(46,229,157,0.12)'; g.fill();
      g.beginPath(); pts.forEach(([px, py], i) => (i ? g.lineTo(px, py) : g.moveTo(px, py)));
      g.strokeStyle = '#2EE59D'; g.lineWidth = 2; g.stroke();
      g.fillStyle = '#2EE59D';
      for (const d of cv.dots || []) { g.beginPath(); g.arc(x(d.f), y(d.db), 4, 0, Math.PI * 2); g.fill(); }
    }
    g.fillStyle = '#5F6862'; g.font = '9px Inter, sans-serif'; g.textBaseline = 'bottom';
    for (const f of [50, 100, 200, 500, 1000, 2000, 5000, 10000]) g.fillText(label(f), x(f) + 3, H - 3);
    for (const db of [-12, -6, 6, 12]) g.fillText(format('%+.0f', db), 4, y(db) - 1);
  }

  let waveFrame = 0;
  function drawWave(pane) {
    const c = (pane || document).querySelector('#pane-assist canvas.as-wave-canvas, canvas.as-wave-canvas');
    if (!c) return;
    const s = st();
    const waving = !!s.waving;
    const n = Math.max(1, s.waveChannels || 1);
    const tSec = waving ? (performance.now() - A.waveStartedAt) / 1000 : 0;
    const cyc = Math.max(0.2, A.waveCycle);
    const W = c.clientWidth, H = c.clientHeight, dpr = window.devicePixelRatio || 1;
    c.width = W * dpr; c.height = H * dpr;
    const g = c.getContext('2d');
    g.scale(dpr, dpr);
    const w = W / n;
    for (let i = 0; i < n; i++) {
      // FaderWave.positions: 0.5 + 0.5 sin(2π (t / cycle − i / n)).
      const p = 0.5 + 0.5 * Math.sin(2 * Math.PI * (tSec / cyc - i / n));
      const xx = i * w + w / 2;
      g.strokeStyle = 'rgba(255,255,255,0.1)'; g.lineWidth = 2;
      g.beginPath(); g.moveTo(xx, 4); g.lineTo(xx, H - 4); g.stroke();
      const yy = 4 + (1 - p) * (H - 8);
      const cw = Math.max(4, w * 0.7);
      g.fillStyle = waving ? '#2EE59D' : '#5F6862';
      g.beginPath();
      if (g.roundRect) g.roundRect(xx - Math.max(2, w * 0.35), yy - 3, cw, 6, 1.5); else g.rect(xx - Math.max(2, w * 0.35), yy - 3, cw, 6);
      g.fill();
    }
    cancelAnimationFrame(waveFrame);
    if (waving) waveFrame = requestAnimationFrame(() => drawWave(null));
  }

  function updateMeters() {
    const pane = document.getElementById('pane-assist');
    if (!pane || pane.hidden) return;
    pane.querySelectorAll('.as-level[data-ch], .as-level[data-bus], .as-level[data-live]').forEach((el) => {
      const bus = el.dataset.bus != null;
      const id = Number(el.dataset.ch || el.dataset.bus || el.dataset.live);
      const v = (bus ? A.meters.buses : A.meters.channels)[id - 1];
      const db = v == null ? -120 : v;
      const i = el.firstElementChild;
      i.style.width = levelWidth(db) + '%';
      i.style.background = el.dataset.live != null ? (db > -3 ? 'var(--status-error)' : 'var(--accent)') : levelColor(db);
    });
  }

  // MARK: actions

  function scan() {
    if (A.scanning) return;
    A.scanning = true;
    SSMT.render();
    const done = () => { A.scanning = false; SSMT.render(); };
    if (api && api.scan) Promise.resolve(api.scan()).then(done, done); else done();
  }

  function autoScan() {
    if (A.autoScan && !isConnected() && (A.family === 'x32' || A.family === 'xAir')) scan();
  }

  function connect() {
    A.message = null;
    if (A.family !== 'simulator') {
      store.set('assist.host', A.host);
      send({ cmd: 'routing', preset: A.routing });
      // A real console opens on learning (the rest is read-only there).
      setMode('learn');
    }
    send({ cmd: 'character', value: A.character });
    send({ cmd: 'tap', value: A.tap });
    send({ cmd: 'connect', family: A.family, host: A.host });
  }

  function setMode(m) {
    if (m !== 'test' && st().waving) send({ cmd: 'waveStop' });
    A.mode = m;
    A.simOpen = false;
    A.menu = null;
  }

  const actions = {
    family(f) {
      A.family = f;
      if (f === 'x32' || f === 'xAir') scan();
      SSMT.render();
    },
    scan() { scan(); },
    connect() { connect(); SSMT.render(); },
    connectTo(ip) {
      const c = A.discovered.find((x) => x.ip === ip);
      if (c) A.family = c.family;
      A.host = ip;
      connect();
      SSMT.render();
    },
    connectManual() {
      const ip = (A.manualIP == null ? A.host : A.manualIP).trim();
      if (!ip) return;
      A.host = ip;
      connect();
      SSMT.render();
    },
    disconnect() { send({ cmd: 'disconnect' }); },
    mode(m) { setMode(m); SSMT.render(); },
    settings() { A.showSettings = true; SSMT.render(); },
    closeSettings() { A.showSettings = false; SSMT.render(); },
    dismiss() { A.message = null; SSMT.render(); },
    step(arg) {
      const [key, d, min, max] = arg.split(':');
      A[key] = Math.max(Number(min), Math.min(Number(max), Number(A[key]) + Number(d)));
      SSMT.render();
    },
    tuneGroup(g) { send({ cmd: 'tuneGroup', group: g }); A.message = null; },
    tuneRange() { send({ cmd: 'tuneGroup', group: 'range', from: A.rangeFrom, to: A.rangeTo }); A.message = null; },
    polarity() { send({ cmd: 'polarity' }); A.message = null; },
    stopJob() { send({ cmd: 'stopJob' }); },
    undoAll() { send({ cmd: 'undo' }); },
    tuneOne(ch) { send({ cmd: 'tune', channel: Number(ch) }); A.message = null; },
    select(ch) { A.selectedChannel = Number(ch); SSMT.render(); },
    guardStart() { send({ cmd: 'guardStart' }); },
    guardStop() { send({ cmd: 'guardStop' }); },
    simOpen() { A.simOpen = !A.simOpen; A.menu = null; SSMT.render(); },
    rehearsalStart() { send({ cmd: 'rehearsalStart', scenario: A.testScenario, first: A.testFirst, sceneSeconds: A.rehearsalSceneSeconds }); },
    rehearsalStop() { send({ cmd: 'rehearsalStop' }); },
    menu(which) { A.menu = A.menu === which ? null : which; A.simOpen = false; SSMT.render(); },
    setMonitor(arg) { const [b, on] = arg.split(':'); A.menu = null; send({ cmd: 'setMonitor', bus: Number(b), on: on === '1' }); },
    setLead(arg) { const [c, on] = arg.split(':'); A.menu = null; send({ cmd: 'setLead', channel: Number(c), on: on === '1' }); },
    cancelCorrection(id) { send({ cmd: 'cancelCorrection', id }); },
    testScenario(v) { A.testScenario = v; SSMT.render(); },
    testMuteMain(v) { A.testMuteMain = !!v; },
    testRun() { send({ cmd: 'testRun', scenario: A.testScenario, first: A.testFirst, muteMain: A.testMuteMain }); },
    waveStart() { send({ cmd: 'waveStart', cycle: A.waveCycle }); },
    waveStop() { send({ cmd: 'waveStop' }); },
    waveCycleSet(v) { A.waveCycle = Number(v); send({ cmd: 'waveCycle', value: A.waveCycle }); SSMT.render(); },
    routing(v) { A.routing = v; store.set('assist.routing', v); send({ cmd: 'routing', preset: v }); SSMT.render(); },
    toSim(mode) {
      send({ cmd: 'disconnect' });
      A.family = 'simulator';
      connect();
      setMode(mode);
      SSMT.render();
    },
    learnStart() { send({ cmd: 'learnStart', title: A.learnTitle.trim() }); },
    learnStop() { send({ cmd: 'learnStop' }); },
    openFolder() { if (api && api.openFolder && A.recordings.dir) api.openFolder(A.recordings.dir); },
    deleteRecording(file) { send({ cmd: 'deleteRecording', file }); },
    exportDataset() { A.dataset = null; send({ cmd: 'exportDataset' }); SSMT.render(); },
    async checkModel() {
      if (!api || !api.llmModels) return;
      const r = await api.llmModels(A.llm.url);
      if (!r || !r.ok) A.llm.status = format(t('assist.llm.fail'), (r && r.error) || '');
      else if (!r.models.some((m) => m === A.llm.model || m === A.llm.model + ':latest')) A.llm.status = format(t('assist.llm.noModel'), A.llm.model, A.llm.model);
      else A.llm.status = format(t('assist.llm.ok'), r.models.join(', '));
      SSMT.render();
    },
    ask() {
      const q = A.llm.question.trim();
      if (!q || A.llm.asking) return;
      A.llm.asking = true;
      A.llm.answer = '';
      send({ cmd: 'prompt', question: q, lang: SSMT.S.lang === 'en' ? 'en' : 'ru', id: 'assist' });
      SSMT.render();
    },
    character(c) { A.character = c; send({ cmd: 'character', value: c }); SSMT.render(); },
    tap(v) { A.tap = v; send({ cmd: 'tap', value: v }); SSMT.render(); },
    signalSource(v) { A.signalSource = v; SSMT.render(); },
    inputDevice(v) { A.inputDevice = v; },
    micID() { /* The measurement mic of the setup function is used (library on Windows: function #1 port). */ },
  };

  const inputs = {
    manualIP(v) { A.manualIP = v; const b = document.querySelector('.as-manual .btn'); if (b) b.disabled = !v.trim(); },
    host(v) { A.host = v; store.set('assist.host', v); },
    learnTitle(v) { A.learnTitle = v; },
    llmURL(v) { A.llm.url = v; store.set('llm.url', v); },
    llmModel(v) { A.llm.model = v; store.set('llm.model', v); },
    llmQuestion(v) { A.llm.question = v; const b = document.querySelector('.as-llm .btn.primary'); if (b) b.disabled = A.llm.asking || !v.trim(); },
    waveCycle(v) { A.waveCycle = Number(v); const o = document.getElementById('assist-wave-cycle'); if (o) o.textContent = format('%.1f s', A.waveCycle); },
  };

  function keys(e) {
    if (e.key === 'Escape') {
      if (A.simOpen || A.menu) { A.simOpen = false; A.menu = null; SSMT.render(); return; }
      if (A.showSettings) { A.showSettings = false; SSMT.render(); }
    }
  }
  document.addEventListener('keydown', (e) => {
    const id = e.target && e.target.id;
    if (e.key !== 'Enter' || e.shiftKey) return;
    if (id === 'assist-llm-question') { e.preventDefault(); actions.ask(); }
    else if (id === 'assist-manual') actions.connectManual();
    else if (id === 'assist-learn-title' && isConnected()) actions.learnStart();
  });
  // A click outside a popover or a menu closes it.
  document.addEventListener('mousedown', (e) => {
    if ((A.simOpen || A.menu) && !e.target.closest('.as-pop-anchor')) { A.simOpen = false; A.menu = null; SSMT.render(); }
  });

  // MARK: engine events

  function onEvent(ev) {
    switch (ev.event) {
      case 'hello': send({ cmd: 'state' }); break;
      case 'state': {
        const was = isConnected();
        A.st = ev;
        if (ev.character) A.character = ev.character;
        if (ev.tap) A.tap = ev.tap;
        if (!ev.family) { A.curve = null; A.curveKey = ''; }
        if (was && !isConnected()) A.visible = false;
        if (ev.waving && !A.waveStartedAt) A.waveStartedAt = performance.now();
        if (!ev.waving) A.waveStartedAt = 0;
        break;
      }
      case 'meters': A.meters = ev; updateMeters(); return;
      case 'log': A.log = ev.entries || []; break;
      case 'curve': A.curve = ev; break;
      case 'learn': A.learn = ev; break;
      case 'recordings': A.recordings = ev; send({ cmd: 'patterns', lang: SSMT.S.lang === 'en' ? 'en' : 'ru' }); break;
      case 'patterns': A.summary = ev.summary || ''; break;
      case 'dataset': A.dataset = ev; break;
      case 'found':
        if (!A.discovered.some((c) => c.family === ev.family && c.ip === ev.ip)) A.discovered.push(ev);
        A.discovered.sort((a, b) => a.ip.localeCompare(b.ip, undefined, { numeric: true }));
        break;
      case 'scanDone': A.scanning = false; break;
      case 'message':
        if (ev.key === 'nothingFound') A.message = 'nothing found';
        else if (ev.key === 'simulatorOnly') return;
        else A.message = ev.detail || ev.key;
        break;
      case 'prompt':
        if (ev.id === 'assist') askModel(ev.text);
        return;
      default: return;
    }
    if (SSMT.S.section === 'assist') SSMT.render();
  }

  async function askModel(prompt) {
    const r = api && api.llmAsk ? await api.llmAsk(A.llm.url, A.llm.model, prompt) : null;
    A.llm.asking = false;
    A.llm.answer = r && r.ok ? String(r.text || '').trim() : format(t('assist.llm.fail'), (r && r.error) || '');
    SSMT.render();
  }

  SSMT.section({ id: 'assist', render, after, actions, inputs, keys, onEvent, state: A });
  // The audio interfaces for the settings sheet (system setup's audio bridge, when present).
  if (SSMT.audio && SSMT.audio.devices) SSMT.audio.devices().then((d) => { A.inputDevices = (d && d.inputs) || []; }).catch(() => {});
  if (api) { send({ cmd: 'state' }); send({ cmd: 'recordings' }); }
})();
