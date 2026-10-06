'use strict';
/* global AudioWorkletProcessor, registerProcessor, currentFrame */
// The audio thread of SSMT.audio (audio-io.js). In the same render quantum it plays the next frames the engine
// rendered and captures the input, so input and output share one clock and keep a fixed offset. Captured blocks
// go to the main thread with the frames of one output channel exactly as they were played (the engine's
// reference), and the queue length, so the main thread can ask the engine for more in time.

class SSMTIO extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = options.processorOptions || {};
    this.inCh = o.inChannels | 0;
    this.outCh = o.outChannels | 0;
    this.loop = Number.isInteger(o.loopChannel) ? o.loopChannel : -1;
    this.block = o.block || 1024;
    this.queue = [];      // interleaved Float32Arrays from the engine
    this.offset = 0;      // frames already played from queue[0]
    this.queued = 0;      // frames waiting
    this.underruns = 0;   // frames played as silence because the queue was empty
    this.position = 0;    // frames since the stream opened
    this.fill = 0;
    this.newBlock();
    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'out') {
        if (m.flush) { this.queue = []; this.offset = 0; this.queued = 0; }
        if (m.data && m.data.length) { this.queue.push(m.data); this.queued += m.data.length / Math.max(1, this.outCh); }
      } else if (m.type === 'close') {
        this.closed = true;
      }
    };
  }

  newBlock() {
    this.cap = new Float32Array(this.block * Math.max(1, this.inCh));
    this.played = this.loop >= 0 ? new Float32Array(this.block) : null;
    this.start = this.position;
  }

  process(inputs, outputs) {
    if (this.closed) return false;
    const input = inputs[0] || [];
    const output = outputs[0] || [];
    const n = (output[0] || input[0] || { length: 128 }).length;
    for (let i = 0; i < n; i++) {
      // Output: next interleaved frame from the queue, silence if it ran dry.
      const chunk = this.queue[0];
      if (chunk) {
        const base = this.offset * this.outCh;
        for (let c = 0; c < output.length; c++) output[c][i] = c < this.outCh ? chunk[base + c] : 0;
        if (this.played) this.played[this.fill] = this.loop < this.outCh ? chunk[base + this.loop] : 0;
        this.offset++;
        this.queued--;
        if (this.offset * this.outCh >= chunk.length) { this.queue.shift(); this.offset = 0; }
      } else {
        for (let c = 0; c < output.length; c++) output[c][i] = 0;
        if (this.played) this.played[this.fill] = 0;
        if (this.outCh > 0) this.underruns++;
      }
      // Input: interleaved, inChannels wide; channels the device does not deliver are zero.
      if (this.inCh > 0) {
        const base = this.fill * this.inCh;
        for (let c = 0; c < this.inCh; c++) this.cap[base + c] = input[c] ? input[c][i] : 0;
      }
      this.fill++;
      this.position++;
      if (this.fill === this.block) {
        const msg = { type: 'block', frame: this.start, queued: this.queued, underruns: this.underruns };
        const transfer = [];
        if (this.inCh > 0) { msg.data = this.cap; transfer.push(this.cap.buffer); }
        if (this.played) { msg.played = this.played; transfer.push(this.played.buffer); }
        this.port.postMessage(msg, transfer);
        this.fill = 0;
        this.newBlock();
      }
    }
    return true;
  }
}

registerProcessor('ssmt-io', SSMTIO);
