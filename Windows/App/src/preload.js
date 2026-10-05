'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// The only bridge between the interface and the rest: engine commands and events, console search, the language model.
contextBridge.exposeInMainWorld('ssmt', {
  send: (cmd) => ipcRenderer.send('engine:send', cmd),
  onEvent: (fn) => ipcRenderer.on('engine', (_e, ev) => fn(ev)),
  scan: () => ipcRenderer.invoke('engine:scan'),
  llmModels: (url) => ipcRenderer.invoke('llm:models', { url }),
  llmAsk: (url, model, prompt) => ipcRenderer.invoke('llm:ask', { url, model, prompt }),
  openFolder: (dir) => ipcRenderer.invoke('app:openFolder', dir),
  version: () => ipcRenderer.invoke('app:version'),
  // Files and export (open / save panels, PDF and PNG from a page of HTML).
  openFile: (o) => ipcRenderer.invoke('file:open', o),
  saveFile: (o) => ipcRenderer.invoke('file:save', o),
  readFile: (p, encoding) => ipcRenderer.invoke('file:read', { path: p, encoding }),
  writeFile: (p, data, encoding) => ipcRenderer.invoke('file:write', { path: p, data, encoding }),
  renderPDF: (o) => ipcRenderer.invoke('render:pdf', o),
  renderPNG: (o) => ipcRenderer.invoke('render:png', o),
  // The floating diagnostics window: toggle | show | hide | expand | opacity (value) | clickThrough (value).
  mini: (op, value) => ipcRenderer.send('mini', { op, value }),
});
