'use strict';
// The Mac snapshot tests' screens (App/Tests/Snapshots/SnapshotTests.swift) with their sizes. `steps` drives the
// Windows interface into the same state; a screen without steps is not ported yet. Keep names and sizes as on the Mac.

const go = (section) => async (h) => {
  await h.eval((s) => { window.SSMT.S.section = s; window.SSMT.render(); }, section);
  await h.settle();
};

// Ptch: the sample document of SnapshotTests.sampleInputList (engine command il.fixture, or the recorded events).
const ptch = (show) => async (h) => {
  if (h.hasEngine) {
    h.send({ cmd: 'il.fixture' });
    await h.waitFor((e) => e.event === 'il.state' && e.doc && e.doc.artist === 'The Sample Band');
  }
  await h.eval(() => { window.SSMT.S.section = 'inputList'; window.SSMT.render(); });
  await h.settle();
  await h.eval((v) => {
    if (v === 'workspace') {
      // InputListWorkspace().padding(16) on its own, as the Mac test renders it.
      const st = document.createElement('style');
      st.textContent = '#sidebar, #workspace-head { display: none !important; } #app { padding: 16px; gap: 0; } .workspace { gap: 0; }';
      document.head.appendChild(st);
      window.SSMT.render();
    } else {
      const html = window.SSMT.inputList.sheet(v);
      document.open(); document.write(html); document.close();
    }
  }, show);
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
  { name: 'input-list', size: [1300, 2100], steps: ptch('workspace') },
  { name: 'input-list-print', size: [842, 595], fixture: 'input-list', steps: ptch('channels') },
  { name: 'stage-plan-print', size: [842, 595], fixture: 'input-list', steps: ptch('stage') },
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
