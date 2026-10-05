'use strict';
// SSMT for Windows: Electron shell. Starts the engine, owns the UDP sockets (engine-link.js) and the local language
// model calls (Ollama), and shows the interface in src/renderer.

const { app, BrowserWindow, dialog, ipcMain, powerSaveBlocker, shell } = require('electron');
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
    if (ev.event && ev.event.startsWith('setup') && miniWin && !miniWin.isDestroyed()) miniWin.webContents.send('engine', ev);
  });
  link.on('stderr', (s) => process.stderr.write(s));
  link.start();
  link.send({ cmd: 'hello', dataDir: dataDir() });
}

function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 1100,
    minHeight: 720,
    backgroundColor: '#070908',
    title: 'SSMT',
    icon: path.join(__dirname, 'renderer', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
  // The diagnostics window appears when the main window is minimized and goes when it comes back (MiniPanelController).
  win.on('minimize', () => { if (mini.autoShow) showMini(); });
  win.on('restore', () => hideMini());
}

// MARK: floating diagnostics window (App/SSMT/Views/MiniPanel.swift)
let miniWin = null;
const mini = { opacity: 0.92, clickThrough: false, autoShow: true };
function showMini() {
  if (!miniWin || miniWin.isDestroyed()) {
    const { screen } = require('electron');
    const area = screen.getPrimaryDisplay().workArea;
    miniWin = new BrowserWindow({
      width: 380, height: 330, x: area.x + area.width - 400, y: area.y + 20, frame: false, transparent: true, resizable: true,
      alwaysOnTop: true, skipTaskbar: true, show: false, hasShadow: true, focusable: true, backgroundColor: '#00000000',
      webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
    });
    miniWin.setAlwaysOnTop(true, 'floating');
    miniWin.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    miniWin.loadFile(path.join(__dirname, 'renderer', 'mini.html'));
    // Snap to the screen edges when dragged close to them.
    miniWin.on('moved', () => {
      const { screen: sc } = require('electron');
      const b = miniWin.getBounds(), a = sc.getDisplayMatching(b).workArea, d = 24;
      let { x, y } = b;
      if (Math.abs(b.x - a.x) < d) x = a.x + 4;
      if (Math.abs(b.x + b.width - (a.x + a.width)) < d) x = a.x + a.width - b.width - 4;
      if (Math.abs(b.y - a.y) < d) y = a.y + 4;
      if (Math.abs(b.y + b.height - (a.y + a.height)) < d) y = a.y + a.height - b.height - 4;
      if (x !== b.x || y !== b.y) miniWin.setPosition(x, y);
    });
    miniWin.once('ready-to-show', () => { applyMini(); miniWin.showInactive(); });
    return;
  }
  applyMini();
  miniWin.showInactive();
}
function applyMini() {
  if (!miniWin || miniWin.isDestroyed()) return;
  miniWin.setOpacity(mini.opacity);
  miniWin.setIgnoreMouseEvents(mini.clickThrough, { forward: true });
}
// The content exists only while the window is shown, so a hidden window costs nothing.
function hideMini() { if (miniWin && !miniWin.isDestroyed()) miniWin.destroy(); miniWin = null; }
ipcMain.on('mini', (_e, { op, value }) => {
  if (op === 'toggle') { if (miniWin && !miniWin.isDestroyed()) hideMini(); else showMini(); }
  else if (op === 'show') showMini();
  else if (op === 'hide') hideMini();
  else if (op === 'opacity') { mini.opacity = Math.min(1, Math.max(0.3, Number(value) || 1)); applyMini(); }
  else if (op === 'clickThrough') { mini.clickThrough = !!value; applyMini(); }
  else if (op === 'expand') {
    hideMini();
    if (win && !win.isDestroyed()) { if (win.isMinimized()) win.restore(); win.show(); win.focus(); }
  }
});

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
// Files, as the Mac app's open and save panels and its PDF / PNG export. Paths are chosen by the person in a dialog.
const filters = (f) => (f || []).map((x) => ({ name: x.name, extensions: x.extensions }));
ipcMain.handle('file:open', async (_e, o = {}) => {
  const r = await dialog.showOpenDialog(win, { title: o.title, filters: filters(o.filters), defaultPath: o.defaultPath,
    properties: ['openFile', ...(o.multiple ? ['multiSelections'] : []), ...(o.directory ? ['openDirectory'] : [])] });
  return r.canceled ? [] : r.filePaths;
});
ipcMain.handle('file:save', async (_e, o = {}) => {
  const r = await dialog.showSaveDialog(win, { title: o.title, defaultPath: o.defaultName, filters: filters(o.filters) });
  return r.canceled ? null : r.filePath;
});
ipcMain.handle('file:read', async (_e, { path: p, encoding }) => fs.promises.readFile(p, encoding === 'base64' ? undefined : 'utf8')
  .then((d) => (encoding === 'base64' ? d.toString('base64') : d)));
ipcMain.handle('file:write', async (_e, { path: p, data, encoding }) => {
  await fs.promises.writeFile(p, encoding === 'base64' ? Buffer.from(data, 'base64') : data);
  return true;
});
/** Renders a self-contained HTML page off screen: to a PDF (pages of `pageSize` in points) or to a PNG. */
async function offscreen(html, size, fn) {
  const w = new BrowserWindow({ show: false, width: Math.ceil(size[0]), height: Math.ceil(size[1]), useContentSize: true,
    webPreferences: { offscreen: true, contextIsolation: true, nodeIntegration: false } });
  try {
    await w.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html), { baseURLForDataURL: 'file://' + path.join(__dirname, 'renderer') + '/' });
    await w.webContents.executeJavaScript('document.fonts.ready.then(() => true)');
    return await fn(w);
  } finally {
    w.destroy();
  }
}
ipcMain.handle('render:pdf', async (_e, { html, path: p, pageSize, landscape }) => {
  const data = await offscreen(html, pageSize || [595, 842], (w) => w.webContents.printToPDF({
    printBackground: true, landscape: !!landscape, margins: { marginType: 'none' }, preferCSSPageSize: true,
    pageSize: pageSize ? { width: pageSize[0] / 72, height: pageSize[1] / 72 } : 'A4' }));
  await fs.promises.writeFile(p, data);
  return true;
});
ipcMain.handle('render:png', async (_e, { html, path: p, width, height, scale }) => {
  const data = await offscreen(html, [width * (scale || 1), height * (scale || 1)], async (w) => (await w.webContents.capturePage()).toPNG());
  await fs.promises.writeFile(p, data);
  return true;
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
