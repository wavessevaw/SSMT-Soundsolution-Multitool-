'use strict';
/* global SSMT */
// Function #5, the handbook: a one-to-one copy of App/SSMT/Handbook (HandbookWorkspace, HandbookSidebarItems,
// HandbookList, HandbookPage, CalculatorView, ArticleView, HandbookTable, ConnectorFace). The content, the page
// lists, search and the calculators' answers come from SSMTCore through the engine (Modules/Handbook.swift).
(function () {
  const { S, t, esc, icon, store, send } = SSMT;
  const FAV = 'favorites';
  const H = {
    index: null, // { categories, entries } from the engine
    byId: {},
    list: { key: '', ids: [] },
    query: '',
    lastQueryEmpty: true,
    results: {}, // calculator id → { results, invalid }
    copied: null,
    tracked: null,
    edits: { field: null, count: 0, last: 0 },
  };
  const ru = () => S.lang !== 'en';
  const L = (x) => (x == null ? '' : typeof x === 'string' ? x : (ru() ? x.ru : x.en));

  const category = () => store.get('handbook.category', 'calculators');
  const itemID = () => store.get('handbook.item', '');
  const favorites = () => store.get('handbook.favorites', '').split(',').filter(Boolean);
  const profile = (fn, ...a) => SSMT.profile && SSMT.profile[fn](...a);

  // MARK: engine

  function listKey() { return JSON.stringify([category(), H.query, S.lang, category() === FAV ? favorites() : []]); }
  function requestList() {
    const key = listKey();
    if (H.list.pending === key) return;
    H.list.pending = key;
    send({ cmd: 'handbookList', category: category(), query: H.query, lang: S.lang, favorites: favorites() });
  }

  function calcState(id) {
    const saved = store.json('handbook.calc.' + id.slice(5), {}) || {};
    const e = H.byId[id];
    const texts = {}, choices = {};
    for (const f of (e && e.fields) || []) {
      if (saved[f.id] === undefined) continue;
      if (f.kind === 'choice') choices[f.id] = Number(saved[f.id]); else texts[f.id] = saved[f.id];
    }
    return { texts, choices };
  }
  function requestCalc(id) {
    const { texts, choices } = calcState(id);
    send({ cmd: 'handbookCalc', id, texts, choices });
  }

  SSMT.onEngine((ev) => {
    switch (ev.event) {
      case 'ready': case 'hello':
        send({ cmd: 'handbookIndex' });
        H.list.pending = null;
        break;
      case 'handbookIndex':
        H.index = ev;
        H.byId = {};
        for (const e of ev.entries) H.byId[e.id] = e;
        H.list.pending = null;
        if (S.section === 'handbook') SSMT.render();
        break;
      case 'handbookList': {
        const key = JSON.stringify([ev.category, ev.query, ev.lang, ev.category === FAV ? favorites() : []]);
        H.list = { key, ids: ev.ids, pending: H.list.pending === key ? null : H.list.pending };
        if (S.section === 'handbook') SSMT.render();
        break;
      }
      case 'handbookResults':
        H.results[ev.id] = { results: ev.results, invalid: ev.invalid || [] };
        if (!patchAnswers(ev.id) && S.section === 'handbook') SSMT.render();
        break;
      default:
    }
  });

  // MARK: sidebar (HandbookSidebarItems)

  function sidebar() {
    const cats = (H.index && H.index.categories) || [];
    const row = (id, ic, title, count) => {
      const on = category() === id;
      return `<button class="hb-cat ${on ? 'on' : ''}" data-act="hbCategory" data-arg="${esc(id)}">${icon(ic, 14)}<b>${esc(title)}</b><span>${count}</span></button>`;
    };
    return `<div class="hb-cats">${cats.map((c) => row(c.id, c.icon, L(c.title), c.count)).join('')}
      <div class="rule"></div>${row(FAV, 'star', t('hb.favorites'), favorites().length)}</div><div class="spacer"></div>`;
  }

  // MARK: workspace (HandbookWorkspace)

  function entries() {
    if (H.list.key !== listKey()) requestList();
    return H.list.ids.map((id) => H.byId[id]).filter(Boolean);
  }

  function workspace() {
    const list = entries();
    const selected = list.find((e) => e.id === itemID()) || list[0];
    if (selected && H.tracked !== selected.id) trackOpened(selected);
    const searching = H.query !== '';
    const page = selected ? pageHTML(selected) : emptyState();
    return `<div class="hb">
      <div class="hb-head">
        <div class="titles"><h1>${esc(t('hb.title'))}</h1><span>${esc(t('section.handbook.subtitle'))}</span></div>
        <label class="hb-search">${icon('magnifyingglass', 14)}<input id="hb-query" type="text" spellcheck="false" placeholder="${esc(t('hb.search'))}" value="${esc(H.query)}" data-input="hbQuery">
          ${searching ? `<button class="clear" data-act="hbClear" title="${esc(t('hb.clear'))}">${icon('xmark.circle.fill', 14)}</button>` : ''}</label>
      </div>
      <div class="hb-body">
        <div class="glass hb-list"><div class="scroll">
          ${searching ? `<div class="hb-results">${esc(t('hb.results', list.length))}</div>` : ''}
          ${list.map((e) => listRow(e, selected && e.id === selected.id, searching)).join('')}
        </div></div>
        <div class="glass hb-page" id="hb-page">${page}</div>
      </div></div>`;
  }

  function listRow(e, on, searching) {
    const cat = H.index && H.index.categories.find((c) => c.id === e.category);
    const sub = searching ? L(cat && cat.title) + ' · ' + L(e.subtitle) : L(e.subtitle);
    return `<button class="hb-row ${on ? 'on' : ''}" data-act="hbSelect" data-arg="${esc(e.id)}">${icon(e.icon, 13)}
      <span class="titles"><b>${esc(L(e.title))}</b><span>${esc(sub)}</span></span></button>`;
  }

  function emptyState() {
    const fav = category() === FAV && !H.query;
    return `<div class="hb-empty">${icon(fav ? 'star' : 'magnifyingglass', 30)}<p>${esc(t(fav ? 'hb.favorites.empty' : 'hb.nothing'))}</p></div>`;
  }

  // MARK: page (HandbookPage)

  function pageHTML(e) {
    const fav = favorites().includes(e.id);
    const body = e.kind === 'calculator' ? calculator(e) : article(e);
    return `<div class="hb-page-in">
      <div class="hb-title">${SSMT.UI.iconTile(e.icon, { tint: 'var(--accent)', size: 44 })}
        <div class="titles"><h2>${esc(L(e.title))}</h2><span>${esc(L(e.subtitle))}</span></div>
        <button class="hb-star ${fav ? 'on' : ''}" data-act="hbFavorite" data-arg="${esc(e.id)}" title="${esc(t(fav ? 'hb.removeFavorite' : 'hb.addFavorite'))}">${icon(fav ? 'star.fill' : 'star', 16)}</button></div>
      ${body}</div>`;
  }

  // MARK: calculator (CalculatorView)

  function calculator(e) {
    const { texts, choices } = calcState(e.id);
    const res = H.results[e.id];
    const invalid = new Set(res ? res.invalid : []);
    const fields = e.fields.map((f) => {
      let control;
      if (f.kind === 'choice') {
        const v = choices[f.id] !== undefined ? choices[f.id] : Math.trunc(f.initial);
        control = `<select class="field hb-choice" data-change="hbChoice" data-arg="${esc(f.id)}">${f.options.map((o, i) => `<option value="${i}" ${i === v ? 'selected' : ''}>${esc(L(o))}</option>`).join('')}</select>`;
      } else {
        const v = texts[f.id] !== undefined ? texts[f.id] : f.initialText;
        control = `<div class="hb-num"><input id="hb-f-${esc(f.id)}" class="${invalid.has(f.id) ? 'invalid' : ''}" type="text" spellcheck="false" value="${esc(v)}" data-input="hbField" data-field="${esc(f.id)}" title="${invalid.has(f.id) ? esc(t('hb.invalid')) : ''}"><span class="unit">${esc(f.unit)}</span></div>`;
      }
      return `<div class="hb-field"><label>${esc(L(f.label))}</label>${control}</div>`;
    }).join('');
    return `<div class="hb-calc">
      <div class="hb-calc-row">
        <div class="hb-fields">${fields}<button class="hb-reset" data-act="hbReset" data-arg="${esc(e.id)}">${esc(t('hb.reset'))}</button></div>
        <div class="hb-answers" id="hb-answers">${answers(e.id)}</div>
      </div>
      <div class="hb-formula">${icon('function', 13)}<span>${esc(L(e.formula))}</span></div></div>`;
  }

  function answers(id) {
    const res = H.results[id];
    if (!res) return '';
    return res.results.map((r) => {
      const key = L(r.label) + '|' + r.label.en;
      const copied = H.copied === r.label.en;
      const copy = `<button class="hb-copy ${copied ? 'done' : ''}" data-act="hbCopy" data-arg="${esc(r.value)}" data-key="${esc(r.label.en)}" title="${esc(t('hb.copy'))}">${icon(copied ? 'checkmark' : 'doc.on.doc', 11)}</button>`;
      if (r.primary) {
        return `<div class="hb-primary" data-k="${esc(key)}"><span class="label">${esc(L(r.label))}</span>
          <div class="line"><span class="value">${esc(r.value)}</span><span class="unit">${esc(r.unit)}</span>${copy}</div></div>`;
      }
      return `<div class="hb-answer"><span class="label">${esc(L(r.label))}</span><span class="value">${esc(r.value + (r.unit ? ' ' + r.unit : ''))}</span>${copy}</div>`;
    }).join('');
  }

  /** New answers without rebuilding the fields (the cursor stays where it is). */
  function patchAnswers(id) {
    const list = entries();
    const selected = list.find((e) => e.id === itemID()) || list[0];
    const el = document.getElementById('hb-answers');
    if (!el || !selected || selected.id !== id) return !!el;
    el.innerHTML = answers(id);
    const inv = new Set(H.results[id].invalid);
    for (const input of document.querySelectorAll('#pane-handbook .hb-num input, .solo .hb-num input')) {
      const bad = inv.has(input.dataset.field);
      input.classList.toggle('invalid', bad);
      input.title = bad ? t('hb.invalid') : '';
    }
    return true;
  }

  function saveCalc(id, fieldID, value) {
    const k = 'handbook.calc.' + id.slice(5);
    const saved = store.json(k, {}) || {};
    saved[fieldID] = String(value);
    store.setJSON(k, saved);
  }

  /** Achievements: calculations (one per pause in typing), the same field again and again. */
  function track(calcID, field) {
    const ed = H.edits;
    ed.count = field === ed.field ? ed.count + 1 : 1;
    ed.field = field;
    if (ed.count >= 30) profile('record', 'secret.perfectionist');
    if (Date.now() - ed.last <= 1500) return;
    ed.last = Date.now();
    profile('record', 'hb.calc');
    if (calcID === 'calc.delay') profile('record', 'hb.delayCalc');
    if (calcID === 'calc.rt60') profile('record', 'hb.rt60');
  }

  // MARK: article (ArticleView, HandbookBlockView)

  function article(e) {
    return `<div class="hb-article">${e.blocks.map(block).join('')}</div>`;
  }

  function block(b) {
    const text = (x) => `<span class="hb-text">${esc(L(x))}</span>`;
    switch (b.type) {
      case 'heading': return `<h3 class="hb-h">${esc(L(b.text))}</h3>`;
      case 'paragraph': return `<p class="hb-p">${esc(L(b.text))}</p>`;
      case 'bullets': return `<div class="hb-bullets">${b.items.map((x) => `<div><i></i>${text(x)}</div>`).join('')}</div>`;
      case 'steps': return `<div class="hb-steps">${b.items.map((x, i) => `<div><i>${i + 1}</i>${text(x)}</div>`).join('')}</div>`;
      case 'table': return table(b);
      case 'warning': return callout(b.text, 'exclamationmark.triangle.fill', 'warning');
      case 'tip': return callout(b.text, 'lightbulb', 'tip');
      case 'connector': return connector(b);
      case 'link': return `<a class="hb-link" href="${esc(b.url)}" target="_blank" rel="noreferrer">${icon('arrow.up.right.square', 13)}<span>${esc(L(b.title))}</span></a>`;
      default: return '';
    }
  }

  function callout(x, ic, kind) {
    return `<div class="hb-callout ${kind}">${icon(ic, 14)}<span>${esc(L(x))}</span></div>`;
  }

  function table(b) {
    const cols = `grid-template-columns:repeat(${b.header.length}, minmax(0, 1fr))`;
    return `<div class="hb-table" style="${cols}">${b.header.map((h) => `<div class="th">${esc(L(h))}</div>`).join('')}
      ${b.rows.map((r, i) => r.map((c, j) => `<div class="td ${i % 2 === 1 ? 'odd' : ''} ${j === 0 ? 'first' : ''}">${esc(L(c))}</div>`).join('')).join('')}</div>`;
  }

  function connector(d) {
    const size = d.shape === 'jack' ? [260, 70] : [150, 150];
    let outline = '';
    if (d.shape === 'round') outline = '<div class="face round"></div>';
    else if (d.shape === 'rectangle') outline = '<div class="face rect"></div>';
    else outline = '<div class="face jack"><span class="tip"></span><span class="ring"></span><span class="sleeve"></span></div>';
    const pins = d.pins.map((p) => `<span class="pin" style="left:${size[0] * p.x}px;top:${size[1] * p.y}px">${esc(p.label)}</span>`).join('');
    return `<div class="hb-connector"><div class="faceBox" style="width:${size[0]}px;height:${size[1]}px">${outline}${pins}</div>
      <span class="caption">${esc(L(d.caption))}</span></div>`;
  }

  // MARK: behaviour

  /** Achievements of the handbook: pages read, terms, consoles. */
  function trackOpened(e) {
    H.tracked = e.id;
    if (e.kind === 'calculator' && !H.results[e.id]) requestCalc(e.id);
    profile('record', 'hb.pages');
    if (e.id === 'xlr3') profile('record', 'hb.xlr');
    if (e.category === 'glossary') profile('insert', e.id, 'hb.terms');
    else if (e.category === 'consoles' && e.id !== 'consoleCommon') profile('insert', e.id, 'hb.consoles');
  }

  function selectFirst() {
    const first = entries()[0];
    if (first) store.set('handbook.item', first.id);
  }

  SSMT.section({
    id: 'handbook',
    sidebar,
    render: workspace,
    actions: {
      hbCategory(id) { store.set('handbook.category', id); SSMT.render(); },
      hbSelect(id) { store.set('handbook.item', id); SSMT.render(); },
      hbClear() { H.query = ''; H.lastQueryEmpty = true; SSMT.render(); },
      hbFavorite(id) {
        const f = favorites();
        const i = f.indexOf(id);
        if (i >= 0) f.splice(i, 1); else f.push(id);
        store.set('handbook.favorites', f.join(','));
        profile('recordMax', 'hb.maxFavorites', f.length);
        SSMT.render();
      },
      hbReset(id) {
        try { localStorage.removeItem('ssmt.handbook.calc.' + id.slice(5)); } catch (_) { /* private mode */ }
        requestCalc(id);
        SSMT.render();
      },
      hbChoice(value, el) {
        const id = itemID() || (entries()[0] || {}).id;
        if (!id) return;
        saveCalc(id, el.dataset.arg, value);
        track(id, el.dataset.arg);
        requestCalc(id);
      },
      hbCopy(value, el) {
        try { navigator.clipboard.writeText(value); } catch (_) { /* no clipboard */ }
        const key = el.dataset.key;
        H.copied = key;
        const page = entries().find((e) => e.id === itemID()) || entries()[0];
        if (page) patchAnswers(page.id);
        setTimeout(() => { if (H.copied === key) { H.copied = null; if (page) patchAnswers(page.id); } }, 1200);
      },
    },
    inputs: {
      hbQuery(q) {
        // One search per new query typed from scratch.
        if (q && H.lastQueryEmpty) profile('record', 'hb.search');
        H.lastQueryEmpty = !q;
        if (q.toLowerCase().includes('спикон')) profile('record', 'hb.speakon');
        H.query = q;
        requestList();
        SSMT.render();
      },
      hbField(value, el) {
        const page = entries().find((e) => e.id === itemID()) || entries()[0];
        if (!page) return;
        saveCalc(page.id, el.dataset.field, value);
        track(page.id, el.dataset.field);
        requestCalc(page.id);
      },
    },
    keys(e) {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        const q = document.getElementById('hb-query');
        if (q) q.focus();
      }
    },
  });

  // ⌘F inside a field of the handbook, and Enter in the search: the first result.
  document.addEventListener('keydown', (e) => {
    if (S.section !== 'handbook') return;
    if (e.target && e.target.id === 'hb-query' && e.key === 'Enter') { selectFirst(); SSMT.render(); }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f' && e.target.closest && e.target.closest('input, textarea, select')) {
      e.preventDefault();
      const q = document.getElementById('hb-query');
      if (q) q.focus();
    }
  });

  SSMT.handbook = { workspace, sidebar };
  send({ cmd: 'handbookIndex' });
})();
