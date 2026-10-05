'use strict';
/* global STRINGS, KINDS, makeT */
// FOH Assist for Windows. Everything the console does comes from the engine as events; the interface sends commands.

const store = {
  get(k, d) { try { const v = localStorage.getItem('ssmt.' + k); return v === null ? d : v; } catch (_) { return d; } },
  set(k, v) { try { localStorage.setItem('ssmt.' + k, v); } catch (_) { /* private mode */ } },
};

const S = {
  lang: store.get('lang', 'ru'),
  tab: store.get('tab', 'learn'),
  family: store.get('family', 'simulator'),
  host: store.get('host', '192.168.1.64'),
  routing: store.get('routing', 'local'),
  state: null,
  meters: { channels: [], buses: [] },
  learn: { recording: false },
  learnTitle: '',
  recordings: { items: [], target: 20, dir: '' },
  summary: '',
  log: [],
  found: [],
  scanning: false,
  scanned: false,
  selected: null,
  message: '',
  llm: { url: store.get('llm.url', 'http://localhost:11434'), model: store.get('llm.model', 'qwen2.5:1.5b'), status: '', question: '', answer: '', asking: false },
  version: '',
};
let t = makeT(S.lang);

const api = window.ssmt;

// MARK: helpers

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const num = (v, d = 1) => (v == null || !isFinite(v) ? '—' : Number(v).toFixed(d));
const signed = (v, d = 1) => (v == null || !isFinite(v) ? '—' : (v > 0 ? '+' : '') + Number(v).toFixed(d));
const db = (v) => (v <= -90 ? '−∞' : signed(v, 1));
const hz = (f) => (f >= 1000 ? num(f / 1000, f >= 10000 ? 0 : 1) + 'k' : num(f, 0));
const kindName = (k) => (KINDS[S.lang] || KINDS.ru)[k] || k || '—';
const clock = (s) => {
  s = Math.max(0, Math.floor(s || 0));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return (h ? h + ':' + String(m).padStart(2, '0') : String(m)) + ':' + String(x).padStart(2, '0');
};
const connected = () => S.state && S.state.family && S.state.status !== 'disconnected';
const readOnly = () => S.state && S.state.readOnly;
const recording = () => S.learn && S.learn.recording;

function send(cmd) { if (api) api.send(cmd); }

// MARK: engine events

function onEvent(ev) {
  switch (ev.event) {
    case 'hello': send({ cmd: 'state' }); break;
    case 'state':
      S.state = ev;
      if (!ev.family) S.selected = null;
      break;
    case 'meters': S.meters = ev; updateMeters(); return;
    case 'learn': S.learn = ev; break;
    case 'recordings': S.recordings = ev; send({ cmd: 'patterns', lang: S.lang }); break;
    case 'patterns': S.summary = ev.summary; break;
    case 'log': S.log = ev.entries || []; break;
    case 'found':
      if (!S.found.some((c) => c.ip === ev.ip)) S.found.push(ev);
      break;
    case 'scanDone': S.scanning = false; S.scanned = true; break;
    case 'message': S.message = t('msg.' + ev.key, ev.detail || ''); break;
    case 'error': S.message = t('msg.' + ev.key, ev.detail || ''); break;
    case 'engineExit': S.message = t('msg.engineExit', ev.code); break;
    case 'engineError': S.message = t('msg.engineError', ev.detail); break;
    case 'prompt': askModel(ev.text); return;
    default: return;
  }
  render();
}

// MARK: actions

