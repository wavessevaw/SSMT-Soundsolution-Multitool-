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
});
