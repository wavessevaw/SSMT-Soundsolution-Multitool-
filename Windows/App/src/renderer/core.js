'use strict';
/* global MAC_STRINGS, ICONS */
// The interface's shared core: settings storage, the Mac strings with printf-style formatting, the engine bridge,
// the section registry and the redraw loop. Sections (sections/*.js) register themselves with `SSMT.section`.

(function () {
  const store = {
    get(k, d) { try { const v = localStorage.getItem('ssmt.' + k); return v === null ? d : v; } catch (_) { return d; } },
    set(k, v) { try { localStorage.setItem('ssmt.' + k, v); } catch (_) { /* private mode */ } },
    json(k, d) { try { const v = localStorage.getItem('ssmt.' + k); return v === null ? d : JSON.parse(v); } catch (_) { return d; } },
    setJSON(k, v) { try { localStorage.setItem('ssmt.' + k, JSON.stringify(v)); } catch (_) { /* private mode */ } },
  };

  /** printf as the Mac strings use it: %@ %d %ld %lld %u %f %.Nf %%, with positions (%1$@). */
  function format(fmt, ...args) {
    let next = 0;
    return String(fmt).replace(/%(?:(\d+)\$)?([-+ 0#]*)(\d+)?(?:\.(\d+))?(l{0,2}|h)?([@dfsuixX%])/g, (m, pos, flags, width, prec, _len, conv) => {
      if (conv === '%') return '%';
      const v = args[pos ? Number(pos) - 1 : next++];
      let s;
      switch (conv) {
        case 'd': case 'i': case 'u': s = String(Math.trunc(Number(v) || 0)); break;
        case 'x': s = (Number(v) >>> 0).toString(16); break;
        case 'X': s = (Number(v) >>> 0).toString(16).toUpperCase(); break;
        case 'f': s = Number(v).toFixed(prec === undefined ? 6 : Number(prec)); break;
        default: s = v == null ? '' : String(v);
      }
      if (flags.includes('+') && (conv === 'd' || conv === 'f') && Number(v) >= 0) s = '+' + s;
      if (width && s.length < Number(width)) s = (flags.includes('-') ? s.padEnd : s.padStart).call(s, Number(width), flags.includes('0') ? '0' : ' ');
      return s;
    });
  }

  const S = { lang: store.get('lang', 'ru'), section: store.get('section', 'setup') };

  /** A string of the Mac app (same key), formatted. Unknown keys show the key, as on the Mac. */
  function t(key, ...args) {
    const table = (MAC_STRINGS[S.lang] || MAC_STRINGS.ru);
    const s = table[key] !== undefined ? table[key] : (MAC_STRINGS.en[key] !== undefined ? MAC_STRINGS.en[key] : key);
    return args.length ? format(s, ...args) : s;
  }

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /** An SF Symbol of the Mac app, drawn as its Lucide counterpart (scripts/assets.js). */
  function icon(name, size = 15, cls = '') {
    const svg = ICONS[name];
    if (!svg) return `<span class="icon missing ${cls}" style="width:${size}px;height:${size}px" title="${esc(name)}"></span>`;
    return svg.replace('<svg', `<svg class="icon ${cls}" width="${size}" height="${size}" aria-hidden="true"`);
  }

  // MARK: engine

  const api = window.ssmt;
  const listeners = [];
  function send(cmd) { if (api) api.send(cmd); }
  function onEngine(fn) { listeners.push(fn); }
  if (api) api.onEvent((ev) => { for (const fn of listeners) fn(ev); });

  // MARK: sections and redraw

  const sections = {};
  /** Registers a function of the program: { id, render(), sidebar?(), topBar?, actions, inputs, changes, after?(root) }. */
  function section(def) { sections[def.id] = def; }

  let scheduled = false;
  function render() {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => { scheduled = false; if (SSMT.draw) SSMT.draw(); });
  }

  window.SSMT = { S, store, format, t, esc, icon, send, onEngine, section, sections, render, api };
})();
