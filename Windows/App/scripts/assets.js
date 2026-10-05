'use strict';
// Builds the interface assets that come from npm packages: the icons (SF Symbols names used by the Mac app → the
// closest Lucide icon, ISC licence) and the Inter font (SIL OFL; SF Pro may not be shipped on Windows).
//   node scripts/assets.js          write src/renderer/icons.gen.js and src/renderer/fonts/
//   node scripts/assets.js --check  fail if a mapped icon is missing
const fs = require('fs');
const path = require('path');

// SF Symbol → Lucide. Add a line when a Mac screen uses a new symbol.
const MAP = {
  'antenna.radiowaves.left.and.right': 'radio-tower', 'arrow.clockwise': 'rotate-cw', 'arrow.counterclockwise': 'rotate-ccw',
  'arrow.down.to.line.compact': 'arrow-down-to-line', 'arrow.right': 'arrow-right', 'arrow.triangle.2.circlepath': 'refresh-cw',
  'arrow.turn.right.down': 'corner-right-down', 'arrow.turn.down.right': 'corner-down-right',
  'arrow.up.left.and.arrow.down.right': 'maximize-2', 'arrow.up.right.square': 'square-arrow-out-up-right',
  'arrowtriangle.right.fill': 'play', 'bolt': 'zap', 'bolt.horizontal': 'cable', 'book': 'book-open',
  'chart.line.downtrend.xyaxis': 'trending-down', 'chart.line.uptrend.xyaxis': 'trending-up', 'checklist': 'list-checks',
  'checkmark': 'check', 'checkmark.circle': 'circle-check', 'checkmark.circle.fill': 'circle-check-big',
  'checkmark.shield': 'shield-check', 'chevron.down': 'chevron-down', 'chevron.up': 'chevron-up', 'chevron.left': 'chevron-left',
  'chevron.right': 'chevron-right', 'clock': 'clock', 'cursorarrow.click': 'mouse-pointer-click', 'dial.medium': 'gauge',
  'doc': 'file', 'doc.on.doc': 'copy', 'doc.richtext': 'file-text', 'doc.text': 'file-text',
  'dot.radiowaves.left.and.right': 'radio', 'ellipsis': 'ellipsis', 'exclamationmark': 'circle-alert',
  'exclamationmark.octagon.fill': 'octagon-alert', 'exclamationmark.triangle.fill': 'triangle-alert', 'folder': 'folder',
  'forward.end': 'skip-forward', 'function': 'sigma', 'gearshape': 'settings', 'hand.point.up': 'pointer',
  'hand.point.up.left': 'pointer', 'hifispeaker.2': 'speaker', 'hifispeaker.fill': 'speaker', 'hifispeaker.slash': 'volume-x',
  'hourglass': 'hourglass', 'info.circle': 'info', 'keyboard': 'keyboard', 'lightbulb': 'lightbulb', 'lightbulb.2': 'lightbulb',
  'list.bullet': 'list', 'list.bullet.rectangle': 'clipboard-list', 'list.number': 'list-ordered', 'lock.fill': 'lock',
  'lock.shield': 'shield-ellipsis', 'magnifyingglass': 'search', 'memorychip': 'cpu', 'mic.fill': 'mic', 'minus.circle': 'circle-minus',
  'minus.magnifyingglass': 'zoom-out', 'music.note': 'music', 'music.quarternote.3': 'music-4', 'noise.periodic': 'audio-waveform',
  'noise.pink': 'audio-lines', 'noise.white': 'activity', 'note.text': 'sticky-note', 'paperplane': 'send', 'pencil': 'pencil',
  'person.3.fill': 'users', 'photo': 'image', 'photo.on.rectangle': 'images', 'play.fill': 'play',
  'play.rectangle.on.rectangle': 'monitor-play', 'plus': 'plus', 'plus.magnifyingglass': 'zoom-in', 'plusminus.circle': 'diff',
  'point.3.connected.trianglepath.dotted': 'waypoints', 'questionmark.folder': 'folder-search', 'record.circle': 'circle-dot',
  'rectangle.connected.to.line.below': 'git-commit-vertical', 'rectangle.on.rectangle': 'layers-2', 'repeat': 'repeat',
  'repeat.1': 'repeat-1', 'rotate.right': 'rotate-cw-square', 'scissors': 'scissors', 'scope': 'crosshair',
  'shield.lefthalf.filled': 'shield-half', 'shield.slash': 'shield-off', 'slider.horizontal.3': 'sliders-horizontal',
  'slider.vertical.3': 'sliders-vertical', 'sparkles': 'sparkles', 'speaker.wave.2': 'volume-2',
  'square.and.arrow.down': 'save', 'square.and.arrow.down.on.square': 'save-all', 'square.and.arrow.up': 'share',
  'square.grid.3x3': 'grid-3x3', 'square.grid.3x3.square': 'grid-3x3', 'square.stack.3d.up': 'layers', 'star': 'star',
  'stop.fill': 'square', 'tablecells': 'table', 'timer': 'timer', 'trash': 'trash-2', 'tray.and.arrow.down': 'inbox',
  'trophy': 'trophy', 'tuningfork': 'audio-lines', 'wand.and.stars': 'wand-sparkles', 'waveform': 'audio-waveform',
  'waveform.badge.plus': 'file-audio', 'waveform.path.ecg': 'activity', 'waveform.path.ecg.rectangle': 'square-activity',
  'wifi': 'wifi', 'xmark': 'x', 'xmark.circle.fill': 'circle-x', 'xmark.octagon.fill': 'octagon-x', 'xmark.shield': 'shield-x',
  'desktopcomputer': 'monitor', 'speaker.wave.3.fill': 'volume-2', 'waveform.path.badge.minus': 'audio-waveform',
  'person.wave.2.fill': 'speech', 'dial.low': 'gauge', 'water.waves': 'waves',
  'folder.badge.plus': 'folder-plus', 'person.crop.circle': 'circle-user', 'questionmark.circle': 'circle-help',
};

