'use strict';
/* global SSMT */
// Qtrl's audio on Windows. Output: the "show" stream of the audio bridge (audio-io.js, SSMT.audio), whose blocks the
// engine's mixer renders sample-accurately. Decoding: the engine asks ("showDecode") for a file at its output rate;
// Chromium decodes it (WAV, AIFF, MP3, AAC, the sound of a video: what the Mac decodes with AVFoundation), resampled
// to that rate, and the planar Float32 samples are written to the engine's cache file, which the engine maps (as the
// Mac's ClipCache does).

(function () {
  const Q = SSMT.qtrl;
  const { st, cmd } = Q;

  /** Opens (or reopens) the show output on the chosen interface and tells the engine what it got. */
  async function openOutput() {
    const audio = SSMT.audio;
    if (!audio || !audio.open) return;
    const doc = st.doc;
    const outputs = doc ? doc.outputs : [];
    const channels = Math.max(2, ...outputs.map((o) => (o.deviceChannel === undefined || o.deviceChannel === null ? 0 : o.deviceChannel + 1)));
    let name = '';
    try {
      const list = await audio.devices();
      const want = doc && doc.deviceUID;
      const dev = (list.outputs || []).find((d) => d.id === want) || (list.outputs || []).find((d) => d.id === 'default') || (list.outputs || [])[0];
      name = dev ? dev.label : '';
      await audio.open('show', { outputId: dev ? dev.id : undefined, inChannels: 0, outChannels: channels, sampleRate: 48000 });
      cmd('outputInfo', { name });
    } catch (e) {
      cmd('outputInfo', { name, error: String((e && e.message) || e) });
    }
  }

  // One file at a time: decoding is memory hungry.
  const queue = [];
  let busy = false;

  function decode(ev) {
    queue.push(ev);
    pump();
  }

  async function pump() {
    if (busy || !queue.length) return;
    busy = true;
    const ev = queue.shift();
    try {
      const api = window.ssmt;
      if (!api || !api.readFile || !api.writeFile) throw new Error('no file access');
      const b64 = await api.readFile(ev.path, 'base64');
      const bin = atob(b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      const ctx = new OfflineAudioContext(1, 1, ev.sampleRate);
      const buf = await ctx.decodeAudioData(bytes.buffer);
      const ch = buf.numberOfChannels;
      const frames = buf.length;
      const planar = new Float32Array(ch * frames);
      for (let c = 0; c < ch; c++) planar.set(buf.getChannelData(c), c * frames);
      await api.writeFile(ev.out, await toBase64(planar.buffer), 'base64');
      SSMT.send({ cmd: 'showDecoded', path: ev.path, sampleRate: ev.sampleRate, channels: ch });
    } catch (e) {
      SSMT.send({ cmd: 'showDecoded', path: ev.path, sampleRate: ev.sampleRate, error: String((e && e.message) || e) });
    }
    busy = false;
    pump();
  }

  function toBase64(buffer) {
    return new Promise((ok, bad) => {
      const r = new FileReader();
      r.onload = () => ok(String(r.result).split(',')[1] || '');
      r.onerror = () => bad(r.error);
      r.readAsDataURL(new Blob([buffer]));
    });
  }

  Object.assign(Q, { openOutput, decode });
})();
