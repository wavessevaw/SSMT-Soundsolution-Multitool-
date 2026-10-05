'use strict';
// The Mac snapshot tests' screens (App/Tests/Snapshots/SnapshotTests.swift) with their sizes. `steps` drives the
// Windows interface into the same state; a screen without steps is not ported yet. Keep names and sizes as on the Mac.

const go = (section) => async (h) => {
  await h.eval((s) => { window.SSMT.S.section = s; window.SSMT.render(); }, section);
  await h.settle();
};

/** A view alone, as the Mac test renders it (SSMT.snapshot sets up the same state); `engine` commands go first. */
const snap = (name, engine = []) => async (h) => {
  for (const c of engine) h.send(c);
  if (engine.length) await h.settle();
  await h.eval((n) => window.SSMT.snapshot(n), name);
  await h.settle();
};
const sample = [{ cmd: 'profilePreview', sample: true }];

module.exports = [
  { name: 'splash', size: [960, 600], steps: snap('splash') },
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
  { name: 'account-register', size: [1200, 760], steps: snap('account-register', [{ cmd: 'profilePreview' }]) },
  { name: 'profile-overview', size: [1100, 760], steps: snap('profile-overview', sample) },
  { name: 'profile-achievements', size: [1100, 900], steps: snap('profile-achievements', sample) },
  { name: 'profile-badge', size: [304, 140], steps: snap('profile-badge', sample) },
  { name: 'achievement-toast', size: [520, 140], steps: snap('achievement-toast', sample) },
  { name: 'handbook-calculator', size: [1300, 820], steps: snap('handbook-calculator') },
  { name: 'handbook-pinout', size: [1300, 820], steps: snap('handbook-pinout') },
  { name: 'show-edit', size: [1500, 900] },
  { name: 'show-show', size: [1500, 900] },
  { name: 'show-group-multitrack', size: [1500, 900] },
  { name: 'show-waveform', size: [1000, 600] },
  { name: 'osc-devices', size: [640, 600] },
  { name: 'osc-setup-eos', size: [640, 600] },
  { name: 'game-launcher', size: [1030, 540], steps: snap('game-launcher') },
  { name: 'assist-connect', size: [1500, 940] },
  { name: 'assist', size: [1500, 940] },
  { name: 'assist-show', size: [1500, 940] },
  { name: 'assist-test', size: [1500, 940] },
  { name: 'assist-learn', size: [1500, 940], steps: go('assist') },
  { name: 'assist-locked', size: [1500, 940] },
];
