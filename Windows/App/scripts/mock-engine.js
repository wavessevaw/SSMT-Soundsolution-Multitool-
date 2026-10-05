'use strict';
// A JavaScript stand-in for the Swift engine, for working on the interface without building the engine
// (SSMT_ENGINE=scripts/mock-engine.js npm start) and for the link tests. It speaks the same JSON lines but has no
// DSP: the console state is made up.

const readline = require('readline');

const out = (event, f = {}) => process.stdout.write(JSON.stringify({ event, ...f }) + '\n');
const names = ['Kick In', 'Snare Top', 'OH L', 'Bass DI', 'Gtr', 'Keys', 'Vox Lead', 'BV 1', 'Violin 1', 'Cello', 'Choir L', 'Choir R'];
const strips = names.map((name, i) => ({
  id: i + 1, name, gainDB: 24 + i, highPassOn: i > 2, highPassHz: 80 + i * 5, eqOn: true,
  eq: [{ type: 'lowShelf', frequency: 120, gainDB: 0, q: 0.7 }, { type: 'peaking', frequency: 400, gainDB: i % 3 ? -2.5 : 0, q: 1.4 },
    { type: 'peaking', frequency: 3000, gainDB: i % 4 ? 1.5 : 0, q: 1.4 }, { type: 'highShelf', frequency: 8000, gainDB: 0, q: 0.7 }],
  compressor: { enabled: i % 2 === 0, thresholdDB: -18, ratio: 3, attackMS: 10, releaseMS: 150, kneeDB: 2, makeupDB: 0, expander: false },
  faderDB: i === 6 ? -2 : -8 - i / 2, muted: i === 11, polarityInverted: false,
}));
const kinds = { 1: 'kick', 2: 'snare', 3: 'overhead', 4: 'bassGuitar', 5: 'electricGuitar', 6: 'keys', 7: 'maleVocal', 8: 'backingVocal', 9: 'violin', 10: 'cello', 11: 'choir', 12: 'choir' };
let family = '';
let host = '';
let learn = null;
const recordings = [];

function state() {
  out('state', { family, host, status: family ? 'connected' : 'disconnected', model: family === 'simulator' ? 'SSMT simulator' : family ? 'X32 · 4.06' : '',
    alive: !!family, readOnly: family === 'x32' || family === 'xAir', routing: 'local', character: 'musical', job: 'none',
    strips: family ? strips : [], buses: [], states: family === 'simulator' ? { 7: 'done', 8: 'tuning' } : {}, kinds });
}

function list() {
  out('recordings', { items: recordings, target: 20, dir: '/tmp/SSMT/Learning' });
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let c;
  try { c = JSON.parse(line); } catch (_) { return; }
  switch (c.cmd) {
    case 'hello': out('hello', { version: 'mock' }); list(); break;
    case 'state': state(); out('learn', learn ? { recording: true, ...learn } : { recording: false }); break;
    case 'connect':
      family = c.family; host = c.host || '';
      if (family !== 'simulator') {
        out('link', { host, port: family === 'xAir' ? 10024 : 10023 });
        out('send', { packets: [Buffer.from('/info\0\0\0,\0\0\0').toString('base64')] });
      }
      state();
      break;
    case 'disconnect': if (family && family !== 'simulator') out('unlink'); family = ''; state(); break;
    case 'osc': out('gotOsc', { data: c.data }); break;
    case 'discovered': out('found', { family: 'x32', ip: c.sender, name: 'X32-MOCK', model: 'X32', firmware: '4.06' }); break;
    case 'learnStart': learn = { title: c.title || 'Event', seconds: 0, frames: 0, changes: 0, params: 0 }; out('learn', { recording: true, ...learn }); break;
    case 'learnStop':
      if (learn) recordings.unshift({ file: 'x.ssmtlearn', title: learn.title, startedAt: Date.now() / 1000, duration: learn.seconds, console: family, model: 'X32 · 4.06', event: learn.seconds >= 300 });
      learn = null; out('learn', { recording: false }); list();
      break;
    case 'recordings': list(); break;
    case 'exportDataset': out('dataset', { path: '/tmp/SSMT/Learning/SSMT-dataset.jsonl', rows: 1240, recordings: recordings.length, bytes: 2400000 }); break;
    case 'patterns': out('patterns', { summary: c.lang === 'en' ? 'Events recorded: 3 of 20, 7.5 h in total.' : 'Записано мероприятий: 3 из 20, всего 7,5 ч.\n• Вокал (муж.) (3): гейн 34 дБ, фейдер -3.0 дБ, обрезной фильтр 120 Гц (100%), EQ3 +2.5 дБ на 3000 Гц, компрессор -20 дБ, 3.0:1, движений фейдера 5.8 в мин\n• Бочка (3): гейн 25 дБ, фейдер -6.0 дБ, движений фейдера 0.2 в мин' }); break;
    case 'prompt': out('prompt', { id: c.id || '', text: 'PROMPT ' + c.question }); break;
    case 'tune': out('log', { entries: [{ step: 1, channel: c.channel, note: { recognised: { _0: kinds[c.channel] || 'unknown', confidence: 0.9 } } }, { step: 2, channel: c.channel, note: { gain: { fromDB: 20, toDB: 31.5 } } }] }); break;
    default: break;
  }
});

setInterval(() => {
  if (family) out('meters', { channels: strips.map((s, i) => -40 + 25 * Math.abs(Math.sin(Date.now() / 700 + i))), buses: [] });
  if (learn) { learn.seconds += 1; learn.frames += 1; learn.params = Math.min(7498, learn.params + 150); if (Math.random() < 0.3) learn.changes += 1; out('learn', { recording: true, ...learn }); }
}, 1000);
out('ready', { version: 'mock' });