const actions = {
  tab(name) { S.tab = name; store.set('tab', name); render(); },
  lang() {
    S.lang = S.lang === 'ru' ? 'en' : 'ru';
    store.set('lang', S.lang);
    t = makeT(S.lang);
    send({ cmd: 'patterns', lang: S.lang });
    render();
  },
  family(f) { S.family = f; store.set('family', f); render(); },
  scan() {
    if (S.scanning || !api) return;
    S.scanning = true;
    S.found = [];
    api.scan();
    render();
  },
  pick(i) {
    const c = S.found[i];
    if (!c) return;
    S.family = c.family; S.host = c.ip;
    store.set('family', S.family); store.set('host', S.host);
    actions.connect();
  },
  connect() {
    S.message = '';
    store.set('host', S.host);
    if (S.family !== 'simulator') send({ cmd: 'routing', preset: S.routing });
    send({ cmd: 'connect', family: S.family, host: S.host });
    if (S.family !== 'simulator') { S.tab = 'learn'; store.set('tab', 'learn'); }
  },
  disconnect() { send({ cmd: 'disconnect' }); },
  select(ch) { S.selected = S.selected === ch ? null : ch; render(); },
  tune() { if (S.selected) send({ cmd: 'tune', channel: S.selected }); },
  group(g) { send({ cmd: 'tuneGroup', group: g }); },
  polarity() { send({ cmd: 'polarity' }); },
  stopJob() { send({ cmd: 'stopJob' }); },
  undo() { send({ cmd: 'undo' }); },
  character(v) { send({ cmd: 'character', value: v }); },
  routing(v) { S.routing = v; store.set('routing', v); send({ cmd: 'routing', preset: v }); },
  learnStart() { send({ cmd: 'learnStart', title: S.learnTitle.trim() }); },
  learnStop() { send({ cmd: 'learnStop' }); },
  openFolder() { if (api && S.recordings.dir) api.openFolder(S.recordings.dir); },
  deleteRecording(file) {
    const r = S.recordings.items.find((x) => x.file === file);
    if (r && confirm(t('learn.delete.confirm', r.title))) send({ cmd: 'deleteRecording', file });
  },
  refreshPatterns() { send({ cmd: 'recordings' }); },
  async checkModel() {
    if (!api) return;
    S.llm.status = '…';
    render();
    const r = await api.llmModels(S.llm.url);
    if (!r.ok) S.llm.status = t('llm.fail', r.error);
    else if (!r.models.some((m) => m === S.llm.model || m === S.llm.model + ':latest')) S.llm.status = t('llm.noModel', S.llm.model);
    else S.llm.status = t('llm.ok', r.models.join(', '));
    render();
  },
  ask() {
    const q = S.llm.question.trim();
    if (!q || S.llm.asking) return;
    S.llm.asking = true;
    S.llm.answer = '';
    send({ cmd: 'prompt', question: q, lang: S.lang });
    render();
  },
  goSim() { S.family = 'simulator'; store.set('family', 'simulator'); actions.disconnect(); setTimeout(actions.connect, 50); },
};

async function askModel(prompt) {
  if (!api) return;
  const r = await api.llmAsk(S.llm.url, S.llm.model, prompt);
  S.llm.asking = false;
  S.llm.answer = r.ok ? r.text.trim() : t('llm.fail', r.error);
  render();
}

// Input fields keep their value in S without redrawing.
const inputs = {
  host: (v) => { S.host = v; },
  learnTitle: (v) => { S.learnTitle = v; },
  llmUrl: (v) => { S.llm.url = v; store.set('llm.url', v); },
  llmModel: (v) => { S.llm.model = v; store.set('llm.model', v); },
  question: (v) => { S.llm.question = v; },
};

// MARK: views

function header() {
  const st = S.state || {};
  let lamp = 'off', label = t('conn.offline');
  if (st.family) {
    if (st.status === 'connecting') { lamp = 'warn'; label = t('conn.connecting'); }
    else if (st.status === 'failed' || (st.status === 'connected' && !st.alive)) { lamp = 'bad'; label = t('conn.failed'); }
    else { lamp = 'good'; label = st.model || st.host || st.family; }
  }
  const tabs = ['soundcheck', 'show', 'test', 'learn'].map((k) =>
    `<button class="tab ${S.tab === k ? 'on' : ''}" data-act="tab" data-arg="${k}">${esc(t('tab.' + k))}${k === 'learn' && recording() ? ' <span class="rec-dot"></span>' : ''}</button>`).join('');
  return `
    <div class="brand"><img src="icon.png" alt=""><div><b>SSMT</b><span>${esc(t('app.subtitle'))}</span></div></div>
    <nav class="tabs">${tabs}</nav>
    <div class="chips">
      <span class="chip"><i class="lamp ${lamp}"></i>${esc(label)}</span>
      ${readOnly() ? `<span class="chip ro">${esc(t('conn.readOnly'))}</span>` : ''}
      ${st.family ? `<button class="ghost" data-act="disconnect">${esc(t('conn.disconnect'))}</button>` : ''}
      <button class="ghost" data-act="lang">${esc(t('lang'))}</button>
    </div>`;
}

