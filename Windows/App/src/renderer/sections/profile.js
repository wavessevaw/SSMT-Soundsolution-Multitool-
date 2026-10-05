'use strict';
/* global SSMT */
// Profile and account: a one-to-one copy of App/SSMT/Profile (AccountViews: AccountGate, LoginView, RegisterView,
// ProfileAvatar, XPBar; ProfileViews: ProfileBadge, ProfileSheet, ProfileOverview, AchievementWall, AchievementCard,
// LevelTable, AchievementToast, LevelUpOverlay). Behaviour is ProfileCenter's, run by the engine
// (Modules/Profile.swift, PlayerProgress / Leveling / AchievementCatalog from SSMTCore); profiles are stored in
// <dataDir>/Profiles/<id>.json in the Mac's format. Other functions record events with SSMT.profile.record(...).
(function () {
  const { S, t, esc, icon, store, send } = SSMT;
  const api = window.ssmt;
  const preview = !!(api && api.preview);
  const P = {
    catalog: null, profiles: [], state: null, // state: { signedIn, preview, profile }
    toasts: [], levelUp: null, showProfile: false, tab: 0, filter: 0, category: '',
    gate: { registering: false, selected: null, password: '', autoLogin: true, failed: false, error: null, color: 0x2A4B3E, name: '', pw: '', again: '' },
    lastSection: null, toastTimer: null,
  };
  const ru = () => S.lang !== 'en';
  const L = (x) => (x == null ? '' : typeof x === 'string' ? x : (ru() ? x.ru : x.en));
  const hex = (n) => '#' + Number(n).toString(16).padStart(6, '0');
  const rgba = (n, a) => `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;

  // Colours of App/SSMT/Profile (EngineerRank.color / textColor, AchievementRarity.color, AchievementCategory.icon).
  const RANK = [[0xB5643A, 0xD08257], [0xC99A5B, 0xDDB27A], [0xC9CED6, 0xE1E5EA], [0xF0C24B, 0xF6D57D]];
  const RARITY = [0xA3ACA6, 0x64D2FF, 0xC79BFF, 0xF0C24B];
  const CAT_ICON = { general: 'sparkles', time: 'clock', setup: 'dial.medium', ptch: 'list.bullet.rectangle', qtrl: 'play.rectangle.on.rectangle',
    foh: 'slider.vertical.3', handbook: 'book', levels: 'chart.line.uptrend.xyaxis', secrets: 'eye' };
  const GOLD = 0xF0C24B, GOLD_TEXT = 0xF6D57D;
  const rankOf = (level) => Math.min(3, Math.max(0, Math.floor((level - 1) / 10)));

  /** "12 345": thin grouping as formatInt on the Mac. */
  function formatInt(n) {
    const d = String(Math.abs(Math.trunc(n)));
    let out = '';
    for (let i = 0; i < d.length; i++) { if (i > 0 && (d.length - i) % 3 === 0) out += ' '; out += d[i]; }
    return n < 0 ? '-' + out : out;
  }
  const formatHours = (h) => (h < 10 ? h.toFixed(1) : String(Math.trunc(h)));

  // MARK: API for the other functions (ProfileCenter.shared.record / recordMax / insert)

  SSMT.profile = {
    record(event, count = 1) { send({ cmd: 'profileRecord', event, count }); },
    recordMax(key, value) { send({ cmd: 'profileRecordMax', key, value }); },
    insert(item, set) { send({ cmd: 'profileInsert', item, set }); },
    get current() { return P.state && P.state.profile; },
  };

  const tracking = () => P.state && P.state.signedIn && !P.state.preview;

  // MARK: engine

  function hello() { send({ cmd: 'profileHello', auto: store.get('profile.auto', '') }); }

  SSMT.onEngine((ev) => {
    switch (ev.event) {
      case 'ready': case 'hello': hello(); break;
      case 'profileCatalog': P.catalog = ev; redrawAll(); break;
      case 'profiles':
        P.profiles = ev.items || [];
        if (!P.profiles.find((p) => p.id === P.gate.selected)) P.gate.selected = P.profiles[0] ? P.profiles[0].id : null;
        drawGate();
        break;
      case 'profile': {
        const was = P.state && P.state.signedIn;
        P.state = ev;
        if (ev.signedIn && !was && !ev.preview) { P.lastSection = S.section; send({ cmd: 'profileSection', name: S.section }); }
        if (!ev.signedIn) { P.toasts = []; P.levelUp = null; P.showProfile = false; }
        redrawAll();
        break;
      }
      case 'profileUnlocked':
        P.toasts.push(...(ev.achievements || []));
        if (ev.level) P.levelUp = ev.level;
        drawToast();
        drawLevelUp();
        break;
      case 'profileAuto':
        if (ev.id) store.set('profile.auto', ev.id); else { try { localStorage.removeItem('ssmt.profile.auto'); } catch (_) { /* private mode */ } }
        break;
      case 'profileError':
        if (ev.key === 'acc.err.wrongPassword' && !P.gate.registering && P.profiles.length) { P.gate.failed = true; P.gate.password = ''; }
        else P.gate.error = ev.key.startsWith('acc.') ? t(ev.key) : ev.key;
        drawGate();
        break;
      default:
    }
  });

  // Input and time (ProfileCenter.handle / tick): every click and key press goes to the engine.
  document.addEventListener('mousedown', (e) => {
    if (!tracking() || (e.button !== 0 && e.button !== 2)) return;
    send({ cmd: 'profileInput', kind: 'click', x: e.clientX, y: e.clientY });
  }, true);
  document.addEventListener('keydown', (e) => {
    if (!tracking() || e.repeat || ['Control', 'Shift', 'Alt', 'Meta'].includes(e.key)) return;
    send({ cmd: 'profileInput', kind: 'key', ctrl: e.ctrlKey || e.metaKey, shift: e.shiftKey, key: e.key.length === 1 ? e.key : '' });
  }, true);
  window.addEventListener('focus', () => send({ cmd: 'profileFocus', active: true }));
  window.addEventListener('blur', () => send({ cmd: 'profileFocus', active: false }));
  window.addEventListener('beforeunload', () => send({ cmd: 'profileQuit' }));

  // Sections opened (MainView.onChange(of: section)).
  window.addEventListener('DOMContentLoaded', () => {
    const draw = SSMT.draw;
    SSMT.draw = () => {
      draw();
      if (tracking() && S.section !== P.lastSection) { P.lastSection = S.section; send({ cmd: 'profileSection', name: S.section }); }
    };
  });

  function redrawAll() {
    drawGate();
    drawSheet();
    drawToast();
    drawLevelUp();
    SSMT.render();
  }

  // MARK: pieces (ProfileAvatar, XPBar)

  function avatar(initials, color, level, size, showLevel = true) {
    const r = RANK[rankOf(level)];
    const ring = Math.max(2, size * 0.055);
    const pill = showLevel ? `<span class="pill" style="font-size:${Math.max(10, size * 0.22)}px;padding:0 ${size * 0.09}px;min-width:${size * 0.46}px;height:${size * 0.42}px;border-radius:${size * 0.21}px;background:${hex(r[0])};box-shadow:0 0 0 ${Math.max(2, size * 0.04)}px var(--panel) inset;right:${-size * 0.1}px;bottom:${-size * 0.06}px">${level}</span>` : '';
    return `<span class="avatar" style="width:${size}px;height:${size}px"><span class="disc" style="font-size:${size * 0.32}px;background:${hex(color)};box-shadow:inset 0 0 0 ${ring}px ${hex(r[0])}">${esc(initials)}</span>${pill}</span>`;
  }

  function xpBar(fraction, color, height) {
    const f = Math.min(1, Math.max(0, Number(fraction) || 0));
    return `<div class="xpbar" style="height:${height}px"><div style="width:max(${height}px, ${f * 100}%);background:${color}"></div></div>`;
  }

  const achievement = (id) => P.catalog && P.catalog.achievements.find((a) => a.id === id);
  const catName = (id) => { const c = P.catalog && P.catalog.categories.find((x) => x.id === id); return c ? L(c.name) : id; };
  const rarityName = (r) => (P.catalog ? L(P.catalog.rarities[r].name) : '');
  const rankName = (r) => (P.catalog ? L(P.catalog.ranks[r].name) : '');
  const rankTitle = (r) => (P.catalog ? L(P.catalog.ranks[r].title) : '');
  const levelRow = (l) => P.catalog && P.catalog.levels[l - 1];

  // MARK: sidebar badge (ProfileBadge)

  function badge() {
    const p = P.state && P.state.profile;
    if (!p || !P.catalog) return '';
    const rank = rankOf(p.level);
    const next = p.next;
    return `<button class="profile-badge" data-profile="open" title="${esc(t('acc.openProfile'))}">
      <div class="top">${avatar(p.initials, p.color, p.level, 42)}
        <div class="names"><b>${esc(p.name)}</b><span style="color:${hex(RANK[rank][1])}">${esc(rankName(rank) + ' · ' + t('acc.levelShort', p.level))}</span></div>
        <span class="trophies">${icon('trophy', 10)}<b>${Object.keys(p.unlocked).length}</b></span></div>
      ${xpBar(next ? next.overall : 1, hex(RANK[rank][0]), 6)}
      ${next ? `<div class="to">${esc(t('acc.toLevel', next.level, Math.round(next.overall * 100)))}</div>` : ''}</button>`;
  }
  SSMT.profileBadge = badge;

  // MARK: profile overview (ProfileOverview)

  function overview() {
    const p = P.state && P.state.profile;
    if (!p || !P.catalog) return '';
    const rank = rankOf(p.level);
    const rc = RANK[rank];
    const n = p.next;
    let progress;
    if (n) {
      const cond = (done, ic, text) => `<span class="cond ${done ? 'done' : ''}">${icon(done ? 'checkmark' : ic, 12)}<span>${esc(text)}</span></span>`;
      progress = `<div class="to-row"><span>${esc(t('acc.toLevelPlain', n.level))}</span><b>${formatInt(p.xp)} / ${formatInt(n.xpRequired)} XP</b></div>
        ${xpBar(n.overall, hex(rc[0]), 14)}
        <div class="conds">${cond(n.hours >= 1, 'clock', t('acc.cond.hours', formatHours(p.hours), formatHours(n.hoursRequired)))}${cond(n.clicks >= 1, 'cursorarrow.click', t('acc.cond.clicks', formatInt(p.clicks), formatInt(n.clicksRequired)))}</div>`;
    } else {
      progress = `<div class="max" style="color:${hex(RANK[3][1])}">${esc(t('acc.maxLevel'))}</div>`;
    }
    const header = `<div class="pcard header">${avatar(p.initials, p.color, p.level, 116)}
      <div class="info"><div class="who"><h1>${esc(p.name)}</h1><span style="color:${hex(rc[1])}">${esc(rankName(rank) + ' · ' + t('acc.level', p.level) + ' · ' + rankTitle(rank))}</span></div>${progress}</div></div>`;
    const src = (k, xp) => `<div class="src"><span>${esc(t(k))}</span><b>${xp}</b></div>`;
    const sources = `<div class="pcard sources"><div class="head">${esc(t('acc.xpFrom'))}</div>
      ${src('acc.xp.hour', '+100')}${src('acc.xp.click', '+1')}${src('acc.xp.delay', '+20')}${src('acc.xp.setup', '+150')}${src('acc.xp.show', '+200')}${src('acc.xp.soundcheck', '+150')}${src('acc.xp.achievement', '+50…500')}</div>`;
    const ladder = `<div class="pcard ladder"><div class="row"><h3>${esc(t('acc.pathToGold'))}</h3><span>${esc(t('acc.level40'))}</span></div>
      <div class="ranks">${P.catalog.ranks.map((r, i) => {
        const cells = [];
        for (let l = r.from; l <= r.to; l++) {
          cells.push(`<i style="background:${l <= p.level ? hex(RANK[i][0]) : '#1F2421'};${l === p.level + 1 ? `box-shadow:inset 0 0 0 1px ${hex(RANK[i][0])}` : ''}"></i>`);
        }
        return `<div class="rank"><div class="cells">${cells.join('')}</div><span style="color:${hex(RANK[i][1])}">${esc(L(r.name) + ` ${r.from}–${r.to} · ` + L(r.title))}</span></div>`;
      }).join('')}</div></div>`;
    const total = P.catalog.achievements.length;
    const unlockedCount = Object.keys(p.unlocked).length;
    const stat = (v, k, gold) => `<div class="stat ${gold ? 'gold' : ''}"><b>${esc(v)}</b><span>${esc(t(k))}</span></div>`;
    const stats = `<div class="stats">${stat(formatHours(p.hours), 'acc.stat.hours')}${stat(formatInt(p.clicks), 'acc.stat.clicks')}${stat(formatInt(p.counters['qtrl.go'] || 0), 'acc.stat.go')}${stat(formatInt(p.counters['setup.finished'] || 0), 'acc.stat.setups')}${stat(`${unlockedCount} / ${total}`, 'acc.stat.achievements', true)}</div>`;
    const last = Object.entries(p.unlocked).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([id]) => achievement(id)).filter(Boolean);
    const recent = `<div class="recent"><h3>${esc(t('acc.recent'))}</h3><div class="rows">${last.map((a) => achievementRow(a)).join('')}${achievementRow(null, total - unlockedCount)}</div></div>`;
    return `<div class="overview"><div class="toprow">${header}${sources}</div>${ladder}${stats}${recent}</div>`;
  }

  function achievementRow(a, hiddenCount = 0) {
    const tile = a
      ? `<span class="tile" style="color:${hex(RARITY[a.rarity])};background:${rgba(RARITY[a.rarity], 0.14)}">${icon(CAT_ICON[a.category], 17)}</span>`
      : `<span class="tile hidden">${icon('lock', 17)}</span>`;
    const text = a ? `<b>${esc(L(a.title))}</b><span>+${a.xp} XP</span>` : `<b class="muted">${esc(t('acc.hiddenLeft', hiddenCount))}</b><span class="muted">${esc(t('acc.keepWorking'))}</span>`;
    return `<div class="ach-row ${a ? '' : 'hidden'}">${tile}<div class="t">${text}</div></div>`;
  }

  // MARK: achievement wall (AchievementWall, AchievementCard)

  function wall() {
    const p = P.state && P.state.profile;
    if (!p || !P.catalog) return '';
    const all = P.catalog.achievements;
    const open = (a) => p.unlocked[a.id] !== undefined;
    const value = (a) => p.values[a.id] || 0;
    const earned = all.filter(open).reduce((s, a) => s + a.xp, 0);
    const list = all.filter((a) => {
      const o = open(a), inProgress = !o && value(a) > 0;
      const kindOK = P.filter === 0 || (P.filter === 1 && o) || (P.filter === 2 && inProgress) || (P.filter === 3 && !o && !inProgress);
      return kindOK && (!P.category || a.category === P.category);
    }).sort((a, b) => ((open(a) ? 0 : 1) - (open(b) ? 0 : 1)) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const chip = (k, i) => `<button class="chip ${P.filter === i ? 'on' : ''}" data-profile="filter" data-arg="${i}">${esc(t(k))}</button>`;
    const opts = [`<option value="" ${!P.category ? 'selected' : ''}>${esc(t('acc.f.allCategories'))}</option>`]
      .concat(P.catalog.categories.map((c) => `<option value="${c.id}" ${P.category === c.id ? 'selected' : ''}>${esc(L(c.name))}</option>`)).join('');
    const count = Object.keys(p.unlocked).length;
    return `<div class="wall"><div class="head"><div class="titles"><h1>${esc(t('acc.tab.achievements'))}</h1><span>${esc(t('acc.opened', count, all.length, formatInt(earned)))}</span></div>
      <div class="bar">${xpBar(count / all.length, hex(GOLD), 10)}</div></div>
      <div class="filters">${chip('acc.f.all', 0)}${chip('acc.f.open', 1)}${chip('acc.f.progress', 2)}${chip('acc.f.hidden', 3)}<span class="vdiv"></span>
        <select class="mac-popup" data-profile-change="category">${opts}</select></div>
      <div class="grid">${list.map((a) => card(a, p)).join('')}</div></div>`;
  }

  function card(a, p) {
    const date = p.unlocked[a.id];
    const open = date !== undefined;
    const value = p.values[a.id] || 0;
    const inProgress = !open && value > 0;
    const shown = open || inProgress;
    const color = RARITY[a.rarity];
    let foot;
    if (open) foot = t('acc.gotOn', new Intl.DateTimeFormat(ru() ? 'ru-RU' : 'en-US', { day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(date * 1000)), a.xp);
    else if (!shown && a.hint) foot = t('acc.hint', L(a.hint));
    else if (!shown) foot = t('acc.noHint');
    else foot = t('acc.inProgress');
    const bar = inProgress && a.target ? `${xpBar(value / a.target, hex(color), 6)}<span class="count">${formatInt(Math.trunc(value))} / ${formatInt(Math.trunc(a.target))}</span>` : '';
    const legendary = a.rarity === 3 && open;
    return `<div class="ach-card ${shown ? '' : 'hidden'}" ${legendary ? `style="border-color:${rgba(color, 0.45)}"` : ''}>
      <div class="top"><span class="tile" style="color:${shown ? hex(color) : 'var(--text-muted)'};${open ? `background:${rgba(color, 0.14)}` : ''}">${icon(shown ? CAT_ICON[a.category] : 'lock', 17)}</span>
        <span class="rarity" style="color:${shown ? hex(color) : 'var(--text-muted)'}">${esc(shown ? rarityName(a.rarity) : '???')}</span></div>
      <b class="title">${esc(shown ? L(a.title) : '???')}</b>
      <p class="text">${esc(shown ? L(a.text) : t('acc.hidden') + ' · ' + catName(a.category))}</p>
      ${bar}<div class="grow"></div><span class="foot">${esc(foot)}</span></div>`;
  }

  // MARK: levels (LevelTable)

  function levels() {
    const p = P.state && P.state.profile;
    if (!P.catalog) return '';
    const current = p ? p.level : 1;
    const rows = P.catalog.levels.map((r) => {
      const rk = rankOf(r.level);
      const bg = r.level === current ? rgba(RANK[rk][0], 0.14) : (r.level % 2 === 0 ? 'rgba(255,255,255,0.02)' : 'transparent');
      const c = (s, cls = '', color = '') => `<div class="${cls}" style="background:${bg};${color ? `color:${color}` : ''}">${esc(s)}</div>`;
      return c(String(r.level), 'mono', hex(RANK[rk][1])) + c((r.level - 1) % 10 === 0 ? rankName(rk) : '', 'bold', hex(RANK[rk][1]))
        + c(formatInt(r.xp), 'mono') + c(formatHours(r.hours), 'mono') + c(formatInt(r.clicks), 'mono');
    }).join('');
    const head = ['acc.col.level', 'acc.col.rank', 'acc.col.xp', 'acc.col.hours', 'acc.col.clicks'].map((k) => `<div class="th">${esc(t(k))}</div>`).join('');
    return `<div class="levels"><h1>${esc(t('acc.levelsTitle'))}</h1><p>${esc(t('acc.levelsText'))}</p><div class="ltable">${head}${rows}</div></div>`;
  }

  // MARK: the profile window (ProfileSheet)

  function sheetHTML() {
    const body = P.tab === 1 ? wall() : P.tab === 2 ? levels() : overview();
    return `<div class="sheet"><div class="bar">
        ${SSMT.UI.segmented([[0, t('acc.tab.profile')], [1, t('acc.tab.achievements')], [2, t('acc.tab.levels')]], P.tab, 'tab').replace(/data-act="tab"/g, 'data-profile="tab"')}
        <div class="grow"></div>${SSMT.UI.button(t('acc.logout'), {}).replace('<button', '<button data-profile="logout"')}${SSMT.UI.button(t('settings.done'), { kind: 'primary' }).replace('<button', '<button data-profile="close"')}</div>
      <div class="rule"></div><div class="content"><div class="pad">${body}</div></div></div>`;
  }

  function drawSheet() {
    let el = document.getElementById('profile-sheet');
    if (!P.showProfile || !(P.state && P.state.signedIn)) { if (el) el.remove(); return; }
    if (!el) {
      el = document.createElement('div');
      el.id = 'profile-sheet';
      el.className = 'modal-backdrop';
      document.body.appendChild(el);
    }
    const scroll = el.querySelector('.content');
    const top = scroll ? scroll.scrollTop : 0;
    el.innerHTML = sheetHTML();
    const s2 = el.querySelector('.content');
    if (s2) s2.scrollTop = top;
  }

  // MARK: toast and level up (AchievementToast, LevelUpOverlay)

  function toastHTML(id) {
    const a = achievement(id);
    if (!a) return '';
    const color = RARITY[a.rarity];
    return `<div class="ach-toast" style="border-color:${rgba(color, 0.45)}" data-profile="open">
      <span class="tile" style="color:${hex(color)};background:${rgba(color, 0.16)}">${icon(CAT_ICON[a.category], 24)}</span>
      <div class="t"><span class="kicker" style="color:${hex(color)}">${esc(t('acc.newAchievement') + ' · ' + rarityName(a.rarity).toUpperCase())}</span>
        <b>${esc(L(a.title))}</b><span class="text">${esc(L(a.text))}</span></div>
      <div class="side"><b>+${a.xp} XP</b><button data-profile="dismiss" title="${esc(t('acc.close'))}">${icon('xmark', 10)}</button></div></div>`;
  }

  function drawToast() {
    let el = document.getElementById('profile-toast');
    const id = P.toasts[0];
    if (!id || !P.catalog) { if (el) el.remove(); return; }
    if (!el) {
      el = document.createElement('div');
      el.id = 'profile-toast';
      document.body.appendChild(el);
    }
    if (el.dataset.id === id) return;
    el.dataset.id = id;
    el.innerHTML = toastHTML(id);
    clearTimeout(P.toastTimer);
    P.toastTimer = setTimeout(() => { if (P.toasts[0] === id) dismissToast(); }, 5000);
  }

  function dismissToast() {
    P.toasts.shift();
    const el = document.getElementById('profile-toast');
    if (el) delete el.dataset.id;
    drawToast();
  }

  function levelUpHTML(level) {
    const p = P.state && P.state.profile;
    const rank = rankOf(level);
    const rc = RANK[rank];
    const newRank = (level - 1) % 10 === 0;
    const next = p && p.next;
    return `<div class="levelup" style="border-color:${rgba(rc[0], 0.4)}">
      <span class="kicker" style="color:${hex(rc[1])}">${esc(t(newRank ? 'acc.newRank' : 'acc.newLevel'))}</span>
      <span class="ring" style="color:${hex(rc[1])};box-shadow:inset 0 0 0 7px ${hex(rc[0])}">${level}</span>
      <div class="names"><b>${esc(newRank ? rankName(rank) + '!' : t('acc.level', level))}</b><span>${esc(rankName(rank) + ' · ' + t('acc.level', level) + ' · ' + rankTitle(rank))}</span></div>
      <p>${esc(t('acc.levelUpText', formatHours(p ? p.hours : 0), formatInt(p ? p.clicks : 0)))}</p>
      ${next ? `<div class="next"><div class="row"><span>${esc(t('acc.toLevelPlain', next.level))}</span><b>${formatInt(p.xp)} / ${formatInt(next.xpRequired)} XP</b></div>${xpBar(next.overall, hex(rc[0]), 8)}</div>` : ''}
      <button class="continue" data-profile="levelDone" style="background:${hex(rc[0])}">${esc(t('acc.continue'))}</button></div>`;
  }

  function drawLevelUp() {
    let el = document.getElementById('profile-levelup');
    if (!P.levelUp || !P.catalog) { if (el) el.remove(); return; }
    if (!el) {
      el = document.createElement('div');
      el.id = 'profile-levelup';
      document.body.appendChild(el);
    }
    el.innerHTML = levelUpHTML(P.levelUp);
  }

  // MARK: account gate (AccountGate, LoginView, RegisterView)

  function gateHTML() {
    const g = P.gate;
    const registering = g.registering || P.profiles.length === 0;
    let card;
    if (registering) {
      card = `<div class="acc-card"><h2>${esc(t('acc.newProfile'))}</h2>
        <input class="acc-field" id="acc-name" type="text" spellcheck="false" placeholder="${esc(t('acc.name'))}" value="${esc(g.name)}" data-acc="name">
        <input class="acc-field" id="acc-pw" type="password" placeholder="${esc(t('acc.password'))}" value="${esc(g.pw)}" data-acc="pw">
        <input class="acc-field" id="acc-again" type="password" placeholder="${esc(t('acc.again'))}" value="${esc(g.again)}" data-acc="again">
        <div class="colors">${((P.catalog && P.catalog.avatarColors) || [0x2A4B3E, 0x23405A, 0x43305A, 0x5A2E2E, 0x5A4A2A]).map((c) => `<button class="${c === g.color ? 'on' : ''}" style="background:${hex(c)}" data-profile="color" data-arg="${c}" title="${esc(t('acc.color'))}"></button>`).join('')}</div>
        ${g.error ? `<div class="error">${esc(g.error)}</div>` : ''}
        <button class="acc-button" data-profile="create">${esc(t('acc.createStart'))}</button>
        ${P.profiles.length ? `<button class="acc-link" data-profile="back">${esc(t('acc.backToLogin'))}</button>` : ''}</div>`;
    } else {
      const p = P.profiles.find((x) => x.id === g.selected) || P.profiles[0];
      const name = P.profiles.length > 1
        ? `<label class="who-menu"><b>${esc(p.name)}</b>${icon('chevron.down', 10)}<select data-acc="select">${P.profiles.map((q) => `<option value="${q.id}" ${q.id === p.id ? 'selected' : ''}>${esc(q.name)}</option>`).join('')}</select></label>`
        : `<b class="who-name">${esc(p.name)}</b>`;
      card = `<div class="acc-card"><div class="who"><span class="disc" style="background:${hex(p.color)}">${esc(p.initials)}</span>${name}</div>
        <input class="acc-field ${g.failed ? 'failed' : ''}" id="acc-login-pw" type="password" placeholder="${esc(t('acc.password'))}" value="${esc(g.password)}" data-acc="password">
        ${g.failed ? `<div class="error">${esc(t('acc.err.wrongPassword'))}</div>` : ''}
        <button class="acc-button" data-profile="signIn">${esc(t('acc.signIn'))}</button>
        <div class="foot"><label class="check"><input type="checkbox" data-acc="auto" ${g.autoLogin ? 'checked' : ''}><span>${esc(t('acc.auto'))}</span></label>
          <button class="acc-link" data-profile="register">${esc(t('acc.create'))}</button></div></div>`;
    }
    return `<div class="acc-gate"><div class="col">${SSMT.brand ? SSMT.brand.mark('full', 96) : ''}${card}</div></div>`;
  }

  function drawGate() {
    let el = document.getElementById('account-gate');
    const show = P.state && !P.state.signedIn && !preview;
    if (!show) { if (el) el.remove(); return; }
    const a = document.activeElement;
    const focus = a && a.id ? { id: a.id, start: a.selectionStart, end: a.selectionEnd } : null;
    if (!el) {
      el = document.createElement('div');
      el.id = 'account-gate';
      el.className = 'backdrop-fill';
      document.body.appendChild(el);
    }
    el.innerHTML = gateHTML();
    const f = focus && document.getElementById(focus.id);
    if (f) { f.focus(); try { f.setSelectionRange(focus.start, focus.end); } catch (_) { /* not text */ } }
    else {
      const first = el.querySelector('#acc-login-pw, #acc-name');
      if (first) first.focus();
    }
  }

  function signIn() {
    const g = P.gate;
    if (!g.selected) return;
    send({ cmd: 'profileLogin', id: g.selected, password: g.password, autoLogin: g.autoLogin });
  }
  function create() {
    const g = P.gate;
    g.error = null;
    send({ cmd: 'profileRegister', name: g.name, password: g.pw, again: g.again, color: g.color, autoLogin: true });
  }

  document.addEventListener('input', (e) => {
    const k = e.target.dataset && e.target.dataset.acc;
    if (!k) return;
    const g = P.gate;
    if (k === 'select') { g.selected = e.target.value; g.failed = false; g.password = ''; drawGate(); return; }
    if (k === 'auto') { g.autoLogin = e.target.checked; return; }
    g[k] = e.target.value;
  });
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter' || !e.target.closest) return;
    if (e.target.closest('#account-gate')) { if (P.gate.registering || P.profiles.length === 0) create(); else signIn(); }
    else if (P.levelUp) { P.levelUp = null; drawLevelUp(); }
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && P.showProfile) { P.showProfile = false; drawSheet(); }
  });

  const actions = {
    open() { P.showProfile = true; drawSheet(); },
    close() { P.showProfile = false; drawSheet(); },
    logout() { send({ cmd: 'profileLogout' }); },
    tab(i) { P.tab = Number(i); drawSheet(); },
    filter(i) { P.filter = Number(i); drawSheet(); if (SSMT.solo && SSMT.solo.fn) SSMT.render(); },
    dismiss(_, e) { e.stopPropagation(); dismissToast(); },
    levelDone() { P.levelUp = null; drawLevelUp(); },
    color(c) { P.gate.color = Number(c); drawGate(); },
    create, signIn,
    register() { P.gate.registering = true; P.gate.error = null; drawGate(); },
    back() { P.gate.registering = false; P.gate.error = null; drawGate(); },
  };
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-profile]');
    if (el && actions[el.dataset.profile]) { actions[el.dataset.profile](el.dataset.arg, e); return; }
    if (P.levelUp && e.target.id === 'profile-levelup') { P.levelUp = null; drawLevelUp(); }
  });
  document.addEventListener('change', (e) => {
    if (e.target.dataset && e.target.dataset.profileChange === 'category') {
      P.category = e.target.value;
      drawSheet();
      if (SSMT.solo && SSMT.solo.fn) SSMT.render();
    }
  });

  /** Views for the snapshot scenarios and for other screens. */
  SSMT.profileViews = {
    badge, overview, wall, levels, gate: gateHTML, toast: () => toastHTML(P.toasts[0]),
    /** Snapshot state: AchievementToast with `id` first in the queue (no timer). */
    setToasts(ids) { P.toasts = ids.slice(); },
    setGate(o) { Object.assign(P.gate, o); },
  };

  hello();
})();
