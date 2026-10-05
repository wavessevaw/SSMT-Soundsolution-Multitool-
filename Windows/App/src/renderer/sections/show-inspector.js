'use strict';
/* global SSMT */
// Qtrl's inspector (App/SSMT/Show/CueInspector.swift): every setting of the selected cue, in tabs per cue type (an
// audio cue its waveform with start, end, loops and fades; a fade its duration and curve; a group its multitrack).

(function () {
  const { t, esc, icon } = SSMT;
  const Q = SSMT.qtrl;
  const { st, ui, cmd, num, parseNum, showTime } = Q;
  const SILENCE = -100;

  /** InspectorTab.tabs(for:isPad:). */
  function tabsFor(c, isPad) {
    const tabs = ['main'];
    switch (c.kind) {
      case 'audio': tabs.push('wave', 'outputs'); break;
      case 'fade': tabs.push('fade'); break;
      case 'group': tabs.push('multitrack', 'mode'); break;
      case 'memo': break;
      default: tabs.push('action');
    }
    tabs.push('triggers');
    if (isPad) tabs.push('pad');
    return tabs;
  }
  /** InspectorTab.primary(for:). */
  function primaryTab(c) {
    switch (c.kind) {
      case 'audio': return 'wave';
      case 'fade': return 'fade';
      case 'group': return 'multitrack';
      case 'memo': return 'main';
      default: return 'action';
    }
  }

  function inspector() {
    const sel = st.show.selection;
    const c = sel.length === 1 ? Q.cue(sel[0]) : null;
    if (!c) {
      const text = sel.length > 1 ? t('show.inspector.many', sel.length) : t('show.inspector.none');
      return `<div class="glass q-noinspect">${icon('slider.horizontal.3', 26)}<span>${esc(text)}</span></div>`;
    }
    const tabs = tabsFor(c, Q.isBankCue(c.id));
    const current = tabs.includes(ui.inspectorTab) ? ui.inspectorTab : primaryTab(c);
    const tabRow = tabs.map((tb) => `<button class="${tb === current ? 'on' : ''}" data-act="inspectorTab" data-arg="${tb}">${esc(t('show.tab.' + tb))}</button>`).join('');
    return `<div class="q-inspector"><div class="q-tabs">${tabRow}</div>
      <div class="q-inspect-scroll" id="q-inspect-scroll" data-keep-scroll><div class="q-inspect-body">${content(c, current)}</div></div></div>`;
  }

  function content(c, tab) {
    switch (tab) {
      case 'main': return mainSection(c) + timingSection(c);
      case 'wave': return audioSection(c);
      case 'fade': return fadeSection(c);
      case 'multitrack': return `<div class="q-multitrack">${Q.multitrack(c)}</div>`;
      case 'mode': return groupSection(c);
      case 'action': return actionSection(c);
      case 'outputs': return outputsSection(c);
      case 'triggers': return triggersSection(c);
      case 'pad': return padSection(c);
      default: return '';
    }
  }

  // MARK: Building blocks

  const section = (title, ic, body) => `<div class="glass q-isec"><div class="h">${icon(ic, 12)}<b>${esc(title)}</b></div>${body}</div>`;
  const caption = (text) => `<span class="q-cap">${esc(text)}</span>`;
  const f = (c, path, extra = '') => `data-id="${c.id}" data-path="${path}"${extra}`;
  const textField = (c, title, path, value, w) => `<div class="q-fieldbox"${w ? ` style="width:${w}px;flex:none"` : ' style="flex:1"'}>${caption(title)}
    <input class="q-field" id="qi-${path}" ${f(c, path)} data-input="setText" value="${esc(value)}"></div>`;
  const seconds = (c, title, path, value, { disabled, w } = {}) => `<div class="q-fieldbox"${w ? ` style="width:${w}px;flex:none"` : ' style="flex:1"'}>${caption(title + ', ' + t('show.sec'))}
    <input class="q-field" id="qi-${path}" ${f(c, path, ' data-min="0"')} data-change="setNum" value="${esc(num(value, 2))}"${disabled ? ' disabled' : ''}></div>`;
  function level(c, title, path, value, act = 'setLevel') {
    const shown = value <= SILENCE ? '−∞ dB' : (value >= 0 ? '+' : '') + Number(value).toFixed(1) + ' dB';
    return `<div class="q-level"><div class="row">${caption(title)}<span class="spacer"></span><span class="v">${shown.replace('-', '−')}</span></div>
      <input type="range" class="q-slider" min="-60" max="12" step="0.5" value="${Math.max(-60, value)}" ${f(c, path)} data-input="${act}"></div>`;
  }
  const picker = (c, path, options, value, extra = {}) => Q.select('setEnum', options, value, Object.assign({}, extra)).replace('<select ', `<select ${f(c, path)} `);
  const toggle = (c, title, path, on, { mini, act = 'setBool' } = {}) =>
    `<label class="q-toggle${mini ? ' mini' : ''}"><span>${esc(title)}</span><input type="checkbox" class="toggle" ${f(c, path)} data-change="${act}"${on ? ' checked' : ''}></label>`;
  const checkbox = (c, title, path, on, act = 'setBool') =>
    `<label class="q-check"><input type="checkbox" ${f(c, path)} data-change="${act}"${on ? ' checked' : ''}><span>${esc(title)}</span></label>`;
  const radios = (c, path, options, value) => `<div class="q-radios">${options.map(([v, l]) => `<label class="q-radio"><input type="radio" name="r-${path}" value="${esc(v)}" ${f(c, path)} data-change="setEnum"${String(v) === String(value) ? ' checked' : ''}><span>${esc(l)}</span></label>`).join('')}</div>`;

  // MARK: Main

  function mainSection(c) {
    const colors = Object.keys(Q.COLORS).map((k) => {
      const on = (c.color || '') === k;
      return `<button class="q-color${on ? ' on' : ''}" style="background:${k ? Q.COLORS[k] : 'rgba(255,255,255,0.08)'}" data-act="cueColor" data-arg="${k}"></button>`;
    }).join('');
    return section(Q.kindName(c.kind), Q.KIND_ICON[c.kind], `
      <div class="hrow">${textField(c, t('show.col.number'), 'number', c.number, 70)}${textField(c, t('show.col.name'), 'name', c.name)}</div>
      <div class="q-fieldbox">${caption(t('show.notes'))}<textarea class="q-notes" id="qi-notes" ${f(c, 'notes')} data-input="setText">${esc(c.notes)}</textarea></div>
      <div class="hrow center">${colors}<span class="spacer"></span>${toggle(c, t('show.armed'), 'armed', c.armed !== false, { mini: true })}</div>`);
  }

  function timingSection(c) {
    return section(t('show.timing'), 'timer', `
      <div class="hrow">${seconds(c, t('show.preWait'), 'preWait', c.preWait)}${seconds(c, t('show.postWait'), 'postWait', c.postWait, { disabled: c.continueMode !== 'autoContinue' })}</div>
      <div class="q-fieldbox">${caption(t('show.continue'))}${picker(c, 'continueMode', ['none', 'autoContinue', 'autoFollow'].map((m) => [m, t('continue.' + m)]), c.continueMode || 'none')}</div>
      ${c.kind === 'wait' ? seconds(c, t('show.duration'), 'duration', c.duration) : ''}`);
  }

  function triggersSection(c) {
    const modes = ['nothing', 'panic', 'stop', 'hardStop', 'restart', 'devamp', 'playNext']
      .filter((m) => m !== 'playNext' || (c.kind === 'group' && c.groupMode === 'playlist'));
    return section(t('show.tab.triggers'), 'bolt', `
      <div class="hrow center">${caption(t('show.hotkey'))}<span class="spacer"></span><input class="q-field center" id="qi-hotkey" style="width:44px" placeholder="—" ${f(c, 'hotkey')} data-input="setHotkey" value="${esc(c.hotkey || '')}"></div>
      <div class="q-fieldbox">${caption(t('show.secondTrigger'))}<span title="${esc(t('show.secondTrigger.help'))}">${picker(c, 'secondTrigger', modes.map((m) => [m, t('secondTrigger.' + m)]), c.secondTrigger || 'nothing')}</span></div>`);
  }

  function actionSection(c) {
    switch (c.kind) {
      case 'audio': return audioSection(c);
      case 'fade': return fadeSection(c);
      case 'group': return groupSection(c);
      case 'network': return networkSection(c);
      case 'wait': return section(Q.kindName('wait'), 'hourglass', seconds(c, t('show.duration'), 'duration', c.duration));
      case 'memo': return '';
      default: return controlSection(c);
    }
  }

  // MARK: Audio

  function audioSection(c) {
    const p = Q.pathOf(c.id);
    const info = Q.infoOf(c.id);
    let status = '';
    if (info) status = `<span class="mono sm2">${esc(showTime(info.duration))} · ${info.channels} ch</span>`;
    else if (p && st.show.missing.includes(p)) status = `<span class="sm warn">${esc(t('show.fileMissing'))}</span><span class="xs muted sel">${esc(p)}</span>`;
    else if (p && st.show.unreadable[p] !== undefined) status = `<span class="sm warn sel">${esc(t('show.fileUnreadable') + ': ' + st.show.unreadable[p])}</span>`;
    else if (st.show.loading > 0) status = `<span class="sm" style="color:var(--data-blue)">${esc(t('error.show.notReady'))}</span>`;
    return section(t('show.wave.title'), 'waveform', `<span class="q-hint">${esc(t('show.wave.hint'))}</span>${Q.waveEditor(c, false)}`)
      + section(t('show.file'), 'music.note', `
      <div class="hrow center"><div class="q-filecol"><span class="fname">${esc(c.audio ? Q.basename(c.audio.file) : '—')}</span>${status}</div><span class="spacer"></span>
        <button class="btn secondary" data-act="chooseFile" data-arg="${c.id}">${esc(t('show.chooseFile'))}</button></div>
      <div class="q-fieldbox">${caption(t('show.rate'))}<input class="q-field" style="width:70px" id="qi-rate" ${f(c, 'audio.rate', ' data-digits="3" data-min="0.05"')} data-change="setNum" value="${esc(num(c.audio ? c.audio.rate : 1, 3))}"></div>`);
  }

  function outputsSection(c) {
    return section(t('show.level'), 'speaker.wave.2', level(c, t('show.level'), 'audio.level', c.audio ? c.audio.level : 0))
      + section(t('show.routing'), 'point.3.connected.trianglepath.dotted', routingGrid(c));
  }

  /** CueInspector.routingGrid: file channels (rows) × show outputs (columns); click to connect. */
  function routingGrid(c) {
    const info = Q.infoOf(c.id);
    const channels = Math.max(1, info ? info.channels : 2);
    const outs = st.doc.outputs;
    const a = c.audio || { routing: [] };
    const xp = (ch, o) => {
      const r = a.routing || [];
      if (ch < r.length) return o < r[ch].length ? r[ch][o] : SILENCE;
      if (channels === 1) return o <= 1 ? 0 : SILENCE;
      return ch === o ? 0 : SILENCE;
    };
    const head = `<div class="hrow g4"><span style="width:28px"></span>${outs.map((o) => `<span class="q-routehead">${esc(o.name)}</span>`).join('')}</div>`;
    const rows = Array.from({ length: channels }, (_, ch) => `<div class="hrow g4"><span class="q-routech">${channels === 2 ? (ch === 0 ? 'L' : 'R') : ch + 1}</span>${outs.map((_, o) => `<button class="q-xp${xp(ch, o) > SILENCE ? ' on' : ''}" data-act="route" data-arg="${ch},${o},${channels}"></button>`).join('')}</div>`).join('');
    return `<div class="q-routing">${head}${rows}</div>`;
  }

  function padSection(c) {
    return section(t('show.tab.pad'), 'square.grid.3x3', `
      <div class="q-fieldbox">${caption(t('show.pad.mode'))}${radios(c, 'padMode', ['start', 'toggle', 'restart', 'hold'].map((m) => [m, t('padmode.' + m)]), c.padMode || 'toggle')}</div>
      <div class="hrow center">${caption(t('show.pad.key'))}<span class="spacer"></span>${picker(c, 'hotkey', [['', '—']].concat(((st.statics || {}).functionKeys || []).map((k) => [k, k])), c.hotkey || '', { style: 'width:90px' })}</div>`);
  }

  // MARK: Fade

  function fadeSection(c) {
    const fd = c.fade || { duration: 3, curve: 'sCurve', level: SILENCE };
    const fadeIn = !!fd.fromSilence;
    const hasLevel = fd.level !== undefined && fd.level !== null;
    const seg = `<div class="q-seg full">${[['0', 'chart.line.downtrend.xyaxis', 'show.fadecue.out'], ['1', 'chart.line.uptrend.xyaxis', 'show.fadecue.in']].map(([v, ic, k]) =>
      `<button class="${(fadeIn ? '1' : '0') === v ? 'on' : ''}" data-act="fadePreset" data-arg="${c.id},${v}">${icon(ic, 12)}${esc(t(k))}</button>`).join('')}</div>`;
    let levelPart = '';
    if (hasLevel) {
      levelPart = `<div class="q-seg full">${[['0', 'show.fade.absolute'], ['1', 'show.fade.relative']].map(([v, k]) =>
        `<button class="${(fd.relative ? '1' : '0') === v ? 'on' : ''}" data-act="fadeRelative" data-arg="${c.id},${v}">${esc(t(k))}</button>`).join('')}</div>
        ${level(c, t(fd.relative ? 'show.fade.by' : 'show.fade.to'), 'fade.level', fd.level)}`;
    }
    return section(Q.kindName('fade'), Q.KIND_ICON.fade, `
      ${targetPicker(c, t('show.target'), 'target')}
      ${seg}
      ${fadeIn ? `<span class="q-hint">${esc(t('show.fadeIn.hint'))}</span>` : ''}
      <div class="hrow top g14"><div class="vcol g8">${seconds(c, t('show.duration'), 'fade.duration', fd.duration, { w: 120 })}
        <div class="q-fieldbox">${caption(t('show.curve'))}${picker(c, 'fade.curve', ['sCurve', 'linearDB', 'linearGain'].map((k) => [k, t('curve.' + k)]), fd.curve || 'sCurve', { style: 'width:180px' })}</div></div>
        <canvas class="q-fadecurve" data-canvas="fadecurve" data-curve="${fd.curve || 'sCurve'}" data-up="${fadeIn ? 1 : 0}" data-dur="${fd.duration}"></canvas></div>
      ${checkbox(c, t('show.fade.changeLevel'), 'fade.level', hasLevel, 'fadeChangeLevel')}
      ${levelPart}
      ${checkbox(c, t('show.fade.stop'), 'fade.stopWhenDone', !!fd.stopWhenDone)}`);
  }

  // MARK: Network (OSC)

  function networkSection(c) {
    const p = c.osc || { address: '/', arguments: [], values: {} };
    const devices = st.doc.devices || [];
    const device = devices.find((d) => d.id === p.device) || null;
    const sel = st.show.selected || {};
    let body;
    if (!devices.length) {
      body = `<span class="q-hint">${esc(t('osc.cue.noDevices'))}</span>
        <div><button class="btn primary" data-act="openOSC">${icon('plus', 13)}${esc(t('osc.add'))}</button></div>`;
    } else {
      body = `<div class="q-fieldbox">${caption(t('osc.cue.device'))}${Q.select('oscDevice', devices.map((d) => [d.id, `${d.name} · ${d.host}`]), p.device || '').replace('<select ', `<select data-id="${c.id}" `)}</div>`;
      if (device) {
        const presets = ((st.statics || {}).presets || {})[device.kind] || [];
        body += `<div class="q-fieldbox">${caption(t('osc.cue.action'))}${Q.select('oscPreset', presets.map((x) => [x.id, t('osc.preset.' + x.id)]).concat([['', t('osc.cue.custom')]]), p.preset || '').replace('<select ', `<select data-id="${c.id}" `)}</div>`;
        const preset = presets.find((x) => x.id === p.preset);
        if (preset) {
          body += preset.fields.map((fl) => presetField(c, fl, (p.values || {})[fl.key] !== undefined ? p.values[fl.key] : fl.default)).join('');
        } else {
          body += `<div class="vcol g6">${caption(t('osc.cue.address'))}<input class="q-field mono" id="qi-oscaddr" placeholder="/composition/columns/1/connect" ${f(c, 'osc.address')} data-input="oscAddress" value="${esc(p.address)}">
            ${caption(t('osc.cue.args'))}<input class="q-field mono" id="qi-oscargs" placeholder="1" data-id="${c.id}" data-change="oscArgs" value="${esc(sel.argsText || '')}">
            <span class="xs muted">${esc(t('osc.cue.args.hint'))}</span></div>`;
        }
      }
      body += `<span class="q-oscmsg">${esc('→ ' + (sel.display || p.address) + (device ? `   ·   ${device.host}:${device.port}` : ''))}</span>
        <div class="hrow center"><button class="btn secondary" data-act="sendNow" data-arg="${c.id}"${device ? '' : ' disabled'}>${icon('paperplane', 13)}${esc(t('osc.cue.sendNow'))}</button>
        <span class="spacer"></span><button class="q-link sm" data-act="openOSC">${esc(t('osc.cue.devices'))}</button></div>
        ${device ? `<span class="xs muted">${esc(t('osc.find.' + device.kind))}</span>` : ''}`;
    }
    return section(Q.kindName('network'), Q.KIND_ICON.network, body);
  }

  function presetField(c, fl, value) {
    let input;
    if (fl.kind === 'level') {
      input = `<div class="hrow center"><input type="range" class="q-slider" min="0" max="1" step="0.01" value="${Number(value) || 0}" data-id="${c.id}" data-key="${fl.key}" data-input="oscLevel">
        <span class="mono sm2" style="width:44px">${Math.round((Number(value) || 0) * 100)} %</span></div>`;
    } else if (fl.kind === 'text') {
      input = `<input class="q-field" id="qi-osc-${fl.key}" data-id="${c.id}" data-key="${fl.key}" data-input="oscField" value="${esc(value)}">`;
    } else {
      input = `<input class="q-field" style="width:90px" id="qi-osc-${fl.key}" data-id="${c.id}" data-key="${fl.key}" data-change="oscNumber" value="${esc(String(parseInt(value, 10) || 1))}">`;
    }
    return `<div class="q-fieldbox">${caption(t('osc.field.' + fl.key))}${input}</div>`;
  }

  // MARK: Group

  function groupSection(c) {
    const modes = ['enter', 'sequence', 'simultaneous', 'playlist', 'random'];
    let playlist = '';
    if (c.groupMode === 'playlist') {
      playlist = checkbox(c, t('show.playlist.loop'), 'loopPlaylist', !!c.loopPlaylist) + checkbox(c, t('show.playlist.shuffle'), 'shuffle', !!c.shuffle)
        + seconds(c, t('show.playlist.crossfade'), 'crossfade', c.crossfade);
    }
    return section(Q.kindName('group'), Q.KIND_ICON.group, `${radios(c, 'groupMode', modes.map((m) => [m, t('group.mode.' + m)]), c.groupMode || 'sequence')}
      ${playlist}<span class="xs secondary">${esc(t('show.group.count', (c.children || []).length))}</span>`);
  }

  // MARK: Control cues

  function controlSection(c) {
    let extra = '';
    if (c.kind === 'stop') extra = seconds(c, t('show.stopFade'), 'stopFade', c.stopFade);
    else if (c.kind === 'target') extra = targetPicker(c, t('show.newTarget'), 'newTarget');
    else if (c.kind === 'devamp') extra = checkbox(c, t('show.devamp.next'), 'devampStartsNext', !!c.devampStartsNext);
    return section(Q.kindName(c.kind), Q.KIND_ICON[c.kind], `${targetPicker(c, t('show.target'), 'target', c.kind === 'stop')}${extra}
      <span class="xs secondary">${esc(t('cue.help.' + c.kind))}</span>`);
  }

  function targetPicker(c, title, key, allowsAll) {
    const ids = key === 'newTarget' ? [...Q.idx.byId.keys()].filter((x) => x !== c.id) : ((st.show.selected || {}).targets || []);
    const current = c[key] && Q.cue(c[key]) ? c[key] : '';
    const opts = [];
    if (allowsAll) opts.push(['', t('show.target.all')]);
    else if (!current) opts.push(['', t('show.noTarget')]);
    for (const id of ids) { const x = Q.cue(id); if (x) opts.push([id, Q.label(x)]); }
    return `<div class="q-fieldbox">${caption(title)}${picker(c, key, opts, current, { cls: 'wide' })}</div>`;
  }

  // MARK: Actions

  const val = (el) => ({ id: el.dataset.id, path: el.dataset.path });
  const set = (id, fields) => cmd('set', { id, fields });
  Object.assign(Q.actions, {
    inspectorTab: (tb) => { ui.inspectorTab = tb; SSMT.render(); },
    cueColor: (k) => { const id = st.show.selection[0]; if (id) set(id, { color: k }); },
    setNum: (v, el) => {
      const { id, path } = val(el);
      const x = parseNum(v);
      if (x === null) { SSMT.render(); return; }
      const min = el.dataset.min !== undefined ? Number(el.dataset.min) : -Infinity;
      set(id, { [path]: Math.max(min, x) });
    },
    setBool: (v, el) => { const { id, path } = val(el); set(id, { [path]: !!v }); },
    setEnum: (v, el) => {
      const { id, path } = val(el);
      if (path === 'target' || path === 'newTarget' || path === 'hotkey') set(id, { [path]: v === '' ? null : v });
      else set(id, { [path]: v });
    },
    chooseFile: async (id) => {
      const api = window.ssmt;
      if (!api || !api.openFile) return;
      const p = await api.openFile({ filters: [{ name: 'Audio', extensions: Q.AUDIO_EXT }] });
      if (p && p[0]) cmd('chooseFile', { id, path: p[0] });
    },
    route: (arg) => {
      const [ch, o, channels] = arg.split(',').map(Number);
      cmd('route', { id: st.show.selection[0], channel: ch, output: o, channels });
    },
    fadePreset: (arg) => { const [id, v] = arg.split(','); cmd('fadePreset', { id, fadeIn: v === '1' }); },
    fadeRelative: (arg) => { const [id, v] = arg.split(','); set(id, { 'fade.relative': v === '1', 'fade.level': v === '1' ? -6 : SILENCE }); },
    fadeChangeLevel: (v, el) => set(el.dataset.id, { 'fade.level': v ? SILENCE : null }),
    oscDevice: (v, el) => set(el.dataset.id, { 'osc.device': v, 'osc.preset': null }),
    oscPreset: (v, el) => cmd('oscPreset', { id: el.dataset.id, preset: v }),
    oscNumber: (v, el) => cmd('oscField', { id: el.dataset.id, key: el.dataset.key, value: String(Math.max(0, parseInt(v, 10) || 0)) }),
    oscArgs: (v, el) => cmd('oscArgs', { id: el.dataset.id, text: v }),
    sendNow: (id) => cmd('sendNow', { id }),
  });
  Object.assign(Q.inputs, {
    setText: (v, el) => { const { id, path } = val(el); set(id, { [path]: v }); },
    setHotkey: (v, el) => {
      const key = v.trim().slice(-1);
      set(el.dataset.id, { hotkey: key ? key : null });
      if (el.value !== key) el.value = key;
    },
    setLevel: (v, el) => { const x = Number(v); set(el.dataset.id, { [el.dataset.path]: x <= -60 ? SILENCE : Math.round(x * 2) / 2 }); },
    oscField: (v, el) => cmd('oscField', { id: el.dataset.id, key: el.dataset.key, value: v }),
    oscLevel: (v, el) => cmd('oscField', { id: el.dataset.id, key: el.dataset.key, value: Number(v).toFixed(2) }),
    oscAddress: (v, el) => set(el.dataset.id, { 'osc.address': v.startsWith('/') ? v : '/' + v }),
  });

  // MARK: Fade curve preview (FadeCurvePreview)

  function drawFadeCurve(cv) {
    const g = Q.ctx2d(cv);
    if (!g) return;
    const { w, h, ctx } = g;
    const curve = cv.dataset.curve, up = cv.dataset.up === '1', dur = Number(cv.dataset.dur);
    const r = { x: 6, y: 8, w: w - 12, h: h - 16 };
    ctx.fillStyle = 'rgba(0,0,0,0.25)';
    Q.roundRect(ctx, 0, 0, w, h, 8); ctx.fill();
    ctx.strokeStyle = 'rgba(255,255,255,0.06)'; ctx.lineWidth = 1;
    for (let k = 1; k < 4; k++) { const x = r.x + r.w * k / 4; ctx.beginPath(); ctx.moveTo(x, r.y); ctx.lineTo(x, r.y + r.h); ctx.stroke(); }
    const shapes = (st.statics || {}).fadeShapes || {};
    const shape = shapes[curve] || [];
    ctx.beginPath();
    for (let i = 0; i <= 120; i++) {
      const tt = i / 120;
      const p = up ? tt : 1 - tt;
      let gain;
      if (curve === 'linearGain') gain = p;
      else {
        const shaped = shape.length > i ? shape[i] : tt;
        const db = up ? -60 + 60 * shaped : -60 * shaped;
        gain = Math.pow(10, db / 20) * (up && tt === 0 ? 0 : 1);
      }
      const x = r.x + r.w * tt, y = r.y + r.h - r.h * Math.min(1, Math.max(0, gain));
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = '#FFD60A'; ctx.lineWidth = 2; ctx.stroke();
    ctx.fillStyle = '#5F6862'; ctx.font = '10px ui-monospace, Consolas, monospace'; ctx.textAlign = 'right'; ctx.textBaseline = 'bottom';
    ctx.fillText(showTime(dur) + ' s', r.x + r.w, r.y + r.h);
  }

  Object.assign(Q, { inspector, primaryTab, tabsFor, drawFadeCurve });
})();
