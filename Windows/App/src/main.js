'use strict';
// SSMT for Windows: Electron shell. Starts the engine, owns the UDP sockets (engine-link.js) and the local language
// model calls (Ollama), and shows the interface in src/renderer.

const { app, BrowserWindow, ipcMain, powerSaveBlocker, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { EngineLink } = require('./engine-link');

let win = null;
let link = null;

function engineCommand() {
  const override = process.env.SSMT_ENGINE;
  if (override) {
    // A JavaScript engine stand-in (development): run it with Electron's own Node.
    if (override.endsWith('.js')) return { command: process.execPath, args: [override], env: { ELECTRON_RUN_AS_NODE: '1' } };
    return { command: override };
  }
  const dir = app.isPackaged ? path.join(process.resourcesPath, 'engine') : path.join(__dirname, '..', 'engine');
  return { command: path.join(dir, process.platform === 'win32' ? 'ssmt-engine.exe' : 'ssmt-engine') };
}

function dataDir() {
  const dir = path.join(app.getPath('documents'), 'SSMT');
  try { fs.mkdirSync(dir, { recursive: true }); } catch (_) { /* reported by the engine when it writes */ }
  return dir;
}

// The computer must not sleep while a show is being recorded (hours, nobody touching it).
let awake = null;
function keepAwake(on) {
  if (on && awake === null) awake = powerSaveBlocker.start('prevent-app-suspension');
  if (!on && awake !== null) { powerSaveBlocker.stop(awake); awake = null; }
}

function startEngine() {
  link = new EngineLink(engineCommand());
  link.on('event', (ev) => {
    if (ev.event === 'learn') keepAwake(!!ev.recording);
    if (win && !win.isDestroyed()) win.webContents.send('engine', ev);
  });
  link.on('stderr', (s) => process.stderr.write(s));
  link.start();
  link.send({ cmd: 'hello', dataDir: dataDir() });
}

function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 1000,
    minHeight: 640,
    backgroundColor: '#070908',
    title: 'SSMT',
    icon: path.join(__dirname, 'renderer', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}

// A small local language model through Ollama (https://ollama.com): nothing leaves the computer.
async function ollama(url, pathName, body, timeoutMs) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(url.replace(/\/+$/, '') + pathName, {
      method: body ? 'POST' : 'GET',
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(t);
  }
}

ipcMain.on('engine:send', (_e, cmd) => link && link.send(cmd));
ipcMain.handle('engine:scan', async () => { if (link) await link.scan(); return true; });
ipcMain.handle('llm:models', async (_e, { url }) => {
  try {
    const r = await ollama(url, '/api/tags', null, 3000);
    return { ok: true, models: (r.models || []).map((m) => m.name) };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
});
ipcMain.handle('llm:ask', async (_e, { url, model, prompt }) => {
  try {
    const r = await ollama(url, '/api/generate', { model, prompt, stream: false, options: { temperature: 0.2 } }, 180000);
    return { ok: true, text: r.response || '' };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
});
ipcMain.handle('app:openFolder', async (_e, dir) => { if (dir) await shell.openPath(dir); return true; });
ipcMain.handle('app:version', () => app.getVersion());

app.whenReady().then(() => {
  startEngine();
  createWindow();
});

app.on('window-all-closed', () => {
  if (link) link.stop();
  app.quit();
});
