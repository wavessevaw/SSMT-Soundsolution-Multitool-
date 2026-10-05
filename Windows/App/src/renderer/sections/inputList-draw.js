'use strict';
/* global SSMT */
// Ptch drawings and printable sheets, as App/SSMT/Views/InputList/StagePlanDrawing.swift, StageSymbols.swift and
// InputListExport.swift (PrintHeader, ChannelSheet, MixesSheet, StageSheet, InputListExporter). Everything here
// takes plain values and returns markup: SVG for the stage, self-contained HTML for the sheets (PDF / PNG export).

(function () {
  const { t, esc } = SSMT;

  /** ChannelGroup.color */
  const GROUP_COLORS = {
    drums: '#FF6B5A', percussion: '#FF9F5A', bass: '#C792EA', guitar: '#5AC8FA', keys: '#7EE0B5',
    vocals: '#FFD60A', playback: '#8E9CFF', fx: '#9AA0A6', other: '#6E7681',
  };
  const gray = (w) => { const v = Math.round(w * 255); return `rgb(${v},${v},${v})`; };

  /** StageInk: dark for the editor, black on white for printing and export. */
  const INK = {
    editor: { line: 'rgba(243,246,244,0.85)', fill: 'rgba(255,255,255,0.07)', accent: '#2EE59D', text: '#F3F6F4',
      muted: '#939C96', stage: 'rgba(255,255,255,0.03)', grid: 'rgba(255,255,255,0.05)' },
    print: { line: '#000', fill: gray(0.92), accent: gray(0.25), text: '#000', muted: gray(0.35), stage: '#fff', grid: gray(0.9) },
  };

  const n = (v) => Math.round(v * 1000) / 1000;
  let clipSeq = 0;

  /** StageGeometry: stage metres to view points, the front edge (audience) at the bottom. */
  function geometry(plan, W, H, margin = 28) {
    const scale = Math.min((W - 2 * margin) / Math.max(plan.width, 0.1), (H - 2 * margin) / Math.max(plan.depth, 0.1));
    const w = plan.width * scale, h = plan.depth * scale;
    const rect = { x: (W - w) / 2, y: (H - h) / 2, w, h };
    const point = (x, y) => [rect.x + x * scale, rect.y + rect.h - y * scale];
    return {
      scale, rect, point,
      stage: (px, py) => [(px - rect.x) / scale, (rect.y + rect.h - py) / scale],
      rectOf: (it) => {
        const [cx, cy] = point(it.x, it.y);
        const iw = it.width * scale, ih = it.depth * scale;
        return { x: cx - iw / 2, y: cy - ih / 2, w: iw, h: ih };
      },
    };
  }

  /** StageSymbols.draw: simple top-view symbols of stage equipment, drawn into a rectangle. */
  function symbol(kind, r, ink) {
    const lw = Math.min(2, Math.max(1, Math.min(r.w, r.h) * 0.04));
    const s = Math.min(r.w, r.h);
    const out = [];
    const stroke = (w) => `stroke="${ink.line}" stroke-width="${n(w === undefined ? lw : w)}"`;
    const pt = (x, y) => [r.x + x * r.w, r.y + y * r.h];
    const circle = (c, rad, filled = true) => out.push(`<circle cx="${n(c[0])}" cy="${n(c[1])}" r="${n(Math.max(rad, 0))}" fill="${filled ? ink.fill : 'none'}" ${stroke()}/>`);
    const box = (b, radius = 0, filled = true, w) => out.push(`<rect x="${n(b.x)}" y="${n(b.y)}" width="${n(Math.max(b.w, 0))}" height="${n(Math.max(b.h, 0))}" rx="${n(radius)}" fill="${filled ? ink.fill : 'none'}" ${stroke(w)}/>`);
    const line = (a, b, w) => out.push(`<line x1="${n(a[0])}" y1="${n(a[1])}" x2="${n(b[0])}" y2="${n(b[1])}" ${stroke(w)}/>`);
    const path = (d, filled = true) => out.push(`<path d="${d}" fill="${filled ? ink.fill : 'none'}" ${stroke()} stroke-linejoin="miter"/>`);
    const P = (p) => `${n(p[0])} ${n(p[1])}`;
    const inset = (b, d) => ({ x: b.x + d, y: b.y + d, w: b.w - 2 * d, h: b.h - 2 * d });
    const midX = r.x + r.w / 2, midY = r.y + r.h / 2;

    switch (kind) {
      case 'drumKit':
        circle(pt(0.5, 0.42), s * 0.22);
        circle(pt(0.24, 0.62), s * 0.11);
        circle(pt(0.38, 0.2), s * 0.09);
        circle(pt(0.62, 0.2), s * 0.09);
        circle(pt(0.78, 0.6), s * 0.13);
        circle(pt(0.1, 0.4), s * 0.1, false);
        circle(pt(0.18, 0.12), s * 0.13, false);
        circle(pt(0.88, 0.22), s * 0.15, false);
        circle(pt(0.5, 0.88), s * 0.05);
        break;
      case 'percussion':
        circle(pt(0.25, 0.45), s * 0.2);
        circle(pt(0.55, 0.4), s * 0.22);
        circle(pt(0.82, 0.6), s * 0.12);
        circle(pt(0.82, 0.3), s * 0.1);
        break;
      case 'guitarAmp': case 'bassAmp': {
        box(inset(r, lw), s * 0.08);
        const rows = kind === 'bassAmp' ? 2 : 1, cols = 2;
        for (let i = 0; i < rows; i++) {
          for (let j = 0; j < cols; j++) {
            circle([r.x + (j + 0.5) / cols * r.w, r.y + (i + 0.5) / rows * r.h], Math.min(r.w / cols, r.h / rows) * 0.32, false);
          }
        }
        break;
      }
      case 'keyboard': {
        box(inset(r, lw), s * 0.06);
        const keys = { x: r.x + r.w * 0.05, y: r.y + r.h * 0.18, w: r.w * 0.9, h: r.h * 0.64 };
        for (let k = 1; k < 14; k++) {
          const x = keys.x + keys.w * k / 14;
          line([x, keys.y + keys.h * 0.25], [x, keys.y + keys.h], lw * 0.6);
        }
        box(keys, 0, false, lw * 0.8);
        break;
      }
      case 'piano': {
        path(`M${P(pt(0.08, 0.95))} L${P(pt(0.08, 0.15))} Q${P(pt(0.15, 0))} ${P(pt(0.55, 0.05))} Q${P(pt(0.95, 0.15))} ${P(pt(0.92, 0.6))} L${P(pt(0.92, 0.95))} Z`);
        box({ x: r.x + r.w * 0.08, y: r.y + r.h * 0.86, w: r.w * 0.84, h: r.h * 0.09 }, 0, false, lw * 0.8);
        break;
      }
      case 'vocalMic':
        line(pt(0.5, 0.5), pt(0.15, 0.85));
        circle(pt(0.5, 0.5), s * 0.08);
        circle(pt(0.62, 0.36), s * 0.14);
        break;
      case 'micStand':
        for (const a of [90, 210, 330]) {
          const rad = a * Math.PI / 180;
          line(pt(0.5, 0.5), [midX + Math.cos(rad) * s * 0.42, midY + Math.sin(rad) * s * 0.42]);
        }
        circle(pt(0.5, 0.5), s * 0.1);
        break;
      case 'diBox':
        box(inset(r, lw), s * 0.1);
        out.push(`<text x="${n(midX)}" y="${n(midY)}" text-anchor="middle" dominant-baseline="central" font-size="${n(s * 0.42)}" font-weight="700" fill="${ink.line}">DI</text>`);
        break;
      case 'wedge':
        path(`M${P(pt(0.05, 0.95))} L${P(pt(0.95, 0.95))} L${P(pt(0.82, 0.08))} L${P(pt(0.18, 0.08))} Z`);
        circle(pt(0.5, 0.58), s * 0.18, false);
        break;
      case 'iem': {
        // Arc from 200° to 340° through the top (angles grow clockwise on screen).
        const c = pt(0.5, 0.62), rad = s * 0.32;
        const a0 = 200 * Math.PI / 180, a1 = 340 * Math.PI / 180;
        out.push(`<path d="M${n(c[0] + Math.cos(a0) * rad)} ${n(c[1] + Math.sin(a0) * rad)} A${n(rad)} ${n(rad)} 0 0 1 ${n(c[0] + Math.cos(a1) * rad)} ${n(c[1] + Math.sin(a1) * rad)}" fill="none" ${stroke()}/>`);
        box({ x: midX - s * 0.42, y: midY - s * 0.05, w: s * 0.16, h: s * 0.32 }, s * 0.05);
        box({ x: midX + s * 0.26, y: midY - s * 0.05, w: s * 0.16, h: s * 0.32 }, s * 0.05);
        break;
      }
      case 'sideFill': case 'speaker':
        box(inset(r, lw), s * 0.05);
        circle(pt(0.5, kind === 'sideFill' ? 0.62 : 0.5), s * 0.28, false);
        if (kind === 'sideFill') box({ x: midX - r.w * 0.25, y: r.y + r.h * 0.1, w: r.w * 0.5, h: r.h * 0.18 });
        break;
      case 'riser': {
        const rr = inset(r, lw);
        const id = 'ilclip' + (++clipSeq);
        out.push(`<rect x="${n(rr.x)}" y="${n(rr.y)}" width="${n(Math.max(rr.w, 0))}" height="${n(Math.max(rr.h, 0))}" fill="${ink.fill}"/>`);
        out.push(`<clipPath id="${id}"><rect x="${n(rr.x)}" y="${n(rr.y)}" width="${n(Math.max(rr.w, 0))}" height="${n(Math.max(rr.h, 0))}"/></clipPath>`);
        const hatch = [];
        const step = Math.max(8, s * 0.12);
        for (let x = rr.x - rr.h; x < rr.x + rr.w; x += step) hatch.push(`M${n(x)} ${n(rr.y + rr.h)} L${n(x + rr.h)} ${n(rr.y)}`);
        out.push(`<path clip-path="url(#${id})" d="${hatch.join(' ')}" fill="none" stroke="${ink.line}" stroke-opacity="0.25" stroke-width="${n(lw * 0.6)}"/>`);
        box(rr, 0, false, lw * 1.2);
        break;
      }
      case 'person':
        out.push(`<ellipse cx="${n(r.x + r.w * 0.5)}" cy="${n(r.y + r.h * 0.63)}" rx="${n(r.w * 0.4)}" ry="${n(r.h * 0.21)}" fill="${ink.fill}" ${stroke()}/>`);
        circle(pt(0.5, 0.4), s * 0.2);
        break;
      case 'chair':
        box({ x: r.x + r.w * 0.15, y: r.y + r.h * 0.25, w: r.w * 0.7, h: r.h * 0.65 }, s * 0.1);
        box({ x: r.x + r.w * 0.15, y: r.y + r.h * 0.08, w: r.w * 0.7, h: r.h * 0.14 }, s * 0.05);
        break;
      case 'musicStand':
        box({ x: r.x + r.w * 0.05, y: r.y + r.h * 0.15, w: r.w * 0.9, h: r.h * 0.3 }, 1);
        line(pt(0.5, 0.45), pt(0.5, 0.9));
        break;
      case 'powerDrop': {
        circle(pt(0.5, 0.5), s * 0.45);
        const b = [[0.56, 0.12], [0.36, 0.55], [0.52, 0.55], [0.44, 0.88], [0.66, 0.42], [0.5, 0.42]].map(([x, y]) => P(pt(x, y)));
        out.push(`<path d="M${b.join(' L')} Z" fill="${ink.accent}"/>`);
        break;
      }
      default: break;
    }
    return out.join('');
  }

  /** StageSymbolIcon: the palette icon of a kind (38 × 28 by default). */
  function symbolIcon(kind, size, w = 38, h = 28, ink = INK.editor) {
    let body;
    if (kind === 'text') {
      body = `<text x="${w / 2}" y="${h / 2}" text-anchor="middle" dominant-baseline="central" font-size="${n(h * 0.7)}" font-weight="600" fill="${ink.line}">T</text>`;
    } else {
      const d = size || { w: 1, d: 1 };
      const aspect = d.w / d.d;
      const iw = aspect >= 1 ? w : h * aspect;
      const ih = aspect >= 1 ? w / aspect : h;
      body = symbol(kind, { x: (w - iw) / 2, y: (h - ih) / 2, w: iw, h: Math.min(ih, h) }, ink);
    }
    return `<svg class="il-symbol" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" aria-hidden="true">${body}</svg>`;
  }

  /** StagePlanDrawing: the whole stage plan as one vector drawing (editor background and export). */
  function drawPlan(plan, ink, W, H, o = {}) {
    const g = geometry(plan, W, H);
    const R = g.rect;
    const out = [];
    out.push(`<rect x="${n(R.x)}" y="${n(R.y)}" width="${n(R.w)}" height="${n(R.h)}" fill="${ink.stage}"/>`);
    if (o.showGrid !== false) {
      const grid = [];
      for (let x = 0; x <= plan.width + 1e-9; x += 1) { const a = g.point(x, 0), b = g.point(x, plan.depth); grid.push(`M${n(a[0])} ${n(a[1])} L${n(b[0])} ${n(b[1])}`); }
      for (let y = 0; y <= plan.depth + 1e-9; y += 1) { const a = g.point(0, y), b = g.point(plan.width, y); grid.push(`M${n(a[0])} ${n(a[1])} L${n(b[0])} ${n(b[1])}`); }
      out.push(`<path d="${grid.join(' ')}" fill="none" stroke="${ink.grid}" stroke-width="1"/>`);
    }
    out.push(`<rect x="${n(R.x)}" y="${n(R.y)}" width="${n(R.w)}" height="${n(R.h)}" fill="none" stroke="${ink.line}" stroke-width="1.5"/>`);
    out.push(`<line x1="${n(R.x)}" y1="${n(R.y + R.h)}" x2="${n(R.x + R.w)}" y2="${n(R.y + R.h)}" stroke="${ink.line}" stroke-width="3"/>`);
    out.push(`<text x="${n(R.x + R.w / 2)}" y="${n(R.y + R.h + 14)}" text-anchor="middle" dominant-baseline="central" font-size="11" font-weight="500" fill="${ink.muted}">${esc(o.audience || '')}</text>`);
    out.push(`<text x="${n(R.x + R.w)}" y="${n(R.y - 10)}" text-anchor="end" dominant-baseline="central" font-size="10" class="tnum" fill="${ink.muted}">${SSMT.format('%.1f × %.1f m', plan.width, plan.depth)}</text>`);

    for (const item of plan.items) {
      const r = g.rectOf(item);
      const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
      const tr = `translate(${n(cx)} ${n(cy)}) rotate(${n(item.rotation || 0)})`;
      if (item.kind === 'text') {
        out.push(`<g transform="${tr}"><text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-size="${n((item.fontSize || 14) * g.scale / 40)}" font-weight="600" fill="${ink.text}">${esc(item.label)}</text></g>`);
      } else {
        out.push(`<g transform="${tr}">${symbol(item.kind, { x: -r.w / 2, y: -r.h / 2, w: r.w, h: r.h }, ink)}</g>`);
        // Caption under the symbol (not rotated, so it stays readable).
        const caption = [item.label, item.info].filter((s) => s).join(' · ');
        if (caption) {
          const extent = Math.max(r.w, r.h) / 2;
          out.push(`<text x="${n(cx)}" y="${n(cy + extent + 8)}" text-anchor="middle" dominant-baseline="central" font-size="${n(Math.max(8, Math.min(12, g.scale * 0.22)))}" fill="${ink.text}">${esc(caption)}</text>`);
        }
      }
      if (o.selected && item.id === o.selected) {
        out.push(`<rect x="${n(r.x - 4)}" y="${n(r.y - 4)}" width="${n(r.w + 8)}" height="${n(r.h + 8)}" rx="4" fill="none" stroke="#2EE59D" stroke-width="1.5" stroke-dasharray="4 3"/>`);
      }
    }
    if (o.hits) {
      // Hit areas of the items (the editor's drag handles): at least 16 points, rotated with the item.
      for (const item of plan.items) {
        const r = g.rectOf(item);
        const w = Math.max(r.w, 16), h = Math.max(r.h, 16);
        const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
        out.push(`<rect class="il-hit" data-item="${esc(item.id)}" x="${n(-w / 2)}" y="${n(-h / 2)}" width="${n(w)}" height="${n(h)}" transform="translate(${n(cx)} ${n(cy)}) rotate(${n(item.rotation || 0)})" fill="transparent"/>`);
      }
    }
    return `<svg class="il-plan" width="${n(W)}" height="${n(H)}" viewBox="0 0 ${n(W)} ${n(H)}">${out.join('')}</svg>`;
  }

  // MARK: printable sheets (A4 landscape, black on white)

  const PAGE = { w: 842, h: 595 };
  /** Height of PrintHeader: title line 24 + 4 + info line 14 + 4 + rule (4 + 1.5). */
  const HEADER_H = 24 + 4 + 14 + 4 + 5.5;

  let measureCtx = null;
  /** Text width in the sheet font, for `minimumScaleFactor`: the font shrinks (to 70 % at most) to fit one line. */
  function fitSize(text, size, weight, avail) {
    if (!text) return size;
    if (!measureCtx) measureCtx = document.createElement('canvas').getContext('2d');
    measureCtx.font = `${weight} ${size}px Inter, 'Segoe UI', sans-serif`;
    const w = measureCtx.measureText(text).width;
    return w <= avail ? size : Math.max(size * 0.7, size * avail / w);
  }

  function dateText(doc) {
    if (!doc.date) return '';
    const d = new Date(doc.date);
    if (isNaN(d)) return '';
    return new Intl.DateTimeFormat(SSMT.S.lang === 'en' ? 'en-US' : 'ru-RU', { day: 'numeric', month: 'long', year: 'numeric' }).format(d);
  }

  /** PrintHeader: show header printed on every sheet. */
  function printHeader(doc, title, page) {
    const line = [doc.event, doc.venue, dateText(doc)].filter((s) => s).join(' · ');
    const contact = [doc.engineer, doc.contact].filter((s) => s).join(' · ');
    return `<div class="ph"><div class="ph-top"><b>${esc(doc.artist || title)}</b><span>${esc(page ? `${title} · ${page}` : title)}</span></div>
      <div class="ph-line"><span>${esc(line)}</span><span>${esc(contact)}</span></div><div class="ph-rule"></div></div>`;
  }

  const CH_COLS = [['№', 34], ['source', 150], ['mic', 120], ['stand', 92], ['48V', 34], ['stagebox', 66], ['insert', 76], ['group', 76], ['notes', 0]];
  const NOTES_W = PAGE.w - 56 - 4 - CH_COLS.reduce((a, c) => a + c[1], 0) - (CH_COLS.length - 1) * 0.5;

  function sheetRow(cells, { header, color, shade }) {
    const parts = cells.map((text, i) => {
      const w = CH_COLS[i][1] || NOTES_W;
      const size = header ? 9 : 10.5;
      const weight = header || i <= 1 ? 600 : 400;
      const fs = fitSize(text, size, weight, w - 10);
      return `<span class="c${i === 0 ? ' r' : ''}" style="width:${w}px;font-size:${n(fs)}px;font-weight:${weight}">${esc(text)}</span>${i < cells.length - 1 ? '<i class="sep"></i>' : ''}`;
    }).join('');
    return `<div class="cr${header ? ' h' : shade ? ' shade' : ''}"><i class="stripe" style="background:${color || 'transparent'}"></i>${parts}</div>`;
  }

  /** ChannelSheet: one sheet of the channel list. */
  function channelSheet(doc, rows, page) {
    const head = sheetRow(CH_COLS.map(([k]) => (k === '№' || k === '48V' ? k : t('il.col.' + k))), { header: true });
    const body = rows.map((c, k) => sheetRow([String(c.number), c.source, c.mic, c.stand === 'none' ? '' : t('stand.' + c.stand),
      c.phantom ? '48V' : '', c.stagebox, c.insert, t('chgroup.' + c.group), c.notes], { color: GROUP_COLORS[c.group], shade: k % 2 === 1 })).join('');
    return `<div class="sheet ch">${printHeader(doc, t('il.print.title'), page)}<div class="ct">${head}${body}</div></div>`;
  }

  /** MixesSheet: monitor mixes, pull list and notes. */
  function mixesSheet(doc, summary, page) {
    const s = summary;
    const mixes = doc.mixes.slice().sort((a, b) => a.number - b.number).map((m) => `<div class="mx"><span class="no">${m.number}</span><span class="nm">${esc(m.name)}</span>
      <span class="tp">${esc(t('mixtype.' + m.type) + (m.stereo ? ' · stereo' : ''))}</span><span class="nt">${esc(m.notes)}</span></div><div class="mx-rule"></div>`).join('');
    const models = s.models.map((m) => `<div class="t11">${esc(`${m.count} × ${m.name}`)}</div>`).join('');
    const stands = s.stands.length ? `<div class="t11 b st">${esc(t('il.sum.stands'))}</div>${s.stands.map((st) => `<div class="t11">${esc(`${st.count} × ` + t('stand.' + st.type))}</div>`).join('')}` : '';
    const notes = doc.notes ? `<div class="t13">${esc(t('il.notes'))}</div><div class="t11 pre">${esc(doc.notes)}</div>` : '';
    return `<div class="sheet mixes">${printHeader(doc, t('il.print.title'), page)}
      <div class="cols"><div class="left"><div class="t13">${esc(t('il.mixes'))}</div>${doc.mixes.length ? '' : '<div class="t11">—</div>'}${mixes}</div>
      <div class="right"><div class="t13">${esc(t('il.summary'))}</div><div class="t11">${esc(t('il.print.counts', s.channelCount, s.phantomCount, s.mixCount))}</div>${models}${stands}</div></div>${notes}</div>`;
  }

  /** StageSheet: the stage plan sheet. */
  function stageSheet(doc, page) {
    const W = PAGE.w - 56, H = PAGE.h - 56 - HEADER_H - 10;
    return `<div class="sheet stage">${printHeader(doc, t('il.stage'), page)}
      <div class="plan">${drawPlan(doc.stage, INK.print, W, H, { audience: t('stage.audience'), showGrid: false })}</div></div>`;
  }

  /** InputListExporter.sheets: all sheets of the document in print order. */
  function sheets(doc, summary, pages) {
    const byId = new Map(doc.channels.map((c) => [c.id, c]));
    const pg = (pages && pages.length ? pages : [[]]).map((ids) => ids.map((id) => byId.get(id)).filter(Boolean));
    const total = pg.length + 2;
    const out = pg.map((rows, i) => channelSheet(doc, rows, `${i + 1} / ${total}`));
    out.push(mixesSheet(doc, summary, `${pg.length + 1} / ${total}`));
    out.push(stageSheet(doc, `${total} / ${total}`));
    return out;
  }

  const SHEET_CSS = `
    html, body { margin: 0; padding: 0; background: #fff; }
    body { font-family: Inter, 'Segoe UI', sans-serif; -webkit-font-smoothing: antialiased; color: #000; }
    .sheet { position: relative; width: 842px; height: 595px; padding: 28px; box-sizing: border-box; background: #fff; color: #000;
      overflow: hidden; display: flex; flex-direction: column; font-variant-numeric: tabular-nums; }
    .sheet.ch, .sheet.stage { gap: 10px; }
    .sheet.mixes { gap: 14px; }
    .ph { display: flex; flex-direction: column; gap: 4px; flex: none; }
    .ph-top { display: flex; align-items: baseline; justify-content: space-between; height: 24px; }
    .ph-top b { font-size: 20px; font-weight: 700; line-height: 24px; white-space: nowrap; }
    .ph-top span { font-size: 12px; font-weight: 600; color: ${gray(0.35)}; white-space: nowrap; }
    .ph-line { display: flex; justify-content: space-between; font-size: 11px; line-height: 14px; height: 14px; color: ${gray(0.25)}; white-space: nowrap; }
    .ph-rule { height: 1.5px; background: #000; margin-top: 4px; }
    .ct { flex: none; outline: 1px solid #000; outline-offset: -0.5px; }
    .cr { display: flex; height: 19px; align-items: stretch; background: #fff; box-shadow: inset 0 -0.5px 0 ${gray(0.75)}; }
    .cr.h { height: 18px; background: ${gray(0.85)}; }
    .cr.shade { background: ${gray(0.95)}; }
    .cr .stripe { width: 4px; flex: none; }
    .cr .sep { width: 0.5px; flex: none; background: ${gray(0.75)}; }
    .cr .c { flex: none; display: flex; align-items: center; padding: 0 5px; box-sizing: border-box; white-space: nowrap; overflow: hidden; }
    .cr .c.r { justify-content: flex-end; }
    .cols { display: flex; align-items: flex-start; gap: 24px; }
    .cols .left { flex: 1; display: flex; flex-direction: column; gap: 6px; min-width: 0; }
    .cols .right { width: 250px; flex: none; display: flex; flex-direction: column; gap: 6px; }
    .t13 { font-size: 13px; font-weight: 700; line-height: 16px; }
    .t11 { font-size: 11px; line-height: 13px; }
    .t11.b { font-weight: 600; }
    .t11.st { margin-top: 6px; }
    .pre { white-space: pre-wrap; }
    .mx { display: flex; gap: 8px; align-items: baseline; font-size: 11px; line-height: 13px; }
    .mx .no { width: 22px; text-align: right; font-weight: 600; flex: none; }
    .mx .nm { width: 150px; flex: none; }
    .mx .tp { width: 110px; flex: none; }
    .mx .nt { font-size: 10px; color: ${gray(0.3)}; }
    .mx-rule { height: 0.5px; background: ${gray(0.8)}; }
    .plan { flex: 1; min-height: 0; }
    .plan svg { display: block; font-family: Inter, 'Segoe UI', sans-serif; }
    .tnum { font-variant-numeric: tabular-nums; }`;

  /** A self-contained page of sheets for renderPDF / renderPNG (relative URLs resolve against src/renderer/). */
  function printDocument(sheetList, { pdf = false, zoom = 1 } = {}) {
    const page = pdf ? `@page { size: ${PAGE.w}pt ${PAGE.h}pt; margin: 0; } html { zoom: ${96 / 72}; } .sheet { break-after: page; } .sheet:last-child { break-after: auto; }` : (zoom !== 1 ? `html { zoom: ${zoom}; }` : '');
    return `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="fonts/inter.css"><style>${SHEET_CSS}${page}</style></head><body>${sheetList.join('')}</body></html>`;
  }

  SSMT.ilDraw = { GROUP_COLORS, INK, PAGE, geometry, symbol, symbolIcon, drawPlan, channelSheet, mixesSheet, stageSheet, sheets, printDocument, SHEET_CSS };
})();
