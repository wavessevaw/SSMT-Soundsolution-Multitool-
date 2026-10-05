'use strict';
// The Mac snapshot tests' screens (App/Tests/Snapshots/SnapshotTests.swift) with their sizes. `steps` drives the
// Windows interface into the same state; a screen without steps is not ported yet. Keep names and sizes as on the Mac.

const go = (section) => async (h) => {
  await h.eval((s) => { window.SSMT.S.section = s; window.SSMT.render(); }, section);
  await h.settle();
};

// System setup: the snapshot tests' session (SimulatedSetupSession.completeWizard in the engine, or the recorded
// fixtures/setup.json), then the main window in a mode, or one view drawn on its own as the Mac test draws it.
const setupSession = async (h) => {
  if (!h.hasEngine) return;
  h.send({ cmd: 'setup', do: 'fixture' });
  await h.waitFor((e) => e.event === 'setupState' && e.wizard && e.wizard.step === 'eqVerification', 120000);
};
const setup = ({ mode = 'wizard', view = null } = {}) => async (h) => {
  await setupSession(h);
  await h.eval(({ mode: m, view: v }) => {
    window.SSMT.setupUI.mode = m;
    window.SSMT.S.section = 'setup';
    if (v) window.SSMT.setupStandalone(v); else window.SSMT.render();
  }, { mode, view });
  await h.settle();
};
const mini = async (h) => {
  const path = require('path');
  await h.page.goto('file://' + path.join(__dirname, '..', 'src', 'renderer', 'mini.html'));
  if (!h.hasEngine) {
    const events = JSON.parse(require('fs').readFileSync(path.join(__dirname, 'fixtures', 'setup.json'), 'utf8'));
    for (const ev of events) await h.eval((e) => window.__ssmtListeners.forEach((fn) => fn(e)), ev);
  }
  await setupSession(h);
  await h.settle();
};

module.exports = [
  { name: 'splash', size: [960, 600] },
  { name: 'instruments', size: [1380, 340], fixture: 'setup', steps: setup({ view: 'instruments' }) },
  { name: 'mini-meters', size: [560, 330], fixture: 'setup', steps: setup({ view: 'mini-meters' }) },
  { name: 'main-wizard', size: [1400, 900], fixture: 'setup', steps: setup() },
  { name: 'main-wizard-en', size: [1400, 900], lang: 'en', fixture: 'setup', steps: setup() },
  { name: 'main-expert', size: [1400, 900], fixture: 'setup', steps: setup({ mode: 'expert' }) },
  { name: 'step0-preparation', size: [1120, 1000], fixture: 'setup', steps: setup({ view: 'step0-preparation' }) },
  { name: 'step4-tuner', size: [1000, 1300], fixture: 'setup', steps: setup({ view: 'step4-tuner' }) },
  { name: 'step5-verify', size: [1000, 1000], fixture: 'setup', steps: setup({ view: 'step5-verify' }) },
  { name: 'step7-eq', size: [1100, 1300], fixture: 'setup', steps: setup({ view: 'step7-eq' }) },
  { name: 'finished', size: [1000, 1250], fixture: 'setup', steps: setup({ view: 'finished' }) },
  { name: 'mini-window', size: [380, 330], steps: mini },
  { name: 'report', size: [1100, 1474], fixture: 'setup', steps: setup({ view: 'report' }) },
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
  { name: 'show-edit', size: [1500, 900] },
  { name: 'show-show', size: [1500, 900] },
  { name: 'show-group-multitrack', size: [1500, 900] },
  { name: 'show-waveform', size: [1000, 600] },
  { name: 'osc-devices', size: [640, 600] },
  { name: 'osc-setup-eos', size: [640, 600] },
  { name: 'game-launcher', size: [1030, 540] },
  { name: 'assist-connect', size: [1500, 940] },
  { name: 'assist', size: [1500, 940] },
  { name: 'assist-show', size: [1500, 940] },
  { name: 'assist-test', size: [1500, 940] },
  { name: 'assist-learn', size: [1500, 940], steps: go('assist') },
  { name: 'assist-locked', size: [1500, 940] },
];
