'use strict';
// Parity check between the Mac app and the Windows interface. Renders every screen the Mac snapshot tests render
// (App/Tests/Snapshots/SnapshotTests.swift), at the same size and with the same data, from the Windows interface
// in Chromium driven by the real engine, and puts each next to the Mac reference with the share of differing pixels
// (the Mac test's own measure). Writes build/parity/: win/<name>.png, compare/<name>.png, report.json, index.html.
//   node scripts/parity.js [path to ssmt-engine] [--only name,name]
// Without an engine the screens that need none are still drawn. Chromium: CHROMIUM_PATH, else Playwright's.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { chromium } = require('playwright-core');
const SCENARIOS = require('./parity-scenarios');

const root = path.join(__dirname, '..');
const repo = path.join(root, '..', '..');
const out = path.join(repo, 'build', 'parity');
const refs = path.join(repo, 'App', 'Tests', 'Snapshots', 'References');
const args = process.argv.slice(2);
const enginePath = args.find((a) => !a.startsWith('--') && !args[args.indexOf(a) - 1]?.startsWith('--only'));
const only = (args[args.indexOf('--only') + 1] || '').split(',').filter((x) => args.includes('--only') && x);

function chromiumPath() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || path.join(os.homedir(), '.cache', 'ms-playwright');
  for (const d of fs.existsSync(base) ? fs.readdirSync(base).sort().reverse() : []) {
    for (const p of ['chrome-linux/chrome', 'chrome-win/chrome.exe', 'chrome-mac/Chromium.app/Contents/MacOS/Chromium']) {
      if (d.startsWith('chromium-') && fs.existsSync(path.join(base, d, p))) return path.join(base, d, p);
    }
  }
  return undefined;
}

/** The engine as a child process speaking JSON lines (as Electron's main process does). */
function startEngine(dataDir) {
  if (!enginePath) return null;
  const p = spawn(path.resolve(enginePath), [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const listeners = [];
  let buf = '';
  p.stdout.on('data', (d) => {
    buf += d.toString('utf8');
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      try { const ev = JSON.parse(line); listeners.forEach((fn) => fn(ev)); } catch (_) { /* not JSON */ }
    }
  });
  const send = (cmd) => p.stdin.write(JSON.stringify(cmd) + '\n');
  send({ cmd: 'hello', dataDir });
  return { send, on: (fn) => listeners.push(fn), stop: () => p.kill() };
}

async function main() {
  fs.mkdirSync(path.join(out, 'win'), { recursive: true });
  fs.mkdirSync(path.join(out, 'compare'), { recursive: true });
  const browser = await chromium.launch({ executablePath: chromiumPath(), args: ['--font-render-hinting=none', '--force-color-profile=srgb'] });
  const report = [];
  for (const sc of SCENARIOS) {
    if (only.length && !only.includes(sc.name)) continue;
    const entry = { name: sc.name, size: sc.size, ported: !!sc.steps };
    report.push(entry);
    if (!sc.steps) continue;
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ssmt-parity-'));
    const engine = startEngine(dataDir);
    const page = await browser.newPage({ viewport: { width: sc.size[0], height: sc.size[1] }, deviceScaleFactor: 1 });
    const events = [];
    await page.exposeFunction('__ssmtSend', (cmd) => engine && engine.send(cmd));
    await page.addInitScript(({ lang }) => {
      localStorage.clear();
      localStorage.setItem('ssmt.lang', lang);
      window.__ssmtListeners = [];
      window.ssmt = {
        send: (cmd) => window.__ssmtSend(cmd),
        onEvent: (fn) => window.__ssmtListeners.push(fn),
        scan: async () => true, llmModels: async () => [], llmAsk: async () => '', openFolder: async () => true,
        version: async () => 'parity', preview: true,
      };
    }, { lang: sc.lang || 'ru' });
    if (engine) engine.on((ev) => { events.push(ev); page.evaluate((e) => window.__ssmtListeners.forEach((fn) => fn(e)), ev).catch(() => {}); });
    await page.goto('file://' + path.join(root, 'src', 'renderer', 'index.html') + (sc.query || ''));
    // Without an engine, a screen can replay recorded engine events (scripts/fixtures/<name>.json, an array) so the
    // interface can be checked where Swift is not available. CI always uses the real engine.
    const fixture = path.join(__dirname, 'fixtures', (sc.fixture || sc.name) + '.json');
    if (!engine && fs.existsSync(fixture)) {
      for (const ev of JSON.parse(fs.readFileSync(fixture, 'utf8'))) {
        events.push(ev);
        await page.evaluate((e) => window.__ssmtListeners.forEach((fn) => fn(e)), ev);
      }
    }
    const h = {
      page, events, engine,
      send: (cmd) => engine && engine.send(cmd),
      hasEngine: !!engine,
      waitFor: async (test, ms = 10000) => {
        const t0 = Date.now();
        while (Date.now() - t0 < ms) { const e = events.find(test); if (e) return e; await page.waitForTimeout(50); }
        throw new Error('timeout waiting for an engine event');
      },
      eval: (fn, arg) => page.evaluate(fn, arg),
      settle: () => page.waitForTimeout(600),
    };
    try {
      await sc.steps(h);
      await page.evaluate(() => document.fonts.ready);
      await page.waitForTimeout(400);
      const file = path.join(out, 'win', sc.name + '.png');
      await page.screenshot({ path: file, clip: sc.clip || undefined });
      entry.win = path.relative(out, file);
      const ref = path.join(refs, sc.name + '.png');
      if (fs.existsSync(ref)) Object.assign(entry, await compare(browser, ref, file, path.join(out, 'compare', sc.name + '.png')));
    } catch (e) {
      entry.error = String(e && e.message || e);
    }
    await page.close();
    if (engine) engine.stop();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
  await browser.close();
  fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2));
  fs.writeFileSync(path.join(out, 'index.html'), html(report));
  for (const r of report) {
    console.log(`${r.name.padEnd(24)} ${!r.ported ? 'not ported' : r.error ? 'ERROR ' + r.error : r.diff === undefined ? 'drawn (no Mac reference)' : (r.diff * 100).toFixed(1) + ' % differ' + (r.sizeMismatch ? ' (size differs)' : '')}`);
  }
  const ported = report.filter((r) => r.ported).length;
  console.log(`parity: ${ported} of ${report.length} Mac screens drawn on Windows`);
  if (report.some((r) => r.error)) process.exit(1);
}

