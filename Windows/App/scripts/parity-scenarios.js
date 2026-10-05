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
// FOH Assist (SnapshotTests.testAssistWorkspace): AssistWorkspace alone on the window background, as the Mac test
// renders it. Each screen replays the Mac test's steps up to its own state on a fresh engine.
const assistSolo = (h) => h.eval(() => {
  const st = document.createElement('style');
  st.textContent = '#sidebar{display:none}#app{padding:0;gap:0}.workspace{gap:0}.backdrop{display:none}body{background:#070908}';
  document.head.appendChild(st);
  window.SSMT.sections.assist.state.autoScan = false;
});
const assistUI = (h, o) => h.eval((v) => Object.assign(window.SSMT.sections.assist.state, v), o);
async function assistSteps(h, upTo) {
  const order = ['connect', 'soundcheck', 'show', 'test', 'learn', 'locked'];
  const reach = (s) => order.indexOf(s) <= order.indexOf(upTo);
  await assistSolo(h);
  await assistUI(h, { family: 'x32', mode: 'soundcheck' });
  if (h.hasEngine) {
    h.send({ cmd: 'assistFixture', name: 'discovered' });
    await h.waitFor((e) => e.event === 'found' && e.ip === '192.168.1.71');
  }
  if (reach('soundcheck')) {
    await assistUI(h, { family: 'simulator', character: 'musical' });
    if (h.hasEngine) {
      h.send({ cmd: 'character', value: 'musical' });
      h.send({ cmd: 'connect', family: 'simulator' });
      await h.waitFor((e) => e.event === 'state' && e.status === 'connected');
      h.send({ cmd: 'tuneGroup', group: 'choir' });
      h.send({ cmd: 'runNow', steps: 14 });
      await h.waitFor((e) => e.event === 'state' && Object.values(e.states || {}).includes('done'));
    }
    await h.eval(() => {
      const A = window.SSMT.sections.assist.state;
      const s = (A.st.strips || []).find((x) => (A.st.states || {})[x.id] === 'done');
      A.selectedChannel = s ? s.id : null;
    });
  }
  if (reach('show')) {
    await assistUI(h, { mode: 'show' });
    if (h.hasEngine) {
      h.send({ cmd: 'guardStart' });
      h.send({ cmd: 'guardRun', steps: 24 });
      await h.waitFor((e) => e.event === 'state' && e.guarding && e.guardElapsed >= 5.75);
    }
  }
  if (reach('test')) {
    if (h.hasEngine) { h.send({ cmd: 'guardStop' }); await h.waitFor((e) => e.event === 'state' && e.status === 'connected' && !e.guarding); }
    await assistUI(h, { mode: 'test' });
  }
  if (reach('learn')) {
    await assistUI(h, { mode: 'learn', learnTitle: 'Мюзикл «Чикаго»' });
    if (h.hasEngine) {
      h.send({ cmd: 'assistFixture', name: 'sampleRecordings' });
      await h.waitFor((e) => e.event === 'patterns' && /из 20/.test(e.summary) && !/: 0 из/.test(e.summary));
    }
  }
  if (reach('locked')) {
    if (h.hasEngine) { h.send({ cmd: 'previewReadOnly', on: true }); await h.waitFor((e) => e.event === 'state' && e.readOnly); }
    await assistUI(h, { mode: 'soundcheck' });
  }
  await h.eval(() => { window.SSMT.S.section = 'assist'; window.SSMT.render(); });
  await h.settle();
}
const assist = (upTo) => (h) => assistSteps(h, upTo);
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
  { name: 'input-list', size: [1300, 2100], steps: ptch('workspace') },
  { name: 'input-list-print', size: [842, 595], fixture: 'input-list', steps: ptch('channels') },
  { name: 'stage-plan-print', size: [842, 595], fixture: 'input-list', steps: ptch('stage') },
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
  { name: 'assist-connect', size: [1500, 940], steps: assist('connect') },
  { name: 'assist', size: [1500, 940], steps: assist('soundcheck') },
  { name: 'assist-show', size: [1500, 940], steps: assist('show') },
  { name: 'assist-test', size: [1500, 940], steps: assist('test') },
  { name: 'assist-learn', size: [1500, 940], steps: assist('learn') },
  { name: 'assist-locked', size: [1500, 940], steps: assist('locked') },
];
