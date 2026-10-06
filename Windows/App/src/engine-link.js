'use strict';
// Runs the SSMT engine (Swift, SSMTCore) as a child process and carries its UDP traffic.
// The engine speaks JSON lines on stdin / stdout. It never opens a socket: "link" / "unlink" / "send" events are
// handled here (one UDP socket to the console), console packets go back to it as "osc" commands. Every other event
// is passed on to the interface.

const { spawn } = require('child_process');
const dgram = require('dgram');
const os = require('os');
const readline = require('readline');
const { EventEmitter } = require('events');

/** "/xinfo" as an OSC packet: every X32 / M32 / X Air / MR on the network answers it. */
const XINFO = Buffer.from('/xinfo\0\0,\0\0\0', 'latin1');

/** Broadcast address of every IPv4 interface, plus the limited broadcast. */
function broadcastAddresses() {
  const out = new Set(['255.255.255.255']);
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' && a.family !== 4) continue;
      if (a.internal) continue;
      const ip = a.address.split('.').map(Number);
      const mask = a.netmask.split('.').map(Number);
      out.add(ip.map((b, i) => (b | (~mask[i] & 255)) & 255).join('.'));
    }
  }
  return [...out];
}

/** IPv4 addresses of this computer, without loopback (Qtrl's network hints). */
function localInterfaces() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if ((a.family === 'IPv4' || a.family === 4) && !a.internal) out.push({ name, address: a.address, mask: a.netmask });
    }
  }
  return out;
}

class EngineLink extends EventEmitter {
  /**
   * @param {{command: string, args?: string[], env?: object}} opts how to start the engine
   */
  constructor(opts) {
    super();
    this.opts = opts;
    this.proc = null;
    this.sock = null;
    this.target = null;
    this.queue = [];
    this.pump = null;
    // Packets per 10 ms: a console on Wi-Fi drops bursts.
    this.batch = 8;
  }

  start() {
    const { command, args = [], env = {} } = this.opts;
    this.proc = spawn(command, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    readline.createInterface({ input: this.proc.stdout }).on('line', (l) => this.onLine(l));
    this.proc.stderr.on('data', (d) => this.emit('stderr', d.toString()));
    this.proc.on('error', (e) => this.emit('event', { event: 'engineError', detail: String(e && e.message || e) }));
    this.proc.on('exit', (code) => {
      this.closeSocket();
      this.oscUnlisten();
      this.emit('event', { event: 'engineExit', code });
    });
  }

  stop() {
    this.closeSocket();
    this.oscUnlisten();
    if (this.oscOut) { try { this.oscOut.close(); } catch (_) { /* closed */ } this.oscOut = null; }
    if (this.proc) {
      try { this.proc.stdin.end(); } catch (_) { /* already closed */ }
      const p = this.proc;
      setTimeout(() => { try { p.kill(); } catch (_) { /* gone */ } }, 1500);
      this.proc = null;
    }
  }

  /** A command for the engine. */
  send(cmd) {
    if (!this.proc || !this.proc.stdin.writable) return;
    this.proc.stdin.write(JSON.stringify(cmd) + '\n');
  }

  onLine(line) {
    let ev;
    try { ev = JSON.parse(line); } catch (_) { return; }
    switch (ev.event) {
      case 'link': this.openSocket(ev.host, ev.port); break;
      case 'unlink': this.closeSocket(); break;
      case 'send':
        for (const p of ev.packets || []) this.queue.push(Buffer.from(p, 'base64'));
        this.startPump();
        break;
      // Generic OSC (Qtrl's show devices): any host, any port, and one listening port for the monitor.
      case 'oscSend': this.oscSend(ev); break;
      case 'oscListen': this.oscListen(ev.port); break;
      case 'oscUnlisten': this.oscUnlisten(); break;
      case 'netInterfaces': this.send({ cmd: 'netInterfaces', items: localInterfaces() }); break;
      default: this.emit('event', ev);
    }
  }

  oscSend(ev) {
    if (!this.oscOut) {
      const s = dgram.createSocket('udp4');
      s.on('message', (msg, rinfo) => this.send({ cmd: 'oscIn', from: rinfo.address, port: rinfo.port, data: msg.toString('base64') }));
      s.on('error', () => { /* unreachable host: OSC is fire and forget */ });
      s.bind(0);
      this.oscOut = s;
    }
    try { this.oscOut.send(Buffer.from(ev.data || '', 'base64'), ev.port, ev.host, () => {}); } catch (_) { /* bad address */ }
  }

  oscListen(port) {
    this.oscUnlisten();
    const s = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    this.oscIn = s;
    s.on('message', (msg, rinfo) => this.send({ cmd: 'oscIn', from: rinfo.address, port: rinfo.port, data: msg.toString('base64') }));
    s.on('error', (e) => {
      if (this.oscIn === s) this.oscIn = null;
      try { s.close(); } catch (_) { /* closed */ }
      this.send({ cmd: 'oscListenError', detail: String(e.code || e.message || e) });
    });
    s.bind(port);
  }

  oscUnlisten() {
    if (this.oscIn) { try { this.oscIn.close(); } catch (_) { /* closed */ } }
    this.oscIn = null;
  }

  openSocket(host, port) {
    this.closeSocket();
    const s = dgram.createSocket('udp4');
    this.sock = s;
    this.target = { host, port };
    s.on('message', (msg, rinfo) => {
      if (this.sock !== s || rinfo.address !== host) return;
      this.send({ cmd: 'osc', data: msg.toString('base64') });
    });
    s.on('error', (e) => this.emit('event', { event: 'socketError', detail: String(e.message || e) }));
    s.bind(0);
  }

  closeSocket() {
    this.queue = [];
    if (this.pump) { clearInterval(this.pump); this.pump = null; }
    if (this.sock) { try { this.sock.close(); } catch (_) { /* closed */ } }
    this.sock = null;
    this.target = null;
  }

  startPump() {
    if (this.pump) return;
    this.pump = setInterval(() => {
      if (!this.sock || !this.target) { this.queue = []; }
      const n = Math.min(this.batch, this.queue.length);
      for (let i = 0; i < n; i++) {
        const pkt = this.queue.shift();
        this.sock.send(pkt, this.target.port, this.target.host);
      }
      if (this.queue.length === 0) { clearInterval(this.pump); this.pump = null; }
    }, 10);
  }

  /**
   * Looks for consoles: "/xinfo" broadcast to UDP 10023 and 10024 on every interface. Answers go to the engine,
   * which reports each console as a "found" event; "scanDone" follows.
   */
  scan(seconds = 1.5, ports = [10023, 10024]) {
    return new Promise((resolve) => {
      const s = dgram.createSocket('udp4');
      s.on('message', (msg, rinfo) => {
        this.send({ cmd: 'discovered', sender: rinfo.address, port: rinfo.port, data: msg.toString('base64') });
      });
      s.on('error', () => { /* a closed interface: ignore */ });
      s.bind(0, () => {
        try { s.setBroadcast(true); } catch (_) { /* not allowed: unicast only */ }
        for (const addr of this.scanAddresses || broadcastAddresses()) {
          for (const port of ports) s.send(XINFO, port, addr, () => {});
        }
      });
      setTimeout(() => {
        try { s.close(); } catch (_) { /* closed */ }
        this.emit('event', { event: 'scanDone' });
        resolve();
      }, seconds * 1000);
    });
  }
}

module.exports = { EngineLink, broadcastAddresses, localInterfaces, XINFO };
