'use strict';
/* global SSMT */
// The setup report (App/SSMT/Views/ReportView.swift) and its export as PDF or PNG at 2× (ReportExporter): the same
// page drawn from the engine's report (SSMTCore SetupReport) and wizard curves, 1100 px wide.

(function () {
  const { S, t, esc, UI, format: f } = SSMT;
  const X = SSMT.SetupUI;
  const C = X.C;

  function dateText(ms) {
    const d = new Date(ms || Date.now());
    const ru = S.lang === 'ru';
    return new Intl.DateTimeFormat(ru ? 'ru-RU' : 'en-US', { day: 'numeric', month: 'long', year: 'numeric', hour: ru ? '2-digit' : 'numeric', minute: '2-digit' }).format(d);
  }

  const cell = (title, value, detail) => `<div class="rp-cell"><span class="title">${esc(title)}</span><b>${esc(value)}</b>${detail ? `<span class="detail">${esc(detail)}</span>` : ''}</div>`;
  const opt = (v, fmt) => (v == null ? '—' : f(fmt, v));

  /** ReportView body: header, alignment, verification, EQ and conditions. */
  function html(D) {
    const s = D.s || {}, r = s.report || {}, w = s.wizard || {};
    const fr = (D.st && D.st.frequencies) || [];
    let out = `<div class="rp-header"><img src="brand-full.png" alt=""><div class="titles"><h1>${esc(t('report.title'))}</h1><span>${esc(dateText(r.date))}</span></div>
      <span class="spacer"></span><span class="brand">SSMT</span></div>`;
    const a = r.alignment;
    if (a) {
      out += UI.panel(t('report.alignment'), `<div class="rp-cells">
        ${cell(t(a.delayTarget === 'mains' ? 'card.delay.mains' : 'card.delay.sub'), a.delayTarget === 'none' ? '0.00 ms' : f('+%.2f ms', a.delayMs), f('≈ %.2f m', a.delayMeters))}
        ${cell(t('card.polarity'), t(a.invert ? 'polarity.invert' : 'polarity.normal'), '')}
        ${cell(t('card.level'), f('%+.1f dB', a.subLevelDB), '')}</div>
        ${a.ambiguous ? X.hazardNotice(t('results.ambiguous')) : ''}`, { marking: t('report.crossover', a.crossover) });
    }
    const v = r.verification;
    if (v) {
      const c = w.curves || {};
      const curves = [];
      if (c.baseline) curves.push({ label: t('curve.before'), db: c.baseline, color: C.textMuted });
      if (c.prediction) curves.push({ label: t('curve.prediction'), db: c.prediction, color: C.dataBlue, dashed: true });
      if (c.verification) curves.push({ label: t('curve.after'), db: c.verification, color: C.accent });
      out += UI.panel(t('report.verification'), `<div class="rp-cells">
        ${cell(t('verify.dip'), opt(v.dipAfter, '%.1f dB'), t('curve.before') + ': ' + opt(v.dipBefore, '%.1f dB'))}
        ${cell(t('verify.sum'), opt(v.sumAfter, '%+.1f dB'), t('curve.before') + ': ' + opt(v.sumBefore, '%+.1f dB'))}
        ${cell(t('verify.predictionError'), f('%.1f dB', v.predictionError ?? NaN), '')}</div>
        ${X.comparisonPlot(fr, curves, w.alignment ? w.alignment.overlapBand : null, [20, 1000], false, 230)}`, { marking: t(`verdict.${v.verdict}`) });
    }
    const e = r.eq;
    if (e) {
      let plot = '';
      const er = w.eqResult;
      if (er) {
        const sm = er.smoothed || {};
        const c = w.curves || {};
        const curves = [
          { label: t('curve.before'), db: sm.measured, color: C.textMuted },
          { label: t('eq.target'), db: sm.target, color: C.dataBlue, dashed: true },
        ];
        if (c.eqAfterSmoothed) curves.push({ label: t('curve.after'), db: c.eqAfterSmoothed, f: c.eqAfterFrequencies, color: C.accent });
        else curves.push({ label: t('curve.prediction'), db: sm.predicted, color: C.accent });
        plot = X.comparisonPlot(er.frequencies, curves, er.workingRange, [20, 20000], false, 230);
      }
      const rows = e.filters.map((fl, i) => `<span class="mono">${i + 1}</span><span>${esc(t(fl.group === 'sub' ? 'group.subs' : 'group.mains'))}</span>
        <span class="mono">${esc(fl.label)}</span><span class="mono semibold">${esc(f('%+.1f dB', fl.gainDB))}</span><span class="mono">${esc(fl.width)}</span>`).join('');
      out += UI.panel(t('report.eq'), `<div class="rp-cells">
        ${cell(t('gauge.deviation'), e.deviationAfter != null ? f('±%.1f dB', e.deviationAfter) : '—', t('curve.before') + f(': ±%.1f dB', e.deviationBefore))}
        ${cell(t('gauge.score'), String(e.scoreAfter != null ? e.scoreAfter : e.scoreBefore), t('curve.before') + ': ' + e.scoreBefore)}
        ${cell(t('eq.target'), t(`target.${e.target}`), '')}</div>
        ${plot}
        <div class="rp-filters">${['#', t('report.group'), 'Fc', 'Gain', 'Q'].map((h) => `<span class="hdr">${esc(h)}</span>`).join('')}${rows}</div>
        <p class="rp-note">${esc(t('gauge.score.note'))}</p>`, { marking: t('report.eqMarking', e.points, e.iterations) });
    }
    const iface = r.interfaceName === 'Simulation' ? t('setup.simulation') : r.interfaceName;
    const row = (k, val) => `<span class="k">${esc(k)}</span><span class="v">${esc(val)}</span>`;
    out += UI.panel(t('report.conditions'), `<div class="rp-conditions">
      ${row(t('setup.interface'), `${iface || ''} · ${Math.trunc(r.sampleRate || 48000)} Hz`)}
      ${row(t('setup.temperature'), f('%.0f °C', r.temperature ?? 20))}
      ${row(t('cal.mic'), r.microphone || t('cal.mic.uncalibrated'))}
      ${r.referenceDelayMs != null ? row(t('report.delayLocked'), f('%.2f ms', r.referenceDelayMs)) : ''}</div>`);
    return `<div class="report">${out}</div>`;
  }

  /** Renders the report off screen into a self-contained page (plots as images) and saves it. */
  async function exportReport(D, pdf) {
    const api = SSMT.api;
    if (!api || !api.saveFile) return;
    const path = await api.saveFile({ defaultName: 'SSMT-report.' + (pdf ? 'pdf' : 'png'), filters: [{ name: pdf ? 'PDF' : 'PNG', extensions: [pdf ? 'pdf' : 'png'] }] });
    if (!path) return;
    const host = document.createElement('div');
    host.className = 'report-export-host';
    X.scope('rp');
    host.innerHTML = html(D);
    document.body.appendChild(host);
    try {
      await document.fonts.ready;
      X.paint(host);
      for (const cv of host.querySelectorAll('canvas')) {
        const img = document.createElement('img');
        img.src = cv.toDataURL('image/png');
        img.className = cv.className;
        img.style.cssText = cv.style.cssText + `;width:${cv.getBoundingClientRect().width}px;height:${cv.getBoundingClientRect().height}px`;
        cv.replaceWith(img);
      }
      const height = Math.ceil(host.firstElementChild.getBoundingClientRect().height);
      const scale = pdf ? 1 : 2;
      const page = `<!doctype html><html lang="${S.lang}"><head><meta charset="utf-8">
        <link rel="stylesheet" href="fonts/inter.css"><link rel="stylesheet" href="theme.css"><link rel="stylesheet" href="sections/setup.css">
        <style>@page { size: 1100px ${height}px; margin: 0 } html, body { height: auto; overflow: visible; background: #070908 } body { zoom: ${scale} }</style>
        </head><body>${host.innerHTML}</body></html>`;
      if (pdf) await api.renderPDF({ html: page, path, pageSize: [1100, height] });
      else await api.renderPNG({ html: page, path, width: 1100, height, scale });
    } catch (e) {
      SSMT.send({ cmd: 'setup', do: 'error', text: String((e && e.message) || e) });
    } finally {
      host.remove();
    }
  }

  SSMT.setupReport = { html, export: exportReport };
})();
