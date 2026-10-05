'use strict';
// The UDP side of the app: packets the engine asks to send reach the console, the console's answers reach the
// engine, and a console search forwards answers to the engine.

const test = require('node:test');
const assert = require('node:assert');
const dgram = require('dgram');
const path = require('path');
const { EngineLink, broadcastAddresses, XINFO } = require('../src/engine-link');
const osc = require('../scripts/osc');

const mock = path.join(__dirname, '..', 'scripts', 'mock-engine.js');

function startLink() {
  const link = new EngineLink({ command: process.execPath, args: [mock] });
  const events = [];
  link.on('event', (e) => events.push(e));
  link.start();
  const wait = (pred, ms = 3000) => new Promise((resolve, reject) => {
    const t0 = Date.now();
    const iv = setInterval(() => {
      const e = events.find(pred);
      if (e) { clearInterval(iv); resolve(e); } else if (Date.now() - t0 > ms) { clearInterval(iv); reject(new Error('timeout')); }
    }, 10);
  });
  return { link, events, wait };
}

function udpServer(port) {
  const s = dgram.createSocket('udp4');
  const got = [];
  s.on('message', (msg, rinfo) => {
    got.push(osc.decode(msg).address);
    s.send(osc.encode('/info', ['V2.07', 'X', 'X32', '4.06']), rinfo.port, rinfo.address);
  });
  return new Promise((resolve) => s.bind(port, '127.0.0.1', () => resolve({ s, got })));
}

test('XINFO is a valid OSC message', () => {
  assert.deepStrictEqual(osc.decode(XINFO), { address: '/xinfo', tags: '', args: [] });
  assert.ok(broadcastAddresses().includes('255.255.255.255'));
});

test('engine packets go to the console and answers come back', async () => {
  const srv = await udpServer(10023);
  const { link, wait } = startLink();
  try {
    await wait((e) => e.event === 'ready');
    link.send({ cmd: 'connect', family: 'x32', host: '127.0.0.1' });
    const back = await wait((e) => e.event === 'gotOsc');
    assert.strictEqual(osc.decode(Buffer.from(back.data, 'base64')).address, '/info');
    assert.deepStrictEqual(srv.got, ['/info']);
    // "link" / "send" stay inside the link; the interface only sees its own events.
    link.send({ cmd: 'disconnect' });
    await wait((e) => e.event === 'state' && e.status === 'disconnected');
    assert.strictEqual(link.sock, null);
  } finally {
    link.stop();
    srv.s.close();
  }
});

test('console search forwards answers to the engine', async () => {
  const srv = await udpServer(10024);
  const { link, wait } = startLink();
  link.scanAddresses = ['127.0.0.1'];
  try {
    await wait((e) => e.event === 'ready');
    await link.scan(0.4, [10024]);
    const found = await wait((e) => e.event === 'found');
    assert.strictEqual(found.ip, '127.0.0.1');
    await wait((e) => e.event === 'scanDone');
    assert.deepStrictEqual(srv.got, ['/xinfo']);
  } finally {
    link.stop();
    srv.s.close();
  }
});
