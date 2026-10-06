'use strict';
/* global SSMT */
// Qtrl (function #3): the state the interface keeps of the engine's show (App/SSMT/Show/ShowStore.swift and ShowLive),
// the view settings the Mac keeps in the store (panels, tabs, zoom) and small formatting helpers shared by the Qtrl
// files (show-*.js). Everything the show does is done by the engine's Qtrl module through SSMTCore.

(function () {
  const { t, esc, icon, store } = SSMT;

  /** Last engine events. */
  const st = {
    doc: null,
    show: null, // the "show" event (document, selection, files, issues…)
    live: { running: [], problems: {}, loaded: {}, meters: [], clipping: [], clips: [], empty: true, goGuarded: false },
    liveAt: 0, // performance.now() of the last "showLive"
    statics: null,
    waves: {}, // file path → overview peaks
    slices: {}, // waveform editor detail, by request key
    envs: {}, // volume line samples, by request key
    osc: null,
  };

  const bool = (k, d) => store.get('show.' + k, d ? '1' : '0') === '1';
  /** View settings (ShowStore's @Published view state, kept like the Mac's UserDefaults). */
  const ui = {
    sidebar: bool('sidebar', true),
    inspector: bool('inspector', true),
    timeline: bool('timeline', false),
    sidebarTab: store.get('show.sidebarTab', 'lists'),
    inspectorTab: 'main',
    span: Number(store.get('show.span', 40)) || 40,
    sheet: null, // 'osc' | 'settings' | {wave: cueID}
    pop: null, // 'issues' | 'keys'
    menu: null, // context menu {x, y, items}
    prompt: null, // {title, value, done(v)}
    anchor: null,
    solo: null, // parity: one view alone ('waveform', 'osc', 'osc-eos')
    groupScroll: 0,
    waveView: {}, // cue id → {start, span}
    oscPage: 'list',
    oscDraft: null,
    oscIsNew: true,
    monitorPort: '53535',
  };
  function saveUI() {
    store.set('show.sidebar', ui.sidebar ? '1' : '0');
    store.set('show.inspector', ui.inspector ? '1' : '0');
    store.set('show.timeline', ui.timeline ? '1' : '0');
    store.set('show.sidebarTab', ui.sidebarTab);
    store.set('show.span', String(ui.span));
  }

  /** Index of the document: every cue with its list, parent and depth. */
  const idx = { byId: new Map(), banks: [], cueLists: [] };
  function reindex() {
    idx.byId = new Map();
    const doc = st.doc;
    if (!doc) return;
    const walk = (cues, list, parent, depth) => {
      for (const c of cues) {
        idx.byId.set(c.id, { cue: c, list, parent, depth });
        walk(c.children || [], list, c, depth + 1);
      }
    };
    for (const l of doc.lists) walk(l.cues || [], l, null, 0);
    idx.banks = doc.lists.filter((l) => l.isBank);
    idx.cueLists = doc.lists.filter((l) => !l.isBank);
  }
  const cue = (id) => (id ? (idx.byId.get(id) || {}).cue || null : null);

  const cmd = (op, f) => SSMT.send(Object.assign({ cmd: 'show', op }, f || {}));

  /** "1:05.3" style time (ShowWorkspace.swift showTime). */
  function showTime(s) {
    if (s === null || s === undefined || !Number.isFinite(s)) return '∞';
    const v = Math.max(0, s);
    const m = Math.floor(Math.floor(v) / 60);
    const rest = v - m * 60;
    return m > 0 ? `${m}:${rest.toFixed(1).padStart(4, '0')}` : rest.toFixed(1);
  }
  /** TextField(format: .number.precision(.fractionLength(0...n))). */
  function num(v, digits = 2) {
    if (v === null || v === undefined || !Number.isFinite(Number(v))) return '';
    return String(Number(Number(v).toFixed(digits)));
  }
  const parseNum = (s) => {
    const v = Number(String(s).trim().replace(',', '.'));
    return String(s).trim() === '' || !Number.isFinite(v) ? null : v;
  };

  const KIND_ICON = {
    audio: 'waveform', fade: 'chart.line.downtrend.xyaxis', group: 'square.stack.3d.up', wait: 'hourglass', memo: 'note.text',
    start: 'play', stop: 'stop', pause: 'pause', load: 'tray.and.arrow.down', reset: 'arrow.counterclockwise',
    goTo: 'arrow.turn.down.right', target: 'scope', arm: 'checkmark.shield', disarm: 'xmark.shield', devamp: 'repeat.1',
    network: 'antenna.radiowaves.left.and.right',
  };
  const MEDIA_KINDS = ['audio', 'fade', 'group', 'wait', 'memo', 'network'];
  const CONTROL_KINDS = ['start', 'stop', 'pause', 'load', 'reset', 'goTo', 'target', 'arm', 'disarm', 'devamp'];
  const NEEDS_TARGET = new Set(['fade', 'start', 'stop', 'pause', 'load', 'reset', 'goTo', 'target', 'arm', 'disarm', 'devamp']);
  const COLORS = { '': 'transparent', red: '#FF5F57', orange: '#FF9F0A', yellow: '#FFD60A', green: '#30D158', blue: '#64D2FF', purple: '#BF5AF2' };
  const BRAND = { resolume: 'Resolume', eos: 'ETC Eos', grandMA3: 'grandMA3', magicQ: 'MagicQ', x32: 'X32', generic: 'OSC' };
  const DEVICE_ICON = { resolume: 'play.rectangle.on.rectangle', eos: 'lightbulb.2', grandMA3: 'lightbulb.2', magicQ: 'lightbulb.2', x32: 'slider.vertical.3', generic: 'antenna.radiowaves.left.and.right' };

  const kindName = (k) => t('cue.kind.' + k);
  /** "4 · Scene 1" (number and name, or the kind). */
  const label = (c) => (c ? [c.number, c.name || kindName(c.kind)].filter((x) => x).join(' · ') : '');
  const basename = (p) => String(p || '').split(/[\\/]/).pop();

  /** Playhead: the snapshot's, or the first cue of the list before anything has played. */
  const playhead = () => (st.live.empty ? st.live.standby : st.live.playhead) || null;
  const running = () => {
    const m = new Map();
    for (const r of st.live.running) m.set(r.id, r);
    return m;
  };
  const remaining = (r) => (r.duration === null || r.duration === undefined ? null : Math.max(0, r.duration - r.elapsed));
  const progress = (r) => (r.duration === null || r.duration === undefined ? null : r.duration > 0 ? Math.min(1, Math.max(0, r.elapsed / r.duration)) : 1);
  const currentList = () => {
    const d = st.doc;
    if (!d) return null;
    return d.lists.find((l) => l.id === (st.show && st.show.listID)) || idx.cueLists[0] || null;
  };
  const currentBank = () => idx.banks.find((b) => b.id === (st.show && st.show.bankID)) || idx.banks[0] || null;
  const selection = () => new Set((st.show && st.show.selection) || []);
  const isBankCue = (id) => idx.banks.some((b) => { const e = idx.byId.get(id); return e && e.list.id === b.id; });
  const pathOf = (id) => (st.show && st.show.paths[id]) || null;
  const infoOf = (id) => { const p = pathOf(id); return p ? (st.show.clipInfo[p] || null) : null; };
  const fileLength = (id) => { const i = infoOf(id); return i ? i.duration : null; };
  /** ShowTimeline.audioDuration as computed by the engine (null = endless or unknown). */
  const audioLength = (id) => { const l = st.show && st.show.lengths; return l && id in l ? l[id] : undefined; };

  /** PlayMap.position (seconds), to draw a clip's waveform through its region and loops. */
  function mapPosition(m, p) {
    const [regionStart, intro, loop, , plays] = m;
    if (p < intro) return regionStart + p;
    const q = p - intro;
    if (plays === 0 || q < loop * plays) return regionStart + intro + (q % loop);
    return regionStart + intro + loop + (q - loop * plays);
  }

  /** A Mac popup button (Picker with the menu style). */
  function select(act, options, value, { cls = '', id, disabled, style } = {}) {
    return `<select class="q-select ${cls}" data-change="${act}"${id ? ` id="${id}"` : ''}${disabled ? ' disabled' : ''}${style ? ` style="${style}"` : ''}>${options.map(([v, l]) => `<option value="${esc(v)}"${String(v) === String(value) ? ' selected' : ''}>${esc(l)}</option>`).join('')}</select>`;
  }
  /** A Mac segmented control. */
  function segmented(act, options, value, { cls = '', disabled } = {}) {
    return `<div class="q-seg ${cls}${disabled ? ' disabled' : ''}">${options.map(([v, l]) => `<button class="${String(v) === String(value) ? 'on' : ''}" data-act="${act}" data-arg="${esc(v)}"${disabled ? ' disabled' : ''}>${l}</button>`).join('')}</div>`;
  }
  /** ToolButtonStyle. */
  const tool = (ic, help, act, arg, { disabled, on, cls = '' } = {}) =>
    `<button class="q-tool ${on ? 'on' : ''} ${cls}" data-act="${act}"${arg !== undefined ? ` data-arg="${esc(arg)}"` : ''} title="${esc(help)}"${disabled ? ' disabled' : ''}>${icon(ic, 13)}</button>`;
  const toolText = (ic, text, act, arg, { disabled, title } = {}) =>
    `<button class="q-tool text" data-act="${act}"${arg !== undefined ? ` data-arg="${esc(arg)}"` : ''}${title ? ` title="${esc(title)}"` : ''}${disabled ? ' disabled' : ''}>${ic ? icon(ic, 12) : ''}<span>${esc(text)}</span></button>`;
  const check = (act, on, text, { id, disabled } = {}) =>
    `<label class="q-check${disabled ? ' disabled' : ''}"><input type="checkbox" data-change="${act}"${on ? ' checked' : ''}${id ? ` id="${id}"` : ''}${disabled ? ' disabled' : ''}><span>${esc(text)}</span></label>`;

  SSMT.qtrl = {
    st, ui, idx, saveUI, reindex, cue, cmd, showTime, num, parseNum, KIND_ICON, MEDIA_KINDS, CONTROL_KINDS, NEEDS_TARGET, COLORS,
    BRAND, DEVICE_ICON, kindName, label, basename, playhead, running, remaining, progress, currentList, currentBank, selection,
    isBankCue, pathOf, infoOf, fileLength, audioLength, mapPosition, select, segmented, tool, toolText, check,
  };
})();
