'use strict';
/* global SSMT */
// The floating diagnostics window (App/SSMT/Views/MiniPanel.swift, MiniDiagnosticsView): live EQ curve against the
// target, SPL, input meter, quality and STOP. Its own always-on-top window (src/main.js, 'mini' messages); the
// engine's setup events reach it as they reach the main window.

(function () {
  const { S, t, esc, icon, UI, store, format: f } = SSMT;
  const X = SSMT.SetupUI;
  const C = X.C;
  const D = { s: null, live: null, freqs: null };
  let menu = false;
  const api = SSMT.api || {};
  const mini = (op, value) => { if (api.mini) api.mini(op, value); };

  SSMT.onEngine((ev) => {
    if (ev.event === 'setupStatic') D.freqs = ev.frequencies;
    else if (ev.event === 'setupState') D.s = ev;
    else if (ev.event === 'setupLive') D.live = ev.running ? ev : null;
    else return;
    SSMT.render();
  });
  SSMT.send({ cmd: 'setup', do: 'state' });

  // Opacity and click-through are remembered here and applied by the main process.
  const opacity = Number(store.get('mini.opacity', '0.92'));
  mini('opacity', opacity);
  mini('clickThrough', store.get('mini.clickThrough', '0') === '1');

  function statusLine() {
    const s = D.s || {};
    const expert = store.get('setup.mode', 'wizard') === 'expert';
    const step = !expert && s.wizard ? ' · ' + t(`wizard.step.${s.wizard.stepIndex}`) : '';
    return t(expert ? 'mode.expert' : 'mode.wizard') + step + (s.noiseOn ? ' · ●' : '');
  }

  function draw() {
    S.lang = store.get('lang', S.lang);
    X.scope('mini');
    const s = D.s || {}, l = D.live;
    const m = l && l.mini;
    const spl = l && l.spl;
    const cellv = (name, v) => `<div class="spl-cell"><b>${esc(v == null ? '—' : f('%.0f', v))}</b><span>${esc(name)}</span></div>`;
    const meter = (label, x) => UI.meterBar(label, x ? x.rms ?? -120 : -120, x ? x.peak ?? -120 : -120, !!(x && x.clipped), t('meters.clip'));
    const q = l ? l.coherence : null;
    const qColor = q == null ? C.textMuted : UI.closeness((q - 0.3) / 0.5);
    const delay = s.delay && s.delay.reliable ? f('Δt %.2f ms', s.delay.ms) : t('mini.noDelay');
    const target = s.wizard && s.wizard.config && s.wizard.config.target ? s.wizard.config.target.preset : 'livePA';
    const items = [1, 0.85, 0.7, 0.55].map((o) => `<button data-mini="opacity" data-arg="${o}">${esc(f('%@ %.0f %%', t('mini.opacity'), o * 100))}</button>`).join('');
    document.getElementById('mini').innerHTML = `<div class="glass mini-panel">
      <div class="mini-head"><img src="brand-mark.png" alt=""><span class="status">${esc(statusLine())}</span><span class="spacer"></span>
        <span class="popup-wrap"><button class="mini-icon" data-mini="menu">${icon('gearshape', 13)}</button>${menu ? `<div class="mac-menu right">${items}<div class="sep"></div>
          <button data-mini="clickThrough">${esc(t('mini.clickThrough'))}</button></div>` : ''}</span>
        <button class="mini-icon" data-mini="expand" title="${esc(t('mini.expand'))}">${icon('arrow.up.left.and.arrow.down.right', 13)}</button></div>
      <div class="mini-curve">${m && D.freqs ? X.miniCurve(D.freqs, m.mag, m.target) : ''}<span class="dev">${esc(m && m.deviation != null ? f('±%.1f dB', m.deviation) : '—')}</span></div>
      <div class="spl-row">${cellv('LAeq', spl && spl.laeq)}${cellv('LCeq', spl && spl.lceq)}${cellv('LCpk', spl && spl.lpeak)}${cellv('LAFmax', spl && spl.lmax)}</div>
      ${meter(t('meters.mic'), l && l.mic)}
      ${s.referenceMode && s.referenceMode !== 'internalSignal' ? meter(t('meters.ref'), l && l.ref) : ''}
      <div class="row q-row">${X.indicatorLamp(qColor, 16)}<span class="q">${esc(q == null ? t('quality.none') : f('%@ %.0f %%', t('gauge.quality'), q * 100))}</span>
        <span class="spacer"></span><span class="mono11 secondary">${esc(delay)}</span></div>
      <div class="row"><span class="t11 muted">${esc(t(`target.${target}`))}</span><span class="spacer"></span>
        <button class="btn danger stop" data-mini="stop">${X.sym('stop.fill', 12)}<span>${esc(t('action.stop'))}</span></button></div>
    </div>`;
    X.paint(document.getElementById('mini'));
  }
  SSMT.draw = draw;

  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-mini]');
    if (!el) { if (menu) { menu = false; draw(); } return; }
    const a = el.dataset.mini;
    if (a === 'menu') { menu = !menu; draw(); return; }
    menu = false;
    if (a === 'opacity') { store.set('mini.opacity', el.dataset.arg); mini('opacity', Number(el.dataset.arg)); }
    else if (a === 'clickThrough') { store.set('mini.clickThrough', '1'); mini('clickThrough', true); }
    else if (a === 'expand') mini('expand');
    else if (a === 'stop') SSMT.send({ cmd: 'setup', do: 'stop' });
    draw();
  });
  window.addEventListener('storage', () => SSMT.render());
  SSMT.render();
})();
