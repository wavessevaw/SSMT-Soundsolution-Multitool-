'use strict';
/* global SSMT */
// Function #1, automatic system setup: the Mac app's setup screens one to one.
//   MainView.workspace(.setup), WizardView and its steps (Views/Wizard/*), the expert screen (MeterPanel,
//   ExpertGraphs), the sidebar (AppSidebar stages and utilities, SetupSidebar, CalibrationPanel), TopBar and
//   StatusPill, the settings sheet, TargetEditorView and CustomProcessorEditor.
// Everything measured or decided comes from the engine (Windows/Engine/.../Modules/Setup.swift, SSMTCore):
//   setupStatic (lists), setupState (on change), setupLive (≈10 per second). The interface only draws and sends
//   {cmd:'setup', do:<action>}. Sound card I/O goes through SSMT.audio (audio-io.js).

(function () {
  const { S, t, esc, icon, UI, store, format } = SSMT;
  const X = SSMT.SetupUI;
  const C = X.C;

  // MARK: data

  const D = { st: null, s: null, live: null };
  const U = {
    mode: store.get('setup.mode', 'wizard'),
    stage: store.get('setup.stage', '0') === '1',
    reduced: store.get('reducedEffects', '0') === '1',
    settings: false,
    open: {},             // collapsibles that are expanded
    band: 0,              // selected EQ band (EQTuningView)
    menu: null,           // open popup menu
    info: null,           // open info popover
    target: null,         // TargetEditorView points while open
    targetPreview: null,
    procEdit: false,      // CustomProcessorEditor
    devices: null,        // {inputs, outputs} from SSMT.audio
    source: store.json('setup.source', { kind: 'simulation' }),
    chan: { in: 0, out: 0 },
    graphs: store.json('setup.graphs', ['magnitude', 'phase', 'coherence']),
    calLevel: 94,
    splText: '',
    permissionDenied: false,
    starting: false,
    dragging: false,
    standalone: null,     // a single view drawn on its own (screens of the Mac snapshot tests)
  };
  let lastHTML = null, lastSidebar = null, lastError = null, deferred = false;

  const cmd = (op, extra) => SSMT.send(Object.assign({ cmd: 'setup', do: op }, extra || {}));
  const W = () => (D.s && D.s.wizard) || {};
  const running = () => !!(D.s && D.s.running);
  const isSim = () => !D.s || D.s.simulation;
  const f = (fmt, ...a) => format(fmt, ...a);
  const opt = (v, fmt) => (v == null ? '—' : f(fmt, v));

  // While a slider is held nothing is redrawn (the redraw would take it from under the pointer); one redraw follows.
  const redraw = () => { if (U.dragging) deferred = true; else SSMT.render(); };
  SSMT.onEngine((ev) => {
    if (ev.event === 'setupStatic') { D.st = ev; redraw(); }
    else if (ev.event === 'setupState') {
      D.s = ev;
      const e = ev.lastError || null;
      if (e !== lastError) { lastError = e; S.lastError = e ? (e.startsWith('error.') ? t(e) : e) : null; }
      if (!ev.running && !U.starting && SSMT.audio && SSMT.audio.isOpen('setup')) SSMT.audio.close('setup');
      redraw();
    } else if (ev.event === 'setupLive') {
      D.live = ev.running ? ev : null;
      redraw();
    } else if (ev.event === 'setupSessionOpened') {
      setMode('wizard');
    } else if (ev.event === 'setupTargetPreview') {
      U.targetPreview = ev.db; redraw();
    }
  });
  cmd('state');

  function setMode(m) { U.mode = m; store.set('setup.mode', m); SSMT.render(); }

  // MARK: wizard stages (AppSidebar.WizardStage)

  const STAGE_OF = { preparation: 0, baseline: 1, subOnly: 1, mainsOnly: 1, results: 2, verification: 2, eqPoints: 3, eqTuning: 3, eqVerification: 3, finished: 4 };
  const STAGE_ICON = ['checklist', 'waveform', 'dial.medium', 'slider.vertical.3', 'doc.text'];
  const stageOf = (step) => STAGE_OF[step] ?? 0;

  // MARK: controls in the macOS style

  /** Toggle (checkbox style, as SwiftUI draws a Toggle on macOS outside a Form). */
  const check = (label, on, act, arg, disabled) => `<button class="mac-check${on ? ' on' : ''}" data-act="${act}"${arg != null ? ` data-arg="${esc(arg)}"` : ''}${disabled ? ' disabled' : ''}>
    <span class="box">${on ? icon('checkmark', 10) : ''}</span><span class="label">${esc(label)}</span></button>`;

  /** Pop-up menu button; items: {label, act, arg, checked, header, divider, disabled}. */
  function popup(id, label, items, { disabled, cls = '', plain, menu } = {}) {
    const list = U.menu === id ? `<div class="mac-menu">${items.map((it) => {
      if (it.divider) return '<div class="sep"></div>';
      if (it.header) return `<div class="hdr">${esc(it.header)}</div>`;
      return `<button data-act="${it.act}"${it.arg != null ? ` data-arg="${esc(it.arg)}"` : ''}${it.disabled ? ' disabled' : ''}><span class="tick">${it.checked ? icon('checkmark', 11) : ''}</span>${esc(it.label)}</button>`;
    }).join('')}</div>` : '';
    return `<span class="popup-wrap ${cls}"><button class="${plain ? 'mac-menu-label' : 'mac-popup'}${menu ? ' menu' : ''}" data-act="menu" data-arg="${id}"${disabled ? ' disabled' : ''}>
      <span class="text">${esc(label)}</span>${plain ? '' : `<span class="chev">${icon(menu ? 'chevron.down' : 'chevron.up.chevron.down', menu ? 9 : 10)}</span>`}</button>${list}</span>`;
  }
  const pickerRow = (title, html) => `<div class="picker-row"><span class="title">${esc(title)}</span>${html}</div>`;
  const stepper = (act) => `<span class="mac-stepper"><button data-act="${act}" data-arg="1">${icon('chevron.up', 8)}</button><button data-act="${act}" data-arg="-1">${icon('chevron.down', 8)}</button></span>`;
  const slider = (key, value, min, max, step = 'any') => {
    const p = Math.min(1, Math.max(0, (value - min) / (max - min))) * 100;
    return `<input type="range" class="mac-slider" data-input="${key}" min="${min}" max="${max}" step="${step}" value="${value}" style="--p:${p}%">`;
  };
  const seg = (options, value, act) => `<div class="mac-seg">${options.map(([v, label]) => `<button class="${String(v) === String(value) ? 'on' : ''}" data-act="${act}" data-arg="${esc(v)}">${esc(label)}</button>`).join('')}</div>`;
  const btn = (label, act, o = {}) => UI.button(label, Object.assign({ act }, o));
  const infoButton = (key, text) => `<span class="popup-wrap info-wrap"><button class="info-button" data-act="info" data-arg="${key}">${icon('info.circle', 16)}</button>
    ${U.info === key ? `<div class="info-pop">${esc(text)}</div>` : ''}</span>`;
  const spinner = () => '<span class="spinner"></span>';
  const busy = (text) => `<span class="busy">${spinner()}${text ? `<span>${esc(text)}</span>` : ''}</span>`;

  // MARK: TopBar and StatusPill

  function statusPill() {
    const s = D.s || {};
    let key = 'status.ready', color = C.statusGood;
    if (!s.running) { key = 'status.off'; color = C.textMuted; }
    else if (D.live && D.live.mic && D.live.mic.clipped) { key = 'meters.clip'; color = C.statusError; }
    else if (U.mode === 'wizard' && !W().prepared) { key = 'status.running'; color = C.accent; }
    const d = s.delay && s.delay.reliable ? `<span class="dt">${esc(f('Δt %.2f ms', s.delay.ms))}</span>` : '';
    return `<span class="status-pill"><i style="background:${color};box-shadow:0 0 4px ${X.rgba(color.startsWith('#') ? color : '#34D399', 0.8)}"></i><span>${esc(t(key))}</span>${d}</span>`;
  }

  function topBar() {
    const s = D.s || {};
    const items = [
      { header: t('mode.title') },
      { label: t('mode.wizard'), act: 'mode', arg: 'wizard', checked: U.mode === 'wizard' },
      { label: t('mode.expert'), act: 'mode', arg: 'expert', checked: U.mode === 'expert' },
      { divider: true },
      { label: t('mode.stage'), act: 'stageMode', checked: U.stage },
      { label: t('graphics.reduced'), act: 'reduced', checked: U.reduced },
      { divider: true },
      { label: t('settings.open'), act: 'settings' },
      { label: t('session.save'), act: 'saveSession' },
      { label: t('session.open'), act: 'openSession' },
      { label: t('report.pdf'), act: 'reportPDF' },
    ];
    const menu = `<span class="popup-wrap more-wrap"><button class="more-button" data-act="menu" data-arg="more">${icon('ellipsis', 14)}</button>${U.menu === 'more' ? `<div class="mac-menu right">${items.map((it) => {
      if (it.divider) return '<div class="sep"></div>';
      if (it.header) return `<div class="hdr">${esc(it.header)}</div>`;
      return `<button data-act="${it.act}" data-arg="${esc(it.arg || '')}"><span class="tick">${it.checked ? icon('checkmark', 11) : ''}</span>${esc(it.label)}</button>`;
    }).join('')}</div>` : ''}</span>`;
    return `<div class="setup-topbar${U.stage ? ' stage' : ''}">
      ${U.mode === 'expert' ? `<span class="tb-title">${esc(t('mode.expert'))}</span>` : ''}
      <span class="spacer"></span>
      ${statusPill()}
      <button class="btn ${s.noiseOn ? 'active' : ''}" data-act="toggleNoise" title="${esc(t('noise.toggle'))}">${icon(s.noiseOn ? 'waveform' : 'waveform.slash', 14)}<span>${esc(t('noise.short'))}</span></button>
      <button class="btn" data-act="mini" title="${esc(t('mini.toggle'))}">${icon('rectangle.on.rectangle', 14)}</button>
      ${menu}
      <button class="btn danger stop" data-act="stop" title="${esc(t('action.stop.help'))}">${X.sym('stop.fill', U.stage ? 20 : 12)}<span>${esc(t('action.stop'))}</span></button>
    </div>`;
  }

  // MARK: sidebar

  function sidebar() {
    if (U.mode === 'wizard') {
      const current = stageOf(W().step);
      const stages = [0, 1, 2, 3, 4].map((i) => UI.stageRow(i + 1, t(`stage.${i}.title`), t(`stage.${i}.subtitle`),
        i === current ? 'current' : i < current ? 'done' : 'upcoming', i === 4)).join('');
      return `<div class="items setup-stages">${stages}</div><div class="spacer"></div><div class="rule wide"></div>
        <div class="items setup-utilities">${UI.utilityRow('slider.horizontal.3', t('settings.title'), 'settings')}
        ${UI.utilityRow('square.and.arrow.down', t('session.save.short'), 'saveSession')}
        ${UI.utilityRow('doc.richtext', t('report.pdf.short'), 'reportPDF')}</div>`;
    }
    return `<div class="setup-sidebar">${setupSidebar(true)}</div>`;
  }

  // MARK: SetupSidebar

  function duplexDevices() {
    const d = U.devices;
    if (!d) return [];
    const out = [];
    for (const i of d.inputs) {
      const o = d.outputs.find((x) => x.groupId && x.groupId === i.groupId);
      if (!o || out.some((x) => x.id === i.groupId)) continue;
      const m = /\(([^)]+)\)\s*$/.exec(i.label);
      out.push({ id: i.groupId, name: m ? m[1] : i.label, input: i.id, output: o.id });
    }
    return out;
  }

  function sourceDescription() {
    const src = U.source;
    if (src.kind === 'device') { const d = duplexDevices().find((x) => x.id === src.id); return d ? { name: d.name, input: d.input, output: d.output } : null; }
    if (src.kind === 'split' && U.devices) {
      const i = U.devices.inputs.find((x) => x.id === src.input), o = U.devices.outputs.find((x) => x.id === src.output);
      return i && o ? { name: `${i.label} → ${o.label}`, input: i.id, output: o.id } : null;
    }
    return null;
  }

  function channelItems(count, selected, act) {
    return Array.from({ length: Math.max(count, 1) }, (_, i) => ({ label: String(i + 1), act, arg: i, checked: i === selected }));
  }

  function sourcePanel() {
    const s = D.s || {};
    const run = !!s.running;
    const split = U.source.kind === 'split';
    let body = check(t('setup.split'), split, 'splitSource', null, run);
    if (split && U.devices) {
      const ins = U.devices.inputs, outs = U.devices.outputs;
      const iSel = ins.find((x) => x.id === U.source.input), oSel = outs.find((x) => x.id === U.source.output);
      body += pickerRow(t('setup.input.device'), popup('inDev', iSel ? iSel.label : '—', ins.map((d) => ({ label: d.label, act: 'inputDevice', arg: d.id, checked: d === iSel })), { disabled: run }));
      body += pickerRow(t('setup.output.device'), popup('outDev', oSel ? oSel.label : '—', outs.map((d) => ({ label: d.label, act: 'outputDevice', arg: d.id, checked: d === oSel })), { disabled: run }));
      body += `<p class="hint">${esc(t('setup.split.hint'))}</p>`;
    } else {
      const devs = duplexDevices();
      const cur = U.source.kind === 'device' ? devs.find((x) => x.id === U.source.id) : null;
      body += pickerRow(t('setup.interface'), popup('iface', cur ? cur.name : t('setup.simulation'), [
        { label: t('setup.simulation'), act: 'iface', arg: '', checked: U.source.kind === 'simulation' },
        ...devs.map((d) => ({ label: d.name, act: 'iface', arg: d.id, checked: cur === d })),
      ], { disabled: run }));
    }
    if (U.source.kind !== 'simulation' && (U.chan.in > 0 || U.chan.out > 0)) {
      const ch = s.channels || { mic: 0, ref: 1, out: 0 };
      body += pickerRow(t('setup.mic.channel'), popup('chMic', String(ch.mic + 1), channelItems(U.chan.in, ch.mic, 'chMic'), { disabled: run }));
      body += pickerRow(t('setup.output.channel'), popup('chOut', String(ch.out + 1), channelItems(U.chan.out, ch.out, 'chOut'), { disabled: run }));
      if (s.referenceMode !== 'internalSignal') body += pickerRow(t('setup.ref.channel'), popup('chRef', String(ch.ref + 1), channelItems(U.chan.in, ch.ref, 'chRef'), { disabled: run }));
    }
    const ref = s.referenceMode || 'internalSignal';
    body += pickerRow(t('setup.reference'), popup('refMode', t(ref === 'internalSignal' ? 'ref.internal' : 'ref.loopback'), [
      { label: t('ref.internal'), act: 'refMode', arg: 'internalSignal', checked: ref === 'internalSignal' },
      { label: t('ref.loopback'), act: 'refMode', arg: 'loopbackInput', checked: ref !== 'internalSignal' },
    ]));
    body += `<p class="hint">${esc(t(ref === 'internalSignal' ? 'ref.internal.hint' : 'ref.loopback.hint'))}</p>`;
    body += `<div class="row"><span class="small-label">${esc(t('setup.temperature'))}</span><span class="spacer"></span><span class="mono12">${esc(f('%.0f °C', s.temperature ?? 20))}</span>${stepper('temperature')}</div>`;
    body += `<div class="row">${run ? btn(t('engine.stop'), 'stopEngine') : btn(t('engine.start'), 'startEngine', { kind: 'primary' })}
      <button class="btn" data-act="refreshDevices" title="${esc(t('setup.refresh'))}">${icon('arrow.clockwise', 14)}</button></div>`;
    if (U.permissionDenied) body += warning(t('permission.denied'));
    if (s.lastError) body += warning(s.lastError.startsWith('error.') ? t(s.lastError) : s.lastError);
    return UI.panel(t('setup.source'), body);
  }

  const warning = (text) => `<div class="sb-warning">${icon('exclamationmark.triangle.fill', 12)}<span>${esc(text)}</span></div>`;

  function generatorPanel() {
    const s = D.s || {};
    const kinds = [[0, 'noise.pink'], [1, 'noise.white'], [2, 'noise.periodic']];
    const noise = s.noise ?? 0;
    let body = pickerRow(t('setup.noise'), popup('noise', t(kinds[noise][1]), kinds.map(([v, k]) => ({ label: t(k), act: 'noiseKind', arg: v, checked: v === noise }))));
    if (noise === 2) body += `<p class="hint yellow">${esc(t('noise.periodic.hint'))}</p>`;
    const level = (title, key, v, min, max) => `<div class="level-slider"><div class="row"><span class="small-label">${esc(title)}</span><span class="spacer"></span><span class="mono12">${esc(f('%.0f dBFS', v))}</span></div>${slider(key, v, min, max, 1)}</div>`;
    body += level(t('setup.level'), 'level', s.level ?? -40, -80, 0);
    body += level(t('setup.max.level'), 'maxLevel', s.maxLevel ?? -12, -60, 0);
    if (D.live) body += `<div class="row"><span class="small-label">${esc(t('setup.output.level'))}</span><span class="spacer"></span><span class="mono12">${esc(opt(D.live.generator, '%.1f dBFS'))}</span></div>`;
    const al = s.autoLevel || { state: 'idle' };
    if (al.state === 'measuringNoise' || al.state === 'raising') {
      body += `<div class="row">${spinner()}<span class="hint">${esc(t(al.state === 'measuringNoise' ? 'autolevel.noise' : 'autolevel.raising'))}</span><span class="spacer"></span>${btn(t('action.cancel'), 'cancelAutoLevel')}</div>`;
    } else {
      body += `<div class="row">${btn(t('autolevel.run'), 'autoLevel', { icon: 'dial.medium', disabled: !s.running, title: t('autolevel.help') })}<span class="spacer"></span></div>`;
    }
    if (al.state === 'done') {
      if (al.outcome === 'targetReached') body += UI.statusBadge('good', t('autolevel.ok', al.level, al.snr));
      else if (al.outcome === 'maximumReached') body += UI.statusBadge('warning', t('autolevel.max', al.snr));
      else body += UI.statusBadge('error', t('autolevel.clipped'));
    }
    body += `<div class="sb-hazard">${icon('exclamationmark.triangle.fill', 12)}<span>${esc(t('safety.hf.warning'))}</span></div>`;
    body += `<div class="row">${btn(s.delaySearch ? t('delay.searching') : t('delay.find'), 'findDelay', { icon: 'scope', disabled: !s.noiseOn || s.delaySearch })}</div>`;
    if (s.delay && !s.delay.reliable) body += warning(t('delay.unreliable'));
    return UI.panel(t('setup.generator'), body);
  }

  function micMenuItems(act) {
    const cal = (D.s && D.s.calibration) || { files: [] };
    const items = [{ label: t('cal.mic.none'), act, arg: '', checked: !cal.selected }];
    if (cal.files.length) {
      items.push({ header: t('cal.section.files') });
      for (const m of cal.files) items.push({ label: m.name, act, arg: m.id, checked: cal.selected === m.id });
    }
    for (const g of (D.st && D.st.microphones) || []) {
      items.push({ header: t(`cal.section.${g.kind}`) });
      for (const p of g.items) items.push({ label: p.name, act, arg: p.id, checked: cal.selected === p.id });
    }
    return items;
  }

  function micTitle() {
    const cal = (D.s && D.s.calibration) || {};
    if (cal.profile) return cal.profile.name;
    return cal.mic ? cal.mic.name : t('cal.mic.none');
  }

  function calibrationPanel() {
    const s = D.s || {};
    const cal = s.calibration || { files: [] };
    let body = pickerRow(t('cal.mic'), popup('calMic', micTitle(), micMenuItems('selectMic')));
    if (cal.mic) {
      body += X.micCurve(cal.mic.curve);
      if (cal.profile) {
        const p = cal.profile;
        body += `<div class="vstack6">${UI.statusBadge(p.flat ? 'idle' : 'warning', t(p.flat ? 'cal.typical.flat' : 'cal.typical'))}
          <p class="hint">${esc(t(p.flat ? 'cal.typical.flat.note' : 'cal.typical.note'))}</p>
          ${p.cardioid ? `<p class="hint yellow">${esc(t('cal.cardioid.note'))}</p>` : ''}</div>`;
      } else {
        body += `<div class="row">${UI.statusBadge('good', t('cal.individual'))}<span class="mono11 muted">${esc(t('cal.points', cal.mic.points))}</span><span class="spacer"></span>
          <button class="btn plain" data-act="removeMic" data-arg="${esc(cal.selected)}" title="${esc(t('cal.remove'))}">${icon('trash', 13)}</button></div>`;
        if (cal.mic.header) body += `<div class="mono11 muted ellipsis">${esc(cal.mic.header)}</div>`;
      }
    } else {
      body += `<div>${UI.statusBadge('warning', t('cal.mic.uncalibrated'))}</div>`;
    }
    body += `<div class="row">${btn(t('cal.import'), 'importMic', { icon: 'square.and.arrow.down' })}</div>`;
    body += '<div class="tech-divider"></div>';
    body += `<div class="row"><span class="small-label">${esc(t('cal.spl'))}</span><span class="spacer"></span>${cal.spl != null ? `<span class="mono11">${esc(f('%.1f dBFS @ 94 dB', cal.spl))}</span>` : UI.statusBadge('idle', t('cal.spl.none'))}</div>`;
    body += `<div class="row"><input id="setup-spl" class="field mono11 grow" placeholder="dBFS @ 94 dB SPL" data-input="splText" value="${esc(U.splText)}">${btn(t('cal.apply'), 'splApply')}</div>`;
    body += `<div class="row">${popup('calLevel', U.calLevel === 94 ? '94 dB' : '114 dB', [
      { label: '94 dB', act: 'calLevel', arg: 94, checked: U.calLevel === 94 }, { label: '114 dB', act: 'calLevel', arg: 114, checked: U.calLevel === 114 }], { cls: 'w90' })}
      ${btn(t('cal.calibrator'), 'calibrator', { disabled: !s.running, title: t('cal.calibrator.help') })}</div>`;
    return UI.panel(t('cal.title'), body);
  }

  function simulationPanel() {
    const s = D.s || {};
    return UI.panel(t('sim.title'), `<p class="hint">${esc(t('sim.hint'))}</p>${check(t('sim.sub'), s.simSub !== false, 'simSub')}${check(t('sim.main'), s.simMain !== false, 'simMain')}`);
  }

  function displayPanel() {
    const s = D.s || {};
    const sm = s.smoothing ?? 12;
    const smLabel = sm === 0 ? t('display.smoothing.none') : `1/${sm} oct`;
    const ct = s.coherenceThreshold ?? 0.6;
    let body = pickerRow(t('display.smoothing'), popup('smoothing', smLabel, [[0, t('display.smoothing.none')], [48], [24], [12], [6], [3]].map(([v, l]) => ({ label: l || `1/${v} oct`, act: 'smoothing', arg: v, checked: v === sm }))));
    body += `<div class="row"><span class="small-label">${esc(t('display.coherence.threshold'))}</span><span class="spacer"></span><span class="mono12">${esc(f('%.2f', ct))}</span></div>`;
    body += slider('coherence', ct, 0.3, 0.95, 0.05);
    for (const g of ['magnitude', 'phase', 'coherence']) body += check(t(`graph.${g}`), U.graphs.includes(g), 'graph', g);
    body += `<div class="row">${btn(t('display.reset.avg'), 'resetAverages')}${btn(t('display.reset.clip'), 'resetClips')}</div>`;
    return UI.panel(t('display.title'), body);
  }

  function languagePanel() {
    const v = store.get('langChoice', S.lang);
    return UI.panel(t('settings.language'), seg([['system', t('language.system')], ['en', 'English'], ['ru', 'Русский']], v, 'language'));
  }

  function setupSidebar(expert) {
    return [sourcePanel(), generatorPanel(), calibrationPanel(), isSim() && U.source.kind === 'simulation' ? simulationPanel() : '',
      expert ? displayPanel() : '', languagePanel()].join('');
  }

  // MARK: wizard pieces

  function scaffold(title, subtitle, info, content, actions) {
    const w = W();
    return `<div class="step">
      <div class="step-head"><span class="step-counter">${esc(t('stage.counter', stageOf(w.step) + 1, 5))}</span>
        <div class="step-title"><h1>${esc(title)}</h1>${info ? infoButton('step', info) : ''}</div>
        ${subtitle ? `<p class="step-sub">${esc(subtitle)}</p>` : ''}</div>
      ${content}${actions}</div>`;
  }

  const gauge = (o) => X.tunerGauge(Object.assign({ large: U.stage }, o));
  const quiet = (title, ic, act, arg) => X.quietButton(title, ic, act, arg);
  const actionRow = (title, ic, act, enabled = true, secondary = '') => `<div class="action-row">${secondary}${X.wizardPrimaryButton(title, ic, act, enabled)}</div>`;
  const collapsible = (key, title, body) => X.collapsible(title, !!U.open[key], 'collapse', key, body);

  function signalQualityGauge(q) {
    const clipped = !!(D.live && D.live.mic && D.live.mic.clipped);
    let instruction;
    if (clipped) instruction = t('gauge.quality.clip');
    else if (q == null) instruction = t('tuner.waiting');
    else instruction = t(q >= 0.8 ? 'gauge.quality.good' : q >= 0.6 ? 'gauge.quality.weak' : 'gauge.quality.bad');
    return gauge({
      title: t('gauge.quality'), value: clipped ? 0 : q == null ? null : (q - 0.3) / 0.55, mode: 'oneSided', tolerance: (0.8 - 0.3) / 0.55,
      readout: clipped ? t('meters.clip') : q == null ? '—' : f('%.0f %%', q * 100), instruction,
      scaleLabels: ['30', '44', '58', '71', '85'], unit: '%',
    });
  }

  function snrGauge() {
    const snr = D.live && D.s && D.s.noiseOn ? D.live.snr : null;
    return gauge({
      title: t('gauge.snr'), value: snr == null ? null : snr / 30, mode: 'oneSided', tolerance: 20 / 30,
      readout: snr == null ? '—' : f('%.0f dB', snr),
      instruction: snr != null ? t(snr >= 20 ? 'gauge.snr.good' : 'gauge.snr.low') : t(D.s && D.s.noiseFloor ? 'tuner.waiting' : 'gauge.snr.needNoise'),
      scaleLabels: ['0', '8', '15', '23', '30'], unit: 'dB',
    });
  }

  function chipLabel(c) {
    return t({ delaySub: 'card.delay.sub', noDelayChange: 'card.delay.sub', delayMains: 'card.delay.mains', polarity: 'card.polarity', subLevel: 'card.level' }[c.kind]);
  }
  function chipValue(c) {
    if (c.kind === 'delaySub' || c.kind === 'delayMains') return f('+%.2f ms', c.seconds * 1000);
    if (c.kind === 'noDelayChange') return '0.00 ms';
    if (c.kind === 'polarity') return t(c.invert ? 'polarity.invert' : 'polarity.normal');
    return f('%+.1f dB', c.dB);
  }
  const chips = () => `<div class="chips">${(W().cards || []).map((c) => X.valueChip(chipLabel(c), chipValue(c))).join('')}</div>`;

  const freqs = () => (D.st && D.st.frequencies) || [];

  // MARK: step 0: preparation

  function checklistRow(done, failed, ic, title, detail, trailing) {
    return `<div class="checklist-row">${UI.checkDot(done, failed)}${UI.iconTile(ic, { tint: done ? C.textPrimary : C.textSecondary })}
      <div class="texts"><b>${esc(title)}</b><span class="${failed ? 'failed' : ''}">${esc(detail)}</span></div><span class="spacer"></span>${trailing}</div>`;
  }

  function preparationStep() {
    const s = D.s || {}, w = W();
    const al = s.autoLevel || { state: 'idle' };
    const levelState = al.state === 'done' ? (al.outcome === 'targetReached' ? 1 : al.outcome === 'maximumReached' ? 0.6 : 0) : null;
    const levelValue = al.state === 'idle' ? '—' : al.state === 'measuringNoise' ? t('prep.level.noise') : al.state === 'raising' ? t('prep.level.raising')
      : al.outcome === 'clipped' ? t('meters.clip') : f('%.0f dBFS', al.level);
    const mic = D.live && D.live.mic;
    const clipped = !!(mic && mic.clipped);
    const present = !!(mic && mic.rms != null && mic.rms > -70);
    let micDetail = t(clipped ? 'prep.mic.clip' : present ? 'prep.mic.ok' : 'prep.mic.hint');
    if (present && !clipped) {
      const cal = s.calibration || {};
      if (!cal.mic) micDetail += ' ' + t('prep.mic.noProfile');
      else if (cal.profile) micDetail += ' ' + t('prep.mic.typical');
    }
    const delayValue = !s.delay ? '—' : s.delay.reliable ? f('%.2f ms', s.delay.ms) : t('prep.delay.bad');
    const divider = '<div class="checklist-divider"></div>';
    const rows = [
      checklistRow(!!s.running, false, 'hifispeaker.fill', t('prep.audio'), s.running ? (s.displayName || '') : t('prep.audio.hint'),
        s.running ? btn(t('prep.change'), 'settings') : btn(t('engine.start'), 'startEngine', { kind: 'primary' })),
      checklistRow(present && !clipped, clipped, 'mic.fill', t('prep.mic'), micDetail,
        `<span class="hstack14">${popup('prepMic', micTitle(), micMenuItems('selectMic'), { cls: 'small', menu: true })}${X.levelStrip(mic ? mic.rms : null, clipped)}</span>`),
      checklistRow(levelState === 1, levelState === 0, 'dial.medium', t('prep.level'), levelState == null ? t('prep.level.hint') : levelValue,
        al.state === 'measuringNoise' ? busy(t('prep.level.noise')) : al.state === 'raising' ? busy(t('prep.level.raising')) : btn(t('autolevel.run'), 'autoLevel', { disabled: !s.running })),
      checklistRow(!!w.prepared, !!(s.delay && !s.delay.reliable), 'scope', t('prep.delay'), s.delay ? delayValue : t('prep.delay.hint'),
        s.wizardDelaySearch ? busy('') : btn(t('delay.find'), 'lockDelay', { disabled: !s.running })),
    ].join(divider);
    const content = `<div class="vstack" style="gap:16px">${UI.panel(t('prep.checklist'), `<div class="checklist">${rows}</div>`)}
      <div class="hstack top" style="gap:16px"><div class="snr-col">${snrGauge()}</div>${systemCard()}</div></div>`;
    return scaffold(t('prep.title'), t('prep.text'), t('prep.info'), content, actionRow(t('wizard.begin'), 'play.fill', 'wizardStart', !!w.prepared));
  }

  function processorName(p) {
    if (!p) return '';
    if (p.isCustom || p.id === 'custom') return t('processor.custom');
    return p.id === 'generic' ? t('processor.generic') : p.name;
  }

  function systemCard() {
    const cfg = W().config || {};
    const p = cfg.processor || {};
    const custom = !!(p.isCustom || p.id === 'custom');
    const procItems = ((D.st && D.st.processors) || []).map((x) => ({ label: x.id === 'generic' ? t('processor.generic') : x.name, act: 'processor', arg: x.id, checked: !custom && x.id === p.id }));
    procItems.push({ divider: true }, { label: t('processor.custom'), act: 'processorCustom', checked: custom });
    let body = `<div class="vstack6"><div class="row"><span class="t13">${esc(t('processor.title'))}</span><span class="spacer"></span>
      <span class="popup-wrap proc-wrap">${popup('processor', processorName(p), procItems, { menu: true })}${U.procEdit ? customProcessorEditor(p) : ''}</span>
      ${custom ? btn(t('processor.edit'), 'processorEdit') : ''}</div>
      ${p.source ? `<p class="hint muted" title="${esc(p.source)}">${esc(t('processor.verified') + ' ' + t(`processor.source.${p.id}`) + ' ' + t('processor.rest'))}</p>` : ''}</div>`;
    body += `<div class="row">${check(t('prep.hasSub'), cfg.hasSubwoofer !== false, 'cfgToggle', 'hasSubwoofer')}<span class="spacer"></span>${check(t('prep.fastMode.short'), !!cfg.fastMode, 'cfgToggle', 'fastMode')}</div>`;
    body += `<div class="row">${check(t('prep.knownCrossover'), cfg.crossover != null, 'cfgToggle', 'knownCrossover')}<span class="spacer"></span>
      ${cfg.crossover != null ? `<span class="mono13">${esc(f('%.0f Hz', cfg.crossover))}</span>${stepper('crossover')}` : `<span class="t12 muted">${esc(t('prep.crossover.auto'))}</span>`}</div>`;
    body += `<div class="hstack" style="gap:16px"><div class="vstack6 grow"><span class="t12 secondary">${esc(t('prep.delayStep'))}</span>${seg([[0.00001, '0.01 ms'], [0.00002, '0.02 ms'], [0.0001, '0.1 ms']], cfg.delayStep, 'delayStep')}</div>
      <div class="vstack6 grow"><span class="t12 secondary">${esc(t('prep.levelStep'))}</span>${seg([[0.1, '0.1 dB'], [0.5, '0.5 dB'], [1, '1 dB']], cfg.levelStep, 'levelStep')}</div></div>`;
    if (cfg.fastMode) body += `<p class="hint yellow">${esc(t('prep.fastMode.warning'))}</p>`;
    return UI.panel(t('prep.system'), `<div class="system-card">${body}</div>`, { tint: C.dataSecondary, cls: 'grow' });
  }

  function customProcessorEditor(p) {
    const row = (label, ctl) => `<div class="form-row"><span class="label">${esc(label)}</span>${ctl}</div>`;
    const choice = (id, key, values, unit) => popup(id, f('%g ' + unit, p[key]), values.map((v) => ({ label: `${v} ${unit}`, act: 'procField', arg: `${key}:${v}`, checked: v === p[key] })));
    return `<div class="popover proc-editor">
      ${row(t('processor.maxDelay'), `<input id="proc-maxdelay" class="field mono12" data-change="procMaxDelay" value="${p.maxDelayMs ?? 0}">`)}
      ${row(t('prep.delayStep'), choice('procDelayStep', 'delayStepMs', [0.01, 0.02, 0.1, 1], 'ms'))}
      ${row(t('processor.bandsSub', p.peqBandsSub ?? 0), stepper('procBandsSub'))}
      ${row(t('processor.bandsMains', p.peqBandsMains ?? 0), stepper('procBandsMains'))}
      ${row(t('processor.gainStep'), choice('procGainStep', 'gainStepDB', [0.1, 0.25, 0.5, 1], 'dB'))}
      ${check(t('processor.octaves'), !!p.bandwidthInOctaves, 'procOctaves')}
    </div>`;
  }

  // MARK: steps 1, 2, 3, 5: capture

  function captureStep() {
    const s = D.s || {}, w = W();
    const step = w.stepIndex;
    const g = w.requiredGroups || { sub: true, mains: true };
    const pill = (name, on) => `<span class="group-pill${on ? ' on' : ''}">${icon(on ? 'speaker.wave.2.fill' : 'speaker.slash.fill', 14)}<span>${esc(name)}</span><span class="state">${esc(t(on ? 'group.on' : 'group.muted'))}</span></span>`;
    const acc = s.lastAcceptance;
    let notice = '';
    if (acc && acc.kind === 'rejected') notice = `<p class="capture-notice">${esc(t('capture.rejected') + ' ' + acc.reasons.map((r) => t(`reason.${r}`)).join(' '))}</p>`;
    else if (acc && acc.kind === 'streamRestarted') notice = `<p class="capture-notice">${esc(t('capture.streamRestarted'))}</p>`;
    let sim = '';
    if (isSim()) {
      const parts = [];
      if (w.requiredGroups && (s.simSub !== g.sub || s.simMain !== g.mains)) parts.push(quiet(t('sim.doIt'), 'wand.and.stars', 'simGroups'));
      if (w.step === 'verification' && !s.simApplied) parts.push(quiet(t('sim.applySettings'), 'wand.and.stars', 'simApply'));
      if (parts.length) sim = `<div class="hstack" style="gap:16px">${parts.join('')}</div>`;
    }
    const content = `<div class="vstack center" style="gap:22px"><div class="hstack" style="gap:12px">${pill(t('group.subs'), g.sub)}${pill(t('group.mains'), g.mains)}</div>
      <div class="gauge-480">${signalQualityGauge(D.live ? D.live.stepQuality : null)}</div>${progressBar()}${notice}${sim}</div>`;
    const retry = acc && acc.kind === 'rejected';
    const actions = actionRow(s.captureRunning ? t('action.cancel') : retry ? t('capture.repeat') : t('capture.start'), s.captureRunning ? 'xmark' : 'record.circle', 'capture', !!s.running,
      quiet(t('wizard.back'), 'chevron.left', 'back'));
    return scaffold(t(`capture.${step}.title`), t(`capture.${step}.short`), t(`capture.${step}.text`), content, actions);
  }

  function progressBar() {
    const s = D.s || {};
    if (!s.captureRunning || !D.live || !D.live.capture) return '';
    const p = D.live.capture.fraction || 0;
    return `<div class="capture-progress"><i style="width:${p * 100}%;background:${UI.closeness(p)}"></i></div>`;
  }

  // MARK: step 4: results and the live tuner

  function tunerPanel() {
    const s = D.s || {}, w = W();
    const r = s.tuner || null;
    const reliable = !!(r && r.reliable);
    const mainsStage = s.tunerStage === 'adjustMainsDelay';
    const showDelay = mainsStage || !s.tunerNeedsMains;
    const fc = (w.alignment && w.alignment.crossover) || 100;
    const scale = (full, fmt) => [-1, -0.5, 0, 0.5, 1].map((v) => (v === 0 ? '0' : f(fmt, v * full)));
    let delayInstruction;
    if (!r) delayInstruction = t('tuner.waiting');
    else if (!r.reliable) delayInstruction = t('tuner.unreliable');
    else if (r.delayInTune) delayInstruction = t('tuner.inTune');
    else { const more = r.delayError > 0; delayInstruction = t(mainsStage ? (more ? 'tuner.mains.more' : 'tuner.mains.less') : (more ? 'tuner.sub.more' : 'tuner.sub.less')); }
    const levelInstruction = !r ? t('tuner.waiting') : r.levelInTune ? t('tuner.inTune') : t(r.levelError > 0 ? 'tuner.level.up' : 'tuner.level.down');
    const gauges = [];
    if (showDelay) {
      gauges.push(gauge({
        title: t(mainsStage ? 'card.delay.mains' : 'card.delay.sub'), value: r ? r.delayPhaseError / 90 : null, tolerance: 10 / 90,
        readout: r ? f('%+.2f', r.delayError * 1000) : '—', instruction: delayInstruction, reliable,
        scaleLabels: scale(250 / fc, '%+.1f'), unit: t('unit.ms'),
      }));
    }
    if (!mainsStage) {
      gauges.push(gauge({
        title: t('card.level'), value: r ? r.levelError / 6 : null, tolerance: 0.5 / 6,
        readout: r ? f('%+.1f', r.levelError) : '—', instruction: levelInstruction, reliable,
        scaleLabels: scale(6, '%+.0f'), unit: 'dB',
      }));
    }
    return `<div class="vstack" style="gap:18px">${mainsStage ? '' : X.polarityLamp(r ? r.polarityWrong : null, U.stage)}
      <div class="hstack top equal" style="gap:18px">${gauges.join('')}</div></div>`;
  }

  function virtualProcessorPanel() {
    const p = (D.s && D.s.simProcessor) || {};
    const knob = (title, key, v, min, max, step, fmt) => `<div class="vproc-knob"><span class="title">${esc(title)}</span>${slider('vproc:' + key, v ?? 0, min, max, step)}
      ${stepper('vprocStep:' + key + ':' + step)}<span class="mono12 value">${esc(f(fmt, v ?? 0))}</span></div>`;
    return `<div class="vstack8">${knob(t('vproc.subDelay'), 'subDelayMs', p.subDelayMs, 0, 20, 0.01, '%.2f ms')}
      ${knob(t('vproc.mainsDelay'), 'mainsDelayMs', p.mainsDelayMs, 0, 20, 0.01, '%.2f ms')}
      ${knob(t('vproc.subLevel'), 'subGainDB', p.subGainDB, -12, 6, 0.5, '%+.1f dB')}
      ${check(t('vproc.subPolarity'), !!p.subPolarityInverted, 'vprocPolarity')}</div>`;
  }

  function predictionCurves() {
    const c = W().curves || {};
    const out = [];
    if (c.baseline) out.push({ label: t('curve.before'), db: c.baseline, color: C.textMuted });
    if (c.prediction) out.push({ label: t('curve.prediction'), db: c.prediction, color: C.dataBlue, dashed: true });
    return out;
  }

  function resultsStep() {
    const s = D.s || {}, w = W();
    let content = '';
    if (w.alignmentError) {
      content = `<p class="error-text center">${esc(t('results.failed'))}<br>${esc(w.alignmentError)}</p>`;
    } else if (w.alignment) {
      const a = w.alignment;
      const proc = (w.config && w.config.processor) || {};
      content = `<div class="vstack" style="gap:24px">${chips()}
        ${a.ambiguous ? `<p class="t13 yellow center">${esc(t('results.ambiguous.short'))}</p>` : ''}
        ${proc.maxDelayMs != null && !a.canEnter ? X.hazardNotice(t('processor.delayTooLong', Math.abs(a.roundedDelay) * 1000, proc.maxDelayMs)) : ''}
        ${tunerPanel()}
        <div class="vstack" style="gap:12px">${isSim() ? collapsible('vproc', t('vproc.title'), virtualProcessorPanel()) : ''}
        ${collapsible('prediction', t('results.prediction'), X.comparisonPlot(freqs(), predictionCurves(), a.overlapBand))}</div></div>`;
    }
    const r = s.tuner;
    let actions;
    if (s.tunerNeedsMains && s.tunerStage === 'adjustSub') {
      actions = actionRow(t('tuner.next.mains'), 'arrow.right', 'tunerAdvance', !!(r && !r.polarityWrong && r.levelInTune), quiet(t('wizard.back'), 'chevron.left', 'back'));
    } else {
      actions = actionRow(t(r && r.allInTune ? 'tuner.verify.ready' : 'results.applied'), 'checkmark', 'beginVerification', true, quiet(t('wizard.back'), 'chevron.left', 'back'));
    }
    return scaffold(t('results.title'), t('results.subtitle'), t('results.text'), content, actions);
  }

  // MARK: step 5 result: alignment check

  function alignmentCheckStep() {
    const w = W(), r = w.report;
    if (!r) return '';
    const dip = r.dipAfter;
    const pe = r.predictionError;
    const content = `<div class="vstack" style="gap:22px"><div class="hstack top equal" style="gap:18px">
      ${gauge({ title: t('verify.dip'), value: dip == null ? null : 1 - dip / 9, mode: 'oneSided', tolerance: 1 - 3 / 9, readout: dip == null ? '—' : f('%.1f', dip),
        instruction: r.dipBefore != null ? t('gauge.before', r.dipBefore) : '', scaleLabels: ['9', '', '4.5', '', '0'], unit: 'dB' })}
      ${gauge({ title: t('verify.predictionError'), value: pe != null ? 1 - pe / 4 : 0, mode: 'oneSided', tolerance: 1 - 2 / 4, readout: pe != null ? f('%.1f', pe) : '—',
        instruction: t(pe != null && pe < 2 ? 'gauge.matches' : 'gauge.differs'), scaleLabels: ['4', '', '2', '', '0'], unit: 'dB' })}</div>
      ${r.advice !== 'none' ? `<p class="advice ${r.verdict === 'checkSettings' ? 'error' : 'yellow'}">${esc(t(`advice.${r.advice}`))}</p>` : ''}
      ${collapsible('verify', t('verify.curves'), X.comparisonPlot(freqs(), verifyCurves(), w.alignment ? w.alignment.overlapBand : null))}</div>`;
    const actions = actionRow(t('wizard.next.eq'), 'slider.horizontal.3', 'beginEQ', true,
      quiet(t('wizard.back'), 'chevron.left', 'back') + quiet(t('verify.again'), 'arrow.counterclockwise', 'beginVerification'));
    return scaffold(t(`verdict.${r.verdict}`), t(`verdict.${r.verdict}.text`), null, content, actions);
  }

  function verifyCurves() {
    const w = W(), c = w.curves || {};
    const out = predictionCurves();
    if (c.verification) {
      const dip = (w.report && w.report.dipAfter != null) ? w.report.dipAfter : 9;
      out.push({ label: t('curve.after'), db: c.verification, color: UI.closeness(1 - Math.max(0, dip - 3) / 6) });
    }
    return out;
  }

  // MARK: steps 6 and 8: EQ points

  function eqResultGauges() {
    const sc = W().eqScores;
    if (!sc) return '';
    const after = sc.after || sc.before;
    return `<div class="vstack lead" style="gap:10px"><div class="hstack top equal" style="gap:12px">
      ${gauge({ title: t('gauge.deviation'), value: 1 - after.deviation / 6, mode: 'oneSided', tolerance: 1 - 1.5 / 6, readout: f('±%.1f', after.deviation),
        instruction: t('gauge.before', sc.before.deviation), scaleLabels: ['6', '', '3', '', '0'], unit: 'dB' })}
      ${gauge({ title: t('gauge.score'), value: after.score / 100, mode: 'oneSided', tolerance: 0.8, readout: String(after.score),
        instruction: t('gauge.beforeScore', sc.before.score), scaleLabels: ['0', '', '50', '', '100'] })}</div>
      <div class="hstack"><span class="spacer"></span>${infoButton('score', t('gauge.score.note'))}</div></div>`;
  }

  function eqPointsStep() {
    const s = D.s || {}, w = W();
    const verifying = w.step === 'eqVerification';
    const pts = w.eqPoints || [], vpts = w.eqVerificationPoints || [];
    const done = verifying ? vpts.length : pts.length;
    const total = verifying ? pts.length : ((w.config && w.config.eqPointCount) || 5);
    const complete = done >= total;
    const title = verifying && complete ? t('eq.verify.done') : complete ? t('eq.points.done') : t(verifying ? 'eq.verify.point' : 'eq.points.point', done + 1, total);
    let content;
    if (verifying && complete) content = eqResultGauges();
    else {
      const acc = s.lastAcceptance;
      const row = [];
      if (!verifying) row.push(targetMenu());
      if (isSim() && !complete) row.push(quiet(t('sim.movePoint', done + 1), 'wand.and.stars', 'simMovePoint'));
      content = `<div class="vstack" style="gap:22px"><div class="hstack top" style="gap:18px"><div class="glass point-map-card">${X.pointMap(total, done, verifying ? vpts : pts)}</div>
        <div class="grow">${signalQualityGauge(D.live ? D.live.coherence : null)}</div></div>${progressBar()}
        ${acc && acc.kind === 'rejected' ? `<p class="t13 error-text">${esc(t('eq.point.rejected') + ' ' + acc.reasons.map((r) => t(`reason.${r}`)).join(' '))}</p>` : ''}
        ${row.length ? `<div class="hstack" style="gap:18px">${row.join('')}</div>` : ''}</div>`;
    }
    let actions;
    const back = quiet(t('wizard.back'), 'chevron.left', 'back');
    if (verifying && complete) actions = actionRow(t('eq.finish'), 'flag.checkered', 'finish', true, back + (w.canIterateEQ ? quiet(t('eq.iterate'), 'arrow.triangle.2.circlepath', 'iterateEQ') : ''));
    else if (complete) actions = actionRow(t('eq.compute'), 'slider.horizontal.3', 'computeEQ', true, back);
    else actions = actionRow(s.captureRunning ? t('action.cancel') : t('eq.capturePoint', done + 1), s.captureRunning ? 'xmark' : 'record.circle', 'capture', !!s.running,
      back + (!verifying && w.canComputeEQ ? quiet(t('eq.compute'), 'slider.horizontal.3', 'computeEQ') : ''));
    return scaffold(title, complete ? '' : t('eq.points.subtitle'), t('eq.points.info'), content, actions);
  }

  function targetMenu() {
    const cfg = W().config || {};
    const presets = ((D.st && D.st.targetPresets) || []).filter((p) => p !== 'custom');
    const cur = (cfg.target && cfg.target.preset) || 'livePA';
    const items = presets.map((p) => ({ label: t(`target.${p}`), act: 'targetPreset', arg: p, checked: p === cur }));
    items.push({ divider: true }, { label: t('target.editor') + '…', act: 'targetEditor' }, { divider: true }, { header: t('eq.grid.title') });
    for (const g of (D.st && D.st.grids) || []) items.push({ label: t(`eq.grid.${g}`), act: 'eqGrid', arg: g, checked: g === cfg.grid });
    items.push({ header: t('eq.pointCount.title') });
    for (let n = 3; n <= 9; n++) items.push({ label: String(n), act: 'eqPointCount', arg: n, checked: n === cfg.eqPointCount });
    return popup('target', t('eq.target') + ': ' + t(`target.${cur}`), items, { plain: true });
  }

  // MARK: step 7: EQ tuning

  function eqTuningStep() {
    const s = D.s || {}, w = W(), r = w.eqResult;
    const reading = s.eqTuner;
    let content = '';
    if (r) {
      let top;
      if (!r.filters.length) top = `<p class="t15 good">${esc(t('eq.nothingToDo'))}</p>`;
      else {
        const right = s.eqTunerReady ? bandGauge(r, reading) + overallLine(reading) : `<div class="glass start-tuner">${icon('tuningfork', 34)}
          ${s.eqReferenceCapturing ? `${spinner()}<span class="t13 secondary">${esc(t('tuner.waiting'))}</span>`
            : `${btn(t('eq.tune.start'), 'startEQTuner', { kind: 'primary', disabled: !s.running })}<span class="t12 muted">${esc(t('eq.tune.reference.short'))}</span>`}</div>`;
        top = `<div class="hstack top" style="gap:20px">${bandList(r, reading)}<div class="vstack grow" style="gap:14px">${right}</div></div>`;
      }
      content = `<div class="vstack" style="gap:22px">${top}<div class="vstack" style="gap:12px">
        ${isSim() ? collapsible('eqSim', t('vproc.title'), eqSimulationPanel(r)) : ''}
        ${collapsible('eqCurves', t('eq.curves'), X.comparisonPlot(r.frequencies, eqCurves(r, reading), r.workingRange, [20, 20000], true, 200))}</div></div>`;
    }
    const actions = actionRow(t(reading && reading.allInTune ? 'eq.tune.allSet' : 'eq.tune.entered'), 'checkmark', 'beginEQVerification', true,
      quiet(t('wizard.back'), 'chevron.left', 'eqBack') + quiet(t('export.copy'), 'doc.on.doc', 'copyExport'));
    return scaffold(t('eq.tune.title'), t('eq.tune.subtitle'), t('eq.tune.text'), content, actions);
  }

  function bandList(r, reading) {
    const rows = r.filters.map((fl, i) => {
      const b = reading && reading.bands.find((x) => x.index === i);
      return `<button class="band-row${U.band === i ? ' on' : ''}" data-act="band" data-arg="${i}">
        <span class="n">${i + 1}</span><span class="grp${fl.group === 'sub' ? ' sub' : ''}">${esc(t(fl.group === 'sub' ? 'group.subs.tag' : 'group.mains.tag'))}</span>
        <span class="fc">${esc(fl.label)}</span><span class="gain">${esc(f('%+.1f', fl.gainDB))}</span><span class="w">${esc(fl.width)}</span><span class="spacer"></span>
        <span class="led">${X.miniLED(b ? b.remaining / 6 : null, 0.5 / 6)}</span></button>`;
    }).join('');
    return `<div class="band-list-frame"><div class="glass band-list">${rows}</div></div>`;
  }

  function bandGauge(r, reading) {
    const i = Math.min(U.band, Math.max(r.filters.length - 1, 0));
    const fl = r.filters[i];
    if (!fl) return '';
    const b = reading && reading.bands.find((x) => x.index === i);
    let instruction;
    if (!b) instruction = t('tuner.waiting');
    else if (b.inTune) instruction = t('tuner.inTune');
    else if (Math.abs(b.remaining) <= 0.5) instruction = t('eq.band.shape');
    else instruction = t(b.remaining < 0 ? 'eq.band.cutMore' : 'eq.band.boostMore', Math.abs(b.remaining));
    return gauge({ title: t('eq.band.title', i + 1, fl.label), value: b ? b.remaining / 6 : null, tolerance: 0.5 / 6,
      readout: b ? f('%+.1f', b.remaining) : '—', instruction, reliable: !!(reading && reading.confidence >= 0.6),
      scaleLabels: ['−6', '', '0', '', '+6'], unit: 'dB' });
  }

  function overallLine(reading) {
    const e = reading ? reading.overall : null;
    const c = e == null ? 0 : e <= 0.75 ? 1 : Math.max(0, 1 - (e - 0.75) / 3);
    const color = e == null ? C.textMuted : UI.closeness(c);
    return `<div class="overall-line">${X.indicatorLamp(color, 14)}<span class="t12 secondary">${esc(t('eq.overall'))}</span>
      <span class="mono13 semibold" style="color:${color}">${esc(e == null ? '—' : f('±%.1f dB', e))}</span></div>`;
  }

  function eqCurves(r, reading) {
    const out = [{ label: t('curve.plan'), db: (reading && reading.planned) || r.filterResponseDB, color: C.dataBlue, dashed: true }];
    if (reading && reading.applied) out.push({ label: t('curve.entered'), db: reading.applied, color: UI.closeness(Math.max(0, 1 - (reading.overall - 0.75) / 3)) });
    return out;
  }

  function eqSimulationPanel(r) {
    const entered = ((D.s && D.s.simProcessor) || {}).entered || {};
    return `<div class="vstack6">${r.filters.map((fl, i) => {
      const e = entered[fl.id];
      return `<div class="row eq-sim-row"><span class="w140">${check(`${i + 1} · ${fl.label}`, e != null, 'simToggleBand', fl.id)}</span>
        ${e != null ? `${slider('simBand:' + fl.id, e, -12, 3, 0.5)}<span class="mono12 w64 center">${esc(f('%+.1f dB', e))}</span>` : ''}</div>`;
    }).join('')}</div>`;
  }

  // MARK: finished

  function finishedStep() {
    const w = W();
    const content = `<div class="vstack" style="gap:24px">${(w.cards || []).length ? chips() : ''}${eqResultGauges()}
      <div class="hstack center" style="gap:10px">${btn(t('report.pdf.short'), 'reportPDF', { kind: 'primary' })}${btn(t('report.png.short'), 'reportPNG')}
        ${btn(t('export.text.short'), 'exportText')}${btn('CSV', 'exportCSV')}${btn(t('session.save.short'), 'saveSession')}</div>
      ${collapsible('bands', t('eq.bands'), `<pre class="export-text">${esc((D.s && D.s.exportText) || '')}</pre>`)}</div>`;
    const actions = `<div class="hstack" style="gap:18px">${quiet(t('wizard.back'), 'chevron.left', 'back')}<span class="spacer"></span>${quiet(t('wizard.restart'), 'arrow.counterclockwise', 'restart')}</div>`;
    return scaffold(t('finished.title'), t('finished.subtitle'), null, content, actions);
  }

  // MARK: WizardView

  function stepView(step) {
    switch (step) {
      case 'preparation': return preparationStep();
      case 'baseline': case 'subOnly': case 'mainsOnly': return captureStep();
      case 'verification': return W().report ? alignmentCheckStep() : captureStep();
      case 'results': return resultsStep();
      case 'eqPoints': case 'eqVerification': return eqPointsStep();
      case 'eqTuning': return eqTuningStep();
      case 'finished': return finishedStep();
      default: return preparationStep();
    }
  }

  // MARK: expert: MeterPanel and ExpertGraphs

  function meterPanel() {
    const s = D.s || {}, l = D.live;
    const m = (x) => x || { rms: -120, peak: -120, clipped: false };
    let body = UI.meterBar(t('meters.mic'), m(l && l.mic).rms ?? -120, m(l && l.mic).peak ?? -120, m(l && l.mic).clipped, t('meters.clip'));
    if (s.referenceMode && s.referenceMode !== 'internalSignal') body += UI.meterBar(t('meters.ref'), m(l && l.ref).rms ?? -120, m(l && l.ref).peak ?? -120, m(l && l.ref).clipped, t('meters.clip'));
    const stat = (title, value) => `<div class="stat"><span>${esc(title)}</span><b>${esc(value)}</b></div>`;
    const coh = l ? l.coherence : null;
    let badge;
    if (coh == null) badge = UI.statusBadge('idle', t('quality.none'));
    else if (coh >= 0.8) badge = UI.statusBadge('good', t('quality.good'));
    else if (coh >= (s.coherenceThreshold ?? 0.6)) badge = UI.statusBadge('warning', t('quality.weak'));
    else badge = UI.statusBadge('error', t('quality.repeat'));
    body += '<div class="tech-divider"></div>';
    body += `<div class="stat-row">${stat(t('meters.coherence'), coh == null ? '—' : f('%.2f', coh))}${stat(t('meters.averages'), l && l.averages != null ? String(l.averages) : '—')}
      ${stat(t('meters.delay'), l ? f('%.2f ms', l.referenceDelayMs) : '—')}<span class="spacer"></span>${badge}</div>`;
    body += '<div class="tech-divider"></div>';
    const spl = l && l.spl;
    const unit = spl && spl.calibrated ? 'dB' : 'dBFS';
    const sv = (v) => (spl && v != null ? f('%.1f %@', v, unit) : '—');
    body += `<div class="stat-row">${stat('LAeq', sv(spl && spl.laeq))}${stat('LCeq', sv(spl && spl.lceq))}${stat('LCpeak', sv(spl && spl.lpeak))}${stat('LAFmax', sv(spl && spl.lmax))}
      <span class="spacer"></span>${spl && spl.calibrated ? '' : UI.statusBadge('idle', t('cal.spl.none'))}${btn(t('spl.reset'), 'resetSPL')}</div>`;
    return UI.panel(t('meters.title'), body, { cls: 'meter-panel' });
  }

  function expertGraphs() {
    const s = D.s || {};
    const sm = s.smoothing ?? 12;
    const marking = sm === 0 ? t('graphs.raw') : t('graphs.octave', sm);
    const g = D.live && D.live.graph;
    let body;
    if (!g) {
      body = `<div class="graphs-empty">${icon('waveform.path.ecg', 30)}<span>${esc(t('graphs.empty'))}</span></div>`;
    } else {
      const data = { f: freqs(), mag: g.mag, phase: g.phase, coh: g.coh };
      body = `<div class="graphs">${['magnitude', 'phase', 'coherence'].filter((k) => U.graphs.includes(k))
        .map((k) => X.transferPlot(k, data, s.coherenceThreshold ?? 0.6, t(`graph.${k}`), k === 'magnitude' ? 'flex:1 1 0' : 'flex:1 1 0;max-height:200px')).join('')}</div>`;
    }
    return UI.panel(t('graphs.title'), body, { marking, cls: 'expert-graphs' });
  }

  // MARK: sheets

  function settingsSheet() {
    return `<div class="sheet-scrim"><div class="sheet settings-sheet">
      <div class="sheet-head"><span class="heading17">${esc(t('settings.title'))}</span><span class="spacer"></span>${btn(t('settings.done'), 'closeSettings', { kind: 'primary' })}</div>
      <div class="sheet-body setup-sidebar">${setupSidebar(false)}</div></div></div>`;
  }

  function targetEditor() {
    const pts = U.target;
    const presets = ((D.st && D.st.targetPresets) || []).filter((p) => p !== 'custom');
    const preview = U.targetPreview;
    const rows = pts.map((p, i) => `<div class="te-row"><span class="mono12 n">${i + 1}</span>
      <input id="te-f-${i}" class="field mono12" data-change="teFreq" data-arg="${i}" value="${Math.round(p.frequency)}"><span class="t11 muted">Hz</span>
      <span class="mono12 gain">${esc(f('%+.1f dB', p.gainDB))}</span>${stepper('teGain:' + i)}<span class="spacer"></span>
      <button class="btn plain" data-act="teRemove" data-arg="${i}"${pts.length <= 2 ? ' disabled' : ''}>${icon('minus.circle', 14)}</button></div>`).join('');
    return `<div class="sheet-scrim"><div class="sheet target-editor">
      <h2>${esc(t('target.editor'))}</h2><p class="t12 secondary">${esc(t('target.editor.hint'))}</p>
      ${X.comparisonPlot(freqs(), [{ label: t('target.custom'), db: preview, color: C.dataBlue }], null, [20, 20000], true, 180)}
      <div class="te-rows">${rows}</div>
      <div class="row">${btn(t('target.addPoint'), 'teAdd')}${popup('teStart', t('target.startFrom'), presets.map((p) => ({ label: t(`target.${p}`), act: 'teStart', arg: p })), { cls: 'w180', menu: true })}
        <span class="spacer"></span>${btn(t('action.cancel'), 'teCancel')}${btn(t('cal.apply'), 'teApply', { kind: 'primary' })}</div></div></div>`;
  }

  // MARK: render

  function workspace() {
    if (U.mode === 'wizard') return `<div class="wizard">${stepView(W().step)}</div>`;
    return `<div class="expert">${meterPanel()}${expertGraphs()}</div>`;
  }

  function overlays() {
    let o = '';
    if (U.settings) o += settingsSheet();
    if (U.target) o += targetEditor();
    return o;
  }

  /** Single views as the Mac snapshot tests draw them (padding 16 on the backdrop, top-aligned). */
  const STANDALONE = {
    'step0-preparation': () => preparationStep(),
    'step4-tuner': () => resultsStep(),
    'step5-verify': () => alignmentCheckStep(),
    'step7-eq': () => eqTuningStep(),
    finished: () => finishedStep(),
    instruments: () => `<div class="hstack top equal" style="gap:16px">
      ${X.tunerGauge({ title: 'Задержка сабвуфера', value: 0.45, tolerance: 10 / 90, readout: '+1.25', instruction: 'Добавьте задержку сабвуферу', scaleLabels: ['−2.8', '−1.4', '0', '+1.4', '+2.8'], unit: 'мс' })}
      ${X.tunerGauge({ title: 'Задержка сабвуфера', value: 0.03, tolerance: 10 / 90, readout: '+0.08', instruction: 'В строю', scaleLabels: ['−2.8', '−1.4', '0', '+1.4', '+2.8'], unit: 'мс' })}
      ${X.tunerGauge({ title: 'Качество сигнала', value: 0.62, mode: 'oneSided', tolerance: 0.91, readout: '64', instruction: 'Слабо — тише или громче', scaleLabels: ['30', '44', '58', '71', '85'], unit: '%' })}</div>`,
    'mini-meters': () => `<div class="vstack lead" style="gap:10px">${X.polarityLamp(true)}${X.polarityLamp(false)}
      ${X.miniMeter(-0.7, 0.5 / 6, '−4.2 dB')}${X.miniMeter(-0.05, 0.5 / 6, '−0.3 dB')}${X.miniMeter(0.15, 0.5 / 6, '+0.9 dB')}</div>`,
  };

  function standalone() {
    let el = document.getElementById('setup-standalone');
    if (!U.standalone) { if (el) el.remove(); return; }
    if (U.standalone === 'report') {
      if (!el) { el = document.createElement('div'); el.id = 'setup-standalone'; el.className = 'report-host'; document.body.appendChild(el); }
      X.scope('sa');
      el.innerHTML = SSMT.setupReport.html(D);
      X.paint(el);
      return;
    }
    if (!el) { el = document.createElement('div'); el.id = 'setup-standalone'; document.body.appendChild(el); }
    X.scope('sa');
    el.innerHTML = `<div class="standalone-view">${STANDALONE[U.standalone]()}</div>`;
    X.paint(el);
  }

  SSMT.section({
    id: 'setup',
    topBar: () => topBar(),
    sidebar() {
      X.scope('sb');
      const html = sidebar();
      lastSidebar = html;
      return html;
    },
    render() {
      if (U.dragging) { deferred = true; return null; }
      if (lastError && !S.lastError) { lastError = null; cmd('dismissError'); }
      X.scope('pane');
      // The settings sheet and the target editor are drawn over the whole window by app.js (SSMT.setupOverlays).
      const html = workspace();
      if (html === lastHTML) return null;
      lastHTML = html;
      return html;
    },
    after(pane) {
      pane.classList.toggle('setup-pane', true);
      pane.classList.toggle('expert-mode', U.mode === 'expert');
      X.paint(pane);
      X.paint(document.getElementById('sidebar'));
      standalone();
    },
    keys(e) {
      if (U.standalone) return;
      if (e.code === 'Space') { e.preventDefault(); cmd('toggleNoise'); }
      else if (e.key === 'Enter' && U.mode === 'wizard') {
        const st = W().step;
        if (['baseline', 'subOnly', 'mainsOnly', 'verification', 'eqPoints', 'eqVerification'].includes(st) && !(st === 'verification' && W().report)) cmd('capture');
      } else if (e.key === 'Escape') { U.menu = null; U.info = null; U.procEdit = false; SSMT.render(); }
    },
    actions: {},
    inputs: {},
  });
  const sec = SSMT.sections.setup;

  // MARK: actions

  const A = sec.actions;
  const closeMenus = () => { U.menu = null; U.info = null; };
  const act = (fn) => (...a) => { closeMenus(); fn(...a); SSMT.render(); };

  A.menu = (id) => { U.info = null; U.menu = U.menu === id ? null : id; SSMT.render(); };
  A.info = (key) => { U.menu = null; U.info = U.info === key ? null : key; SSMT.render(); };
  A.collapse = (key) => { U.open[key] = !U.open[key]; SSMT.render(); };
  A.mode = act((m) => setMode(m));
  A.stageMode = act(() => { U.stage = !U.stage; store.set('setup.stage', U.stage ? '1' : '0'); });
  A.reduced = act(() => { U.reduced = !U.reduced; store.set('reducedEffects', U.reduced ? '1' : '0'); });
  A.settings = act(() => { U.settings = true; refreshDevices(); });
  A.closeSettings = act(() => { U.settings = false; });
  A.toggleNoise = act(() => cmd('toggleNoise'));
  A.stop = act(() => cmd('stop'));
  A.mini = act(() => { if (SSMT.api && SSMT.api.mini) SSMT.api.mini('toggle'); });

  // Source and devices
  A.splitSource = act(() => {
    if (U.source.kind === 'split') U.source = { kind: 'simulation' };
    else if (U.devices && U.devices.inputs.length && U.devices.outputs.length) U.source = { kind: 'split', input: U.devices.inputs[0].id, output: U.devices.outputs[0].id };
    sourceChanged();
  });
  A.iface = act((id) => { U.source = id ? { kind: 'device', id } : { kind: 'simulation' }; sourceChanged(); });
  A.inputDevice = act((id) => { U.source = Object.assign({}, U.source, { input: id }); sourceChanged(); });
  A.outputDevice = act((id) => { U.source = Object.assign({}, U.source, { output: id }); sourceChanged(); });
  A.chMic = act((v) => cmd('channels', { mic: Number(v) }));
  A.chOut = act((v) => cmd('channels', { out: Number(v) }));
  A.chRef = act((v) => cmd('channels', { ref: Number(v) }));
  A.refMode = act((v) => cmd('referenceMode', { value: v }));
  A.temperature = act((d) => cmd('temperature', { value: ((D.s && D.s.temperature) ?? 20) + Number(d) }));
  A.startEngine = act(() => startEngine());
  A.stopEngine = act(() => { cmd('stopEngine'); if (SSMT.audio) SSMT.audio.close('setup'); });
  A.refreshDevices = act(() => refreshDevices(true));

  // Generator
  A.noiseKind = act((v) => cmd('noise', { value: Number(v) }));
  A.autoLevel = act(() => cmd('autoLevel'));
  A.cancelAutoLevel = act(() => cmd('cancelAutoLevel'));
  A.findDelay = act(() => cmd('findDelay'));
  A.lockDelay = act(() => cmd('lockDelay'));

  // Calibration
  A.selectMic = act((id) => cmd('selectMic', id ? { id } : {}));
  A.removeMic = act((id) => cmd('removeMic', { id }));
  A.importMic = act(async () => {
    const api = SSMT.api;
    if (!api || !api.openFile) return;
    const paths = await api.openFile({ title: t('cal.import'), filters: [{ name: 'Calibration', extensions: ['txt', 'cal', 'frd', 'csv', 'mic'] }, { name: '*', extensions: ['*'] }] });
    if (!paths || !paths.length) return;
    try {
      const text = await api.readFile(paths[0]);
      cmd('importMic', { text, name: paths[0].split(/[\\/]/).pop() });
    } catch (e) { cmd('error', { text: String(e && e.message || e) }); }
  });
  A.splApply = act(() => cmd('splText', { text: U.splText }));
  A.calLevel = act((v) => { U.calLevel = Number(v); });
  A.calibrator = act(() => cmd('calibrator', { value: U.calLevel }));
  sec.inputs.splText = (v) => { U.splText = v; };

  // Simulation and display
  A.simSub = act(() => cmd('simSub', { value: !(D.s && D.s.simSub !== false) }));
  A.simMain = act(() => cmd('simMain', { value: !(D.s && D.s.simMain !== false) }));
  A.smoothing = act((v) => cmd('smoothing', { value: Number(v) }));
  A.graph = act((g) => { U.graphs = U.graphs.includes(g) ? U.graphs.filter((x) => x !== g) : [...U.graphs, g]; store.setJSON('setup.graphs', U.graphs); });
  A.resetAverages = act(() => cmd('resetAverages'));
  A.resetClips = act(() => cmd('resetClips'));
  A.resetSPL = act(() => cmd('resetSPL'));
  A.language = act((v) => {
    store.set('langChoice', v);
    const lang = v === 'system' ? ((navigator.language || 'ru').toLowerCase().startsWith('ru') ? 'ru' : 'en') : v;
    S.lang = lang; store.set('lang', lang); lastHTML = null;
    if (SSMT.profile) SSMT.profile.record('ui.language'); // Localizer.language set
  });
  sec.inputs.level = (v) => cmd('level', { value: Number(v) });
  sec.inputs.maxLevel = (v) => cmd('maxLevel', { value: Number(v) });
  sec.inputs.coherence = (v) => cmd('coherenceThreshold', { value: Number(v) });

  // Wizard configuration
  A.processor = act((id) => cmd('config', { processorPreset: id }));
  A.processorCustom = act(() => { cmd('config', { processorCustom: true }); U.procEdit = true; });
  A.processorEdit = act(() => { U.procEdit = !U.procEdit; });
  const procUpdate = (fn) => {
    const p = Object.assign({}, (W().config || {}).processor || {});
    fn(p);
    cmd('config', { processor: p });
  };
  A.procField = act((arg) => { const [k, v] = String(arg).split(':'); procUpdate((p) => { p[k] = Number(v); }); U.procEdit = true; });
  A.procMaxDelay = (v) => procUpdate((p) => { const x = Number(String(v).replace(',', '.')); p.maxDelayMs = x > 0 ? x : null; });
  A.procBandsSub = act((d) => { procUpdate((p) => { p.peqBandsSub = Math.min(16, Math.max(0, (p.peqBandsSub || 0) + Number(d))); }); U.procEdit = true; });
  A.procBandsMains = act((d) => { procUpdate((p) => { p.peqBandsMains = Math.min(16, Math.max(0, (p.peqBandsMains || 0) + Number(d))); }); U.procEdit = true; });
  A.procOctaves = act(() => { procUpdate((p) => { p.bandwidthInOctaves = !p.bandwidthInOctaves; }); U.procEdit = true; });
  A.cfgToggle = act((k) => {
    const cfg = W().config || {};
    if (k === 'knownCrossover') cmd('config', { knownCrossover: cfg.crossover == null });
    else cmd('config', { [k]: !cfg[k] });
  });
  A.crossover = act((d) => { const fc = (W().config || {}).crossover; if (fc != null) cmd('config', { crossover: Math.min(250, Math.max(40, fc + 5 * Number(d))) }); });
  A.delayStep = act((v) => cmd('config', { delayStep: Number(v) }));
  A.levelStep = act((v) => cmd('config', { levelStep: Number(v) }));
  A.targetPreset = act((p) => cmd('config', { targetPreset: p }));
  A.eqGrid = act((g) => cmd('config', { grid: g }));
  A.eqPointCount = act((n) => cmd('config', { eqPointCount: Number(n) }));

  // Wizard steps
  A.wizardStart = act(() => cmd('wizardStart'));
  A.capture = act(() => cmd('capture'));
  A.back = act(() => cmd('back'));
  A.restart = act(() => cmd('restart'));
  A.beginVerification = act(() => cmd('beginVerification'));
  A.tunerAdvance = act(() => cmd('tunerAdvance'));
  A.beginEQ = act(() => cmd('beginEQ'));
  A.simGroups = act(() => cmd('simGroups'));
  A.simApply = act(() => cmd('simApply'));
  A.simMovePoint = act(() => cmd('simMovePoint'));
  A.computeEQ = act(() => cmd('computeEQ'));
  A.iterateEQ = act(() => cmd('iterateEQ'));
  A.finish = act(() => cmd('finish'));
  A.startEQTuner = act(() => cmd('startEQTuner'));
  A.beginEQVerification = act(() => cmd('beginEQVerification'));
  A.eqBack = act(() => { cmd('stopEQTuner'); cmd('back'); });
  A.band = act((i) => { U.band = Number(i); });
  A.copyExport = act(() => { try { navigator.clipboard.writeText((D.s && D.s.exportText) || ''); } catch (_) { /* no clipboard */ } });
  A.vprocPolarity = act(() => cmd('simProcessor', { subPolarityInverted: !((D.s && D.s.simProcessor) || {}).subPolarityInverted }));
  A.simToggleBand = act((id) => cmd('simToggleBand', { id: Number(id) }));
  // Steppers of the virtual processor carry "vprocStep:<field>:<step>" as their action.
  const vprocStep = (field, step, dir) => {
    const p = (D.s && D.s.simProcessor) || {};
    const lim = { subDelayMs: [0, 20], mainsDelayMs: [0, 20], subGainDB: [-12, 6] }[field];
    const v = Math.min(lim[1], Math.max(lim[0], Math.round(((p[field] || 0) + step * dir) / step) * step));
    cmd('simProcessor', { [field]: v });
  };

  // Target editor
  A.targetEditor = act(() => {
    const cfg = W().config || {};
    const cur = cfg.target || {};
    U.target = (cur.preset === 'custom' ? cur.points : (D.st && D.st.targets && D.st.targets[cur.preset])) || [];
    U.target = U.target.map((p) => ({ frequency: p.frequency, gainDB: p.gainDB }));
    previewTarget();
  });
  const previewTarget = () => { U.targetPreview = null; cmd('targetPreview', { points: [...U.target].sort((a, b) => a.frequency - b.frequency) }); };
  A.teFreq = (v, el) => { const i = Number(el.dataset.arg); const x = Number(String(v).replace(',', '.')); if (Number.isFinite(x)) { U.target[i].frequency = Math.min(Math.max(x, 10), 24000); previewTarget(); } SSMT.render(); };
  A.teRemove = act((i) => { if (U.target.length > 2) { U.target.splice(Number(i), 1); previewTarget(); } });
  A.teAdd = act(() => { const last = U.target[U.target.length - 1]; U.target.push({ frequency: Math.min((last ? last.frequency : 1000) * 2, 20000), gainDB: last ? last.gainDB : 0 }); previewTarget(); });
  A.teStart = act((p) => { U.target = ((D.st && D.st.targets && D.st.targets[p]) || []).map((x) => ({ frequency: x.frequency, gainDB: x.gainDB })); previewTarget(); });
  A.teCancel = act(() => { U.target = null; });
  A.teApply = act(() => {
    cmd('config', { targetPoints: [...U.target].sort((a, b) => a.frequency - b.frequency), targetName: t('target.custom') });
    U.target = null;
  });

  // Session, report and exports
  A.saveSession = act(async () => {
    const api = SSMT.api;
    if (!api || !api.saveFile) return;
    const p = await api.saveFile({ defaultName: 'SSMT-session.ssmtsession', filters: [{ name: 'SSMT session', extensions: ['ssmtsession'] }] });
    if (p) cmd('saveSession', { path: p, appVersion: await api.version() });
  });
  A.openSession = act(async () => {
    const api = SSMT.api;
    if (!api || !api.openFile) return;
    const paths = await api.openFile({ filters: [{ name: 'SSMT session', extensions: ['ssmtsession', 'json'] }] });
    if (paths && paths.length) cmd('openSession', { path: paths[0] });
  });
  A.exportText = act(() => saveExport(false));
  A.exportCSV = act(() => saveExport(true));
  async function saveExport(csv) {
    const api = SSMT.api;
    if (!api || !api.saveFile) return;
    const p = await api.saveFile({ defaultName: csv ? 'SSMT-filters.csv' : 'SSMT-filters.txt', filters: [{ name: csv ? 'CSV' : 'Text', extensions: [csv ? 'csv' : 'txt'] }] });
    if (p) cmd('saveExport', { path: p, csv });
  }
  A.reportPDF = act(() => SSMT.setupReport && SSMT.setupReport.export(D, true));
  A.reportPNG = act(() => SSMT.setupReport && SSMT.setupReport.export(D, false));

  // Generic dispatch for actions carrying a field in their name ("teGain:3", "vprocStep:subDelayMs:0.01").
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-act]');
    if (!el || el.disabled || !el.closest('#pane-setup, #sidebar, #app-overlay')) return;
    const a = el.dataset.act;
    if (a.startsWith('teGain:')) {
      const i = Number(a.slice(7));
      U.target[i].gainDB = Math.min(12, Math.max(-12, U.target[i].gainDB + 0.5 * Number(el.dataset.arg)));
      previewTarget(); SSMT.render();
    } else if (a.startsWith('vprocStep:')) {
      const [, field, step] = a.split(':');
      vprocStep(field, Number(step), Number(el.dataset.arg));
    }
  });
  // Sliders with a field in their key.
  document.addEventListener('input', (e) => {
    const k = e.target.dataset && e.target.dataset.input;
    if (!k || !e.target.closest('#pane-setup, #sidebar, #app-overlay')) return;
    if (k.startsWith('vproc:')) {
      const field = k.slice(6);
      const step = field === 'subGainDB' ? 0.5 : 0.01;
      cmd('simProcessor', { [field]: Math.round(Number(e.target.value) / step) * step });
    } else if (k.startsWith('simBand:')) {
      cmd('simBandGain', { id: Number(k.slice(8)), value: Math.round(Number(e.target.value) * 2) / 2 });
    }
  });
  // No redraw while a slider is held: the redraw would take it from under the pointer.
  document.addEventListener('pointerdown', (e) => {
    if (e.target.matches && e.target.matches('input[type=range]')) U.dragging = true;
    // A click outside an open menu or popover closes it.
    if ((U.menu || U.info) && !e.target.closest('.popup-wrap')) { closeMenus(); SSMT.render(); }
    if (U.procEdit && !e.target.closest('.proc-wrap')) { U.procEdit = false; SSMT.render(); }
  }, true);
  document.addEventListener('pointerup', () => {
    if (!U.dragging) return;
    U.dragging = false;
    if (deferred) { deferred = false; SSMT.render(); }
  }, true);

  // MARK: sound card

  async function refreshDevices(force) {
    if (!SSMT.audio || (SSMT.api && SSMT.api.preview && !force)) return;
    try {
      U.devices = await SSMT.audio.devices();
      U.permissionDenied = false;
    } catch (e) {
      U.permissionDenied = e && e.name === 'NotAllowedError';
    }
    await probeChannels();
    SSMT.render();
  }

  async function probeChannels() {
    const d = sourceDescription();
    if (!d || !SSMT.audio) { U.chan = { in: 0, out: 0 }; return; }
    const r = await SSMT.audio.probe(d.input, d.output);
    U.chan = { in: r.inChannels, out: r.outChannels };
  }

  function sourceChanged() {
    store.setJSON('setup.source', U.source);
    const d = sourceDescription();
    cmd('source', d ? { kind: 'stream', name: d.name } : { kind: 'simulation' });
    probeChannels().then(() => SSMT.render());
  }

  async function startEngine() {
    const s = D.s || {};
    const d = sourceDescription();
    if (!d) { cmd('startEngine', { kind: 'simulation' }); return; }
    const ch = s.channels || { mic: 0, ref: 1, out: 0 };
    U.starting = true;
    try {
      await SSMT.audio.open('setup', { inputId: d.input, outputId: d.output, inChannels: U.chan.in || 2, outChannels: U.chan.out || 2, sampleRate: 48000, loopChannel: ch.out });
      cmd('startEngine', { kind: 'stream', name: d.name, mic: ch.mic, ref: ch.ref, out: ch.out, split: U.source.kind === 'split' });
    } catch (e) {
      if (e && e.name === 'NotAllowedError') U.permissionDenied = true;
      cmd('error', { text: String((e && e.message) || e) });
    } finally {
      U.starting = false;
      SSMT.render();
    }
  }
  if (U.source.kind !== 'simulation') refreshDevices().then(() => { const d = sourceDescription(); if (d) cmd('source', { kind: 'stream', name: d.name }); });

  // MARK: shared with the other screens

  /** The setup TopBar, which the Mac also shows above Ptch (inputList). */
  SSMT.setupTopBar = () => topBar();
  /** The setup sheets (settings, target editor), which the Mac shows over the whole window. */
  SSMT.setupOverlays = () => { X.scope('ov'); return overlays(); };
  SSMT.setupPaint = (el) => X.paint(el);
  /** Draws one view on its own, as the Mac snapshot tests do (parity checks). Null returns to the window. */
  SSMT.setupStandalone = (name) => { U.standalone = name; lastHTML = null; SSMT.render(); };
  SSMT.setupData = D;
  SSMT.setupUI = U;
})();
