'use strict';
// End-to-end check of the engine binary (CI on Linux and Windows): the simulator, a learning recording, the pattern
// summary, and a read-only link to a fake X32 on 127.0.0.1:10023 that fails the run if the engine ever tries to set
// a value on it.
//   node scripts/engine-smoke.js <path to ssmt-engine[.exe]>

const assert = require('assert');
const dgram = require('dgram');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { EngineLink } = require('../src/engine-link');
const osc = require('./osc');

const enginePath = process.argv[2];
if (!enginePath) { console.error('usage: engine-smoke.js <engine>'); process.exit(2); }

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ssmt-smoke-'));
const link = new EngineLink({ command: path.resolve(enginePath) });
const events = [];
const waiters = [];
link.on('event', (ev) => {
  events.push(ev);
  for (const w of waiters.slice()) if (w.test(ev)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(ev); }
});
link.on('stderr', (s) => process.stderr.write(s));

function waitFor(test, ms, what) {
  const hit = events.find(test);
  if (hit) return Promise.resolve(hit);
  return new Promise((resolve, reject) => {
    const w = { test, resolve };
    waiters.push(w);
    setTimeout(() => { if (waiters.includes(w)) reject(new Error('timeout: ' + what)); }, ms);
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (s) => console.log('· ' + s);

/** A fake X32: answers /info, the name and fader of channel 1 and every other query (0.5), streams channel meters
 * and the RTA, and records every write it is sent. */
function fakeConsole() {
  const sock = dgram.createSocket('udp4');
  const writes = [];
  let packets = 0;
  let rta = null;
  sock.on('close', () => clearInterval(rta));
  sock.on('message', (msg, rinfo) => {
    packets++;
    const m = osc.decode(msg);
    if (m.tags && m.address !== '/meters') writes.push(m.address);
    const reply = (address, args) => sock.send(osc.encode(address, args), rinfo.port, rinfo.address);
    if (m.address === '/info') reply('/info', ['V2.07', 'FakeX32', 'X32', '4.06']);
    if (m.address === '/ch/01/config/name') reply('/ch/01/config/name', ['Vox Lead']);
    else if (m.address === '/ch/01/mix/fader') reply('/ch/01/mix/fader', [0.75]);
    else if (!m.tags && m.address !== '/info' && m.address !== '/xremote') reply(m.address, [0.5]);
    if (m.address === '/meters' && m.args[0] === '/meters/15' && !rta) {
      // The RTA streams ten times a second, as a console does after the request.
      const blob = Buffer.alloc(4 + 100 * 2);
      blob.writeUInt32LE(50, 0);
      for (let k = 0; k < 100; k++) blob.writeInt16LE(-40 * 256, 4 + 2 * k);
      rta = setInterval(() => reply('/meters/15', [blob]), 100);
    }
    if (m.address === '/meters' && m.args[0] === '/meters/1') {
      const blob = Buffer.alloc(4 + 32 * 4);
      blob.writeUInt32LE(32, 0);
      blob.writeFloatLE(0.1, 4);   // channel 1 at -20 dBFS
      reply('/meters/1', [blob]);
    }
  });
  return new Promise((resolve) => sock.bind(10023, '127.0.0.1', () => resolve({ sock, writes, count: () => packets })));
}

(async () => {
  link.start();
  await waitFor((e) => e.event === 'ready', 15000, 'ready');
  step('engine started');
  link.send({ cmd: 'hello', dataDir });
  const hello = await waitFor((e) => e.event === 'hello', 5000, 'hello');
  assert.ok(hello.version, 'version');

  // Simulator: console state and a learning recording.
  link.send({ cmd: 'connect', family: 'simulator' });
  const st = await waitFor((e) => e.event === 'state' && e.status === 'connected' && e.family === 'simulator', 5000, 'simulator state');
  assert.ok(st.strips.length >= 8, 'simulator strips');
  assert.strictEqual(st.readOnly, false);
  step(`simulator: ${st.strips.length} channels`);
  link.send({ cmd: 'learnStart', title: 'Smoke test' });
  const simLearn = await waitFor((e) => e.event === 'learn' && e.recording && e.frames >= 3, 8000, 'three recorded seconds');
  assert.ok(simLearn.params > 100, 'simulator parameters recorded: ' + simLearn.params);
  link.send({ cmd: 'learnStop' });
  const recs = await waitFor((e) => e.event === 'recordings' && e.items.some((r) => r.title === 'Smoke test'), 5000, 'recording listed');
  const files = fs.readdirSync(path.join(dataDir, 'Learning'));
  assert.strictEqual(files.length, 1, 'one recording file');
  step(`recording written: ${files[0]} (${recs.items[0].duration.toFixed(1)} s)`);
  link.send({ cmd: 'patterns', lang: 'ru' });
  const pat = await waitFor((e) => e.event === 'patterns', 5000, 'patterns');
  assert.match(pat.summary, /из 20/);
  link.send({ cmd: 'prompt', question: 'Какой гейн?', lang: 'ru', id: 'q1' });
  const pr = await waitFor((e) => e.event === 'prompt' && e.id === 'q1', 5000, 'prompt');
  assert.match(pr.text, /Вопрос: Какой гейн\?$/);
  step('patterns and model prompt built');

  // Soundcheck in the simulator.
  link.send({ cmd: 'tune', channel: 1 });
  const log = await waitFor((e) => e.event === 'log' && e.entries.length > 0, 15000, 'soundcheck log');
  step(`soundcheck in the simulator: ${log.entries.length} log entries`);
  link.send({ cmd: 'stopJob' });

  // A real console (fake X32 on localhost): read-only.
  const fake = await fakeConsole();
  link.send({ cmd: 'routing', preset: 'local' });
  link.send({ cmd: 'connect', family: 'x32', host: '127.0.0.1' });
  // The state streams in as the console answers, so wait for both the name and the fader of channel 1.
  const real = await waitFor((e) => e.event === 'state' && e.family === 'x32'
    && e.strips.some((s) => s.id === 1 && s.name === 'Vox Lead' && Math.abs(s.faderDB) < 0.01), 8000, 'console state over UDP (name and fader read)');
  assert.strictEqual(real.readOnly, true);
  await waitFor((e) => e.event === 'meters' && e.channels[0] > -21 && e.channels[0] < -19, 5000, 'channel meter');
  step(`console read over UDP: ${fake.count()} packets sent to it, model "${real.model}"`);
  // Soundcheck commands are refused on a real console.
  link.send({ cmd: 'tune', channel: 1 });
  await waitFor((e) => e.event === 'message' && e.key === 'simulatorOnly', 3000, 'soundcheck refused');
  link.send({ cmd: 'learnStart', title: 'Real console' });
  const realLearn = await waitFor((e) => e.event === 'learn' && e.recording && e.title === 'Real console' && e.frames >= 3, 8000, 'recording the console');
  assert.ok(realLearn.params >= 150, 'console parameters read: ' + realLearn.params);
  link.send({ cmd: 'learnStop' });
  await sleep(500);
  const realFile = fs.readdirSync(path.join(dataDir, 'Learning')).find((f) => f.includes('Real'));
  const lines = fs.readFileSync(path.join(dataDir, 'Learning', realFile), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.strictEqual(lines[0].format, 2);
  const allParams = Object.assign({}, ...lines.slice(1).map((f) => f.p || {}));
  assert.strictEqual(allParams['/ch/01/config/name'], 'Vox Lead');
  assert.ok(Object.keys(allParams).some((a) => a.startsWith('/ch/01/gate/')), 'gate parameters recorded');
  assert.ok(lines.slice(1).some((f) => f.m && f.m.rta && f.m.rta.length === 30), 'RTA recorded');
  step(`recording of the console: ${Object.keys(allParams).length} parameters, RTA and meters`);
  link.send({ cmd: 'exportDataset' });
  const ds = await waitFor((e) => e.event === 'dataset' && e.recordings === 2, 10000, 'training dataset');
  const rows = fs.readFileSync(ds.path, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  const vox = rows.find((r) => r.ch === 1 && r.name === 'Vox Lead');
  assert.ok(vox, 'dataset row of channel 1');
  assert.ok(vox.settings['mix/fader'] !== undefined && vox.rta && vox.rta.length === 30, 'dataset row has settings and RTA');
  step(`training dataset: ${ds.rows} rows from ${ds.recordings} recordings`);
  assert.deepStrictEqual(fake.writes, [], 'the engine sent writes to the console: ' + fake.writes.join(', '));
  step('no write reached the console');
  fake.sock.close();
  link.stop();
  fs.rmSync(dataDir, { recursive: true, force: true });
  console.log('engine smoke test passed');
  process.exit(0);
})().catch((e) => {
  console.error('FAILED:', e.message);
  console.error('last events:', events.slice(-5).map((e) => e.event).join(', '));
  link.stop();
  process.exit(1);
});
