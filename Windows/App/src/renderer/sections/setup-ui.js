'use strict';
/* global SSMT */
// Instruments and plots of the system setup, one-to-one copies of the Mac views:
//   TunerGauge, ArcGeometry, ArcScale (Views/Wizard/TunerGauge.swift), IndicatorLamp, MiniMeter, MiniLED,
//   PolarityLamp, LevelStrip, ValueChip, Collapsible, HazardNotice, WizardPrimaryButton, QuietButton,
//   TransferPlotView, ComparisonPlotView, FrequencyAxis (Graphs/), MicCurvePreview, PointMap, MiniCurve.
// Markup is built as strings; the drawn parts are <canvas data-draw="…"> filled by `SetupUI.paint(root)` after
// the markup is in the page, as SwiftUI's Canvas draws once the layout is known.

(function () {
  const { esc, icon, t } = SSMT;
  const closeness = (c) => SSMT.UI.closeness(c);
  const C = {
    textPrimary: '#F3F6F4', textSecondary: '#939C96', textMuted: '#5F6862', accent: '#2EE59D', accentHot: '#10A86E',
    dataSecondary: '#A7F3D0', dataBlue: '#64D2FF', statusGood: '#34D399', signalYellow: '#FFD60A', statusError: '#FF453A',
    panel: '#121513',
  };
  const rgba = (hex, a) => {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
  };
  const withAlpha = (color, a) => (color.startsWith('#') ? rgba(color, a) : color.replace('rgb(', 'rgba(').replace(')', `,${a})`));
  const fmt = (f, v) => SSMT.format(f, v);
  const store = new Map();   // canvas id → drawing spec
  let nextId = 1;

  /** A canvas whose drawing is `spec` ({kind, …}); painted by `paint`. */
  function canvas(spec, style = '') {
    const id = 'cv' + (nextId++);
    store.set(id, spec);
    return `<canvas class="ssmt-canvas" data-draw="${id}" style="${style}"></canvas>`;
  }

  function prepare(cv) {
    const r = cv.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(r.width)), h = Math.max(1, Math.round(r.height));
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    const g = cv.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    return { g, w, h };
  }

  const PAINTERS = {};
  function paint(root) {
    const used = new Set();
    for (const cv of (root || document).querySelectorAll('canvas[data-draw]')) {
      const spec = store.get(cv.dataset.draw);
      used.add(cv.dataset.draw);
      if (spec && PAINTERS[spec.kind]) PAINTERS[spec.kind](cv, spec);
    }
    // Specs of canvases no longer in the page are dropped.
    if (store.size > 400) for (const k of [...store.keys()]) if (!used.has(k) && !document.querySelector(`canvas[data-draw="${k}"]`)) store.delete(k);
  }

  function text(g, s, x, y, { size = 10, weight = 400, color = C.textMuted, align = 'center', base = 'middle' } = {}) {
    g.font = `${weight} ${size}px Inter, 'Segoe UI', sans-serif`;
    g.fillStyle = color;
    g.textAlign = align;
    g.textBaseline = base;
    g.fillText(s, x, y);
  }

  // MARK: FrequencyAxis

  const axis = (min = 20, max = 20000) => ({ min, max, x: (f, width) => Math.log10(f / min) / Math.log10(max / min) * width });
  const MAJOR = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
  const MINOR = [30, 40, 60, 70, 80, 90, 300, 400, 600, 700, 800, 900, 3000, 4000, 6000, 7000, 8000, 9000];
  const fLabel = (f) => (f >= 1000 ? `${Math.trunc(f / 1000)}k` : `${Math.trunc(f)}`);
  const signedInt = (v) => (v > 0 ? '+' : v < 0 ? '-' : '+') + Math.abs(Math.round(v));

  // MARK: TunerGauge

  /** Arc layout: a 120° arc around the top of a circle whose centre lies below the readout. */
  function arcGeometry(w, h, large) {
    const span = 60, lw = large ? 7 : 5;
    const s = Math.sin(span * Math.PI / 180), c = Math.cos(span * Math.PI / 180);
    const radius = Math.max(40, Math.min((w - 48) / (2 * s), (h - 26) / (1 - c)));
    const center = { x: w / 2, y: 10 + radius };
    const angle = (p) => (-90 + p * span) * Math.PI / 180;
    const point = (p, r) => ({ x: center.x + r * Math.cos(angle(p)), y: center.y + r * Math.sin(angle(p)) });
    return { lw, radius, center, angle, point, large };
  }

  function gaugeState(o) {
    const centered = o.mode !== 'oneSided';
    const has = o.value != null && Number.isFinite(o.value);
    const v = has ? (centered ? Math.min(Math.max(o.value, -1), 1) : Math.min(Math.max(o.value, 0), 1)) : 0;
    const position = centered ? v : v * 2 - 1;
    const cl = (p) => {
      if (centered) { const a = Math.abs(p); return a <= o.tolerance ? 1 : Math.max(0, 1 - (a - o.tolerance) / Math.max(1 - o.tolerance, 1e-6)); }
      const x = (p + 1) / 2;
      return x >= o.tolerance ? 1 : x / Math.max(o.tolerance, 1e-6);
    };
    const close = o.value == null ? 0 : cl(position);
    const color = o.value == null ? C.textMuted : closeness(close);
    const zone = centered ? [-o.tolerance, o.tolerance] : [o.tolerance * 2 - 1, 1];
    const origin = centered ? 0 : -1;
    const labels = o.scaleLabels && o.scaleLabels.length === 5 ? [o.scaleLabels[0], o.scaleLabels[2], o.scaleLabels[4]] : (centered ? ['−', '0', '+'] : ['', '', '']);
    return { has: o.value != null, position, close, color, zone, origin, labels, inTune: o.value != null && close >= 1 };
  }

  /**
   * TunerGauge(title:value:mode:tolerance:readout:instruction:reliable:large:scaleLabels:unit:).
   * mode 'centered' (−1…1, target 0) or 'oneSided' (0…1, target on the right).
   */
  function tunerGauge(o) {
    const st = gaugeState(o);
    const large = !!o.large;
    return `<div class="glass tuner-gauge${large ? ' large' : ''}">
      <div class="tg-title">${esc(o.title)}</div>
      ${canvas({ kind: 'gauge', o, st }, `height:${large ? 214 : 158}px;opacity:${o.reliable === false ? 0.5 : 1}`)}
      <div class="tg-instruction" style="color:${st.has ? st.color : C.textMuted}">${st.inTune ? icon('checkmark.circle.fill', large ? 18 : 15) : ''}<span>${esc(o.instruction)}</span></div>
    </div>`;
  }

  PAINTERS.gauge = (cv, { o, st }) => {
    const { g, w, h } = prepare(cv);
    const a = arcGeometry(w, h, !!o.large);
    const arc = (from, to, color) => {
      g.beginPath();
      g.arc(a.center.x, a.center.y, a.radius, a.angle(from), a.angle(to), false);
      g.strokeStyle = color; g.lineWidth = a.lw; g.lineCap = 'round'; g.stroke();
    };
    arc(-1, 1, 'rgba(255,255,255,0.09)');
    arc(Math.max(-1, st.zone[0]), Math.min(1, st.zone[1]), rgba(C.statusGood, 0.28));
    for (let i = -10; i <= 10; i++) {
      const p = i / 10, major = i === 0 || Math.abs(i) === 10;
      const p0 = a.point(p, a.radius - a.lw - (major ? 12 : 7)), p1 = a.point(p, a.radius - a.lw - 3);
      g.beginPath(); g.moveTo(p0.x, p0.y); g.lineTo(p1.x, p1.y);
      g.strokeStyle = `rgba(255,255,255,${major ? 0.45 : 0.16})`; g.lineWidth = 1; g.lineCap = 'butt'; g.stroke();
    }
    st.labels.forEach((label, k) => {
      if (!label) return;
      const p = a.point(k - 1, a.radius - a.lw - (k === 1 ? 24 : 22));
      text(g, label, p.x, p.y, { size: o.large ? 12 : 11 });
    });
    if (st.has) {
      const lo = Math.min(st.origin, st.position), hi = Math.max(st.origin, st.position);
      if (hi - lo > 0.001) arc(lo, hi, st.color);
      const c = a.point(st.position, a.radius), r = a.lw * 1.6;
      g.save();
      g.shadowColor = withAlpha(st.color, 0.35); g.shadowBlur = 12;
      g.beginPath(); g.arc(c.x, c.y, r, 0, Math.PI * 2); g.fillStyle = st.color; g.fill();
      g.restore();
      g.beginPath(); g.arc(c.x, c.y, r, 0, Math.PI * 2); g.strokeStyle = '#131715'; g.lineWidth = a.lw * 0.6; g.stroke();
    }
    // Readout and unit, centred at (cx, cy − 0.6 r + 24) within a frame r·1.3 wide.
    const cx = a.center.x, cy = a.center.y - a.radius * 0.6 + (o.large ? 30 : 24);
    const big = o.large ? 54 : 42, small = o.large ? 14 : 12;
    const lineBig = big * 1.19, lineSmall = small * 1.19;
    const hasUnit = !!o.unit;
    const total = lineBig + (hasUnit ? 2 + lineSmall : 0);
    let size = big;
    g.font = `300 ${size}px Inter, 'Segoe UI', sans-serif`;
    const maxW = a.radius * 1.3;
    const tw = g.measureText(o.readout).width;
    if (tw > maxW) size = Math.max(big * 0.5, size * maxW / tw);
    text(g, o.readout, cx, cy - total / 2 + lineBig / 2 + 1, { size, weight: 300, color: st.has ? C.textPrimary : C.textMuted });
    if (hasUnit) text(g, o.unit, cx, cy + total / 2 - lineSmall / 2, { size: small, color: C.textMuted });
  };

  // MARK: small instruments

  const indicatorLamp = (color, size) => `<span class="indicator-lamp" style="width:${size}px;height:${size}px"><i style="width:${size * 0.5}px;height:${size * 0.5}px;background:${color}"></i></span>`;

  function miniMeter(value, tolerance, readout, width = 120) {
    const cl = (p) => { const a = Math.abs(p); return a <= tolerance ? 1 : Math.max(0, 1 - (a - tolerance) / Math.max(1 - tolerance, 1e-6)); };
    const v = Math.min(Math.max(value == null ? 0 : value, -1), 1);
    const color = value == null ? C.textMuted : closeness(cl(v));
    const x = (v + 1) / 2 * width, mid = width / 2;
    return `<div class="mini-meter"><div class="mm-track" style="width:${width}px">
        <i style="left:0;width:${width}px;background:rgba(255,255,255,0.09)"></i>
        <i style="left:${mid - width * tolerance / 2}px;width:${Math.max(3, width * tolerance)}px;background:${rgba(C.statusGood, 0.3)}"></i>
        ${value != null ? `<i style="left:${Math.min(x, mid)}px;width:${Math.abs(x - mid)}px;background:${color}"></i><b style="left:${x - 4.5}px;background:${color}"></b>` : ''}
      </div><span class="mm-readout" style="color:${value == null ? C.textMuted : C.textPrimary}">${esc(readout)}</span></div>`;
  }

  function miniLED(value, tolerance) {
    const v = Math.min(Math.max(value == null ? 0 : value, -1), 1), a = Math.abs(v);
    const c = a <= tolerance ? 1 : Math.max(0, 1 - (a - tolerance) / (1 - tolerance));
    return `<div class="mini-led"><i class="track"></i><i class="zone" style="left:${50 - tolerance * 50}%;width:max(2px,${tolerance * 100}%)"></i>
      ${value != null ? `<b style="left:calc(${(v + 1) / 2 * 100}% - 3.5px);background:${closeness(c)}"></b>` : ''}</div>`;
  }

  /** PolarityLamp: true = wrong (switch), false = correct, null = waiting. */
  function polarityLamp(wrong, large = false) {
    const color = wrong === true ? closeness(0) : wrong === false ? C.statusGood : C.textMuted;
    const ic = wrong === true ? 'arrow.triangle.2.circlepath' : wrong === false ? 'checkmark.circle.fill' : 'circle.dashed';
    const label = wrong === true ? t('tuner.polarity.switch') : wrong === false ? t('tuner.polarity.ok') : t('tuner.waiting');
    return `<div class="glass polarity-lamp${large ? ' large' : ''}">
      <span class="pl-icon${wrong === true ? ' blink' : ''}" style="color:${color}">${icon(ic, large ? 26 : 22)}</span>
      <div class="pl-text"><span>${esc(t('card.polarity'))}</span><b style="color:${color}">${esc(label)}</b></div>
      <span class="pl-value">${wrong === true ? '180°' : wrong === false ? '0°' : '—'}</span>
    </div>`;
  }

  /** LevelStrip: 18 segments, −70…0 dBFS, with the value. */
  function levelStrip(dbfs, clipped, segments = 18) {
    const x = dbfs == null ? 0 : Math.min(1, Math.max(0, (dbfs + 70) / 70));
    let segs = '';
    for (let i = 0; i < segments; i++) {
      const p = (i + 0.5) / segments;
      const c = p <= x ? (clipped || p > 0.92 ? C.statusError : p > 0.75 ? C.signalYellow : C.statusGood) : 'rgba(255,255,255,0.10)';
      segs += `<i style="background:${c}"></i>`;
    }
    return `<div class="level-strip"><span class="segs">${segs}</span><span class="value">${dbfs == null ? '—' : fmt('%.0f dB', dbfs)}</span></div>`;
  }

  const valueChip = (label, value) => `<div class="glass value-chip"><b>${esc(value)}</b><span>${esc(label)}</span></div>`;

  const hazardNotice = (txt, color = C.signalYellow) => `<div class="hazard-notice" style="background:${rgba(color, 0.10)}">
    <span style="color:${color}">${icon('exclamationmark.triangle.fill', 13)}</span><span class="text">${esc(txt)}</span></div>`;

  /** Collapsible: closed by default; `open` and `act`/`arg` wire the toggle to the section's state. */
  const collapsible = (title, open, act, arg, body) => `<div class="glass collapsible">
    <button class="cl-head" data-act="${act}" data-arg="${esc(arg)}"><span class="chev${open ? ' open' : ''}">${icon('chevron.right', 13)}</span><span>${esc(title)}</span></button>
    ${open ? `<div class="cl-body">${body}</div>` : ''}</div>`;

  const quietButton = (title, ic, act, arg) => `<button class="quiet-button" data-act="${act}"${arg != null ? ` data-arg="${esc(arg)}"` : ''}>${ic ? icon(ic, 14) : ''}<span>${esc(title)}</span></button>`;

  function wizardPrimaryButton(title, ic, act, enabled = true) {
    return `<button class="wizard-primary${enabled ? '' : ' disabled'}" data-act="${act}"${enabled ? '' : ' disabled'}>
      <span class="wp-label">${icon(ic, 17)}<span>${esc(title)}</span></span><span class="wp-arrow">${icon('arrow.right', 16)}</span></button>`;
  }

  const actionRow = (title, ic, act, enabled, secondary) => `<div class="action-row">${secondary || ''}${wizardPrimaryButton(title, ic, act, enabled)}</div>`;

  // MARK: TransferPlotView

  /** kind 'magnitude' | 'phase' | 'coherence'; data {f, mag, phase, coh} on one grid; null = invalid point. */
  function transferPlot(kind, data, threshold, title, style) {
    return `<div class="transfer-plot" style="${style || ''}">${canvas({ kind: 'transfer', plot: kind, data, threshold })}<span class="tp-title">${esc(title)}</span></div>`;
  }

  PAINTERS.transfer = (cv, { plot: kind, data, threshold }) => {
    const { g, w, h } = prepare(cv);
    const P = { x: 40, y: 6, w: w - 48, h: h - 22 };
    const ax = axis();
    const range = kind === 'magnitude' ? [-30, 18] : kind === 'phase' ? [-180, 180] : [0, 1];
    const gridV = kind === 'magnitude' ? [-24, -18, -12, -6, 0, 6, 12] : kind === 'phase' ? [-180, -90, 0, 90, 180] : [0, 0.25, 0.5, 0.75, 1];
    const y = (v) => P.y + P.h - Math.min(Math.max((v - range[0]) / (range[1] - range[0]), 0), 1) * P.h;
    const vline = (x, a) => { g.beginPath(); g.moveTo(x, P.y); g.lineTo(x, P.y + P.h); g.strokeStyle = `rgba(255,255,255,${a})`; g.lineWidth = 1; g.stroke(); };
    for (const f of MINOR) vline(P.x + ax.x(f, P.w), 0.04);
    for (const f of MAJOR) { const x = P.x + ax.x(f, P.w); vline(x, 0.10); text(g, fLabel(f), x, P.y + P.h + 9); }
    for (const v of gridV) {
      const yy = y(v);
      g.beginPath(); g.moveTo(P.x, yy); g.lineTo(P.x + P.w, yy);
      g.strokeStyle = `rgba(255,255,255,${v === 0 && kind !== 'coherence' ? 0.18 : 0.07})`; g.lineWidth = 1; g.stroke();
      text(g, kind === 'coherence' ? v.toFixed(2) : signedInt(v), P.x - 18, yy);
    }
    if (kind === 'coherence') {
      const yy = y(threshold);
      g.save(); g.setLineDash([4, 4]); g.beginPath(); g.moveTo(P.x, yy); g.lineTo(P.x + P.w, yy);
      g.strokeStyle = rgba(C.signalYellow, 0.6); g.lineWidth = 1; g.stroke(); g.restore();
    }
    if (!data) return;
    const f = data.f, n = f.length;
    const valid = (i) => data.mag[i] != null && data.phase[i] != null && data.coh[i] != null;
    const mask = data.coh.map((c) => c != null && c >= threshold);
    if (kind !== 'coherence') {
      // Hatch the columns below the coherence threshold.
      g.save();
      g.beginPath();
      let any = false;
      for (let i = 0; i < n;) {
        if (mask[i]) { i++; continue; }
        const s = i;
        while (i < n && !mask[i]) i++;
        const f0 = f[s] / Math.pow(2, 1 / 48), f1 = f[i - 1] * Math.pow(2, 1 / 48);
        const x0 = P.x + ax.x(Math.max(f0, ax.min), P.w), x1 = P.x + ax.x(Math.min(f1, ax.max), P.w);
        g.rect(x0, P.y, Math.max(1, x1 - x0), P.h);
        any = true;
      }
      if (any) {
        g.clip();
        g.fillStyle = 'rgba(255,255,255,0.025)'; g.fillRect(P.x, P.y, P.w, P.h);
        g.beginPath();
        for (let x = P.x - P.h; x < P.x + P.w; x += 7) { g.moveTo(x, P.y + P.h); g.lineTo(x + P.h, P.y); }
        g.strokeStyle = 'rgba(255,255,255,0.07)'; g.lineWidth = 1; g.stroke();
      }
      g.restore();
    }
    // Magnitude normalised so the median of coherent points in 100 Hz – 10 kHz sits at 0 dB.
    let offset = 0;
    if (kind === 'magnitude') {
      const vals = [];
      for (let i = 0; i < n; i++) if (f[i] >= 100 && f[i] <= 10000 && mask[i] && valid(i)) vals.push(data.mag[i]);
      vals.sort((a, b) => a - b);
      offset = vals.length ? vals[Math.floor(vals.length / 2)] : 0;
    }
    const good = new Path2D(), weak = new Path2D();
    let last = null, lastV = null, lastGood = false;
    for (let i = 0; i < n; i++) {
      const fi = f[i];
      const v = !valid(i) ? null : kind === 'magnitude' ? data.mag[i] - offset : kind === 'phase' ? data.phase[i] : data.coh[i];
      if (fi < ax.min || fi > ax.max || v == null) { last = null; continue; }
      const p = { x: P.x + ax.x(fi, P.w), y: y(v) };
      const isGood = mask[i] || kind === 'coherence';
      const wrapped = kind === 'phase' && lastV != null && Math.abs(v - lastV) > 180;
      if (last && !wrapped) { const path = isGood && lastGood ? good : weak; path.moveTo(last.x, last.y); path.lineTo(p.x, p.y); }
      last = p; lastV = v; lastGood = isGood;
    }
    g.lineCap = 'round'; g.lineJoin = 'round';
    g.strokeStyle = rgba(C.textMuted, 0.6); g.lineWidth = 1.6 * 0.8; g.stroke(weak);
    g.strokeStyle = kind === 'coherence' ? C.dataSecondary : C.accent; g.lineWidth = 1.6; g.stroke(good);
  };

  // MARK: ComparisonPlotView

  /**
   * curves [{label, db (array on f), color, dashed}], already smoothed as on the Mac (the engine smooths at 1/6 octave
   * for relative plots; absolute plots are drawn as they are). band [lo, hi] or null; range [lo, hi].
   */
  function comparisonPlot(f, curves, band, range = [20, 1000], absolute = false, height = 220) {
    const legend = curves.map((c) => `<span class="cp-key"><i style="background:${c.color}"></i>${esc(c.label)}</span>`).join('');
    return `<div class="comparison-plot" style="height:${height}px">${canvas({ kind: 'comparison', f, curves, band, range, absolute })}<div class="cp-legend">${legend}</div></div>`;
  }

  PAINTERS.comparison = (cv, { f, curves, band, range, absolute }) => {
    const { g, w, h } = prepare(cv);
    const P = { x: 36, y: 6, w: w - 42, h: h - 22 };
    const ax = axis(range[0], range[1]);
    const inRange = (x) => x >= range[0] && x <= range[1];
    let ref = 0;
    if (!absolute && curves[0] && curves[0].db) {
      const v = [];
      curves[0].db.forEach((d, i) => { if (d != null && inRange(f[i])) v.push(d); });
      v.sort((a, b) => a - b);
      ref = v.length ? v[Math.floor(v.length / 2)] : 0;
    }
    const y = (db) => {
      const tt = absolute ? (db - ref + 15) / 24 : (db - ref + 24) / 36;
      return P.y + P.h - Math.min(Math.max(tt, 0), 1) * P.h;
    };
    if (band) {
      const x0 = P.x + ax.x(Math.max(band[0], range[0]), P.w), x1 = P.x + ax.x(Math.min(band[1], range[1]), P.w);
      g.fillStyle = rgba(C.accent, 0.07); g.fillRect(x0, P.y, x1 - x0, P.h);
    }
    for (const fr of [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) {
      if (!inRange(fr)) continue;
      const x = P.x + ax.x(fr, P.w);
      g.beginPath(); g.moveTo(x, P.y); g.lineTo(x, P.y + P.h); g.strokeStyle = 'rgba(255,255,255,0.08)'; g.lineWidth = 1; g.stroke();
      text(g, fLabel(fr), x, P.y + P.h + 9);
    }
    for (let db = absolute ? -12 : -18; db <= (absolute ? 6 : 12); db += absolute ? 3 : 6) {
      const yy = y(ref + db);
      g.beginPath(); g.moveTo(P.x, yy); g.lineTo(P.x + P.w, yy);
      g.strokeStyle = `rgba(255,255,255,${db === 0 ? 0.16 : 0.06})`; g.lineWidth = 1; g.stroke();
      text(g, signedInt(db), P.x - 16, yy);
    }
    for (const c of curves) {
      if (!c.db) continue;
      g.beginPath();
      let started = false;
      c.db.forEach((d, i) => {
        if (d == null || !inRange(f[i])) return;
        const x = P.x + ax.x(f[i], P.w), yy = y(d);
        if (started) g.lineTo(x, yy); else { g.moveTo(x, yy); started = true; }
      });
      g.save();
      g.setLineDash(c.dashed ? [6, 4] : []);
      g.strokeStyle = c.color; g.lineWidth = 2; g.lineJoin = 'round'; g.stroke();
      g.restore();
    }
  };

  // MARK: MicCurvePreview (±10 dB, 20 Hz – 20 kHz, 1/12-octave points)

  const micCurve = (curve) => `<div class="mic-curve">${canvas({ kind: 'micCurve', curve })}</div>`;
  PAINTERS.micCurve = (cv, { curve }) => {
    const { g, w, h } = prepare(cv);
    const ax = axis();
    const y = (db) => h / 2 - Math.max(-10, Math.min(10, db)) * h / 20;
    g.beginPath(); g.moveTo(0, h / 2); g.lineTo(w, h / 2); g.strokeStyle = 'rgba(255,255,255,0.15)'; g.lineWidth = 1; g.stroke();
    for (const fr of [100, 1000, 10000]) {
      const x = ax.x(fr, w);
      g.beginPath(); g.moveTo(x, 0); g.lineTo(x, h); g.strokeStyle = 'rgba(255,255,255,0.06)'; g.stroke();
      text(g, fLabel(fr), x + 3, h - 6, { size: 9, align: 'left' });
    }
    g.beginPath();
    let fr = 20;
    (curve || []).forEach((d, i) => {
      const x = ax.x(fr, w), yy = y(d == null ? 0 : d);
      if (i === 0) g.moveTo(x, yy); else g.lineTo(x, yy);
      fr *= Math.pow(2, 1 / 12);
    });
    g.strokeStyle = C.accent; g.lineWidth = 1.5; g.stroke();
  };

  // MARK: PointMap

  function pointMap(total, done, qualities) {
    return `<div class="point-map"><div class="pm-title">${esc(t('eq.map'))}</div>${canvas({ kind: 'pointMap', total, done, qualities, stage: t('eq.map.stage') }, 'height:200px')}</div>`;
  }
  PAINTERS.pointMap = (cv, { total, done, qualities, stage }) => {
    const { g, w, h } = prepare(cv);
    const sr = { x: w * 0.15, y: 4, w: w * 0.7, h: 16 };
    g.fillStyle = 'rgba(255,255,255,0.08)';
    g.beginPath(); g.roundRect(sr.x, sr.y, sr.w, sr.h, 4); g.fill();
    text(g, stage, sr.x + sr.w / 2, sr.y + sr.h / 2, { size: 11 });
    g.fillStyle = C.textSecondary;
    for (const x of [sr.x - 8, sr.x + sr.w + 8]) g.fillRect(x - 6, 2, 12, 20);
    const cols = 3, rows = Math.max(1, Math.ceil(total / cols));
    for (let i = 0; i < total; i++) {
      const row = Math.floor(i / cols), col = i % cols;
      const x = w * (0.25 + 0.25 * (row % 2 === 0 ? col : cols - 1 - col));
      const yy = 40 + (h - 56) * (rows === 1 ? 0.5 : row / (rows - 1));
      let color;
      if (i < done) color = qualities[i] === 'good' ? closeness(1) : qualities[i] === 'weak' ? closeness(0.7) : closeness(0);
      else if (i === done) color = C.accent;
      else color = C.textMuted;
      const r = i === done ? 13 : 10;
      g.beginPath(); g.arc(x, yy, r, 0, Math.PI * 2);
      g.fillStyle = withAlpha(color, i < done ? 0.9 : 0.25); g.fill();
      g.strokeStyle = color; g.lineWidth = i === done ? 2 : 1; g.stroke();
      text(g, String(i + 1), x, yy, { size: 11, weight: 700, color: i < done ? '#000' : C.textPrimary });
    }
  };

  // MARK: MiniCurve (live 1/3-octave response, closeness colour, target dashed)

  const miniCurve = (f, mag, target) => canvas({ kind: 'miniCurve', f, mag, target }, 'height:92px;width:100%');
  PAINTERS.miniCurve = (cv, { f, mag, target }) => {
    const { g, w, h } = prepare(cv);
    if (!mag || !f) return;
    const ax = axis();
    const mids = [];
    mag.forEach((d, i) => { if (d != null && f[i] >= 200 && f[i] <= 4000) mids.push(d - target[i]); });
    mids.sort((a, b) => a - b);
    const ref = mids.length ? mids[Math.floor(mids.length / 2)] : 0;
    const y = (db) => h / 2 - (db - ref) * h / 30;
    g.beginPath();
    f.forEach((fr, i) => { const x = ax.x(fr, w), yy = y(target[i]); if (i === 0) g.moveTo(x, yy); else g.lineTo(x, yy); });
    g.save(); g.setLineDash([3, 3]); g.strokeStyle = 'rgba(255,255,255,0.3)'; g.lineWidth = 1; g.stroke(); g.restore();
    g.beginPath();
    let first = true;
    mag.forEach((d, i) => { if (d == null) return; const x = ax.x(f[i], w), yy = y(d); if (first) { g.moveTo(x, yy); first = false; } else g.lineTo(x, yy); });
    g.strokeStyle = C.accent; g.lineWidth = 1.6; g.stroke();
  };

  /** Target curve value at f (TargetCurve.value(at:) for drawing the dashed target): points interpolated in log f. */
  function targetAt(points, fr) {
    if (!points || !points.length) return 0;
    const first = points[0], last = points[points.length - 1];
    if (fr <= first.frequency) return first.gainDB;
    if (fr >= last.frequency) return last.gainDB;
    for (let i = 1; i < points.length; i++) {
      if (fr <= points[i].frequency) {
        const a = points[i - 1], b = points[i];
        const tt = Math.log(fr / a.frequency) / Math.log(b.frequency / a.frequency);
        return a.gainDB + tt * (b.gainDB - a.gainDB);
      }
    }
    return last.gainDB;
  }

  SSMT.SetupUI = {
    C, rgba, canvas, paint, tunerGauge, gaugeState, indicatorLamp, miniMeter, miniLED, polarityLamp, levelStrip, valueChip,
    hazardNotice, collapsible, quietButton, wizardPrimaryButton, actionRow, transferPlot, comparisonPlot, micCurve, pointMap,
    miniCurve, targetAt, fLabel,
  };
})();
