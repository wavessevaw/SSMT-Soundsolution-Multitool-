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

/** A fake X32: answers /info and two parameters of channel 1, and records every write it is sent. */
function fakeConsole() {
  const sock = dgram.createSocket('udp4');
  const writes = [];
  let packets = 0;
  sock.on('message', (msg, rinfo) => {
    packets++;
    const m = osc.decode(msg);
    if (m.tags && m.address !== '/meters') writes.push(m.address);
    const reply = (address, args) => sock.send(osc.encode(address, args), rinfo.port, rinfo.address);
    if (m.address === '/info') reply('/info', ['V2.07', 'FakeX32', 'X32', '4.06']);
    if (m.address === '/ch/01/config/name') reply('/ch/01/config/name', ['Vox Lead']);
    if (m.address === '/ch/01/mix/fader') reply('/ch/01/mix/fader', [0.75]);
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
  await waitFor((e) => e.event === 'learn' && e.recording && e.frames >= 3, 8000, 'three recorded seconds');
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
  const real = await waitFor((e) => e.event === 'state' && e.family === 'x32' && e.strips.some((s) => s.id === 1 && s.name === 'Vox Lead'), 8000, 'console state over UDP');
  assert.strictEqual(real.readOnly, true);
  assert.ok(Math.abs(real.strips.find((s) => s.id === 1).faderDB) < 0.01, 'fader read');
  await waitFor((e) => e.event === 'meters' && e.channels[0] > -21 && e.channels[0] < -19, 5000, 'channel meter');
  step(`console read over UDP: ${fake.count()} packets sent to it, model "${real.model}"`);
  // Soundcheck commands are refused on a real console.
  link.send({ cmd: 'tune', channel: 1 });
  await waitFor((e) => e.event === 'message' && e.key === 'simulatorOnly', 3000, 'soundcheck refused');
  link.send({ cmd: 'learnStart', title: 'Real console' });
  await waitFor((e) => e.event === 'learn' && e.recording && e.frames >= 2, 6000, 'recording the console');
  link.send({ cmd: 'learnStop' });
  await sleep(500);
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
