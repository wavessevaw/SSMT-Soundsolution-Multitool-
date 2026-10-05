'use strict';
/* global SSMT */
// The brand (App/SSMT/Brand/BrandMark.swift), About (Views/AboutView.swift), the splash (Views/LaunchView.swift,
// SplashView) and the hidden game's launcher (Game/GameWindow.swift). One click on the brand in the sidebar opens
// About; five quick clicks open the game. The game is the Mac's Mega Drive ROM (game/soundcheck.bin), handed to
// the emulator Windows associates with .gen files, as the Mac hands it to OpenEmu.
(function () {
  const { S, t, esc, icon, store, send } = SSMT;
  /** CURRENT_PROJECT_VERSION of the Mac app (project.yml), shown in About next to the version. */
  const BUILD = '15';
  const B = { version: '', taps: 0, tapTimer: null, about: false, game: null, shot: 0, shotTimer: null };
  const api = window.ssmt;
  if (api && api.version) api.version().then((v) => { B.version = v; });

  /** BrandMark: only the files supplied by the brand owner, never redrawn. */
  function mark(variant, height) {
    const src = variant === 'full' ? 'brand/BrandLogoFull.png' : 'brand/BrandMark.png';
    return `<img class="brand-mark" src="${src}" alt="" style="height:${height}px">`;
  }

  // MARK: a screen alone (snapshot scenarios: the Mac tests render single views)

  /** Shows `fn()` alone over a backdrop, as the Mac snapshot tests render one view; redrawn with the app. */
  SSMT.solo = function (fn, { padding = 0, background = 'backdrop', cls = '' } = {}) {
    let el = document.getElementById('solo');
    if (!el) {
      el = document.createElement('div');
      el.id = 'solo';
      document.body.appendChild(el);
      const draw = SSMT.draw;
      SSMT.draw = () => { draw(); if (SSMT.solo.fn) document.getElementById('solo').innerHTML = SSMT.solo.fn(); };
    }
    el.className = `solo ${background} ${cls}`;
    el.style.padding = padding + 'px';
    document.getElementById('app').style.visibility = 'hidden';
    SSMT.solo.fn = fn;
    el.innerHTML = fn();
  };

  /** The state of one Mac snapshot test (App/Tests/Snapshots/SnapshotTests.swift), for the parity check. */
  SSMT.snapshot = function (name) {
    const pv = SSMT.profileViews;
    const views = {
      splash: [() => splashHTML({ progress: 0.6, version: '1.0.0' }), { background: 'black' }],
      'game-launcher': [launcherHTML, { background: 'background' }],
      'account-register': [() => pv.gate(), {}],
      'profile-overview': [() => pv.overview(), { padding: 28 }],
      'profile-achievements': [() => pv.wall(), { padding: 28 }],
      'profile-badge': [() => `<div style="width:272px">${pv.badge()}</div>`, { padding: 16 }],
      'achievement-toast': [() => `<div class="solo-backdrop" style="align-self:center;padding:20px">${pv.toast()}</div>`, { background: 'background' }],
      'handbook-calculator': [() => SSMT.handbook.workspace(), { padding: 16 }],
      'handbook-pinout': [() => SSMT.handbook.workspace(), { padding: 16 }],
    };
    if (name === 'achievement-toast') pv.setToasts(['nightOwl']);
    if (name.startsWith('handbook-')) {
      store.set('handbook.category', name === 'handbook-calculator' ? 'calculators' : 'pinouts');
      store.set('handbook.item', name === 'handbook-calculator' ? 'calc.cable' : 'speakon');
      try { localStorage.removeItem('ssmt.handbook.calc.cable'); } catch (_) { /* private mode */ }
    }
    const [fn, opts] = views[name];
    SSMT.solo(fn, opts);
    SSMT.render();
  };

  // MARK: brand clicks (AppSidebar.brandTapped)

  function brandTapped() {
    B.taps += 1;
    clearTimeout(B.tapTimer);
    if (B.taps >= 5) {
      B.taps = 0;
      openGame();
      return;
    }
    const taps = B.taps;
    B.tapTimer = setTimeout(() => {
      if (taps === 1) { B.about = true; drawAbout(); }
      B.taps = 0;
    }, 450);
  }

  // MARK: About (AboutView, a popover on the brand)

  function aboutHTML() {
    const on = store.get('showSplash', 'true') !== 'false';
    return `<div class="about">${mark('full', 64)}
      <div class="name">SSMT · SoundSolution Multi Tool</div>
      <div class="ver">v${esc(B.version || '0')} (${BUILD})</div>
      <p>${esc(t('about.text'))}</p>
      <label class="check"><input type="checkbox" id="about-splash" ${on ? 'checked' : ''}><span>${esc(t('about.splash'))}</span></label></div>`;
  }

  function drawAbout() {
    let el = document.getElementById('about-pop');
    if (!B.about) { if (el) el.remove(); return; }
    if (!el) {
      el = document.createElement('div');
      el.id = 'about-pop';
      el.className = 'popover';
      document.body.appendChild(el);
    }
    const brand = document.querySelector('[data-shell="brand"]');
    const r = brand ? brand.getBoundingClientRect() : { left: 20, bottom: 80, width: 200 };
    el.style.left = Math.max(8, r.left + 21 - 30) + 'px';
    el.style.top = (r.bottom + 6) + 'px';
    el.innerHTML = `<span class="arrow"></span>${aboutHTML()}`;
  }

  document.addEventListener('mousedown', (e) => {
    if (B.about && !e.target.closest('#about-pop') && !e.target.closest('[data-shell="brand"]')) { B.about = false; drawAbout(); }
  }, true);
  document.addEventListener('change', (e) => {
    if (e.target.id === 'about-splash') store.set('showSplash', e.target.checked ? 'true' : 'false');
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (B.about) { B.about = false; drawAbout(); }
      if (B.game) closeGame();
    }
  });

  // MARK: splash (SplashView, LaunchState)

  function splashHTML({ progress = 0, slow = false, version } = {}) {
    return `<div class="splash-in">
      <div class="grow"></div>${mark('full', 150)}<div class="tagline">SoundSolution Multi Tool</div><div class="grow"></div>
      <div class="foot"><div class="bar"><div class="fill" style="width:${Math.round(progress * 160)}px"></div></div>
        ${slow ? `<div class="loading">${esc(t('launch.loading'))}</div>` : ''}<div class="ver">v${esc(version || B.version || '0')}</div></div></div>`;
  }

  /** Cold start: the splash over the (hidden) interface for at least 1.6 s, then a crossfade. */
  function runSplash() {
    if (store.get('showSplash', 'true') === 'false' || (api && api.preview)) return;
    const el = document.createElement('div');
    el.id = 'splash';
    document.body.appendChild(el);
    const st = { progress: 0.2, slow: false };
    const draw = () => { el.innerHTML = splashHTML(st); };
    draw();
    const start = Date.now();
    const slowTimer = setTimeout(() => { st.slow = true; draw(); }, 4000);
    let ready = false;
    const finish = () => {
      if (ready) return;
      ready = true;
      st.progress = 0.9; draw();
      setTimeout(() => {
        clearTimeout(slowTimer);
        st.progress = 1; draw();
        el.classList.add('out');
        setTimeout(() => el.remove(), 750);
      }, Math.max(0, 1600 - (Date.now() - start)));
    };
    document.fonts.ready.then(() => { st.progress = 0.5; draw(); });
    // Initialized: the profile state from the engine (or no engine after 3 s).
    SSMT.onEngine((ev) => { if (ev.event === 'profile' || ev.event === 'profiles') finish(); });
    setTimeout(finish, 3000);
  }

  // MARK: the hidden game (GameLauncherView, GameROM)

  const SHOTS = ['game-shot-title', 'game-shot-play', 'game-shot-boss'];
  const ROM_SIZE = 786432;
  const gameInfo = { dir: '', path: '', hasEmulator: false };

  function launcherHTML() {
    const keys = ['move', 'punch', 'kick', 'jump', 'items', 'down', 'start'];
    const primary = gameInfo.hasEmulator
      ? SSMT.UI.button(t('game.win.play'), { kind: 'primary', act: 'gamePlay' })
      : SSMT.UI.button(t('game.win.getEmulator'), { kind: 'primary', act: 'gameGetEmulator', cls: 'wrap' });
    return `<div class="game">
      <div class="left"><div class="screen"><img src="game/${SHOTS[B.shot]}.png" alt=""></div>
        <div class="dots">${SHOTS.map((_, i) => `<span class="${i === B.shot ? 'on' : ''}" data-game="shot" data-arg="${i}"></span>`).join('')}</div></div>
      <div class="right">
        <div class="titles"><h2>${esc(t('game.title'))}</h2><span>${esc(t('game.subtitle', Math.floor(ROM_SIZE / 1024)))}</span></div>
        <p class="story">${esc(t('game.story'))}</p>
        <div class="buttons">${primary}<div class="row">${SSMT.UI.button(t('game.save'), { act: 'gameSave' })}${SSMT.UI.button(t('game.win.reveal'), { act: 'gameReveal' })}</div></div>
        <div class="controls"><div class="head">${esc(t('game.controls'))}</div>
          ${keys.map((k) => `<div class="key"><b>${esc(t('game.key.' + k))}</b><span>${esc(t('game.does.' + k))}</span></div>`).join('')}</div>
        <p class="run">${esc(t('game.run'))}</p>
      </div></div>`;
  }

  function drawGame() {
    const body = document.querySelector('#game-window .body');
    if (body) body.innerHTML = launcherHTML();
    const solo = document.querySelector('#solo .game');
    if (solo) solo.outerHTML = launcherHTML();
  }

  /** The launcher's own window (a window over the app, 1030 × 540 as on the Mac). */
  function openGame() {
    B.about = false;
    drawAbout();
    if (SSMT.profile) SSMT.profile.record('secret.game');
    send({ cmd: 'gameInfo' });
    if (B.game) return;
    const el = document.createElement('div');
    el.id = 'game-window';
    el.innerHTML = `<div class="win"><div class="titlebar"><span>${esc(t('game.title'))}</span><button data-game="close">${icon('xmark', 13)}</button></div><div class="body"></div></div>`;
    document.body.appendChild(el);
    B.game = el;
    B.shotTimer = setInterval(() => { B.shot = (B.shot + 1) % SHOTS.length; drawGame(); }, 4000);
    drawGame();
  }

  function closeGame() {
    clearInterval(B.shotTimer);
    if (B.game) B.game.remove();
    B.game = null;
  }

  /** The bundled ROM's path on disk (inside the app), for the main process to read. */
  function bundledROM() {
    let p = decodeURIComponent(new URL('game/soundcheck.bin', location.href).pathname);
    if (/^\/[A-Za-z]:\//.test(p)) p = p.slice(1).replace(/\//g, '\\');
    return p;
  }

  /** A copy outside the app with an extension emulators recognise. */
  async function exported() {
    if (!api || !gameInfo.path) return null;
    const data = await api.readFile(bundledROM(), 'base64');
    await api.writeFile(gameInfo.path, data, 'base64');
    return gameInfo.path;
  }

  const gameActions = {
    async gamePlay() {
      const rom = await exported();
      if (!rom) return;
      if (SSMT.profile) SSMT.profile.record('secret.gamePlayed');
      api.openFolder(rom);
    },
    gameGetEmulator() { window.open('https://www.retrodev.com/blastem/'); },
    async gameSave() {
      if (!api) return;
      const dst = await api.saveFile({ title: t('game.save'), defaultName: 'soundcheck-of-the-dead.md',
        filters: [{ name: 'Mega Drive ROM', extensions: ['md', 'gen', 'bin'] }] });
      if (!dst) return;
      await api.writeFile(dst, await api.readFile(bundledROM(), 'base64'), 'base64');
    },
    async gameReveal() {
      const rom = await exported();
      if (rom) api.openFolder(gameInfo.dir);
    },
  };

  document.addEventListener('click', (e) => {
    const g = e.target.closest('[data-game]');
    if (g) {
      if (g.dataset.game === 'close') closeGame();
      if (g.dataset.game === 'shot') { B.shot = Number(g.dataset.arg); drawGame(); }
      return;
    }
    const b = e.target.closest('#game-window [data-act], #solo .game [data-act]');
    if (b && gameActions[b.dataset.act]) gameActions[b.dataset.act]();
  });
  window.addEventListener('focus', () => { if (B.game) send({ cmd: 'gameInfo' }); });

  SSMT.onEngine((ev) => {
    if (ev.event === 'gameInfo') { Object.assign(gameInfo, ev); drawGame(); }
  });

  SSMT.brand = { mark, brandTapped, splashHTML, launcherHTML, aboutHTML, openGame };
  runSplash();
})();