const root = path.join(__dirname, '..');
const lucide = path.join(root, 'node_modules', 'lucide-static', 'icons');
const missing = Object.entries(MAP).filter(([, l]) => !fs.existsSync(path.join(lucide, l + '.svg')));
if (missing.length) { console.error('Missing Lucide icons:', missing.map(([s, l]) => `${s} → ${l}`).join(', ')); process.exit(1); }
if (process.argv.includes('--check')) { console.log(`icons OK: ${Object.keys(MAP).length}`); process.exit(0); }

const icons = {};
for (const [sf, l] of Object.entries(MAP)) {
  icons[sf] = fs.readFileSync(path.join(lucide, l + '.svg'), 'utf8')
    .replace(/<!--[\s\S]*?-->/g, '').replace(/\s*class="[^"]*"/, '').replace(/\s+/g, ' ').trim();
}
fs.writeFileSync(path.join(root, 'src', 'renderer', 'icons.gen.js'),
  "'use strict';\n// Generated by scripts/assets.js (Lucide icons, ISC licence). Do not edit.\nwindow.ICONS = " +
  JSON.stringify(icons, null, 0) + ';\n');

const fonts = path.join(root, 'src', 'renderer', 'fonts');
fs.mkdirSync(fonts, { recursive: true });
let css = '/* Inter (SIL Open Font License), generated by scripts/assets.js */\n';
for (const w of [300, 400, 500, 600, 700]) {
  for (const sub of ['latin', 'cyrillic']) {
    const f = `inter-${sub}-${w}-normal.woff2`;
    fs.copyFileSync(path.join(root, 'node_modules', '@fontsource', 'inter', 'files', f), path.join(fonts, f));
    const range = sub === 'latin'
      ? 'U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD'
      : 'U+0301, U+0400-045F, U+0490-0491, U+04B0-04B1, U+2116';
    css += `@font-face { font-family: 'Inter'; font-style: normal; font-weight: ${w}; font-display: block; src: url('${f}') format('woff2'); unicode-range: ${range}; }\n`;
  }
}
fs.writeFileSync(path.join(fonts, 'inter.css'), css);
console.log(`assets written: ${Object.keys(icons).length} icons, Inter ${fs.readdirSync(fonts).length - 1} files`);