function card(title, body, extra = '', cls = '') {
  return `<section class="card ${cls}"><header><h3>${esc(title)}</h3>${extra}</header><div class="body">${body}</div></section>`;
}

function connectScreen() {
  const fams = ['simulator', 'x32', 'xAir'].map((f) => `
    <button class="fam ${S.family === f ? 'on' : ''}" data-act="family" data-arg="${f}">
      <b>${esc(t('family.' + f))}</b><span>${esc(t(f === 'simulator' ? 'family.simulator.hint' : 'family.real.hint'))}</span>
    </button>`).join('');
  const real = S.family !== 'simulator';
  const found = S.found.map((c, i) => `
    <button class="found" data-act="pick" data-arg="${i}"><b>${esc(c.name || c.model)}</b><span>${esc(c.model)} · ${esc(c.ip)}${c.firmware ? ' · ' + esc(c.firmware) : ''}</span></button>`).join('');
  const addr = real ? card('2 · ' + t('connect.step2'), `
      <label>${esc(t('connect.ip'))}<input id="host" data-input="host" value="${esc(S.host)}" spellcheck="false"></label>
      <button class="secondary" data-act="scan" ${S.scanning ? 'disabled' : ''}>${esc(S.scanning ? t('connect.scanning') : t('connect.scan'))}</button>
      <div class="found-list">${found || (S.scanned && !S.scanning ? `<p class="muted">${esc(t('connect.none'))}</p>` : '')}</div>`) : '';
  return `
    <div class="connect">
      <h1>${esc(t('connect.title'))}</h1>
      ${card('1 · ' + t('connect.step1'), `<div class="fams">${fams}</div>`)}
      ${addr}
      <button class="primary big" data-act="connect">${esc(t('connect.go'))}</button>
      ${S.message ? `<p class="message">${esc(S.message)}</p>` : ''}
    </div>`;
}

function soon(kind) {
  const toLearn = `<button class="primary" data-act="tab" data-arg="learn">${esc(t('soon.toLearn'))}</button>`;
  const toSim = kind === 'soundcheck' && S.state && S.state.family !== 'simulator'
    ? `<button class="secondary" data-act="goSim">${esc(t('soon.toSim'))}</button>` : '';
  return `<div class="soon"><div class="soon-badge">SOON</div><h2>${esc(t('soon.title.' + kind))}</h2>
    <p>${esc(t('soon.text.' + kind))}</p><div class="row">${toLearn}${toSim}</div></div>`;
}

function eqText(s) {
  if (!s.eqOn) return t('off');
  const bands = (s.eq || []).map((b, i) => (Math.abs(b.gainDB) >= 0.5 ? `${i + 1}: ${signed(b.gainDB, 1)}@${hz(b.frequency)}` : null)).filter(Boolean);
  return bands.length ? bands.join(' · ') : '0';
}

