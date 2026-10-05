'use strict';
/* global SSMT */
// SSMT.audio: the Windows app's sound card I/O for the engine. Chromium's Web Audio (WASAPI underneath) captures
// and plays; the samples travel to and from the engine as JSON lines (Windows/Engine/.../Modules/AudioIO.swift):
//   open   → {cmd:'audioConfig', stream, sampleRate, inChannels, outChannels, loopChannel, latency}
//   input  → {cmd:'audioIn', stream, data, played, frame}  base64 Float32LE, interleaved, inChannels wide
//   output → {cmd:'audioNeed', stream, frames} when the queue is short; the engine answers
//            {event:'audioOut', stream, data[, flush]} (interleaved, outChannels wide)
// One AudioWorklet node plays and captures in the same render quantum, so input and output keep a fixed offset
// (the system delay the measurement locks). `loopChannel` (an output channel) is echoed with every captured block
// exactly as it was played: the engine's reference, the same samples as on the Mac's duplex device.
// Separate input and output devices run on the output device's clock with the input resampled onto it, as the
// Mac's private aggregate device does with drift compensation.

(function () {
  const TARGET = 8192;  // frames queued ahead for playback (≈170 ms at 48 kHz)
  const CHUNK = 1024;   // frames per engine request and per captured block
  const streams = {};

  function toBase64(f32) {
    const u8 = new Uint8Array(f32.buffer, f32.byteOffset, f32.byteLength);
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }

  function fromBase64(b64) {
    const bin = atob(b64 || '');
    const u8 = new Uint8Array(bin.length - (bin.length % 4));
    for (let i = 0; i < u8.length; i++) u8[i] = bin.charCodeAt(i);
    return new Float32Array(u8.buffer);
  }

  const pseudo = (d) => d.deviceId === 'default' || d.deviceId === 'communications' || !d.deviceId;

  /** Audio inputs and outputs of the system: {inputs:[{id,label,groupId}], outputs:[…]}. */
  async function devices() {
    const md = navigator.mediaDevices;
    if (!md || !md.enumerateDevices) return { inputs: [], outputs: [] };
    let list = await md.enumerateDevices();
    // Labels appear once the page may use the microphone.
    if (list.some((d) => d.kind === 'audioinput' && !d.label)) {
      try {
        const s = await md.getUserMedia({ audio: true });
        s.getTracks().forEach((t) => t.stop());
        list = await md.enumerateDevices();
      } catch (_) { /* permission refused: no labels */ }
    }
    const map = (kind) => list.filter((d) => d.kind === kind && !pseudo(d))
      .map((d) => ({ id: d.deviceId, label: d.label || d.deviceId.slice(0, 8), groupId: d.groupId }));
    return { inputs: map('audioinput'), outputs: map('audiooutput') };
  }

  function captureConstraints(inputId, channels) {
    return {
      audio: {
        deviceId: { exact: inputId },
        echoCancellation: false, noiseSuppression: false, autoGainControl: false,
        channelCount: { ideal: channels },
      },
    };
  }

  /** Channel counts of an input and an output device: {inChannels, outChannels}. */
  async function probe(inputId, outputId) {
    let inChannels = 0, outChannels = 0;
    if (inputId) {
      try {
        const s = await navigator.mediaDevices.getUserMedia(captureConstraints(inputId, 32));
        const t = s.getAudioTracks()[0];
        const caps = t && t.getCapabilities ? t.getCapabilities() : {};
        inChannels = (caps.channelCount && caps.channelCount.max) || (t && t.getSettings().channelCount) || 1;
        s.getTracks().forEach((x) => x.stop());
      } catch (_) { inChannels = 0; }
    }
    if (outputId) {
      try {
        const ctx = new AudioContext();
        if (ctx.setSinkId) await ctx.setSinkId(outputId);
        outChannels = ctx.destination.maxChannelCount || 2;
        await ctx.close();
      } catch (_) { outChannels = 0; }
    }
    return { inChannels, outChannels };
  }

  /**
   * Opens a stream ('setup' or 'show'): {inputId, outputId, inChannels, outChannels, sampleRate, loopChannel}.
   * Resolves to {sampleRate, inChannels, outChannels} as opened; rejects with the device error.
   */
  async function open(stream, o = {}) {
    await close(stream);
    const ctx = new AudioContext({ sampleRate: o.sampleRate || 48000, latencyHint: 'interactive' });
    const st = { ctx, media: null, node: null, pending: 0, outCh: 0, inCh: 0 };
    streams[stream] = st;
    try {
      if (o.outputId && ctx.setSinkId) await ctx.setSinkId(o.outputId);
      await ctx.audioWorklet.addModule('audio-worklet.js');
      let inCh = Math.max(0, o.inChannels | 0);
      let source = null;
      if (inCh > 0) {
        st.media = await navigator.mediaDevices.getUserMedia(captureConstraints(o.inputId, inCh));
        const track = st.media.getAudioTracks()[0];
        const got = track && track.getSettings().channelCount;
        if (got && got < inCh) inCh = got;
        source = ctx.createMediaStreamSource(st.media);
      }
      const outCh = Math.max(0, Math.min(o.outChannels | 0, ctx.destination.maxChannelCount || 2));
      if (outCh > 0) {
        ctx.destination.channelCount = outCh;
        ctx.destination.channelCountMode = 'explicit';
        ctx.destination.channelInterpretation = 'discrete';
      }
      const loopChannel = Number.isInteger(o.loopChannel) && o.loopChannel < outCh ? o.loopChannel : undefined;
      const node = new AudioWorkletNode(ctx, 'ssmt-io', {
        numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [Math.max(1, outCh)],
        channelCount: Math.max(1, inCh), channelCountMode: 'explicit', channelInterpretation: 'discrete',
        processorOptions: { inChannels: inCh, outChannels: outCh, loopChannel, block: CHUNK },
      });
      if (source) source.connect(node);
      node.connect(ctx.destination);
      st.node = node;
      st.inCh = inCh;
      st.outCh = outCh;
      node.port.onmessage = (e) => {
        const m = e.data;
        if (m.type !== 'block' || streams[stream] !== st) return;
        if (m.data) {
          const cmd = { cmd: 'audioIn', stream, data: toBase64(m.data), frame: m.frame };
          if (m.played) cmd.played = toBase64(m.played);
          SSMT.send(cmd);
        }
        if (outCh > 0) {
          const need = TARGET - m.queued - st.pending;
          if (need >= CHUNK) {
            const frames = Math.floor(need / CHUNK) * CHUNK;
            st.pending += frames;
            SSMT.send({ cmd: 'audioNeed', stream, frames });
          }
        }
      };
      await ctx.resume();
      const track = st.media && st.media.getAudioTracks()[0];
      const inLatency = (track && track.getSettings().latency) || 0;
      const latency = (ctx.baseLatency || 0) + (ctx.outputLatency || 0) + inLatency;
      SSMT.send({ cmd: 'audioConfig', stream, sampleRate: ctx.sampleRate, inChannels: inCh, outChannels: outCh, loopChannel, latency });
      // Prime the output queue so playback starts without a gap.
      if (outCh > 0) { st.pending = TARGET; SSMT.send({ cmd: 'audioNeed', stream, frames: TARGET }); }
      return { sampleRate: ctx.sampleRate, inChannels: inCh, outChannels: outCh };
    } catch (e) {
      await close(stream);
      throw e;
    }
  }

  async function close(stream) {
    const st = streams[stream];
    if (!st) return;
    delete streams[stream];
    try { if (st.node) { st.node.port.postMessage({ type: 'close' }); st.node.disconnect(); } } catch (_) { /* gone */ }
    if (st.media) st.media.getTracks().forEach((t) => t.stop());
    try { await st.ctx.close(); } catch (_) { /* already closed */ }
    SSMT.send({ cmd: 'audioClose', stream });
  }

  SSMT.onEngine((ev) => {
    if (ev.event !== 'audioOut') return;
    const st = streams[ev.stream];
    if (!st || !st.node) return;
    const data = fromBase64(ev.data);
    if (st.outCh > 0) st.pending = Math.max(0, st.pending - data.length / st.outCh);
    st.node.port.postMessage({ type: 'out', data, flush: !!ev.flush }, [data.buffer]);
  });

  SSMT.audio = { devices, probe, open, close, isOpen: (stream) => !!streams[stream] };
})();
