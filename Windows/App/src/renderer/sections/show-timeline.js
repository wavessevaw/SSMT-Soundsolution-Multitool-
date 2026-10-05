'use strict';
/* global SSMT */
// Qtrl's multitrack timeline (App/SSMT/Show/ShowTimelineView.swift). "Whole show": a live strip where "now" stays put
// and sound flows right to left; what the next GO would start is drawn dashed from "now". "Group": the contents of a
// group, editable with the mouse (drag a clip = its pre-wait; edges trim; Alt slips the sound inside the clip).
// The clips come from the engine (ShowTimeline.plan / planGroup / assignLanes); this file draws them and turns drags
// into settings, as the Mac view does.

(function () {
  const { t, esc, icon } = SSMT;
  const Q = SSMT.qtrl;
  const { st, ui, cmd, showTime } = Q;
  const CONTROL_LANE = -1;
  const RULER = 18, CONTROL_ROW = 22;

  // MARK: Markup

  const zoom = () => `<div class="q-zoom"><button class="q-plain" data-act="zoomOut">${icon('minus.magnifyingglass', 13)}</button>
    <span>${Math.trunc(ui.span)} ${esc(t('show.sec'))}</span><button class="q-plain" data-act="zoomIn">${icon('plus.magnifyingglass', 13)}</button></div>`;

  /** The timeline card under the cue list. */
  function timelineCard() {
    const g = st.show.timelineGroup ? Q.cue(st.show.timelineGroup) : null;
    const sel = st.show.selection.length === 1 ? Q.cue(st.show.selection[0]) : null;
    const choice = g || (sel && sel.kind === 'group' ? sel : null);
    const opts = [['', esc(t('show.timeline.show'))]];
    if (choice) opts.push([choice.id, esc(t('show.timeline.group', choice.number || choice.name))]);
    const hint = g && !st.show.showMode ? `<span class="xs muted">${esc(t('show.timeline.dragHint'))}</span>` : '';
    return `<div class="glass q-timeline"><div class="q-tlhead"><span class="cap">${esc(t('show.timeline').toUpperCase())}</span>
      ${Q.segmented('timelineGroup', opts, g ? g.id : '', { cls: 'fit' })}${hint}<span class="spacer"></span>${zoom()}</div>
      <div class="q-tlcanvas"><canvas data-canvas="timeline" data-group="${g ? g.id : ''}"></canvas></div>${g ? slider(g.id, false) : ''}</div>`;
  }

  /** A group's own multitrack (inspector tab): one track per cue, drag to set its start. */
  function multitrack(c) {
    const showMode = st.show.showMode;
    const note = c.groupMode !== 'simultaneous'
      ? `<span class="q-mtnote warn">${esc(t('show.group.notTimeline'))}</span><button class="btn secondary" data-act="makeTimeline" data-arg="${c.id}"${showMode ? ' disabled' : ''}>${esc(t('show.group.makeTimeline'))}</button>`
      : `<span class="q-mtnote">${esc(t('show.group.multitrackHint'))}</span>`;
    return `<div class="q-mthead"><button class="btn secondary" data-act="addTracks" data-arg="${c.id}"${showMode ? ' disabled' : ''}>${icon('plus', 13)}${esc(t('show.group.addTracks'))}</button>
      ${note}<span class="spacer"></span>${zoom()}</div>
      <div class="q-tlcanvas mt"><canvas data-canvas="multitrack" data-group="${c.id}"></canvas></div>${slider(c.id, true)}`;
  }

  function slider(gid, perCue) {
    const clips = groupClips(gid, perCue);
    const length = Math.max(ui.span, Math.max(0, ...clips.map((c) => (c.duration === null ? c.start : c.start + c.duration))) + 2);
    const max = Math.max(-1, length - ui.span * 0.8);
    return `<input type="range" class="q-slider mini q-tlscroll" min="-2" max="${max}" step="0.01" value="${Math.min(max, ui.groupScroll)}" data-input="groupScroll" title="${esc(t('show.timeline.scroll'))}">`;
  }

  // MARK: Data

  function groupClips(gid, perCue) {
    if (perCue) return (st.show.selected && st.show.selected.id === gid && st.show.selected.multitrack) || [];
    return (st.show.groupPlan && st.show.groupPlan.id === gid && st.show.groupPlan.clips) || [];
  }

  /** Seconds since the last engine snapshot, while something plays. */
  const isPlaying = () => st.live.running.some((r) => !r.paused) || !!drag.scrub;
  const dtNow = () => (isPlaying() ? Math.min(0.15, Math.max(0, (performance.now() - st.liveAt) / 1000)) : 0);

  /** Live clips moved by the time since the snapshot (ShowTimelineView.currentClips(dt)). */
  function liveClips(dt) {
    return (st.live.clips || []).map((c) => {
      if (!c.live || c.paused || !dt) return c;
      // Waiting (pre-wait, start ahead of "now") counts down to 0; playing moves left.
      return Object.assign({}, c, { start: c.start > 0 ? Math.max(0, c.start - dt) : c.start - dt });
    });
  }

  /** Playback position on a group timeline and whether the group is under way. */
  function cursor(gid, dt, clips) {
    if (drag.scrub !== null && drag.scrubGroup === gid) return { time: drag.scrub, active: true };
    const run = st.live.running;
    const r = run.find((x) => x.id === gid);
    if (r) {
      const d = r.paused ? 0 : dt;
      if (r.phase === 'preWait') return { time: -Math.max(0, (Q.remaining(r) || 0) - d), active: true };
      return { time: r.elapsed + d, active: true };
    }
    for (const x of run) {
      if (x.phase === 'preWait') continue;
      const c = clips.find((k) => k.cue === x.id && k.style !== 'marker');
      if (c) return { time: c.start + x.elapsed + (x.paused ? 0 : dt), active: true };
    }
    return { time: (st.live.loaded || {})[gid] || 0, active: false };
  }

  function layout(w, h, live, clips, scroll) {
    const lanes = Math.max(3, Math.max(0, ...clips.map((c) => c.lane)) + 1);
    const laneHeight = Math.max(16, Math.min(46, (h - RULER - CONTROL_ROW - 6) / lanes));
    const pps = w / ui.span;
    const origin = live ? w * 0.25 : 12 - scroll * pps;
    const L = { w, h, live, lanes, laneHeight, pps, origin, ruler: RULER };
    L.x = (tt) => origin + tt * pps;
    L.laneY = (lane) => (lane === CONTROL_LANE ? RULER + lanes * laneHeight + 4 : RULER + lane * laneHeight);
    L.rect = (c) => {
      const x0 = L.x(c.start);
      const x1 = c.duration === null || c.duration === undefined ? w + 40 : L.x(c.start + c.duration);
      const hh = c.lane === CONTROL_LANE ? CONTROL_ROW - 4 : laneHeight - 4;
      return { x: x0, y: L.laneY(c.lane) + 2, w: Math.max(3, x1 - x0), h: hh };
    };
    return L;
  }

  // MARK: Drawing

  function ctx2d(cv) {
    const w = cv.clientWidth, h = cv.clientHeight;
    if (!w || !h) return null;
    const dpr = window.devicePixelRatio || 1;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
    const ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return { ctx, w, h };
  }
  function roundRect(ctx, x, y, w, h, r) {
    const rr = Math.max(0, Math.min(r, w / 2, h / 2));
    ctx.beginPath();
    ctx.moveTo(x + rr, y); ctx.arcTo(x + w, y, x + w, y + h, rr); ctx.arcTo(x + w, y + h, x, y + h, rr);
    ctx.arcTo(x, y + h, x, y, rr); ctx.arcTo(x, y, x + w, y, rr); ctx.closePath();
  }
  const rgba = (hex, a) => {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
  };
  const MONO = '9px ui-monospace, "Cascadia Mono", Consolas, monospace';

  function drawTimeline(cv) {
    const g = ctx2d(cv);
    if (!g) return;
    const gid = cv.dataset.group || null;
    const perCue = cv.dataset.canvas === 'multitrack';
    const dt = dtNow();
    const live = !gid;
    const clips = live ? liveClips(dt) : groupClips(gid, perCue);
    const base = live ? (st.live.clips || []) : clips;
    const L = layout(g.w, g.h, live, base, live ? 0 : ui.groupScroll);
    cv._layout = L;
    cv._clips = base;
    draw(g.ctx, L, clips, live ? null : cursor(gid, dt, clips), gid);
  }

  function draw(ctx, L, clips, cur, gid) {
    const { w, h } = L;
    // Lanes.
    for (let i = 0; i < L.lanes; i++) {
      ctx.fillStyle = `rgba(255,255,255,${i % 2 === 0 ? 0.03 : 0.018})`;
      roundRect(ctx, 0, L.laneY(i) + 1, w, L.laneHeight - 2, 4); ctx.fill();
    }
    ctx.fillStyle = 'rgba(255,255,255,0.02)';
    roundRect(ctx, 0, L.laneY(CONTROL_LANE), w, CONTROL_ROW, 4); ctx.fill();

    // Ruler: a readable step for the zoom.
    const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300];
    const step = steps.find((s) => s * L.pps >= 60) || 600;
    const tMin = -L.origin / L.pps, tMax = (w - L.origin) / L.pps;
    ctx.font = MONO; ctx.textBaseline = 'middle'; ctx.textAlign = 'left';
    for (let tt = Math.floor(tMin / step) * step; tt <= tMax; tt += step) {
      const x = L.x(tt);
      ctx.strokeStyle = 'rgba(255,255,255,0.05)'; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x, RULER - 5); ctx.lineTo(x, h); ctx.stroke();
      const text = (L.live && tt > 0 ? '+' : '') + showTime(Math.abs(tt)).replace('.0', '');
      ctx.fillStyle = '#5F6862';
      ctx.fillText((tt < 0 ? '−' : '') + text, x + 3, 7);
    }

    // Snapping guides while dragging.
    if (drag.clip && drag.moved) {
      ctx.setLineDash([3, 3]); ctx.strokeStyle = rgba('#64D2FF', 0.35);
      for (const gx of guides(drag.clip.cue, clips, gid)) { ctx.beginPath(); ctx.moveTo(L.x(gx), RULER); ctx.lineTo(L.x(gx), h); ctx.stroke(); }
      ctx.setLineDash([]);
    }
    for (const c of clips) {
      let r = L.rect(c);
      if (drag.clip && drag.moved && drag.clip.cue === c.cue && drag.canvasGroup === gid) {
        if (drag.mode === 'move') r = Object.assign({}, r, { x: r.x + drag.dx });
        else if (drag.mode === 'trimStart') r = Object.assign({}, r, { x: r.x + drag.dx, w: Math.max(3, r.w - drag.dx) });
        else if (drag.mode === 'trimEnd') r = Object.assign({}, r, { w: Math.max(3, r.w + drag.dx) });
      }
      if (r.x + r.w <= -20 || r.x >= w + 20) continue;
      const cue = Q.cue(c.cue);
      const ghost = L.live && !c.live;
      if (c.style === 'audio') {
        const tint = cue && cue.color && Q.COLORS[cue.color] && cue.color !== '' ? Q.COLORS[cue.color] : '#2EE59D';
        roundRect(ctx, r.x, r.y, r.w, r.h, 5);
        ctx.fillStyle = rgba(tint, ghost ? 0.05 : 0.16); ctx.fill();
        let slip = 0;
        if (drag.clip && drag.moved && drag.clip.cue === c.cue && drag.mode === 'slip') slip = -drag.dx / L.pps;
        if (cue) drawWave(ctx, cue, r, L.pps, ghost ? 0.25 : 0.7, tint, slip);
        roundRect(ctx, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1, 5);
        if (ghost) { ctx.setLineDash([4, 3]); ctx.strokeStyle = 'rgba(255,255,255,0.3)'; ctx.lineWidth = 1; ctx.stroke(); ctx.setLineDash([]); }
        else { ctx.strokeStyle = rgba(tint, 0.6); ctx.lineWidth = 1; ctx.stroke(); }
        // Already played part (live view): darker.
        if (L.live && r.x < L.origin) {
          roundRect(ctx, r.x, r.y, Math.min(r.w, L.origin - r.x), r.h, 5);
          ctx.fillStyle = 'rgba(0,0,0,0.35)'; ctx.fill();
        }
      } else if (c.style === 'fade') {
        const f = cue && cue.fade;
        const up = (f && f.fromSilence) || (f && f.level !== undefined && f.level !== null ? f.level : -100) > -20;
        ctx.beginPath(); ctx.moveTo(r.x, up ? r.y + r.h : r.y); ctx.lineTo(r.x + r.w, up ? r.y : r.y + r.h);
        ctx.strokeStyle = rgba('#64D2FF', ghost ? 0.4 : 0.9); ctx.lineWidth = 1.6;
        if (ghost) ctx.setLineDash([4, 3]);
        ctx.stroke(); ctx.setLineDash([]);
      } else if (c.style === 'wait') {
        roundRect(ctx, r.x, r.y, r.w, r.h, 4); ctx.fillStyle = `rgba(255,255,255,${ghost ? 0.03 : 0.06})`; ctx.fill();
      } else {
        const my = r.y + r.h / 2;
        ctx.beginPath(); ctx.moveTo(r.x, my - 5); ctx.lineTo(r.x + 5, my); ctx.lineTo(r.x, my + 5); ctx.lineTo(r.x - 5, my); ctx.closePath();
        ctx.fillStyle = rgba('#FFD60A', ghost ? 0.4 : 0.9); ctx.fill();
      }
      // Caption at the visible left edge of the clip.
      const lx = Math.max(r.x, 0) + 6;
      if (r.x + r.w - lx > 30 || c.style === 'marker') {
        ctx.font = '500 10px Inter, "Segoe UI", sans-serif'; ctx.textBaseline = 'middle'; ctx.textAlign = 'left';
        ctx.fillStyle = ghost ? '#939C96' : '#F3F6F4';
        ctx.fillText(Q.label(cue), c.style === 'marker' ? r.x + 8 : lx, r.y + Math.min(9, r.h / 2));
      }
    }

    // Playback cursor of a group timeline (yellow line).
    if (cur && !L.live) {
      const x = L.x(cur.time);
      if (x >= -1 && x <= w + 1) {
        const color = rgba('#FFD60A', cur.active ? 1 : 0.55);
        ctx.strokeStyle = color; ctx.lineWidth = cur.active ? 1.5 : 1;
        ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke();
        ctx.fillStyle = color;
        ctx.beginPath(); ctx.moveTo(x - 5, 0); ctx.lineTo(x + 5, 0); ctx.lineTo(x, 7); ctx.closePath(); ctx.fill();
        ctx.font = '600 ' + MONO;
        const text = clockText(cur.time);
        const bw = ctx.measureText(text).width + 8;
        const bx = Math.min(Math.max(x + 6, 0), w - bw);
        roundRect(ctx, bx, 1, bw, 13, 3); ctx.fill();
        ctx.fillStyle = '#000'; ctx.textBaseline = 'middle'; ctx.textAlign = 'left';
        ctx.fillText(text, bx + 4, 7.5);
      }
    }

    // "Now" (live view).
    if (L.live) {
      ctx.strokeStyle = '#F3F6F4'; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(L.origin, 0); ctx.lineTo(L.origin, h); ctx.stroke();
      ctx.fillStyle = '#F3F6F4'; ctx.font = '600 9px Inter, "Segoe UI", sans-serif'; ctx.textBaseline = 'middle'; ctx.textAlign = 'left';
      ctx.fillText(t('show.timeline.now'), L.origin + 4, 7);
    }
  }

  function clockText(tt) {
    const v = Math.abs(tt);
    const m = Math.floor(Math.floor(v) / 60);
    const s = v - m * 60;
    const body = m > 0 ? `${m}:${s.toFixed(1).padStart(4, '0')}` : s.toFixed(1);
    return (tt < -0.05 ? '−' : '') + body;
  }

  /** Waveform of an audio clip from the file overview, following region, rate and loops. */
  function drawWave(ctx, cue, r, pps, alpha, tint, slip) {
    const a = cue.audio;
    const path = Q.pathOf(cue.id);
    const wave = path ? st.waves[path] : null;
    const length = Q.fileLength(cue.id);
    const map = st.show.maps[cue.id];
    if (!a || !wave || !wave.length || !length || !map) return;
    const rate = Math.max(a.rate || 1, 0.05);
    const mid = r.y + r.h / 2, half = r.h * 0.42;
    ctx.beginPath();
    for (let x = Math.max(r.x, -2), end = Math.min(r.x + r.w, 4000); x < end; x += 2) {
      const tau = (x - r.x) / pps * rate;
      const fileT = Q.mapPosition(map, tau) + slip * rate;
      const i = Math.min(wave.length - 1, Math.max(0, Math.floor(fileT / length * wave.length)));
      const hh = wave[i] * half;
      ctx.moveTo(x, mid - hh); ctx.lineTo(x, mid + hh);
    }
    ctx.strokeStyle = rgba(tint, alpha); ctx.lineWidth = 1; ctx.stroke();
  }

  // MARK: Editing with the mouse (group timeline)

  const drag = { clip: null, mode: null, dx: 0, moved: false, startX: 0, scrub: null, scrubGroup: null, pan: null, canvasGroup: null };

  function guides(exceptCue, clips, gid) {
    const g = [0];
    if (gid) g.push(cursor(gid, 0, clips).time);
    for (const o of clips) {
      if (o.cue === exceptCue) continue;
      g.push(o.start);
      if (o.duration !== null && o.duration !== undefined) g.push(o.start + o.duration);
    }
    return g;
  }

  function snapped(c, dx, mode, clips, L, gid, noSnap) {
    if (noSnap || mode === 'slip') return dx;
    const delta = dx / L.pps;
    const hasD = c.duration !== null && c.duration !== undefined;
    const edges = mode === 'move' ? [c.start].concat(hasD ? [c.start + c.duration] : []) : mode === 'trimStart' ? [c.start] : hasD ? [c.start + c.duration] : [];
    const tol = 8 / L.pps;
    let best = null;
    for (const e of edges) {
      for (const g of guides(c.cue, clips, gid)) {
        if (Math.abs(e + delta - g) < tol) {
          const d = g - e;
          if (best === null || Math.abs(d - delta) < Math.abs(best - delta)) best = d;
        }
      }
    }
    return (best === null ? delta : best) * L.pps;
  }

  function hit(L, clips, x, y) {
    for (let i = clips.length - 1; i >= 0; i--) {
      const c = clips[i];
      if (c.style === 'marker') continue;
      const r = L.rect(c);
      const rw = Math.max(8, r.w), rh = Math.max(8, r.h);
      if (x >= r.x && x <= r.x + rw && y >= r.y && y <= r.y + rh) return { c, r };
    }
    return null;
  }

  function commit(c, dx, mode, L) {
    const delta = dx / L.pps;
    const cue = Q.cue(c.cue);
    if (Math.abs(delta) <= 0.01 || !cue) return;
    const r2 = (v) => Math.round(v * 100) / 100;
    const a = cue.audio;
    const set = (fields) => cmd('set', { id: cue.id, fields });
    if (mode === 'move') { set({ preWait: Math.max(0, r2((cue.preWait || 0) + delta)) }); return; }
    if (!a) return;
    const rate = Math.max(a.rate || 1, 0.05);
    const len = Q.fileLength(cue.id);
    if (mode === 'trimStart') {
      const limitEnd = (a.end !== undefined && a.end !== null ? a.end : len !== null ? len : Infinity) - 0.05;
      const d = Math.min(Math.max(delta, -(cue.preWait || 0), -(a.start || 0) / rate), (limitEnd - (a.start || 0)) / rate);
      set({ preWait: Math.max(0, r2((cue.preWait || 0) + d)), 'audio.start': Math.max(0, r2((a.start || 0) + d * rate)) });
    } else if (mode === 'trimEnd') {
      if (c.duration === null || c.duration === undefined || a.plays !== 1 || (a.loopStart !== undefined && a.loopStart !== null)) return;
      const length = len !== null ? len : Infinity;
      const newEnd = Math.min(length, Math.max((a.start || 0) + 0.05, (a.start || 0) + (c.duration + delta) * rate));
      set({ 'audio.end': r2(newEnd) });
    } else if (mode === 'slip') {
      if (len === null) return;
      const used = (a.end !== undefined && a.end !== null ? a.end : len) - (a.start || 0);
      const shift = Math.min(Math.max(-delta * rate, -(a.start || 0)), len - used - (a.start || 0));
      if (Math.abs(shift) <= 0.005) return;
      const fields = { 'audio.start': Math.max(0, r2((a.start || 0) + shift)) };
      if (a.end !== undefined && a.end !== null) fields['audio.end'] = r2(a.end + shift);
      if (a.loopStart !== undefined && a.loopStart !== null) fields['audio.loopStart'] = r2(a.loopStart + shift);
      if (a.loopEnd !== undefined && a.loopEnd !== null) fields['audio.loopEnd'] = r2(a.loopEnd + shift);
      set(fields);
    }
  }

  document.addEventListener('pointerdown', (e) => {
    const cv = e.target.closest && e.target.closest('#pane-show canvas[data-canvas="timeline"], #pane-show canvas[data-canvas="multitrack"]');
    if (!cv || e.button !== 0 || !cv._layout) return;
    const L = cv._layout;
    const rect = cv.getBoundingClientRect();
    const x = e.clientX - rect.left, y = e.clientY - rect.top;
    const gid = cv.dataset.group || null;
    const perCue = cv.dataset.canvas === 'multitrack';
    const clips = cv._clips || [];
    Object.assign(drag, { clip: null, mode: null, dx: 0, moved: false, startX: e.clientX, pan: null, canvasGroup: gid, cv });
    if (gid && y < RULER + 4) {
      // Ruler of a group timeline: click or drag to move playback there.
      drag.scrubGroup = gid;
      drag.scrub = Math.max(0, (x - L.origin) / L.pps);
      cv.setPointerCapture(e.pointerId);
      kick();
      return;
    }
    const h = hit(L, clips, x, y);
    if (h) {
      if (!perCue) cmd('select', { ids: [h.c.cue] });
      if (gid && !st.show.showMode) {
        drag.clip = h.c;
        if (h.c.style === 'audio' && e.altKey) drag.mode = 'slip';
        else if (h.c.style !== 'audio' || h.r.w <= 24) drag.mode = 'move';
        else if (x - h.r.x < 7) drag.mode = 'trimStart';
        else if (h.c.duration !== null && h.c.duration !== undefined && x > h.r.x + h.r.w - 7) drag.mode = 'trimEnd';
        else drag.mode = 'move';
        cv.setPointerCapture(e.pointerId);
      }
      return;
    }
    if (gid) { drag.pan = ui.groupScroll; cv.setPointerCapture(e.pointerId); }
  });
  document.addEventListener('pointermove', (e) => {
    const cv = drag.cv;
    if (!cv || !cv._layout) return;
    const L = cv._layout;
    const rect = cv.getBoundingClientRect();
    const dx = e.clientX - drag.startX;
    if (drag.scrub !== null) { drag.scrub = Math.max(0, (e.clientX - rect.left - L.origin) / L.pps); redraw(); return; }
    if (drag.clip) {
      if (Math.abs(dx) < 2 && !drag.moved) return;
      drag.moved = true;
      drag.dx = snapped(drag.clip, dx, drag.mode, cv._clips || [], L, drag.canvasGroup, e.ctrlKey || e.metaKey);
      redraw();
      return;
    }
    if (drag.pan !== null && Math.abs(dx) >= 2) {
      ui.groupScroll = Math.max(-2, drag.pan - dx / L.pps);
      redraw();
      syncSliders();
    }
  });
  document.addEventListener('pointerup', (e) => {
    const cv = drag.cv;
    if (!cv) return;
    const L = cv._layout;
    if (drag.scrub !== null) {
      const rect = cv.getBoundingClientRect();
      const s = Math.max(0, Math.round((e.clientX - rect.left - L.origin) / L.pps * 100) / 100);
      cmd('seek', { id: drag.scrubGroup, seconds: s });
      drag.scrub = null; drag.scrubGroup = null;
    } else if (drag.clip && drag.moved) {
      commit(drag.clip, drag.dx, drag.mode, L);
    }
    Object.assign(drag, { clip: null, mode: null, dx: 0, moved: false, pan: null, cv: null });
    redraw();
  });
  // Wheel / trackpad over a group timeline scrolls it sideways.
  document.addEventListener('wheel', (e) => {
    const cv = e.target.closest && e.target.closest('#pane-show canvas[data-canvas]');
    if (!cv || !cv.dataset.group || (cv.dataset.canvas !== 'timeline' && cv.dataset.canvas !== 'multitrack')) return;
    e.preventDefault();
    const d = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
    ui.groupScroll = Math.max(-2, ui.groupScroll + d * ui.span / 900);
    redraw();
    syncSliders();
  }, { passive: false });

  function syncSliders() {
    document.querySelectorAll('#pane-show .q-tlscroll').forEach((s) => { s.value = String(Math.min(Number(s.max), ui.groupScroll)); });
  }

  /** While a group plays, its timeline scrolls to keep the cursor in view. */
  function followCursor() {
    if (drag.clip || drag.scrub !== null || drag.pan !== null) return;
    const cv = document.querySelector('#pane-show canvas[data-canvas="multitrack"], #pane-show canvas[data-canvas="timeline"][data-group]:not([data-group=""])');
    if (!cv) return;
    const gid = cv.dataset.group;
    const c = cursor(gid, 0, groupClips(gid, cv.dataset.canvas === 'multitrack'));
    if (!c.active) return;
    if (c.time > ui.groupScroll + ui.span * 0.9 || c.time < ui.groupScroll - 0.5) { ui.groupScroll = Math.max(-2, c.time - ui.span * 0.1); syncSliders(); }
  }

  Object.assign(Q.actions, {
    zoomOut: () => { ui.span = Math.min(600, ui.span * 1.5); Q.saveUI(); SSMT.render(); },
    zoomIn: () => { ui.span = Math.max(5, ui.span / 1.5); Q.saveUI(); SSMT.render(); },
    timelineGroup: (v) => cmd('timelineGroup', { id: v || undefined }),
    makeTimeline: (id) => cmd('set', { id, fields: { groupMode: 'simultaneous' } }),
    addTracks: (id) => Q.chooseAudio(undefined, id),
  });
  Object.assign(Q.inputs, { groupScroll: (v) => { ui.groupScroll = Number(v); redraw(); } });

  // MARK: Redraw loop

  function redraw() {
    const pane = document.getElementById('pane-show');
    if (!pane || pane.hidden) return;
    pane.querySelectorAll('canvas[data-canvas]').forEach((cv) => {
      const k = cv.dataset.canvas;
      if (k === 'timeline' || k === 'multitrack') drawTimeline(cv);
      else if (k === 'fadecurve') Q.drawFadeCurve(cv);
      else if (k === 'wave' && Q.drawWaveEditor) Q.drawWaveEditor(cv);
    });
  }
  let looping = false;
  function kick() {
    if (looping) return;
    looping = true;
    const step = () => {
      const pane = document.getElementById('pane-show');
      const active = pane && !pane.hidden && (isPlaying() || (st.show && st.show.audition));
      redraw();
      if (active) requestAnimationFrame(step); else looping = false;
    };
    requestAnimationFrame(step);
  }
  function drawCanvases() {
    followCursor();
    redraw();
    kick();
  }

  Object.assign(Q, { timelineCard, multitrack, drawCanvases, ctx2d, roundRect, rgba, redraw, kick });
})();
