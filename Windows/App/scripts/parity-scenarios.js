'use strict';
// The Mac snapshot tests' screens (App/Tests/Snapshots/SnapshotTests.swift) with their sizes. `steps` drives the
// Windows interface into the same state; a screen without steps is not ported yet. Keep names and sizes as on the Mac.

const go = (section) => async (h) => {
  await h.eval((s) => { window.SSMT.S.section = s; window.SSMT.render(); }, section);
  await h.settle();
};

// Qtrl (show control): the Mac renders the view alone with padding 16 (ShowWorkspace), 20 (WaveformEditor) or none
// (OSCDevicesView), without the app sidebar. The engine builds the sample show of SnapshotTests.prepareShow.
const QTRL_CSS = '#sidebar{display:none!important}#app{padding:16px!important;gap:0!important}#workspace-head{display:none!important}';
const qtrl = (variant, ui, engineOps = []) => async (h) => {
  await h.eval((css) => { const s = document.createElement('style'); s.textContent = css; document.head.appendChild(s); }, QTRL_CSS);
  if (h.hasEngine) {
    h.send({ cmd: 'show', op: 'fixture', variant });
    await h.waitFor((e) => e.event === 'showLive');
    for (const op of engineOps) h.send(Object.assign({ cmd: 'show' }, op));
    await h.settle();
  }
  await h.eval((u) => {
    const Q = window.SSMT.qtrl;
    Object.assign(Q.ui, u);
    if (u.solo === 'waveform') Q.ui.soloCue = Q.st.show.selection[0];
    if (u.oscStart) Q.oscStartWith(u.oscStart);
    window.SSMT.S.section = 'show';
    window.SSMT.render();
  }, ui);
  await h.settle();
};

module.exports = [
  { name: 'splash', size: [960, 600] },
  { name: 'instruments', size: [1380, 340] },
  { name: 'mini-meters', size: [560, 330] },
  { name: 'main-wizard', size: [1400, 900], steps: go('setup') },
  { name: 'main-wizard-en', size: [1400, 900], lang: 'en' },
  { name: 'main-expert', size: [1400, 900] },
  { name: 'step0-preparation', size: [1120, 1000] },
  { name: 'step4-tuner', size: [1000, 1300] },
  { name: 'step5-verify', size: [1000, 1000] },
  { name: 'step7-eq', size: [1100, 1300] },
  { name: 'finished', size: [1000, 1250] },
  { name: 'mini-window', size: [380, 330] },
  { name: 'report', size: [1100, 1474] },
  { name: 'input-list', size: [1300, 2100] },
  { name: 'input-list-print', size: [842, 595] },
  { name: 'stage-plan-print', size: [842, 595] },
  { name: 'account-register', size: [1200, 760] },
  { name: 'profile-overview', size: [1100, 760] },
  { name: 'profile-achievements', size: [1100, 900] },
  { name: 'profile-badge', size: [304, 140] },
  { name: 'achievement-toast', size: [520, 140] },
  { name: 'handbook-calculator', size: [1300, 820] },
  { name: 'handbook-pinout', size: [1300, 820] },
  { name: 'show-edit', size: [1500, 900], steps: qtrl('player', { sidebar: true, inspector: true, timeline: false, sidebarTab: 'pads', inspectorTab: 'main' }) },
  { name: 'show-show', size: [1500, 900], steps: qtrl('player', { sidebar: true, inspector: true, timeline: true, sidebarTab: 'active', inspectorTab: 'main' }, [{ op: 'showMode', on: true }]) },
  { name: 'show-group-multitrack', size: [1500, 900], steps: qtrl('multitrack', { sidebar: true, inspector: true, timeline: false, sidebarTab: 'active', inspectorTab: 'multitrack' }) },
  { name: 'show-waveform', size: [1000, 600], steps: qtrl('waveform', { solo: 'waveform' }) },
  { name: 'osc-devices', size: [640, 600], steps: qtrl('osc', { solo: 'osc', oscPage: 'list' }) },
  { name: 'osc-setup-eos', size: [640, 600], steps: qtrl('osc', { solo: 'osc', oscStart: 'eos' }) },
  { name: 'game-launcher', size: [1030, 540] },
  { name: 'assist-connect', size: [1500, 940] },
  { name: 'assist', size: [1500, 940] },
  { name: 'assist-show', size: [1500, 940] },
  { name: 'assist-test', size: [1500, 940] },
  { name: 'assist-learn', size: [1500, 940], steps: go('assist') },
  { name: 'assist-locked', size: [1500, 940] },
];
