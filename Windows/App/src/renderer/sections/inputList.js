'use strict';
/* global SSMT */
// Ptch, function #2 (App/SSMT/Views/InputList/InputListWorkspace.swift, EditableRows.swift, StagePlanEditor.swift,
// InputListExport.swift and the input list items of AppSidebar.swift): the input list, monitor mixes, the pull
// list, the stage plan editor and the exports. The document lives in the engine (Modules/InputList.swift, through
// SSMTCore, as InputListStore on the Mac); this screen shows the engine's state and sends one command per edit.

(function () {
  const { S, t, esc, icon, UI, send } = SSMT;
  const D = SSMT.ilDraw;

  const blankDoc = () => ({ version: 1, artist: '', event: '', venue: '', engineer: '', contact: '', notes: '', channels: [], mixes: [],
    stage: { width: 10, depth: 6, items: [], grid: 0.25 } });

  const L = {
    doc: blankDoc(),
    summary: { channelCount: 0, phantomCount: 0, mixCount: 0, stereoMixCount: 0, models: [], stands: [] },
    issues: [], pages: [[]], file: '', path: '', suggestedName: 'Ptch',
    catalog: { templates: [], micModels: [], kinds: [], stands: [], groups: [], mixTypes: [], rowsPerPage: 24 },
    selCh: new Set(), selMix: new Set(), item: null, anchorCh: null, anchorMix: null,
    error: null, menu: null, popover: false, sb: { prefix: 'SB1-', start: 1, onlyEmpty: true },
    focus: null, drag: null, pending: 0,
  };
  let dirty = true;
  let lastLang = null;
  const invalidate = () => { dirty = true; SSMT.render(); };
  const profile = (k, v) => { const p = SSMT.profile; if (p && p.record) p.record(k, v); };
  const profileMax = (k, v) => { const p = SSMT.profile; if (p && p.recordMax) p.recordMax(k, v); };

  // MARK: engine

  const edit = (op, fields = {}, name = '') => send({ cmd: 'il.edit', op, name, ...fields });
  /** A field of the document (InputListStore bindings): one undoable step in the engine. */
  function setField(target, id, key, value, quiet) {
    if (quiet) L.pending++;
    applyLocal(target, id, key, value);
    edit('set', { target, id, key, value, quiet: !!quiet });
  }
  /** Typing shows at once; the engine's answer then replaces the document. */
  function applyLocal(target, id, key, value) {
    const d = L.doc;
    const obj = target === 'doc' ? d : target === 'channel' ? d.channels.find((c) => c.id === id)
      : target === 'mix' ? d.mixes.find((m) => m.id === id) : d.stage.items.find((i) => i.id === id);
    if (obj) obj[key] = value;
  }

  send({ cmd: 'il.init' });

  function onEvent(ev) {
    switch (ev.event) {
      case 'ready': send({ cmd: 'il.init' }); break;
      case 'il.catalog':
        L.catalog = { ...L.catalog, ...ev };
        invalidate();
        break;
      case 'il.state': {
        const quiet = !!ev.quiet;
        if (quiet && L.pending > 0) L.pending--;
        if (!quiet || L.pending === 0) L.doc = ev.doc && ev.doc.stage ? ev.doc : blankDoc();
        Object.assign(L, { summary: ev.summary || L.summary, issues: ev.issues || [], pages: ev.pages || [[]], file: ev.file || '',
          path: ev.path || '', suggestedName: ev.suggestedName || 'Ptch' });
        if (ev.select) {
          if (ev.select.channels) { L.selCh = new Set(ev.select.channels); L.anchorCh = ev.select.channels[0] || null; }
          if (ev.select.mixes) L.selMix = new Set(ev.select.mixes);
          if (ev.select.item !== undefined) L.item = ev.select.item || null;
        }
        // Rows that are gone (deleted, new patch, undo) leave the selection too.
        const ch = new Set(L.doc.channels.map((c) => c.id)), mx = new Set(L.doc.mixes.map((m) => m.id));
        for (const id of L.selCh) if (!ch.has(id)) L.selCh.delete(id);
        for (const id of L.selMix) if (!mx.has(id)) L.selMix.delete(id);
        if (L.anchorCh && !ch.has(L.anchorCh)) L.anchorCh = null;
        if (L.anchorMix && !mx.has(L.anchorMix)) L.anchorMix = null;
        if (L.item && !L.doc.stage.items.some((i) => i.id === L.item)) L.item = null;
        if (quiet) refreshDerived(); else invalidate();
        break;
      }
      case 'il.mics':
        if (L.micRequest && L.micRequest.id === ev.id) {
          const r = L.micRequest;
          L.micRequest = null;
          openMenu('mic', r.rect, (ev.items || []).map((m) => ({ label: m, act: 'pickMic', arg: `${r.id}\n${m}` })));
        }
        break;
      case 'il.error': L.error = ev.text; invalidate(); break;
      case 'il.exported': exported(); break;
      case 'il.progress':
        if (ev.channelAdded) profile('ptch.channelAdded');
        for (const k of ['maxChannels', 'maxDrums', 'maxSM58', 'maxPhantom', 'maxMixes', 'maxStageItems']) profileMax('ptch.' + k, ev[k]);
        if (ev.fridayEvening) profile('ptch.fridayEvening');
        break;
      default: break;
    }
  }

  function exported() {
    profile('ptch.export');
    if (!L.doc.channels.length) profile('ptch.emptyExport');
  }

  // MARK: files and export (InputListStore open / save, InputListExporter)

  const api = () => window.ssmt || {};
  const baseName = (p) => String(p).split(/[\\/]/).pop();

  function newDocument() { closeMenus(); send({ cmd: 'il.new' }); }

  async function open() {
    closeMenus();
    if (!api().openFile) return;
    const paths = await api().openFile({ title: t('il.open'), filters: [{ name: 'SSMT Ptch', extensions: ['ssmtinput', 'json'] }] });
    if (paths && paths[0]) send({ cmd: 'il.open', path: paths[0] });
  }

  async function save(as = false) {
    closeMenus();
    let path = L.path;
    if (!path || as) {
      if (!api().saveFile) return;
      path = await api().saveFile({ title: t(as ? 'il.saveAs' : 'il.save'), defaultName: L.suggestedName + '.ssmtinput',
        filters: [{ name: 'SSMT Ptch', extensions: ['ssmtinput'] }] });
      if (!path) return;
    }
    send({ cmd: 'il.save', path });
  }

  async function exportAs(kind) {
    closeMenus();
    const a = api();
    if (!a.saveFile) return;
    const ext = kind === 'pdf' ? 'pdf' : kind.startsWith('png') ? 'png' : 'csv';
    const suffix = kind === 'pngStage' ? ' - stage' : kind === 'csvMixes' ? ' - mixes' : '';
    const path = await a.saveFile({ title: t('il.export.' + kind), defaultName: L.suggestedName + suffix + '.' + ext,
      filters: [{ name: ext.toUpperCase(), extensions: [ext] }] });
    if (!path) return;
    try {
      const sheets = D.sheets(L.doc, L.summary, L.pages);
      switch (kind) {
        case 'pdf':
          await a.renderPDF({ html: D.printDocument(sheets, { pdf: true }), path, pageSize: [D.PAGE.w, D.PAGE.h] });
          exported();
          break;
        case 'pngList': {
          // Every sheet but the stage plan, one under the other, at 2× for messengers and e-mail.
          const list = sheets.slice(0, -1);
          await a.renderPNG({ html: D.printDocument(list, { zoom: 2 }), path, width: D.PAGE.w, height: D.PAGE.h * list.length, scale: 2 });
          exported();
          break;
        }
        case 'pngStage':
          await a.renderPNG({ html: D.printDocument([D.stageSheet(L.doc, '')], { zoom: 2 }), path, width: D.PAGE.w, height: D.PAGE.h, scale: 2 });
          exported();
          break;
        case 'csvChannels': send({ cmd: 'il.csv', kind: 'channels', path }); break;
        case 'csvMixes': send({ cmd: 'il.csv', kind: 'mixes', path }); break;
        default: break;
      }
    } catch (e) {
      L.error = `${baseName(path)}: ${e && e.message ? e.message : e}`;
      invalidate();
    }
  }

  // MARK: menus and popovers

  function openMenu(id, rect, items) {
    L.menu = { id, rect, items };
    invalidate();
  }
  function closeMenus() {
    if (!L.menu && !L.popover) return;
    L.menu = null;
    L.popover = false;
    invalidate();
  }
  const rectOf = (el) => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, w: r.width, h: r.height }; };

  function menuHTML() {
    if (!L.menu) return '';
    const m = L.menu;
    const items = m.items.map((it) => (it === '-' ? '<div class="il-menu-sep"></div>'
      : `<button class="il-menu-item" data-act="${it.act}" data-arg="${esc(it.arg)}">${esc(it.label)}</button>`)).join('');
    const top = m.rect.y + m.rect.h + 4;
    const right = m.align === 'right';
    return `<div class="il-menu" style="top:${top}px;${right ? `right:${window.innerWidth - m.rect.x - m.rect.w}px` : `left:${m.rect.x}px`}">${items}</div>`;
  }

  // MARK: helpers for the markup

  const field = (id, value, attrs, cls = 'il-field') => `<input id="${id}" class="${cls}" type="text" value="${esc(value)}" spellcheck="false" ${attrs}>`;
  const checkbox = (id, on, attrs) => `<input id="${id}" class="il-check" type="checkbox" ${on ? 'checked' : ''} ${attrs}>`;
  const popup = (id, value, options, attrs) => `<select id="${id}" class="il-pop" ${attrs}>${options.map(([v, label]) => `<option value="${esc(v)}" ${v === value ? 'selected' : ''}>${esc(label)}</option>`).join('')}</select>`;
  /** Stepper: the label and the small up / down control. */
  function stepper(label, act, value, lo, hi, step) {
    const up = Math.min(value + step, hi), down = Math.max(value - step, lo);
    return `<span class="il-stepper"><span>${esc(label)}</span><span class="il-step">
      <button data-act="${act}" data-arg="${up}" ${value >= hi ? 'disabled' : ''} tabindex="-1"><svg width="7" height="4" viewBox="0 0 7 4"><path d="M0.5 3.5 L3.5 0.5 L6.5 3.5" fill="none" stroke="currentColor" stroke-width="1.2"/></svg></button>
      <button data-act="${act}" data-arg="${down}" ${value <= lo ? 'disabled' : ''} tabindex="-1"><svg width="7" height="4" viewBox="0 0 7 4"><path d="M0.5 0.5 L3.5 3.5 L6.5 0.5" fill="none" stroke="currentColor" stroke-width="1.2"/></svg></button></span></span>`;
  }
  const btn = (label, o) => UI.button(label, o);
  /** An icon-only tool button of the toolbars (dimmed when off, as ChannelToolbar.tool). */
  const tool = (ic, key, act, enabled, arg) => `<button class="btn secondary il-tool ${enabled ? '' : 'off'}" data-act="${act}" ${arg !== undefined ? `data-arg="${esc(arg)}"` : ''} ${enabled ? '' : 'disabled'} title="${esc(t(key))}">${icon(ic, 14)}</button>`;

  // MARK: workspace

  function header() {
    return `<div class="il-head">
      <div class="il-titles"><h1>${esc(t('il.title'))}</h1><div class="il-file">${esc(L.file || t('il.unsaved'))}</div></div>
      <button class="il-export" data-act="exportMenu">${icon('square.and.arrow.up', 13)}<span>${esc(t('il.export'))}</span>${icon('chevron.down', 9, 'il-chev')}</button>
    </div>`;
  }

  function errorBanner() {
    if (!L.error) return '';
    return `<div class="il-error">${icon('exclamationmark.octagon.fill', 14)}<span class="text">${esc(L.error)}</span>
      <button class="il-plain" data-act="dismissError" title="${esc(t('action.close'))}">${icon('xmark', 13)}</button></div>`;
  }

  function showInfo() {
    const d = L.doc;
    const f = (key, prop) => `<div class="il-col"><label>${esc(t(key))}</label>${field('il-doc-' + prop, d[prop] || '', `data-input="docField" data-key="${prop}"`, 'il-field rounded')}</div>`;
    const date = d.date ? new Date(d.date) : null;
    const ymd = date && !isNaN(date) ? `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}` : '';
    const dateCell = `<div class="il-col"><label>${esc(t('il.date'))}</label><div class="il-date">
      ${checkbox('il-doc-date-on', !!d.date, 'data-change="dateToggle"')}
      ${date ? `<button class="il-field il-datetext" data-act="datePick">${esc(new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'numeric', day: 'numeric' }).format(date))}</button>
        <input id="il-doc-date" class="il-datepick" type="date" value="${ymd}" data-change="dateSet" tabindex="-1">
        <span class="il-step"><button data-act="dateStep" data-arg="1" tabindex="-1"><svg width="7" height="4" viewBox="0 0 7 4"><path d="M0.5 3.5 L3.5 0.5 L6.5 3.5" fill="none" stroke="currentColor" stroke-width="1.2"/></svg></button><button data-act="dateStep" data-arg="-1" tabindex="-1"><svg width="7" height="4" viewBox="0 0 7 4"><path d="M0.5 0.5 L3.5 3.5 L6.5 0.5" fill="none" stroke="currentColor" stroke-width="1.2"/></svg></button></span>` : ''}
    </div></div>`;
    const body = `<div class="il-grid">${f('il.artist', 'artist')}${f('il.event', 'event')}${f('il.venue', 'venue')}
      ${f('il.engineer', 'engineer')}${f('il.contact', 'contact')}${dateCell}</div>
      <div class="il-col"><label>${esc(t('il.notes'))}</label><textarea id="il-doc-notes" class="il-field rounded il-notes" rows="1" spellcheck="false" data-input="docField" data-key="notes">${esc(d.notes || '')}</textarea></div>`;
    return UI.panel(t('il.show'), body);
  }

  // Channels

  const anchor = () => { let a = null; for (const c of L.doc.channels) if (L.selCh.has(c.id)) a = c.id; return a; };

  function channelToolbar() {
    const sel = L.selCh, none = L.doc.channels.length === 0;
    return `<div class="il-toolbar" id="il-ch-toolbar">
      ${btn(t('il.addChannel'), { kind: 'primary', act: 'addChannel', icon: 'plus', title: t('il.addChannel') + ' (Ctrl+Shift+N)' })}
      <button class="il-menubtn" data-act="templateMenu">${icon('square.stack.3d.up', 14)}<span>${esc(t('il.template'))}</span>${icon('chevron.down', 9, 'il-chev')}</button>
      <span class="il-vdiv"></span>
      ${tool('arrow.left.and.right', 'il.stereo', 'stereo', sel.size === 1)}
      ${tool('plus.square.on.square', 'action.duplicate', 'duplicate', sel.size > 0)}
      ${tool('arrow.up', 'il.moveUp', 'move', sel.size > 0, -1)}
      ${tool('arrow.down', 'il.moveDown', 'move', sel.size > 0, 1)}
      ${tool('trash', 'action.delete', 'deleteChannels', sel.size > 0)}
      <span class="il-vdiv"></span>
      ${tool('list.number', 'il.renumber', 'renumber', !none)}
      <span class="il-pop-anchor">${btn(t('il.stagebox.fill'), { act: 'stageboxOpen', icon: 'rectangle.connected.to.line.below', disabled: none })}${L.popover ? stageboxPopover() : ''}</span>
    </div>`;
  }

  function stageboxPopover() {
    const sb = L.sb;
    return `<div class="il-popover"><div class="il-popover-arrow"></div>
      <div class="il-popover-title">${esc(t('il.stagebox.fill'))}</div>
      <div class="il-popover-row"><span>${esc(t('il.stagebox.prefix'))}</span>${field('il-sb-prefix', sb.prefix, 'placeholder="SB1-" data-input="sbPrefix"', 'il-field rounded il-sb-prefix')}
        ${stepper(t('il.stagebox.start', sb.start), 'sbStart', sb.start, 1, 256, 1)}</div>
      <label class="il-toggle">${checkbox('il-sb-only', sb.onlyEmpty, 'data-change="sbOnly"')}<span>${esc(t('il.stagebox.onlyEmpty'))}</span></label>
      <div>${btn(t('il.stagebox.apply'), { kind: 'primary', act: 'stageboxApply' })}</div></div>`;
  }

  const CH_COLS = 'il-cols-ch';
  const MIX_COLS = 'il-cols-mix';

  /** EditableRows: header, rows of fields, selection; height follows the row count within `visible`. */
  function rows(kind, cols, headers, list, selected, cells, visible, empty) {
    const h = Math.min(Math.max(list.length, visible[0]), visible[1]) * 28;
    const head = headers.map((x) => `<span>${esc(x)}</span>`).join('');
    const body = list.map((r) => `<div class="il-row ${cols} ${selected.has(r.id) ? 'on' : ''}" data-row="${kind}" data-id="${r.id}">${cells(r)}</div>`).join('');
    return `<div class="il-rows ${L.focus === kind ? 'focused' : ''}" data-rows="${kind}">
      <div class="il-rows-head ${cols}">${head}</div><div class="il-rows-div"></div>
      <div class="il-rows-body" data-scroll="${kind}" style="height:${h}px">${body}${empty && !list.length ? empty : ''}</div></div>`;
  }

  function channelTable() {
    const c = L.catalog;
    const headers = ['№', t('il.col.source'), t('il.col.mic'), t('il.col.stand'), '+48V', t('il.col.stagebox'), t('il.col.insert'), t('il.col.group'), t('il.col.notes')];
    const stands = c.stands.map((s) => [s, t('stand.' + s)]);
    const groups = c.groups.map((g) => [g, t('chgroup.' + g)]);
    const empty = `<div class="il-empty">${icon('list.bullet.rectangle', 26)}<span>${esc(t('il.empty'))}</span></div>`;
    return rows('channels', CH_COLS, headers, L.doc.channels, L.selCh, (ch) => {
      const id = ch.id, a = `data-target="channel" data-id="${id}"`;
      return `<span class="il-num"><i style="background:${D.GROUP_COLORS[ch.group] || D.GROUP_COLORS.other}"></i>${field(`il-ch-${id}-number`, ch.number, `${a} data-key="number" data-change="number" inputmode="numeric"`, 'il-field cell num right')}</span>
        ${field(`il-ch-${id}-source`, ch.source, `${a} data-key="source" data-input="field" placeholder="${esc(t('il.col.source'))}"`, 'il-field cell')}
        <span class="il-mic">${field(`il-ch-${id}-mic`, ch.mic, `${a} data-key="mic" data-input="field"`, 'il-field cell')}<button class="il-plain il-mic-menu" data-act="micMenu" data-arg="${id}" tabindex="-1">${icon('chevron.down', 15)}</button></span>
        ${popup(`il-ch-${id}-stand`, ch.stand, stands, `${a} data-key="stand" data-change="field"`)}
        <span>${checkbox(`il-ch-${id}-phantom`, ch.phantom, `${a} data-key="phantom" data-change="field"`)}</span>
        ${field(`il-ch-${id}-stagebox`, ch.stagebox, `${a} data-key="stagebox" data-input="field" placeholder="SB1-01"`, 'il-field cell mono12')}
        ${field(`il-ch-${id}-insert`, ch.insert, `${a} data-key="insert" data-input="field"`, 'il-field cell')}
        ${popup(`il-ch-${id}-group`, ch.group, groups, `${a} data-key="group" data-change="field"`)}
        ${field(`il-ch-${id}-notes`, ch.notes, `${a} data-key="notes" data-input="field"`, 'il-field cell')}`;
    }, [4, 24], empty);
  }

  function issueText(i) {
    switch (i.kind) {
      case 'duplicateNumber': return t('il.issue.dupNumber', i.number);
      case 'duplicateStagebox': return t('il.issue.dupStagebox', i.stagebox);
      default: return t('il.issue.emptySource', i.channel);
    }
  }
  function issuesHTML() {
    const list = L.issues || [];
    if (!list.length) return '';
    return `<div class="il-issues">${list.slice(0, 6).map((i) => `<div class="il-issue">${icon('exclamationmark.triangle.fill', 12)}<span>${esc(issueText(i))}</span></div>`).join('')}
      ${list.length > 6 ? `<div class="il-issues-more">${esc(t('il.issues.more', list.length - 6))}</div>` : ''}</div>`;
  }

  // Mixes

  function mixToolbar() {
    return `<div class="il-toolbar" id="il-mix-toolbar">
      ${btn(t('il.addMix'), { act: 'addMix', icon: 'plus' })}
      <button class="btn secondary il-keep" data-act="deleteMixes" ${L.selMix.size ? '' : 'disabled'} title="${esc(t('action.delete'))}">${icon('trash', 14)}</button>
      <button class="btn secondary" data-act="renumberMixes" title="${esc(t('il.renumber'))}">${icon('list.number', 14)}</button></div>`;
  }

  function mixTable() {
    const types = L.catalog.mixTypes.map((m) => [m, t('mixtype.' + m)]);
    const toolbar = mixToolbar();
    const headers = ['№', t('il.mix.name'), t('il.mix.type'), t('il.mix.stereo'), t('il.col.notes')];
    return `<div class="il-mixes">${toolbar}${rows('mixes', MIX_COLS, headers, L.doc.mixes, L.selMix, (m) => {
      const id = m.id, a = `data-target="mix" data-id="${id}"`;
      return `${field(`il-mx-${id}-number`, m.number, `${a} data-key="number" data-change="number" inputmode="numeric"`, 'il-field cell num')}
        ${field(`il-mx-${id}-name`, m.name, `${a} data-key="name" data-input="field" placeholder="${esc(t('il.mix.name'))}"`, 'il-field cell')}
        ${popup(`il-mx-${id}-type`, m.type, types, `${a} data-key="type" data-change="field"`)}
        <span>${checkbox(`il-mx-${id}-stereo`, m.stereo, `${a} data-key="stereo" data-change="field"`)}</span>
        ${field(`il-mx-${id}-notes`, m.notes, `${a} data-key="notes" data-input="field"`, 'il-field cell')}`;
    }, [3, 16])}</div>`;
  }

  // Summary

  function summaryHTML() {
    const s = L.summary;
    const stat = (v, label) => `<div class="il-stat"><b>${esc(v)}</b><span>${esc(label)}</span></div>`;
    const chips = (items) => `<div class="il-chips">${items.map((x) => `<span>${esc(x)}</span>`).join('')}</div>`;
    return `<div class="il-stats">${stat(String(s.channelCount), t('il.sum.channels'))}${stat(String(s.phantomCount), '+48V')}${stat(String(s.mixCount), t('il.sum.mixes'))}</div>
      ${s.models.length ? `<div class="il-sub">${esc(t('il.sum.mics'))}</div>${chips(s.models.map((m) => `${m.count}× ${m.name}`))}` : ''}
      ${s.stands.length ? `<div class="il-sub">${esc(t('il.sum.stands'))}</div>${chips(s.stands.map((x) => `${x.count}× ` + t('stand.' + x.type)))}` : ''}`;
  }

  // Stage plan

  const kindSize = (k) => { const c = L.catalog.kinds.find((x) => x.id === k); return c ? { w: c.w, d: c.d } : { w: 1, d: 1 }; };

  function stageEditor() {
    const plan = L.doc.stage;
    const palette = `<div class="il-palette" data-scroll="palette">${L.catalog.kinds.map((k) => `<button class="il-kind" data-act="stageAdd" data-arg="${k.id}" title="${esc(t('stage.add.help'))}">
      ${D.symbolIcon(k.id, { w: k.w, d: k.d })}<span>${esc(t('stage.kind.' + k.id))}</span></button>`).join('')}</div>`;
    const controls = `<div class="il-stage-controls">
      ${stepper(t('stage.size.width', plan.width), 'stageWidth', plan.width, 2, 40, 0.5)}
      ${stepper(t('stage.size.depth', plan.depth), 'stageDepth', plan.depth, 2, 30, 0.5)}
      <label class="il-toggle">${checkbox('il-stage-snap', plan.grid > 0, 'data-change="stageSnap"')}<span>${esc(t('stage.snap'))}</span></label></div>`;
    return `<div class="il-stage">${palette}<div class="il-stage-main"><div class="il-canvas" id="il-canvas" tabindex="-1"></div>
      <div class="il-inspector" id="il-inspector">${inspector()}</div></div>${controls}</div>`;
  }

  function inspector() {
    const item = L.item && L.doc.stage.items.find((i) => i.id === L.item);
    if (!item) {
      return `<div class="glass il-insp il-hint">${icon('hand.point.up.left', 20)}<span>${esc(t('stage.hint'))}</span></div>`;
    }
    const id = item.id, a = `data-target="item" data-id="${id}"`;
    const fld = (title, key) => `<div class="il-col"><label>${esc(title)}</label>${field(`il-it-${id}-${key}`, item[key] || '', `${a} data-key="${key}" data-input="field"`, 'il-field rounded')}</div>`;
    const sizeSteppers = item.kind === 'text'
      ? stepper(t('stage.fontSize', item.fontSize), 'itemFont', item.fontSize, 8, 48, 2)
      : `${stepper(t('stage.width', item.width), 'itemWidth', item.width, 0.2, 12, 0.1)}${stepper(t('stage.depth', item.depth), 'itemDepth', item.depth, 0.2, 12, 0.1)}`;
    const ib = (ic, help, act) => `<button class="btn secondary" data-act="${act}" title="${esc(help)}">${icon(ic, 14)}</button>`;
    return `<div class="glass il-insp">
      <div class="il-insp-head">${D.symbolIcon(item.kind, kindSize(item.kind), 34, 26)}<b>${esc(t('stage.kind.' + item.kind))}</b></div>
      ${fld(t(item.kind === 'text' ? 'stage.text' : 'stage.label'), 'label')}
      ${item.kind !== 'text' ? fld(t('stage.info'), 'info') : ''}
      <div class="il-col"><label id="il-rot-label">${esc(t('stage.rotation', item.rotation))}</label>
        <div class="il-rot"><input id="il-it-${id}-rotation" class="il-slider" type="range" min="0" max="345" step="15" value="${item.rotation}" data-input="rotation" data-id="${id}">
        <button class="il-plain" data-act="rotate90" title="+90°">${icon('rotate.right', 15)}</button></div></div>
      <div class="il-insp-steps">${sizeSteppers}</div>
      <div class="il-insp-tools">${ib('plus.square.on.square', t('action.duplicate'), 'itemDuplicate')}${ib('square.3.layers.3d.top.filled', t('stage.front'), 'itemFront')}${ib('square.3.layers.3d.bottom.filled', t('stage.back'), 'itemBack')}
        <span class="spacer"></span>${ib('trash', t('action.delete'), 'itemDelete')}</div></div>`;
  }

  /** The plan with the item being dragged shown at its live position (not yet snapped or saved). */
  function displayedPlan(W, H) {
    const plan = L.doc.stage;
    if (!L.drag || !L.drag.moved) return plan;
    const g = D.geometry(plan, W, H);
    return { ...plan, items: plan.items.map((i) => (i.id === L.drag.id ? { ...i, x: i.x + L.drag.dx / g.scale, y: i.y - L.drag.dy / g.scale } : i)) };
  }

  function drawCanvas() {
    const box = document.getElementById('il-canvas');
    if (!box) return;
    const W = box.clientWidth, H = box.clientHeight;
    if (!W || !H) return;
    box.innerHTML = D.drawPlan(displayedPlan(W, H), D.INK.editor, W, H, { audience: t('stage.audience'), selected: L.item, hits: true });
  }

  // MARK: the screen

  let rendered = false;
  function render() {
    rendered = false;
    if (!dirty && lastLang === S.lang && document.querySelector('#pane-inputList .il')) return null;
    rendered = true;
    // Inner scroll positions survive the redraw.
    L.scroll = {};
    for (const el of document.querySelectorAll('#pane-inputList [data-scroll]')) L.scroll[el.dataset.scroll] = [el.scrollLeft, el.scrollTop];
    dirty = false;
    lastLang = S.lang;
    const d = L.doc;
    return `<div class="il">
      ${header()}
      ${errorBanner()}
      ${showInfo()}
      ${UI.panel(t('il.channels'), channelToolbar() + channelTable() + `<div id="il-issues-slot">${issuesHTML()}</div>`, { marking: t('il.count', d.channels.length) })}
      <div class="il-pair">
        ${UI.panel(t('il.mixes'), mixTable(), { marking: t('il.count', d.mixes.length), tint: 'var(--data-secondary)', cls: 'il-mixpanel' })}
        ${UI.panel(t('il.summary'), `<div id="il-summary" class="il-summary">${summaryHTML()}</div>`, { tint: 'var(--signal-yellow)', cls: 'il-sumpanel' })}
      </div>
      ${UI.panel(t('il.stage'), stageEditor(), { tint: 'var(--data-blue)' })}
    </div>${menuHTML()}`;
  }

  function after(pane) {
    if (!pane.__il) { pane.__il = true; wire(pane); }
    if (!rendered) return;
    rendered = false;
    for (const el of pane.querySelectorAll('[data-scroll]')) {
      const s = L.scroll && L.scroll[el.dataset.scroll];
      if (s) { el.scrollLeft = s[0]; el.scrollTop = s[1]; }
    }
    for (const ta of pane.querySelectorAll('.il-notes')) autosize(ta);
    const canvas = pane.querySelector('#il-canvas');
    if (canvas && window.ResizeObserver) new ResizeObserver(() => drawCanvas()).observe(canvas);
    drawCanvas();
  }

  /** A new selection (rows, focus, stage item) redraws only what depends on it, never a field being used. */
  function selectionChanged() {
    const pane = document.getElementById('pane-inputList');
    if (!pane) return;
    for (const row of pane.querySelectorAll('[data-row]')) {
      row.classList.toggle('on', (row.dataset.row === 'channels' ? L.selCh : L.selMix).has(row.dataset.id));
    }
    for (const r of pane.querySelectorAll('[data-rows]')) r.classList.toggle('focused', L.focus === r.dataset.rows);
    const swap = (id, html) => { const el = document.getElementById(id); if (el) el.outerHTML = html; };
    swap('il-ch-toolbar', channelToolbar());
    swap('il-mix-toolbar', mixToolbar());
    const insp = document.getElementById('il-inspector');
    if (insp) insp.innerHTML = inspector();
    drawCanvas();
  }

  /** Parts that follow typing without a redraw of the fields being typed in. */
  function refreshDerived() {
    const sum = document.getElementById('il-summary');
    if (sum) sum.innerHTML = summaryHTML();
    const iss = document.getElementById('il-issues-slot');
    if (iss) iss.innerHTML = issuesHTML();
    const rot = document.getElementById('il-rot-label');
    const item = L.item && L.doc.stage.items.find((i) => i.id === L.item);
    if (rot && item) rot.textContent = t('stage.rotation', item.rotation);
    const file = document.querySelector('#pane-inputList .il-file');
    if (file) file.textContent = L.file || t('il.unsaved');
    drawCanvas();
  }

  function autosize(ta) {
    ta.style.height = 'auto';
    const line = 17;
    ta.style.height = Math.min(Math.max(ta.scrollHeight, 22), 22 + line * 4) + 'px';
  }

  // MARK: selection, dragging and keys

  /** EditableRows.select: click selects one row, Ctrl-click toggles, Shift-click selects a range. */
  function selectRow(kind, id, e) {
    const sel = kind === 'channels' ? L.selCh : L.selMix;
    const list = kind === 'channels' ? L.doc.channels : L.doc.mixes;
    const anchorKey = kind === 'channels' ? 'anchorCh' : 'anchorMix';
    if (e.ctrlKey || e.metaKey) {
      if (sel.has(id)) sel.delete(id); else sel.add(id);
      L[anchorKey] = id;
    } else if (e.shiftKey && L[anchorKey]) {
      const i = list.findIndex((r) => r.id === L[anchorKey]), j = list.findIndex((r) => r.id === id);
      if (i >= 0 && j >= 0) {
        sel.clear();
        for (const r of list.slice(Math.min(i, j), Math.max(i, j) + 1)) sel.add(r.id);
      }
    } else {
      sel.clear();
      sel.add(id);
      L[anchorKey] = id;
    }
  }

  function wire(pane) {
    pane.addEventListener('click', (e) => {
      const row = e.target.closest('[data-row]');
      if (row) {
        selectRow(row.dataset.row, row.dataset.id, e);
        // Clicking the row itself (not a field in it) gives the rows the keyboard, so Delete works.
        if (!e.target.closest('input, select, textarea, button')) {
          L.focus = row.dataset.row;
          if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
        }
        selectionChanged();
      } else if (e.target.closest('[data-rows]') && !e.target.closest('input, select, textarea, button')) {
        L.focus = e.target.closest('[data-rows]').dataset.rows;
        selectionChanged();
      }
    });
    pane.addEventListener('focusin', (e) => {
      if (e.target.matches('input, select, textarea') && L.focus) { L.focus = null; }
    });
    // Stage canvas: tap selects, drag moves (one undoable move on drop), tap on the stage clears the selection.
    pane.addEventListener('pointerdown', (e) => {
      const canvas = e.target.closest('#il-canvas');
      if (!canvas || e.button !== 0) return;
      L.focus = 'stage';
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
      canvas.focus({ preventScroll: true });
      const hit = e.target.closest('.il-hit');
      if (!hit) { if (L.item) { L.item = null; selectionChanged(); } return; }
      L.drag = { id: hit.dataset.item, x0: e.clientX, y0: e.clientY, dx: 0, dy: 0, moved: false, W: canvas.clientWidth, H: canvas.clientHeight };
      canvas.setPointerCapture(e.pointerId);
      if (L.item !== L.drag.id) { L.item = L.drag.id; selectionChanged(); }
      e.preventDefault();
    });
    pane.addEventListener('pointermove', (e) => {
      const g = L.drag;
      if (!g) return;
      g.dx = e.clientX - g.x0;
      g.dy = e.clientY - g.y0;
      if (!g.moved && Math.hypot(g.dx, g.dy) >= 2) g.moved = true;
      if (g.moved) drawCanvas();
    });
    const drop = () => {
      const g = L.drag;
      if (!g) return;
      L.drag = null;
      if (!g.moved) return;
      const plan = L.doc.stage;
      const item = plan.items.find((i) => i.id === g.id);
      if (!item) { drawCanvas(); return; }
      const geo = D.geometry(plan, g.W, g.H);
      const c = geo.point(item.x, item.y);
      const [x, y] = geo.stage(c[0] + g.dx, c[1] + g.dy);
      edit('stageMove', { id: g.id, x, y }, t('stage.move'));
    };
    pane.addEventListener('pointerup', drop);
    pane.addEventListener('pointercancel', drop);
    pane.addEventListener('input', (e) => { if (e.target.classList.contains('il-notes')) autosize(e.target); });
  }

  // Menus close on any click outside them.
  document.addEventListener('mousedown', (e) => {
    if (!L.menu && !L.popover) return;
    if (e.target.closest('.il-menu, .il-popover, [data-act="exportMenu"], [data-act="templateMenu"], [data-act="micMenu"], [data-act="stageboxOpen"]')) return;
    closeMenus();
  }, true);

  // Window shortcuts of the Mac menu bar while Ptch is open (they work while typing, as menu shortcuts do).
  document.addEventListener('keydown', (e) => {
    if (S.section !== 'inputList' || !(e.ctrlKey || e.metaKey) || e.altKey) return;
    const k = e.key.toLowerCase();
    const hit = (fn) => { e.preventDefault(); e.stopPropagation(); fn(); };
    if (k === 'o' && !e.shiftKey) hit(open);
    else if (k === 's') hit(() => save(e.shiftKey));
    else if (k === 'e' && !e.shiftKey) hit(() => exportAs('pdf'));
    else if (k === 'n' && e.shiftKey) hit(() => actions.addChannel());
  }, true);

  function keys(e) {
    const mod = e.ctrlKey || e.metaKey;
    if (e.key === 'Escape') { closeMenus(); return; }
    if (mod && !e.altKey && (e.key.toLowerCase() === 'z' || e.key.toLowerCase() === 'y')) {
      e.preventDefault();
      send({ cmd: e.key.toLowerCase() === 'y' || e.shiftKey ? 'il.redo' : 'il.undo' });
      return;
    }
    if (e.key === 'Delete' || e.key === 'Backspace') {
      if (L.focus === 'channels' && L.selCh.size) { e.preventDefault(); actions.deleteChannels(); }
      else if (L.focus === 'mixes' && L.selMix.size) { e.preventDefault(); actions.deleteMixes(); }
      else if (L.focus === 'stage' && L.item) { e.preventDefault(); actions.itemDelete(); }
      return;
    }
    if (L.focus === 'stage' && L.item && ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(e.key)) {
      e.preventDefault();
      const plan = L.doc.stage;
      const item = plan.items.find((i) => i.id === L.item);
      if (!item) return;
      const step = plan.grid > 0 ? plan.grid : 0.1;
      let { x, y } = item;
      if (e.key === 'ArrowLeft') x -= step;
      if (e.key === 'ArrowRight') x += step;
      if (e.key === 'ArrowUp') y += step;
      if (e.key === 'ArrowDown') y -= step;
      edit('stageMove', { id: item.id, x, y }, t('stage.move'));
    }
  }


  // MARK: actions

  const ids = (set) => Array.from(set);
  const actions = {
    // Sidebar and header
    newDocument, open, saveDoc: () => save(false), saveAs: () => save(true),
    exportKind: (kind) => exportAs(kind),
    exportMenu(_a, el) {
      if (L.menu && L.menu.id === 'export') { closeMenus(); return; }
      L.popover = false;
      openMenu('export', rectOf(el), [
        { label: t('il.export.pdf'), act: 'exportKind', arg: 'pdf' }, '-',
        { label: t('il.export.pngList'), act: 'exportKind', arg: 'pngList' },
        { label: t('il.export.pngStage'), act: 'exportKind', arg: 'pngStage' }, '-',
        { label: t('il.export.csvChannels'), act: 'exportKind', arg: 'csvChannels' },
        { label: t('il.export.csvMixes'), act: 'exportKind', arg: 'csvMixes' },
      ]);
      L.menu.align = 'right';
    },
    dismissError() { L.error = null; invalidate(); },
    // Show info
    dateToggle(on) {
      const now = new Date();
      now.setMilliseconds(0);
      setField('doc', null, 'date', on ? (L.doc.date || now.toISOString().replace('.000Z', 'Z')) : '', false);
    },
    dateSet(v) {
      const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(v || '');
      if (!m) { invalidate(); return; }
      const d = L.doc.date ? new Date(L.doc.date) : new Date();
      d.setFullYear(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
      d.setMilliseconds(0);
      setField('doc', null, 'date', d.toISOString().replace('.000Z', 'Z'), false);
    },
    datePick(_a, el) {
      const input = el.parentElement.querySelector('.il-datepick');
      try { if (input && input.showPicker) input.showPicker(); } catch (_) { /* not shown without a user gesture */ }
    },
    dateStep(by) {
      if (!L.doc.date) return;
      const d = new Date(L.doc.date);
      d.setDate(d.getDate() + Number(by));
      d.setMilliseconds(0);
      setField('doc', null, 'date', d.toISOString().replace('.000Z', 'Z'), false);
    },
    // Channels
    addChannel() { edit('addChannel', { after: anchor() }, t('il.addChannel')); },
    templateMenu(_a, el) {
      if (L.menu && L.menu.id === 'template') { closeMenus(); return; }
      L.popover = false;
      openMenu('template', rectOf(el), L.catalog.templates.map((tp) => ({ label: t('template.' + tp.id) + '  ·  ' + tp.count, act: 'template', arg: tp.id })));
    },
    template(id) { L.menu = null; edit('template', { template: id, after: anchor() }, t('il.template')); },
    stereo() { const id = ids(L.selCh)[0]; if (id) edit('stereo', { id }, t('il.stereo')); },
    duplicate() { const s = ids(L.selCh); edit('duplicate', { ids: s }, t('action.duplicate')); profile('ptch.duplicated', s.length); },
    move(by) { edit('move', { ids: ids(L.selCh), by: Number(by) }, t(Number(by) < 0 ? 'il.moveUp' : 'il.moveDown')); },
    deleteChannels() {
      const s = ids(L.selCh);
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
      L.selCh.clear();
      edit('delete', { ids: s }, t('action.delete'));
    },
    renumber() { edit('renumber', {}, t('il.renumber')); },
    stageboxOpen() { L.menu = null; L.popover = !L.popover; invalidate(); },
    sbStart(v) { L.sb.start = Number(v); invalidate(); },
    sbOnly(on) { L.sb.onlyEmpty = !!on; },
    stageboxApply() {
      edit('stagebox', { prefix: L.sb.prefix, start: L.sb.start, onlyEmpty: L.sb.onlyEmpty }, t('il.stagebox.fill'));
      profile('ptch.stagebox');
      L.popover = false;
      invalidate();
    },
    micMenu(id, el) {
      if (L.menu && L.menu.id === 'mic') { closeMenus(); return; }
      const ch = L.doc.channels.find((c) => c.id === id);
      L.micRequest = { id, rect: rectOf(el) };
      send({ cmd: 'il.mics', id, text: ch ? ch.mic : '' });
    },
    pickMic(arg) {
      const [id, model] = String(arg).split('\n');
      L.menu = null;
      edit('pickMic', { id, model });
    },
    // Fields
    field(value, el) {
      const { target, id, key } = el.dataset;
      setField(target, id, key, value, false);
    },
    number(value, el) {
      const { target, id, key } = el.dataset;
      const v = String(value).trim().replace(/\s/g, '');
      if (!/^[-+]?\d+$/.test(v)) { invalidate(); return; }
      setField(target, id, key, Number(v), false);
    },
    // Mixes
    addMix() { edit('addMix', {}, t('il.addMix')); },
    deleteMixes() {
      const s = ids(L.selMix);
      if (!s.length) return;
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
      L.selMix.clear();
      edit('deleteMixes', { ids: s }, t('action.delete'));
    },
    renumberMixes() { edit('renumberMixes', {}, t('il.renumber')); },
    // Stage plan
    stageAdd(kind) { edit('stageAdd', { kind, label: kind === 'text' ? t('stage.text.default') : '' }, t('stage.add.help')); },
    rotate90() { if (L.item) edit('stageRotate', { id: L.item, by: 90 }); },
    itemFont(v) { if (L.item) setField('item', L.item, 'fontSize', Number(v), false); },
    itemWidth(v) { if (L.item) setField('item', L.item, 'width', Number(v), false); },
    itemDepth(v) { if (L.item) setField('item', L.item, 'depth', Number(v), false); },
    itemDuplicate() { if (L.item) edit('stageDuplicate', { id: L.item }); },
    itemFront() { if (L.item) edit('stageFront', { id: L.item }); },
    itemBack() { if (L.item) edit('stageBack', { id: L.item }); },
    itemDelete() {
      if (!L.item) return;
      const id = L.item;
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
      L.item = null;
      edit('stageRemove', { id }, t('action.delete'));
    },
    stageWidth(v) { edit('stageWidth', { value: Number(v) }); },
    stageDepth(v) { edit('stageDepth', { value: Number(v) }); },
    stageSnap(on) { edit('stageSnap', { value: !!on }); },
  };

  const inputs = {
    docField(value, el) { setField('doc', null, el.dataset.key, value, true); },
    field(value, el) { setField(el.dataset.target, el.dataset.id, el.dataset.key, value, true); },
    sbPrefix(value) { L.sb.prefix = value; },
    rotation(value, el) {
      const v = Math.round(Number(value) / 15) * 15;
      setField('item', el.dataset.id, 'rotation', v, true);
      refreshDerived();
    },
  };

  /** AppSidebar.inputListItems: document actions and exports. */
  function sidebar() {
    return `<div class="items">
      ${UI.utilityRow('doc', t('il.new'), 'newDocument')}
      ${UI.utilityRow('folder', t('il.open'), 'open')}
      ${UI.utilityRow('square.and.arrow.down', t('il.save'), 'saveDoc')}
      ${UI.utilityRow('square.and.arrow.down.on.square', t('il.saveAs'), 'saveAs')}
      <div class="rule"></div>
      ${UI.utilityRow('doc.richtext', t('il.export.pdf'), 'exportKind', 'pdf')}
      ${UI.utilityRow('photo', t('il.export.pngList'), 'exportKind', 'pngList')}
      ${UI.utilityRow('photo.on.rectangle', t('il.export.pngStage'), 'exportKind', 'pngStage')}
      ${UI.utilityRow('tablecells', t('il.export.csvChannels'), 'exportKind', 'csvChannels')}
    </div><div class="spacer"></div>`;
  }

  SSMT.section({ id: 'inputList', render, after, sidebar, actions, inputs, keys, onEvent });
  /** For the parity check and the integrator: the sheets of the open document. */
  SSMT.inputList = {
    state: L,
    sheetsHTML: () => D.sheets(L.doc, L.summary, L.pages),
    printDocument: D.printDocument,
    /** One sheet as a page: 'channels' (the first channel sheet) or 'stage', numbered as in the full print. */
    sheet(kind) {
      const all = D.sheets(L.doc, L.summary, L.pages);
      return D.printDocument([kind === 'stage' ? all[all.length - 1] : all[0]]);
    },
  };
})();
