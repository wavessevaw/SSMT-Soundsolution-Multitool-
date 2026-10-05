'use strict';
/* global SSMT */
// Components of App/SSMT/DesignSystem/Components.swift as HTML builders. Each takes plain values and returns markup.

(function () {
  const { esc, icon } = SSMT;
  const attrs = (o) => Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== false)
    .map(([k, v]) => (v === true ? k : `${k}="${esc(v)}"`)).join(' ');

  const UI = {
    attrs,
    /** CardTitle: short coloured bar, title, optional marking on the right. */
    cardTitle(title, { marking, tint } = {}) {
      return `<div class="card-title"><span class="bar"${tint ? ` style="background:${tint}"` : ''}></span><h3>${esc(title)}</h3>${marking != null ? `<span class="marking">${esc(marking)}</span>` : ''}</div>`;
    },
    /** Panel: glass card with an optional title. */
    panel(title, body, { marking, tint, cls = '', style = '' } = {}) {
      const head = title != null || marking != null ? UI.cardTitle(title || '', { marking, tint }) : '';
      return `<section class="glass panel ${cls}"${style ? ` style="${style}"` : ''}>${head}${body}</section>`;
    },
    /** glassCard(padding:, radius:, highlighted:). */
    glass(body, { padding = 18, radius, highlighted, cls = '', style = '' } = {}) {
      return `<div class="glass ${highlighted ? 'highlighted' : ''} ${cls}" style="padding:${padding}px;${radius ? `border-radius:${radius}px;` : ''}${style}">${body}</div>`;
    },
    /** SSMTButtonStyle: kind primary | secondary | danger; act/arg wire it to the section's actions. */
    button(label, { kind = 'secondary', act, arg, active, disabled, icon: ic, title, cls = '' } = {}) {
      return `<button ${attrs({ class: `btn ${kind} ${active ? 'active' : ''} ${cls}`, 'data-act': act, 'data-arg': arg, disabled, title })}>${ic ? icon(ic, 14) : ''}${label ? esc(label) : ''}</button>`;
    },
    /** StatusBadge: level good | warning | error | idle. */
    statusBadge(level, text) {
      const ic = { good: 'checkmark', warning: 'exclamationmark.triangle.fill', error: 'xmark.octagon.fill', idle: 'minus.circle' }[level];
      return `<span class="status-badge ${level}">${icon(ic, 10)}${esc(text)}</span>`;
    },
    iconTile(name, { tint, size = 40 } = {}) {
      return `<span class="icon-tile" style="width:${size}px;height:${size}px;border-radius:${size * 0.28}px;${tint ? `color:${tint}` : ''}">${icon(name, Math.round(size * 0.42))}</span>`;
    },
    checkDot(done, failed = false) {
      return `<span class="check-dot ${done ? 'done' : failed ? 'failed' : ''}">${done ? icon('checkmark', 11) : failed ? icon('exclamationmark', 11) : ''}</span>`;
    },
    /** MeterBar: −60…0 dBFS with a peak tick. */
    meterBar(label, rms, peak, clipped, clipText) {
      const f = (db) => Math.min(1, Math.max(0, (db + 60) / 60)) * 100;
      return `<div class="meter-bar"><div class="head"><span class="label">${esc(label)}</span><span class="value">${Number(rms).toFixed(1)} dBFS</span>${clipped ? `<span class="clip">${esc(clipText)}</span>` : ''}</div>
        <div class="track"><div class="fill ${clipped ? 'clipped' : ''}" style="width:max(4px,${f(rms)}%)"></div><div class="peak" style="left:calc(${f(peak)}% - 1px)"></div></div></div>`;
    },
    divider() { return '<div class="divider"></div>'; },
    utilityRow(ic, title, act, arg) {
      return `<button ${attrs({ class: 'utility-row', 'data-act': act, 'data-arg': arg })}>${icon(ic, 15)}<span>${esc(title)}</span></button>`;
    },
    /** StageRow: numbered circle on a line, title and subtitle; state done | current | upcoming. */
    stageRow(number, title, subtitle, state, isLast) {
      return `<div class="stage-row ${state}"><div class="rail"><div class="num">${state === 'done' ? SSMT.icon('checkmark', 12) : number}</div>${isLast ? '' : '<div class="line"></div>'}</div>
        <div class="titles"><b>${esc(title)}</b><span>${esc(subtitle)}</span></div></div>`;
    },
    segmented(options, value, change) {
      return `<div class="segmented">${options.map(([v, label]) => `<button ${attrs({ class: v === value ? 'on' : '', 'data-act': change, 'data-arg': v })}>${esc(label)}</button>`).join('')}</div>`;
    },
    /** Closeness colour, 0 = far (red) … 1 = on target (green), as Theme.closeness. */
    closeness(c) {
      const stops = [[0, [1, 0.271, 0.227]], [0.4, [1, 0.624, 0.039]], [0.75, [1, 0.839, 0.039]], [1, [0.204, 0.827, 0.6]]];
      const x = Math.min(Math.max(Number.isFinite(c) ? c : 0, 0), 1);
      for (let i = 1; i < stops.length; i++) {
        if (x <= stops[i][0]) {
          const [x0, a] = stops[i - 1], [x1, b] = stops[i], t = (x - x0) / (x1 - x0);
          const ch = (k) => Math.round((a[k] + (b[k] - a[k]) * t) * 255);
          return `rgb(${ch(0)},${ch(1)},${ch(2)})`;
        }
      }
      return '#34D399';
    },
  };
  SSMT.UI = UI;
})();