function channelTable(withState) {
  const st = S.state || {};
  const rows = (st.strips || []).map((s) => {
    const state = (st.states || {})[s.id] || '';
    const kind = (st.kinds || {})[s.id];
    const c = s.compressor || {};
    return `<tr class="${S.selected === s.id ? 'sel' : ''} ${s.muted ? 'muted' : ''}" ${withState ? `data-act="select" data-arg="${s.id}"` : ''}>
      <td class="n">${s.id}</td><td>${esc(s.name || '—')}</td><td class="dim">${esc(kind ? kindName(kind) : '')}</td>
      <td class="r">${num(s.gainDB, 1)}</td><td class="r">${s.highPassOn ? hz(s.highPassHz) : esc(t('off'))}</td>
      <td class="eq">${esc(eqText(s))}</td>
      <td class="r">${c.enabled ? (c.expander ? 'EXP' : `${num(c.thresholdDB, 0)} / ${num(c.ratio, 1)}:1`) : esc(t('off'))}</td>
      <td class="r">${s.muted ? `<span class="mute">${esc(t('muted'))}</span>` : db(s.faderDB)}</td>
      ${withState ? `<td class="state ${state}">${esc(t('state.' + (state || 'idle')))}</td>` : ''}
      <td class="lvl"><div class="meter" data-ch="${s.id}"><i></i></div></td></tr>`;
  }).join('');
  return `<div class="table-wrap"><table class="channels"><thead><tr>
    <th>${esc(t('col.ch'))}</th><th>${esc(t('col.name'))}</th><th>${esc(t('col.source'))}</th><th class="r">${esc(t('col.gain'))}</th>
    <th class="r">${esc(t('col.hpf'))}</th><th>${esc(t('col.eq'))}</th><th class="r">${esc(t('col.comp'))}</th><th class="r">${esc(t('col.fader'))}</th>
    ${withState ? `<th>${esc(t('col.state'))}</th>` : ''}<th>${esc(t('col.level'))}</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function noteText(n) {
  if (!n || typeof n !== 'object') return '';
  const [k] = Object.keys(n);
  const v = n[k] || {};
  switch (k) {
    case 'waitingForSignal': return t('note.waiting');
    case 'recognised': return t('note.recognised', kindName(v._0), Math.round((v.confidence || 0) * 100));
    case 'gain': return t('note.gain', num(v.fromDB), num(v.toDB));
    case 'clipRisk': return t('note.clip', num(v.peakDB));
    case 'highPass': return t('note.hpf', num(v.hz, 0));
    case 'eqBand': return t('note.eq', (v.index || 0) + 1, signed(v.gainDB), num(v.frequency, 0));
    case 'compressor': return t('note.comp', num(v.thresholdDB), num(v.ratio));
    case 'compressorOff': return t('note.compOff');
    case 'fader': return t('note.fader', num(v.toDB));
    case 'feedback': return t('note.feedback', num(v.frequency, 0), num(v.notchDB, 0));
    case 'polarityChecking': return t('note.polarityChecking', v.against);
    case 'polarity': return t(v.inverted ? 'note.polarity.inverted' : 'note.polarity.kept', num(v.differenceDB));
    case 'polarityUnclear': return t('note.polarityUnclear', num(v.differenceDB));
    case 'done': return t('note.done', num(v.remainingDeviationDB));
    case 'gaveUp': return t('note.gaveUp', v.reason || '');
    default: return k;
  }
}

function soundcheckScreen() {
  if (readOnly()) return soon('soundcheck');
  const st = S.state || {};
  const running = st.job && st.job !== 'none';
  const chars = ['musical', 'rock', 'classical', 'speech'].map((c) => `<option value="${c}" ${st.character === c ? 'selected' : ''}>${esc(t('char.' + c))}</option>`).join('');
  const sel = S.selected ? (st.strips || []).find((s) => s.id === S.selected) : null;
  const acts = `
    <label>${esc(t('sc.character'))}<select data-change="character">${chars}</select></label>
    <button class="primary" data-act="tune" ${sel && !running ? '' : 'disabled'}>${esc(sel ? `${t('sc.tuneOne')} ${sel.id} · ${sel.name}` : t('sc.pick'))}</button>
    <div class="row"><button class="secondary" data-act="group" data-arg="orchestra" ${running ? 'disabled' : ''}>${esc(t('sc.orchestra'))}</button>
    <button class="secondary" data-act="group" data-arg="choir" ${running ? 'disabled' : ''}>${esc(t('sc.choir'))}</button></div>
    <button class="secondary" data-act="polarity" ${running ? 'disabled' : ''}>${esc(t('sc.polarity'))}</button>
    <div class="row"><button class="danger" data-act="stopJob" ${running ? '' : 'disabled'}>${esc(t('sc.stop'))}</button>
    <button class="ghost" data-act="undo">${esc(t('sc.undo'))}</button></div>
    <p class="status ${running ? 'on' : ''}">${esc(running ? t('sc.running') : t('sc.idle'))}</p>`;
  const log = S.log.length
    ? `<ol class="log">${S.log.slice().reverse().map((e) => `<li><span class="ch">${e.channel}</span>${esc(noteText(e.note))}</li>`).join('')}</ol>`
    : `<p class="muted">${esc(t('sc.log.empty'))}</p>`;
  return `<div class="split"><div class="main-col">${card(t('sc.channels'), channelTable(true), '', 'fill')}</div>
    <div class="side-col">${card(t('sc.actions'), acts)}${card(t('sc.log'), log, '', 'fill')}</div></div>`;
}

function learnScreen() {
  const st = S.state || {};
  const L = S.learn || {};
  const isRec = !!L.recording;
  const routing = st.family === 'x32' ? `<label>${esc(t('learn.routing'))}<select data-change="routing">${['local', 'aes50A', 'aes50B', 'auto']
    .map((r) => `<option value="${r}" ${S.routing === r ? 'selected' : ''}>${esc(t('routing.' + r))}</option>`).join('')}</select></label>` : '';
  const rec = `
    <p class="muted">${esc(t('learn.hint'))}</p>
    ${isRec ? `<div class="rec-live"><span class="rec-dot big"></span><b>${esc(t('learn.recording'))}: ${esc(L.title || '')}</b>
        <span class="clock">${clock(L.seconds)}</span></div>
      <div class="stats"><div><b>${L.frames || 0}</b><span>${esc(t('learn.frames'))}</span></div><div><b>${L.changes || 0}</b><span>${esc(t('learn.changes'))}</span></div></div>
      <button class="danger big" data-act="learnStop">${esc(t('learn.stop'))}</button>`
    : `<label>${esc(t('learn.title'))}<input id="learnTitle" data-input="learnTitle" value="${esc(S.learnTitle)}" placeholder="${esc(t('learn.title.ph'))}"></label>
      <button class="primary big" data-act="learnStart">${esc(t('learn.start'))}</button>`}
    ${routing}`;
  const R = S.recordings || { items: [] };
  const events = R.items.filter((r) => r.event).length;
  const target = R.target || 20;
  const list = R.items.length ? `<ul class="recs">${R.items.map((r) => `<li>
      <div><b>${esc(r.title)}</b><span>${new Date(r.startedAt * 1000).toLocaleString(S.lang === 'ru' ? 'ru-RU' : 'en-GB')} · ${clock(r.duration)} · ${esc(r.model || r.console)}${r.event ? '' : ' · ' + esc(t('learn.test'))}</span></div>
      <button class="ghost small" data-act="deleteRecording" data-arg="${esc(r.file)}" ${isRec ? 'disabled' : ''}>${esc(t('learn.delete'))}</button></li>`).join('')}</ul>`
    : `<p class="muted">${esc(t('learn.list.empty'))}</p>`;
  const progress = `
    <div class="progress-head"><b>${esc(t('learn.events', events, target))}</b></div>
    <div class="bar"><i style="width:${Math.min(100, (events / target) * 100)}%"></i></div>
    <p class="muted">${esc(t('learn.progress.hint'))}</p>${list}`;
  const patterns = S.summary && R.items.length ? `<pre class="summary">${esc(S.summary)}</pre>` : `<p class="muted">${esc(t('learn.patterns.empty'))}</p>`;
  const llm = `
    <p class="muted">${esc(t('llm.hint'))}</p>
    <div class="row"><label class="grow">${esc(t('llm.url'))}<input id="llmUrl" data-input="llmUrl" value="${esc(S.llm.url)}" spellcheck="false"></label>
    <label>${esc(t('llm.model'))}<input id="llmModel" data-input="llmModel" value="${esc(S.llm.model)}" spellcheck="false"></label>
    <button class="ghost" data-act="checkModel">${esc(t('llm.check'))}</button></div>
    ${S.llm.status ? `<p class="status">${esc(S.llm.status)}</p>` : ''}
    <label>${esc(t('llm.question'))}<textarea id="question" data-input="question" rows="2" placeholder="${esc(t('llm.question.ph'))}">${esc(S.llm.question)}</textarea></label>
    <button class="primary" data-act="ask" ${S.llm.asking ? 'disabled' : ''}>${esc(S.llm.asking ? t('llm.asking') : t('llm.ask'))}</button>
    ${S.llm.answer ? `<div class="answer">${esc(S.llm.answer)}</div>` : ''}`;
  return `<div class="split">
    <div class="main-col">${card(t('learn.record'), rec, isRec ? '<span class="chip rec">REC</span>' : '')}
      ${card(t('learn.live'), channelTable(false), '', 'fill')}</div>
    <div class="side-col">${card(t('learn.progress'), progress, `<button class="ghost small" data-act="openFolder">${esc(t('learn.openFolder'))}</button>`)}
      ${card(t('learn.patterns'), patterns, `<button class="ghost small" data-act="refreshPatterns">${esc(t('learn.refresh'))}</button>`)}
      ${card(t('llm.title'), llm)}</div></div>`;
}

function mainView() {
  if (!connected()) return connectScreen();
  const msg = S.message ? `<p class="message" data-act="clearMessage">${esc(S.message)}</p>` : '';
  switch (S.tab) {
    case 'soundcheck': return msg + soundcheckScreen();
    case 'show': return msg + soon('show');
    case 'test': return msg + soon('test');
    default: return msg + learnScreen();
  }
}

// MARK: rendering

let queued = false;
function render() {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    // Keep the focused field and its cursor across the redraw.
    const a = document.activeElement;
    const focus = a && a.id ? { id: a.id, start: a.selectionStart, end: a.selectionEnd } : null;
    document.getElementById('header').innerHTML = header();
    document.getElementById('main').innerHTML = mainView();
    document.documentElement.lang = S.lang;
    if (focus) {
      const el = document.getElementById(focus.id);
      if (el) { el.focus(); try { el.setSelectionRange(focus.start, focus.end); } catch (_) { /* not a text field */ } }
    }
    updateMeters();
  });
}

function updateMeters() {
  const ch = S.meters.channels || [];
  document.querySelectorAll('.meter[data-ch]').forEach((m) => {
    const v = ch[Number(m.dataset.ch) - 1];
    const pct = v == null ? 0 : Math.max(0, Math.min(100, ((v + 60) / 60) * 100));
    const i = m.firstElementChild;
    i.style.width = pct + '%';
    i.className = v > -3 ? 'hot' : v > -18 ? 'mid' : '';
  });
}

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  const act = el.dataset.act;
  if (act === 'clearMessage') { S.message = ''; render(); return; }
  const fn = actions[act];
  if (!fn) return;
  const arg = el.dataset.arg;
  fn(act === 'select' || act === 'pick' ? Number(arg) : arg);
});
document.addEventListener('input', (e) => {
  const k = e.target.dataset && e.target.dataset.input;
  if (k && inputs[k]) inputs[k](e.target.value);
});
document.addEventListener('change', (e) => {
  const k = e.target.dataset && e.target.dataset.change;
  if (k && actions[k]) actions[k](e.target.value);
});
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' || e.shiftKey) return;
  const id = e.target.id;
  if (id === 'question') { e.preventDefault(); actions.ask(); }
  if (id === 'learnTitle') actions.learnStart();
  if (id === 'host') actions.connect();
});

if (api) {
  api.onEvent(onEvent);
  api.version().then((v) => { S.version = v; });
  send({ cmd: 'state' });
  send({ cmd: 'recordings' });
}
render();
