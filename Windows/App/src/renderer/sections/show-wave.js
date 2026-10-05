'use strict';
/* global SSMT */
// Waveform editor of an audio cue (App/SSMT/Show/WaveformEditor.swift): drag the start / end flags, the fade handles,
// the loop edges and the points of the volume line; click to listen from that point; zoom and pan. One undo step per
// drag. Peaks and the volume line's shape come from the engine (ShowWaveform, VolumeEnvelope in SSMTCore).

(function () {
  const { t, esc, icon } = SSMT;
  const Q = SSMT.qtrl;
  const { st, ui, cmd, num, parseNum, showTime } = Q;
  const SILENCE = -100, FLOOR = -60, ENV_TOP = 32, ENV_N = 400;

  const drafts = {}; // cue id → audio params being dragged
  const params = (c) => drafts[c.id] || c.audio || {};

  // MARK: Markup

  function waveEditor(c, compact) {
    const length = Q.fileLength(c.id);
    if (!(length > 0)) {
      const p = Q.pathOf(c.id);
      return `<div class="q-wave-wait">${esc(t(p && st.show.missing.includes(p) ? 'show.fileMissing' : 'show.wave.loading'))}</div>`;
    }
    const a = params(c);
    const env = a.envelope;
    return `<div class="q-wave">
      <div class="q-wavebox" style="height:${compact ? 120 : 280}px"><canvas data-canvas="wave" data-cue="${c.id}"></canvas></div>
      ${transport(c, a, length, compact)}${fields(c, length, compact)}${loopControls(c, a)}${envelopeControls(c, env)}</div>`;
  }

  function transport(c, a, length, compact) {
    const playing = st.show.audition && st.show.audition.cue === c.id;
    return `<div class="q-wave-transport">
      ${Q.toolText(playing ? 'stop.fill' : 'play.fill', t(playing ? 'show.wave.stop' : 'show.wave.play'), 'wavePlay', c.id)}
      ${Q.toolText('forward.end', t('show.wave.end'), 'waveEnd', c.id, { title: t('show.wave.end.help') })}
      ${Q.toolText('scissors', t('show.wave.trim'), 'waveTrim', c.id, { title: t('show.wave.trim.help') })}
      <span class="spacer"></span>
      <button class="q-plain" data-act="waveZoom" data-arg="${c.id},0.5">${icon('plus.magnifyingglass', 12)}</button>
      <button class="q-plain" data-act="waveZoom" data-arg="${c.id},2">${icon('minus.magnifyingglass', 12)}</button>
      ${compact ? `<button class="q-plain" data-act="waveExpand" data-arg="${c.id}" title="${esc(t('show.wave.expand'))}">${icon('arrow.up.left.and.arrow.down.right', 12)}</button>` : ''}</div>`;
  }

  const numberField = (c, title, key, value) => `<div class="q-fieldbox g3"><span class="q-cap">${esc(title + ', ' + t('show.sec'))}</span>
    <input class="q-field" id="qw-${key}" data-id="${c.id}" data-key="${key}" data-change="waveField" value="${esc(num(value, 3))}"></div>`;

  function fields(c, length, compact) {
    const a = c.audio || {};
    return `<div class="q-wave-fields" style="grid-template-columns:repeat(${compact ? 2 : 4},1fr)">
      ${numberField(c, t('show.start'), 'start', a.start || 0)}
      ${numberField(c, t('show.wave.endField'), 'end', a.end !== undefined && a.end !== null ? a.end : length)}
      ${numberField(c, t('show.fadeIn'), 'fadeIn', a.fadeIn || 0)}
      ${numberField(c, t('show.fadeOut'), 'fadeOut', a.fadeOut || 0)}</div>`;
  }

  function loopControls(c, a) {
    const hasLoop = a.loopStart !== undefined && a.loopStart !== null;
    const mode = hasLoop ? 2 : a.plays === 1 ? 0 : 1;
    let more = '';
    if (mode !== 0) {
      more = `<div class="hrow center"><button class="q-togglebtn${a.plays === 0 ? ' on' : ''}" data-act="waveInfinite" data-arg="${c.id}">∞</button>
        ${a.plays !== 0 ? `<span class="q-stepper"><span>${esc(t('show.wave.times', a.plays))}</span><span class="arrows"><button data-act="wavePlays" data-arg="${c.id},1">▴</button><button data-act="wavePlays" data-arg="${c.id},-1">▾</button></span></span>` : ''}</div>`;
      if (mode === 2) {
        more += `<div class="hrow">${numberField(c, t('show.wave.loopStart'), 'loopStart', a.loopStart || 0)}${numberField(c, t('show.wave.loopEnd'), 'loopEnd', a.loopEnd || 0)}</div>
          <span class="q-hint">${esc(t('show.wave.loopPart.hint'))}</span>`;
      }
    }
    return `<div class="vcol g8">${Q.segmented('waveLoop', [[`${c.id},0`, esc(t('show.wave.noLoop'))], [`${c.id},1`, esc(t('show.wave.loopAll'))], [`${c.id},2`, esc(t('show.wave.loopPart'))]], `${c.id},${mode}`, { cls: 'full' })}${more}</div>`;
  }

  function envelopeControls(c, env) {
    const on = !!(env && env.enabled);
    let more = '';
    if (on) {
      more = Q.segmented('envSmooth', [[`${c.id},1`, esc(t('show.env.smooth'))], [`${c.id},0`, esc(t('show.env.linear'))]], `${c.id},${env.smooth === false ? 0 : 1}`, { cls: 'fit' })
        + `<label class="q-check"><input type="checkbox" data-id="${c.id}" data-change="envLock"${env.lockToRegion !== false ? ' checked' : ''}><span>${esc(t('show.env.lock'))}</span></label>`
        + `<button class="q-tool text" data-act="envReset" data-arg="${c.id}"${(env.points || []).length ? '' : ' disabled'}><span>${esc(t('show.env.reset'))}</span></button>`;
    }
    return `<div class="hrow center g10 q-envrow"><label class="q-check" title="${esc(t('show.env.help'))}"><input type="checkbox" data-id="${c.id}" data-change="envOn"${on ? ' checked' : ''}><span>${esc(t('show.env.on'))}</span></label>${more}</div>
      ${on ? `<span class="q-hint">${esc(t('show.env.hint'))}</span>` : ''}`;
  }

  // MARK: Geometry

  function win(c, length) {
    const v = ui.waveView[c.id] || {};
    const span = Math.min(length, Math.max(0.05, v.span || length));
    const start = Math.min(Math.max(0, v.start || 0), Math.max(0, length - span));
    return [start, span];
  }
  function envSpan(a, length) {
    if (a.envelope && a.envelope.lockToRegion === false) return [0, length];
    const s = a.start || 0;
    return [s, Math.max(s + 0.001, a.end !== undefined && a.end !== null ? a.end : length)];
  }
  const envY = (db, h) => ENV_TOP + (Math.max(FLOOR, Math.min(0, db)) / FLOOR) * (h - 22 - ENV_TOP);
  const envDB = (y, h) => Math.round(Math.max(0, Math.min(1, (y - ENV_TOP) / Math.max(1, h - 22 - ENV_TOP))) * FLOOR * 2) / 2;

  /** The volume line as the engine computes it (VolumeEnvelope.db), sampled along 0…1 of its span. */
  function envSamples(env) {
    const key = JSON.stringify({ p: env.points, s: env.smooth, n: ENV_N });
    const got = st.envs[key];
    if (!got && !envSamples.asked[key]) {
      envSamples.asked[key] = true;
      cmd('envSample', { key, envelope: { points: env.points || [], smooth: env.smooth !== false, lockToRegion: env.lockToRegion !== false, enabled: env.enabled !== false }, n: ENV_N });
    }
    return got || envSamples.last[JSON.stringify(env.points.map((p) => p.u))] || null;
  }
  envSamples.asked = {};
  envSamples.last = {};
  const dbAt = (samples, u) => {
    if (!samples) return 0;
    const x = Math.max(0, Math.min(1, u)) * (samples.length - 1);
    const i = Math.floor(x), f = x - i;
    const a = samples[i], b = samples[Math.min(samples.length - 1, i + 1)];
    return a + (b - a) * f;
  };

  // MARK: Drawing

  function drawWaveEditor(cv) {
    const c = Q.cue(cv.dataset.cue);
    if (!c) return;
    const length = Q.fileLength(c.id);
    const g = Q.ctx2d(cv);
    if (!g || !(length > 0)) return;
    const { ctx, w, h } = g;
    const a = params(c);
    const [v0, span] = win(c, length);
    const pps = w / span;
    const x = (tt) => (tt - v0) * pps;
    const s = a.start || 0, e = a.end !== undefined && a.end !== null ? a.end : length;
    const mid = h / 2, half = h * 0.42;
    cv._geo = { v0, span, pps, length, w, h };

    // Background (rounded, 0.3 black).
    ctx.save();
    Q.roundRect(ctx, 0, 0, w, h, 8); ctx.clip();
    ctx.fillStyle = 'rgba(0,0,0,0.3)'; ctx.fillRect(0, 0, w, h);

    // Waveform: detailed slice when ready, otherwise the file overview.
    const path = Q.pathOf(c.id);
    const cols = Math.max(1, Math.floor(w / 2));
    const key = `${path}|${v0}|${span}|${Math.floor(w)}`;
    const detail = st.slices[key];
    if (path && !detail && !drawWaveEditor.asked[key]) {
      drawWaveEditor.asked[key] = true;
      cmd('slice', { path, from: v0, to: v0 + span, buckets: Math.max(50, Math.floor(w / 2)), key });
    }
    const overview = (path && st.waves[path]) || [];
    ctx.beginPath();
    for (let k = 0; k < cols; k++) {
      const px = k * 2;
      let v = 0;
      if (detail && detail.length) v = detail[Math.min(detail.length - 1, Math.floor(k * detail.length / cols))];
      else if (overview.length) {
        const tt = v0 + px / pps;
        v = overview[Math.min(overview.length - 1, Math.max(0, Math.floor(tt / length * overview.length)))];
      }
      const hh = v * half;
      ctx.moveTo(px, mid - hh); ctx.lineTo(px, mid + Math.max(0.5, hh));
    }
    ctx.strokeStyle = 'rgba(46,229,157,0.8)'; ctx.lineWidth = 1; ctx.stroke();

    // Outside the region: dimmed.
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(0, 0, Math.max(0, x(s)), h);
    ctx.fillRect(x(e), 0, Math.max(0, w - x(e)), h);

    // Inner loop.
    if (a.loopStart !== undefined && a.loopStart !== null && a.loopEnd !== undefined && a.loopEnd !== null) {
      const rx = x(a.loopStart), rw = Math.max(1, x(a.loopEnd) - rx);
      ctx.fillStyle = 'rgba(100,210,255,0.12)'; ctx.fillRect(rx, 0, rw, h);
      ctx.fillStyle = 'rgba(100,210,255,0.35)'; ctx.fillRect(rx, h - 18, rw, 18);
      ctx.strokeStyle = '#64D2FF'; ctx.lineWidth = 1.5;
      for (const lx of [rx, rx + rw]) { ctx.beginPath(); ctx.moveTo(lx, 0); ctx.lineTo(lx, h); ctx.stroke(); }
      ctx.fillStyle = '#F3F6F4'; ctx.font = '600 10px Inter, "Segoe UI", sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(t('show.wave.loop') + ' ' + (a.plays === 0 ? '∞' : '×' + a.plays), rx + rw / 2, h - 9);
    }

    // Fades: the gain curve over the waveform, handles in the top strip.
    const fi = a.fadeIn || 0, fo = a.fadeOut || 0;
    ctx.beginPath(); ctx.moveTo(x(s), h); ctx.lineTo(x(s + fi), 8); ctx.lineTo(x(e - fo), 8); ctx.lineTo(x(e), h);
    ctx.strokeStyle = 'rgba(255,214,10,0.85)'; ctx.lineWidth = 1.3; ctx.stroke();
    ctx.fillStyle = '#FFD60A';
    for (const hx of [x(s + fi), x(e - fo)]) { ctx.beginPath(); ctx.arc(hx, 8, 5, 0, Math.PI * 2); ctx.fill(); }

    // Integrated fade: the volume line (0 dB at the top) and its control points.
    const env = a.envelope;
    if (env && env.enabled !== false && env.enabled) {
      const [es, ee] = envSpan(a, length);
      const samples = (env.points || []).length ? envSamples(env) : null;
      if (samples) envSamples.last[JSON.stringify(env.points.map((p) => p.u))] = samples;
      ctx.beginPath();
      let started = false;
      for (let px = Math.max(0, x(es)); px <= Math.min(w, x(ee)); px += 2) {
        const tt = v0 + px / pps;
        const db = (env.points || []).length ? dbAt(samples, (tt - es) / (ee - es)) : 0;
        const y = envY(db <= FLOOR ? SILENCE : db, h);
        if (started) ctx.lineTo(px, y); else { ctx.moveTo(px, y); started = true; }
      }
      ctx.strokeStyle = '#FFD60A'; ctx.lineWidth = 2; ctx.stroke();
      for (const p of env.points || []) {
        const cx = x(es + p.u * (ee - es)), cy = envY(p.db, h);
        ctx.beginPath(); ctx.arc(cx, cy, 5, 0, Math.PI * 2);
        ctx.fillStyle = '#FFD60A'; ctx.fill();
        ctx.strokeStyle = 'rgba(0,0,0,0.5)'; ctx.lineWidth = 1; ctx.stroke();
      }
    }

    // Start / end flags.
    for (const [fx, isStart] of [[x(s), true], [x(e), false]]) {
      ctx.strokeStyle = '#2EE59D'; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(fx, 0); ctx.lineTo(fx, h); ctx.stroke();
      const fw = isStart ? 12 : -12;
      ctx.fillStyle = '#2EE59D';
      ctx.beginPath(); ctx.moveTo(fx, h - 2); ctx.lineTo(fx + fw, h - 9); ctx.lineTo(fx, h - 16); ctx.closePath(); ctx.fill();
    }

    // Time ticks.
    const steps = [0.01, 0.05, 0.1, 0.5, 1, 2, 5, 10, 30, 60, 120];
    const step = steps.find((sv) => sv * pps >= 70) || 300;
    ctx.font = '9px ui-monospace, "Cascadia Mono", Consolas, monospace'; ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    for (let tt = Math.ceil(v0 / step) * step; tt < v0 + span; tt += step) {
      ctx.fillStyle = '#5F6862'; ctx.fillText(showTime(tt), x(tt) + 3, 22);
      ctx.strokeStyle = 'rgba(255,255,255,0.15)'; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x(tt), 16); ctx.lineTo(x(tt), 28); ctx.stroke();
    }

    // Listening position.
    const au = st.show.audition;
    if (au && au.cue === c.id) {
      const k = `${au.cue}|${au.from}|${au.length}`;
      if (drawWaveEditor.auKey !== k) { drawWaveEditor.auKey = k; drawWaveEditor.auAt = performance.now(); }
      const pos = au.from + (performance.now() - drawWaveEditor.auAt) / 1000 * au.rate;
      ctx.fillStyle = '#F3F6F4'; ctx.fillRect(x(Math.min(pos, au.from + au.length)), 0, 2, h);
    }
    ctx.restore();
  }
  drawWaveEditor.asked = {};

  // MARK: Mouse

  const drag = { cue: null, handle: null, startX: 0, startY: 0, panOrigin: 0, moved: false, cv: null };

  function handleAt(c, px, py, geo) {
    const a = params(c);
    const len = geo.length;
    const x = (tt) => (tt - geo.v0) * geo.pps;
    const s = a.start || 0, e = a.end !== undefined && a.end !== null ? a.end : len;
    const env = a.envelope;
    const envOn = !!(env && env.enabled);
    if (envOn) {
      const [es, ee] = envSpan(a, len);
      for (let i = 0; i < (env.points || []).length; i++) {
        const p = env.points[i];
        if (Math.abs(x(es + p.u * (ee - es)) - px) <= 8 && Math.abs(envY(p.db, geo.h) - py) <= 8) return { env: i };
      }
    }
    const cands = [];
    if (py < 24) cands.push(['fadeIn', x(s + (a.fadeIn || 0))], ['fadeOut', x(e - (a.fadeOut || 0))]);
    if (a.loopStart !== undefined && a.loopStart !== null && a.loopEnd !== undefined && a.loopEnd !== null && py > geo.h - 26) cands.push(['loopStart', x(a.loopStart)], ['loopEnd', x(a.loopEnd)]);
    cands.push(['start', x(s)], ['end', x(e)]);
    let best = null;
    for (const cd of cands) if (!best || Math.abs(cd[1] - px) < Math.abs(best[1] - px)) best = cd;
    if (best && Math.abs(best[1] - px) <= 12) return { h: best[0] };
    if (envOn) {
      const [es, ee] = envSpan(a, len);
      const tt = geo.v0 + px / geo.pps;
      if (tt >= es && tt <= ee) {
        const samples = (env.points || []).length ? envSamples(env) : null;
        const db = (env.points || []).length ? dbAt(samples, (tt - es) / (ee - es)) : 0;
        if (Math.abs(envY(db <= FLOOR ? SILENCE : db, geo.h) - py) <= 8) return { envNew: true };
      }
    }
    return { h: 'pan' };
  }

  function addEnvelopePoint(c, time, geo) {
    const a = JSON.parse(JSON.stringify(drafts[c.id] || c.audio));
    const env = a.envelope || { points: [], smooth: true, lockToRegion: true, enabled: true };
    const [s, e] = envSpan(a, geo.length);
    const u = Math.max(0, Math.min(1, (time - s) / (e - s)));
    const samples = env.points.length ? envSamples(env) : null;
    const db = env.points.length ? dbAt(samples, u) : 0;
    env.points.push({ u, db: db <= SILENCE ? FLOOR : db });
    env.points.sort((p, q) => p.u - q.u);
    a.envelope = env;
    drafts[c.id] = a;
    return env.points.findIndex((p) => p.u === u);
  }

  function apply(c, time, dx, py, geo) {
    const a = JSON.parse(JSON.stringify(drafts[c.id] || c.audio));
    const length = geo.length;
    if (drag.handle && drag.handle.env !== undefined) {
      const env = a.envelope;
      const i = drag.handle.env;
      if (!env || !env.points[i]) return;
      const [s, e] = envSpan(a, length);
      const lo = i > 0 ? env.points[i - 1].u + 0.0005 : 0;
      const hi = i + 1 < env.points.length ? env.points[i + 1].u - 0.0005 : 1;
      env.points[i].u = Math.max(lo, Math.min(hi, (time - s) / (e - s)));
      env.points[i].db = envDB(py, geo.h);
      drafts[c.id] = a;
      return;
    }
    const tt = Math.round(Math.max(0, Math.min(length, time)) * 1000) / 1000;
    const e = a.end !== undefined && a.end !== null ? a.end : length;
    switch (drag.handle && drag.handle.h) {
      case 'start': a.start = Math.min(tt, e - 0.01); break;
      case 'end': if (tt >= length - 0.001) delete a.end; else a.end = Math.max(tt, (a.start || 0) + 0.01); break;
      case 'fadeIn': a.fadeIn = Math.max(0, Math.min(tt - (a.start || 0), e - (a.start || 0))); break;
      case 'fadeOut': a.fadeOut = Math.max(0, Math.min(e - tt, e - (a.start || 0))); break;
      case 'loopStart': if (a.loopEnd !== undefined && a.loopEnd !== null) a.loopStart = Math.max(a.start || 0, Math.min(tt, a.loopEnd - 0.01)); break;
      case 'loopEnd': if (a.loopStart !== undefined && a.loopStart !== null) a.loopEnd = Math.min(e, Math.max(tt, a.loopStart + 0.01)); break;
      case 'pan': {
        const v = ui.waveView[c.id];
        if (v && v.span) v.start = Math.max(0, drag.panOrigin - dx / geo.pps);
        return;
      }
      default: return;
    }
    drafts[c.id] = a;
  }

  document.addEventListener('pointerdown', (e) => {
    const cv = e.target.closest && e.target.closest('#pane-show canvas[data-canvas="wave"]');
    if (!cv || e.button !== 0 || !cv._geo) return;
    const c = Q.cue(cv.dataset.cue);
    if (!c) return;
    const r = cv.getBoundingClientRect();
    const px = e.clientX - r.left, py = e.clientY - r.top;
    const geo = cv._geo;
    let hd = handleAt(c, px, py, geo);
    drafts[c.id] = JSON.parse(JSON.stringify(c.audio));
    if (hd.envNew) hd = { env: addEnvelopePoint(c, geo.v0 + px / geo.pps, geo) };
    Object.assign(drag, { cue: c.id, handle: hd, startX: e.clientX, startY: e.clientY, panOrigin: geo.v0, moved: false, cv });
    cv.setPointerCapture(e.pointerId);
    apply(c, geo.v0 + px / geo.pps, 0, py, geo);
    Q.redraw();
  });
  document.addEventListener('pointermove', (e) => {
    if (!drag.cv) return;
    const c = Q.cue(drag.cue);
    const geo = drag.cv._geo;
    if (!c || !geo) return;
    const r = drag.cv.getBoundingClientRect();
    if (Math.abs(e.clientX - drag.startX) >= 3 || Math.abs(e.clientY - drag.startY) >= 3) drag.moved = true;
    apply(c, geo.v0 + (e.clientX - r.left) / geo.pps, e.clientX - drag.startX, e.clientY - r.top, geo);
    Q.redraw();
  });
  document.addEventListener('pointerup', (e) => {
    if (!drag.cv) return;
    const c = Q.cue(drag.cue);
    const geo = drag.cv._geo;
    const r = drag.cv.getBoundingClientRect();
    const draft = drafts[drag.cue];
    if (c && geo) {
      if (drag.handle && drag.handle.env !== undefined) {
        // Alt-click on a point removes it; anything else keeps what was drawn.
        if (e.altKey && !drag.moved && draft && draft.envelope) draft.envelope.points.splice(drag.handle.env, 1);
        if (draft) cmd('set', { id: c.id, fields: { audio: draft } });
      } else if (!drag.moved) {
        // A click: listen from here.
        cmd('audition', { id: c.id, from: Math.max(0, Math.min(geo.length, geo.v0 + (e.clientX - r.left) / geo.pps)) });
      } else if (drag.handle && drag.handle.h !== 'pan' && draft) {
        cmd('set', { id: c.id, fields: { audio: draft } });
      }
    }
    // The draft stays drawn until the engine's document arrives.
    const id = drag.cue;
    setTimeout(() => { delete drafts[id]; Q.redraw(); }, drag.moved || (drag.handle && drag.handle.env !== undefined) ? 300 : 0);
    Object.assign(drag, { cue: null, handle: null, cv: null, moved: false });
  });

  // MARK: Actions

  Object.assign(Q.actions, {
    wavePlay: (id) => {
      const c = Q.cue(id);
      if (!c) return;
      if (st.show.audition && st.show.audition.cue === id) cmd('stopAudition'); else cmd('audition', { id, from: (c.audio || {}).start || 0 });
    },
    waveEnd: (id) => {
      const c = Q.cue(id);
      if (!c || !c.audio) return;
      const len = Q.fileLength(id);
      const e = c.audio.end !== undefined && c.audio.end !== null ? c.audio.end : len;
      cmd('audition', { id, from: Math.max(c.audio.start || 0, e - 3) });
    },
    waveTrim: (id) => cmd('trim', { id }),
    waveZoom: (arg) => {
      const [id, factor] = arg.split(',');
      const c = Q.cue(id);
      const length = Q.fileLength(id);
      if (!c || !length) return;
      const [v0, span] = win(c, length);
      const center = v0 + span / 2;
      const ns = Math.min(length, Math.max(0.05, span * Number(factor)));
      ui.waveView[id] = { span: ns >= length ? null : ns, start: Math.max(0, center - ns / 2) };
      Q.redraw();
    },
    waveField: (v, el) => {
      const c = Q.cue(el.dataset.id);
      const x = parseNum(v);
      if (!c || x === null) { SSMT.render(); return; }
      const length = Q.fileLength(c.id) || 0;
      const k = el.dataset.key;
      const f = {};
      if (k === 'start') f['audio.start'] = Math.max(0, x);
      else if (k === 'end') f['audio.end'] = x >= length - 0.001 ? null : Math.max(0, x);
      else if (k === 'fadeIn') f['audio.fadeIn'] = Math.max(0, x);
      else if (k === 'fadeOut') f['audio.fadeOut'] = Math.max(0, x);
      else if (k === 'loopStart') f['audio.loopStart'] = Math.max((c.audio || {}).start || 0, x);
      else if (k === 'loopEnd') f['audio.loopEnd'] = x;
      cmd('set', { id: c.id, fields: f });
    },
    waveLoop: (arg) => { const [id, m] = arg.split(','); cmd('loopMode', { id, mode: Number(m) }); },
    waveInfinite: (id) => { const c = Q.cue(id); if (c && c.audio) cmd('set', { id, fields: { 'audio.plays': c.audio.plays === 0 ? 2 : 0 } }); },
    wavePlays: (arg) => {
      const [id, d] = arg.split(',');
      const c = Q.cue(id);
      if (c && c.audio) cmd('set', { id, fields: { 'audio.plays': Math.min(999, Math.max(1, c.audio.plays + Number(d))) } });
    },
    envOn: (v, el) => cmd('envOn', { id: el.dataset.id, on: !!v }),
    envSmooth: (arg) => { const [id, v] = arg.split(','); cmd('set', { id, fields: { 'audio.envelope.smooth': v === '1' } }); },
    envLock: (v, el) => cmd('set', { id: el.dataset.id, fields: { 'audio.envelope.lockToRegion': !!v } }),
    envReset: (id) => cmd('set', { id, fields: { 'audio.envelope.points': [] } }),
    waveExpand: (id) => { ui.sheet = { wave: id }; SSMT.render(); },
  });

  Object.assign(Q, { waveEditor, drawWaveEditor });
})();