/** Mac | Windows | difference, and the Mac test's measure: share of pixels (every 2nd) differing by > 0.08. */
async function compare(browser, macFile, winFile, outFile) {
  const page = await browser.newPage();
  const res = await page.evaluate(async ({ mac, win }) => {
    const load = (src) => new Promise((ok, bad) => { const i = new Image(); i.onload = () => ok(i); i.onerror = bad; i.src = src; });
    const [a, b] = await Promise.all([load(mac), load(win)]);
    const w = Math.max(a.width, b.width), hgt = Math.max(a.height, b.height);
    const px = (img) => { const c = document.createElement('canvas'); c.width = w; c.height = hgt; const g = c.getContext('2d'); g.fillStyle = '#000'; g.fillRect(0, 0, w, hgt); g.drawImage(img, 0, 0); return g.getImageData(0, 0, w, hgt); };
    const da = px(a), db = px(b);
    const diff = new ImageData(w, hgt);
    let n = 0, total = 0;
    for (let y = 0; y < hgt; y++) {
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        const d = Math.max(Math.abs(da.data[i] - db.data[i]), Math.abs(da.data[i + 1] - db.data[i + 1]), Math.abs(da.data[i + 2] - db.data[i + 2])) / 255;
        const off = d > 0.08;
        diff.data[i] = off ? 255 : da.data[i] * 0.25; diff.data[i + 1] = off ? 40 : da.data[i + 1] * 0.25; diff.data[i + 2] = off ? 80 : da.data[i + 2] * 0.25; diff.data[i + 3] = 255;
        if (x % 2 === 0 && y % 2 === 0) { total++; if (off) n++; }
      }
    }
    const c = document.createElement('canvas'); c.width = w * 3 + 40; c.height = hgt + 30;
    const g = c.getContext('2d'); g.fillStyle = '#222'; g.fillRect(0, 0, c.width, c.height);
    g.fillStyle = '#ddd'; g.font = '16px sans-serif';
    g.fillText('macOS', 8, 20); g.fillText('Windows', w + 28, 20); g.fillText('difference', 2 * w + 48, 20);
    g.putImageData(da, 0, 30); g.putImageData(db, w + 20, 30); g.putImageData(diff, 2 * w + 40, 30);
    return { diff: total ? n / total : 0, sizeMismatch: a.width !== b.width || a.height !== b.height, png: c.toDataURL('image/png') };
  }, { mac: 'data:image/png;base64,' + fs.readFileSync(macFile).toString('base64'), win: 'data:image/png;base64,' + fs.readFileSync(winFile).toString('base64') });
  await page.close();
  fs.writeFileSync(outFile, Buffer.from(res.png.split(',')[1], 'base64'));
  return { diff: res.diff, sizeMismatch: res.sizeMismatch, compare: path.relative(out, outFile) };
}

function html(report) {
  const rows = report.map((r) => `<section><h2>${r.name} <small>${!r.ported ? 'not ported yet' : r.error ? 'error: ' + r.error : r.diff === undefined ? 'no Mac reference' : (r.diff * 100).toFixed(1) + ' % of pixels differ'}</small></h2>
    ${r.compare ? `<img src="${r.compare}">` : r.win ? `<img src="${r.win}">` : ''}</section>`).join('');
  return `<!doctype html><meta charset="utf-8"><title>SSMT parity</title><style>body{background:#111;color:#eee;font:14px sans-serif;padding:20px}img{max-width:100%;border:1px solid #333}small{color:#999;font-weight:normal}</style>
    <h1>SSMT: macOS and Windows, screen by screen</h1>${rows}`;
}

main().catch((e) => { console.error(e); process.exit(1); });
