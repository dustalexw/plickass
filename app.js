// plickass — native Cocoa window (JavaScript for Automation).
// Run by the app's launcher: osascript -l JavaScript app.js
// Follows the dustalexw app layout (Banana Split Redux, Data Curator, Cover Flow): an integrated brand bar
// with an accent rule, uppercase section kickers on rounded cards, one solid accent button, a mint
// guidance line, a status bar and a branded About window.
// Palette comes from the icon and README header (scripts/make_brand.py): warm charcoal, Plexamp amber, cream, mint.
ObjC.import('Cocoa');

const env = $.NSProcessInfo.processInfo.environment;
function envVar(k) { const v = env.objectForKey(k); return v.isNil() ? '' : v.js; }
const RES = envVar('PDC_RES');
const PY = envVar('PDC_PYTHON') || '/usr/bin/python3';
const VERSION = envVar('PDC_VERSION') || '1.3.0';
const NAME = 'plickass';
const REPO = 'https://github.com/dustalexw/plickass';
const HOME = $.NSHomeDirectory().js;
const fm = $.NSFileManager.defaultManager;
try { $.NSProcessInfo.processInfo.processName = NAME; } catch (e) {}

// ---- palette -------------------------------------------------------------
function rgb(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, a === undefined ? 1 : a);
}
const C = {
  ink: rgb('#1a1511'), bar: rgb('#100c09'), card: rgb('#221b15'), field: rgb('#120e0b'),
  line: rgb('#3a3027'), button: rgb('#2e261f'), amber: rgb('#f5b03c'), amberDim: rgb('#5a4630'),
  coral: rgb('#ff7e67'), mint: rgb('#7ed6b8'), cream: rgb('#faf4e4'), muted: rgb('#b3a896'),
  dim: rgb('#7d7366'), amberSoft: rgb('#f5b03c', 0.14),
};
function font(size, weight) { return $.NSFont.systemFontOfSizeWeight(size, weight || 0); }
function rounded(size, weight) {
  const f = font(size, weight);
  try {
    const d = f.fontDescriptor.fontDescriptorWithDesign($.NSFontDescriptorSystemDesignRounded);
    if (!d.isNil()) return $.NSFont.fontWithDescriptorSize(d, size);
  } catch (e) {}
  return f;
}
let MONO;
try { MONO = $.NSFont.monospacedSystemFontOfSizeWeight(11.5, 0); } catch (e) { MONO = $.NSFont.userFixedPitchFontOfSize(11.5); }
// JXA can't call NSAttributedString's init methods on current macOS, so styled text is built
// from an empty mutable string, then the text and attributes are added.
function astr(text, color, f, kern) {
  const m = $.NSMutableAttributedString.alloc.init;
  m.mutableString.appendString(text);
  const r = $.NSMakeRange(0, m.length);
  m.addAttributeValueRange($.NSForegroundColorAttributeName, color, r);
  m.addAttributeValueRange($.NSFontAttributeName, f, r);
  if (kern) m.addAttributeValueRange($.NSKernAttributeName, $(kern), r);
  return m;
}
function centred(m) {
  const p = $.NSMutableParagraphStyle.alloc.init;
  p.alignment = 1;
  m.addAttributeValueRange($.NSParagraphStyleAttributeName, p, $.NSMakeRange(0, m.length));
  return m;
}
function brandName(size) { // "plick" in cream, "ass" in amber, as in the README header
  const f = rounded(size, 0.62);
  const t = astr('plick', C.cream, f);
  t.appendAttributedString(astr('ass', C.amber, f));
  return t;
}

// ---- helpers ---------------------------------------------------------------
function isDir(p) { const d = Ref(); return !!p && fm.fileExistsAtPathIsDirectory(p, d) && d[0]; }
const DEFAULT_SRC = HOME + '/Library/Application Support/Plexamp/Offline';
const DEFAULT_DST = HOME + '/Music/Plexamp Copies';
const LOG = $.NSTemporaryDirectory().js + 'plickass-' + $.NSProcessInfo.processInfo.processIdentifier + '.log';
const icon = $.NSImage.alloc.initWithContentsOfFile(RES + '/AppIcon.icns');

function alert(title, msg, buttons) {
  const a = $.NSAlert.alloc.init;
  a.messageText = title;
  a.informativeText = msg;
  if (!icon.isNil()) a.icon = icon;
  (buttons || ['OK']).forEach(b => a.addButtonWithTitle(b));
  return a.runModal; // 1000 = first button
}

function pickFolder(title, start) {
  const p = $.NSOpenPanel.openPanel;
  p.canChooseFiles = false;
  p.canChooseDirectories = true;
  p.canCreateDirectories = true;
  p.allowsMultipleSelection = false;
  p.showsHiddenFiles = true; // the Plexamp folder lives under ~/Library
  p.message = title;
  if (start && isDir(start)) p.directoryURL = $.NSURL.fileURLWithPath(start);
  return p.runModal == 1 ? p.URL.path.js : null;
}

function openURL(u) { $.NSWorkspace.sharedWorkspace.openURL($.NSURL.URLWithString(u)); }

// Reads Plexamp's index.json files (read-only) to say what's waiting to be copied.
function scanSource(p) {
  if (!isDir(p)) return null;
  const names = fm.contentsOfDirectoryAtPathError(p, null);
  if (names.isNil()) return null;
  let tracks = 0;
  const albums = {}, artists = {};
  ObjC.deepUnwrap(names).forEach(n => {
    const s = $.NSString.stringWithContentsOfFileEncodingError(p + '/' + n + '/index.json', $.NSUTF8StringEncoding, null);
    if (s.isNil()) return;
    try {
      (JSON.parse(s.js).items || []).forEach(it => {
        const artist = it.grandparentTitle || 'Unknown Artist';
        tracks++;
        artists[artist] = 1;
        albums[artist + '\u0000' + (it.parentTitle || 'Unknown Album')] = 1;
      });
    } catch (e) {}
  });
  return { tracks, albums: Object.keys(albums).length, artists: Object.keys(artists).length };
}
function plural(n, word) { return `${n.toLocaleString()} ${word}${n === 1 ? '' : 's'}`; }

// ---- state -----------------------------------------------------------------
let srcField, dstField, srcHint, copyBtn, finderBtn, textView, statusLabel, progLabel, progFill, progTrack, guide;
let task = null, consumed = 0, total = 0, copied = 0, skipped = 0, failed = 0, notes = 0, runDst = '';
let aboutWin = null;

function logLine(prefix, prefixColor, body, bodyColor) {
  const ts = textView.textStorage;
  if (prefix) ts.appendAttributedString(astr(prefix, prefixColor, font(11.5, 0.3)));
  ts.appendAttributedString(astr(body + '\n', bodyColor, MONO));
  textView.scrollRangeToVisible($.NSMakeRange(ts.length, 0));
}
function clearLog() { textView.textStorage.setAttributedString(astr('', C.muted, MONO)); }
function rel(p) {
  const base = runDst.replace(/\/+$/, '') + '/';
  return (p.indexOf(base) === 0 ? p.slice(base.length) : p).split('/').join('  ›  ');
}

function setProgress() {
  const done = copied + skipped + failed;
  const frac = total > 0 ? Math.min(1, done / total) : 0;
  const tf = progTrack.frame;
  progFill.frame = $.NSMakeRect(tf.origin.x, tf.origin.y, Math.max(frac > 0 ? 8 : 0, tf.size.width * frac), tf.size.height);
  progFill.hidden = frac === 0;
  progLabel.stringValue = $(total > 0 ? `${done.toLocaleString()} of ${plural(total, 'track')}` : '');
}

function setStatus(text, color) { statusLabel.stringValue = $(text); statusLabel.textColor = color || C.muted; }

let hintFor = null;
function updateSourceHint() {
  hintFor = srcField.stringValue.js.trim();
  const info = scanSource(hintFor);
  if (!info) {
    srcHint.stringValue = $('Choose Plexamp\'s "Offline" folder — usually ~/Library/Application Support/Plexamp/Offline.');
    srcHint.textColor = C.amber;
  } else if (info.tracks === 0) {
    srcHint.stringValue = $('No Plexamp downloads in this folder yet.');
    srcHint.textColor = C.amber;
  } else {
    srcHint.stringValue = $(`${plural(info.tracks, 'track')}  ·  ${plural(info.albums, 'album')}  ·  ${plural(info.artists, 'artist')} ready to copy`);
    srcHint.textColor = C.mint;
  }
}

function handle(line) {
  let m;
  if ((m = line.match(/^__TOTAL__ (\d+)/))) { total = +m[1]; return; }
  if ((m = line.match(/^Copying '(.*)' to '(.*)'$/))) { copied++; logLine('Copied        ', C.mint, rel(m[2]), C.cream); return; }
  if ((m = line.match(/^WARN: (.*) exists! Not copying\.\.\.$/))) { skipped++; logLine('Already there ', C.dim, rel(m[1]), C.muted); return; }
  if ((m = line.match(/^Failed to copy (.*?): (.*)$/))) { failed++; copied--; logLine('Failed        ', C.coral, rel(m[1]) + '  —  ' + m[2], C.coral); return; }
  if (/^(ERROR|WARN)/.test(line)) { notes++; logLine('Note          ', C.amber, line.replace(/^(ERROR|WARN): ?/, ''), C.amber); return; }
  if (/SyntaxWarning|^\s+""" /.test(line)) return; // harmless noise from newer Pythons
  if (line.trim()) logLine('', null, line, C.muted);
}

function readLog() {
  const s = $.NSString.stringWithContentsOfFileEncodingError(LOG, $.NSUTF8StringEncoding, null);
  return s.isNil() ? '' : s.js;
}

function start() {
  if (task) return;
  const src = srcField.stringValue.js.trim();
  const dst = dstField.stringValue.js.trim();
  if (!isDir(src)) { alert('Plexamp downloads folder not found', 'Click Browse… and choose Plexamp\'s "Offline" folder.\n\nIt is usually in ~/Library/Application Support/Plexamp/Offline.'); return; }
  if (!dst) { alert('Choose a destination', 'Click Browse… and choose where your music should be copied.'); return; }
  if (!isDir(dst)) {
    if (alert('Create this folder?', dst, ['Create Folder', 'Cancel']) != 1000) return;
    const err = Ref();
    if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dst, true, $(), err)) {
      alert('Couldn\'t create the folder', ObjC.unwrap(err[0].localizedDescription) || dst); return;
    }
  }
  $('').writeToFileAtomicallyEncodingError(LOG, true, $.NSUTF8StringEncoding, null);
  clearLog();
  consumed = total = copied = skipped = failed = notes = 0;
  runDst = dst;
  setProgress();
  task = $.NSTask.alloc.init;
  task.launchPath = '/bin/sh';
  task.arguments = $(['-c', 'exec "$1" -u "$2" "$3" "$4" > "$5" 2>&1', 'sh', PY, RES + '/copy_runner.py', src, dst, LOG]);
  task.launch;
  copyBtn.setEnabled(false);
  finderBtn.hidden = true;
  guide.stringValue = $('Copying… you can keep using your Mac. Your Plexamp downloads are only read, never changed.');
  setStatus('Copying…', C.amber);
}

function tick() {
  if (!task) {
    // Keep the "N tracks ready" hint in step with what's typed or pasted into the source field.
    if (srcField.currentEditor.isNil() && srcField.stringValue.js.trim() !== hintFor) updateSourceHint();
    return;
  }
  const s = readLog();
  const end = s.lastIndexOf('\n') + 1;
  if (end > consumed) {
    s.slice(consumed, end).split('\n').forEach(l => { if (l) handle(l); });
    consumed = end;
    setProgress();
  }
  if (task.running) return;
  if (s.length > consumed) { handle(s.slice(consumed)); consumed = s.length; setProgress(); }
  const code = task.terminationStatus;
  task = null;
  copyBtn.setEnabled(true);
  fm.removeItemAtPathError(LOG, null);
  const parts = [`${copied.toLocaleString()} copied`, `${skipped.toLocaleString()} already there`];
  if (failed) parts.push(`${failed.toLocaleString()} failed`);
  if (code !== 0) {
    setStatus('Stopped with an error — see the log above.', C.coral);
    guide.stringValue = $('Something went wrong. The log above says what; fix it, then click Copy Music again.');
  } else if (copied + skipped + failed === 0) {
    setStatus('No downloaded tracks were found in that folder.', C.amber);
    guide.stringValue = $('Download some music in Plexamp first, or choose a different "Offline" folder.');
  } else {
    setStatus('Done  ·  ' + parts.join('  ·  '), failed ? C.coral : C.mint);
    guide.stringValue = $('All done. Run it again any time — tracks already copied are skipped.');
    finderBtn.hidden = false;
  }
}

// ---- Objective-C classes ---------------------------------------------------
ObjC.registerSubclass({
  name: 'PDCFlippedView', superclass: 'NSView',
  methods: { 'isFlipped': { types: ['bool', []], implementation: function () { return true; } } },
});

ObjC.registerSubclass({
  name: 'PDCController', superclass: 'NSObject', protocols: ['NSApplicationDelegate'],
  methods: {
    'browseSrc:': { types: ['void', ['id']], implementation: function () {
      const d = pickFolder('Choose Plexamp\'s "Offline" downloads folder', srcField.stringValue.js || HOME);
      if (d) { srcField.stringValue = $(d); updateSourceHint(); }
    } },
    'browseDst:': { types: ['void', ['id']], implementation: function () {
      const d = pickFolder('Choose where to copy your music', dstField.stringValue.js || HOME);
      if (d) dstField.stringValue = $(d);
    } },
    'copyMusic:': { types: ['void', ['id']], implementation: function () { start(); } },
    'showInFinder:': { types: ['void', ['id']], implementation: function () {
      $.NSWorkspace.sharedWorkspace.openURL($.NSURL.fileURLWithPath(runDst));
    } },
    'showAbout:': { types: ['void', ['id']], implementation: function () { about(); } },
    'closeAbout:': { types: ['void', ['id']], implementation: function () { if (aboutWin) aboutWin.performClose(null); } },
    'openReleases:': { types: ['void', ['id']], implementation: function () { openURL(REPO + '/releases'); } },
    'openSource:': { types: ['void', ['id']], implementation: function () { openURL(REPO); } },
    'openIssues:': { types: ['void', ['id']], implementation: function () { openURL(REPO + '/issues'); } },
    'tick:': { types: ['void', ['id']], implementation: function () { tick(); } },
    'applicationShouldTerminateAfterLastWindowClosed:': { types: ['bool', ['id']], implementation: function () { return true; } },
    'applicationWillTerminate:': { types: ['void', ['id']], implementation: function () {
      if (task && task.running) task.terminate;
    } },
  },
});

// ---- app & menus -------------------------------------------------------------
const app = $.NSApplication.sharedApplication;
app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
app.appearance = $.NSAppearance.appearanceNamed('NSAppearanceNameDarkAqua');
const ctl = $.PDCController.alloc.init;
app.delegate = ctl;
if (!icon.isNil()) app.applicationIconImage = icon;

function menuItem(title, action, key, target) {
  const i = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(title, action, key || '');
  if (target) i.target = target;
  return i;
}
function submenu(bar, title, items) {
  const holder = menuItem(title, null); bar.addItem(holder);
  const m = $.NSMenu.alloc.initWithTitle(title);
  items.forEach(i => m.addItem(i || $.NSMenuItem.separatorItem));
  holder.submenu = m;
}
const mainMenu = $.NSMenu.alloc.init;
submenu(mainMenu, NAME, [
  menuItem(`About ${NAME}`, 'showAbout:', '', ctl), null,
  menuItem(`Hide ${NAME}`, 'hide:', 'h'), menuItem('Hide Others', 'hideOtherApplications:', ''),
  menuItem('Show All', 'unhideAllApplications:', ''), null,
  menuItem(`Quit ${NAME}`, 'terminate:', 'q'),
]);
submenu(mainMenu, 'Edit', [
  menuItem('Cut', 'cut:', 'x'), menuItem('Copy', 'copy:', 'c'),
  menuItem('Paste', 'paste:', 'v'), menuItem('Select All', 'selectAll:', 'a'),
]);
submenu(mainMenu, 'Window', [menuItem('Minimize', 'performMiniaturize:', 'm'), menuItem('Close', 'performClose:', 'w')]);
submenu(mainMenu, 'Help', [
  menuItem('Source on GitHub', 'openSource:', '', ctl), menuItem('Report an Issue', 'openIssues:', '', ctl),
]);
app.mainMenu = mainMenu;

// ---- view building -------------------------------------------------------------
// autoresizing (flipped view: "MAX_Y" is the bottom margin, "MIN_Y" the top)
const FLEX_W = 2, FLEX_H = 16, MIN_X = 1, MAX_X = 4, MIN_Y = 8, MAX_Y = 32;
const TOP = FLEX_W | MAX_Y;
let PARENT = null; // the view that add() places things in

function add(v, x, y, w, h, mask) { v.frame = $.NSMakeRect(x, y, w, h); v.autoresizingMask = mask; PARENT.addSubview(v); return v; }
function box(x, y, w, h, mask, fill, opts) {
  opts = opts || {};
  const b = $.NSBox.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
  b.boxType = 4; b.titlePosition = 0; b.fillColor = fill;
  b.borderWidth = opts.border ? 1 : 0;
  if (opts.border) b.borderColor = opts.border;
  b.cornerRadius = opts.radius || 0;
  return add(b, x, y, w, h, mask);
}
function label(text, x, y, w, h, mask, color, f) {
  const l = $.NSTextField.labelWithString(text);
  l.textColor = color; l.font = f;
  return add(l, x, y, w, h, mask);
}
function wrapped(text, x, y, w, h, mask, color, f, centre) {
  const l = $.NSTextField.wrappingLabelWithString(text);
  l.textColor = color; l.font = f;
  if (centre) l.alignment = 1;
  return add(l, x, y, w, h, mask);
}
function kicker(text, x, y, w, mask, color) {
  const l = label('', x, y, w, 16, mask, color, font(11, 0.4));
  l.attributedStringValue = astr(text, color, font(11, 0.4), 1.6);
  return l;
}
function field(value, x, y, w, placeholder) {
  box(x, y, w, 34, TOP, C.field, { border: C.line, radius: 8 });
  const f = $.NSTextField.alloc.initWithFrame($.NSMakeRect(0, 0, 10, 10));
  f.bezeled = false; f.bordered = false; f.drawsBackground = false; f.focusRingType = 1;
  f.textColor = C.cream; f.font = font(13);
  f.cell.scrollable = true; f.cell.lineBreakMode = $.NSLineBreakByTruncatingHead;
  f.placeholderAttributedString = astr(placeholder, C.dim, font(13));
  f.stringValue = $(value);
  return add(f, x + 12, y + 8, w - 24, 18, TOP);
}
// House-style buttons: a drawn rounded plate under a borderless button, so the colours hold
// whether or not the window is active. kind: 'primary' (solid amber) or 'secondary'.
function plate(title, action, x, y, w, h, mask, kind) {
  const primary = kind === 'primary';
  const size = primary ? 14 : 13, weight = primary ? 0.4 : 0.23;
  const bg = box(x, y, w, h, mask, primary ? C.amber : C.button, { border: primary ? null : C.line, radius: 8 });
  if (primary) {
    try {
      bg.wantsLayer = true;
      const s = $.NSShadow.alloc.init;
      s.shadowColor = rgb('#f5b03c', 0.45); s.shadowBlurRadius = 12; s.shadowOffset = $.NSMakeSize(0, -1);
      bg.shadow = s;
    } catch (e) {}
  }
  const b = $.NSButton.buttonWithTitleTargetAction(title, ctl, action);
  b.bordered = false;
  b.attributedTitle = astr(title, primary ? C.ink : C.cream, font(size, weight));
  add(b, x, y, w, h, mask);
  return {
    button: b,
    setEnabled(on) {
      b.enabled = on;
      bg.fillColor = primary ? (on ? C.amber : C.amberDim) : C.button;
      b.attributedTitle = astr(title, on ? (primary ? C.ink : C.cream) : C.dim, font(size, weight));
    },
  };
}

// ---- main window ---------------------------------------------------------------
const W = 760, H = 640, BAR = 58, M = 24;
const style = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable |
              $.NSWindowStyleMaskResizable | (1 << 15); // full-size content view
const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, W, H), style, $.NSBackingStoreBuffered, false);
win.title = NAME;
win.titleVisibility = 1;                // hidden: the brand bar carries the name
win.titlebarAppearsTransparent = true;
try { win.toolbar = $.NSToolbar.alloc.initWithIdentifier('pdc'); win.toolbarStyle = 3; } catch (e) {} // unified: centres the traffic lights in the bar
win.backgroundColor = C.ink;
win.minSize = $.NSMakeSize(640, 560);
win.releasedWhenClosed = false;
const view = $.PDCFlippedView.alloc.initWithFrame($.NSMakeRect(0, 0, W, H));
win.contentView = view;
PARENT = view;

// brand bar: traffic lights, logo and name on charcoal, amber rule beneath
box(0, 0, W, BAR, FLEX_W | MAX_Y, C.bar);
box(0, BAR, W, 2, FLEX_W | MAX_Y, C.amber);
if (!icon.isNil()) {
  const iv = $.NSImageView.imageViewWithImage(icon);
  iv.imageScaling = 3; // proportionally up or down
  add(iv, 82, 10, 38, 38, MAX_Y);
}
const title = label('', 128, 17, 380, 26, MAX_Y, C.cream, rounded(19, 0.62));
title.attributedStringValue = brandName(19);
box(W - M - 76, 16, 76, 26, MIN_X | MAX_Y, C.amberSoft, { radius: 13 });
const ver = label('v' + VERSION, W - M - 76, 20, 76, 18, MIN_X | MAX_Y, C.amber, font(12, 0.3));
ver.alignment = 1; // centred

// card: where from, where to
const CP = 20, BW = 116;
const CX = M, CW = W - M * 2, IX = CX + CP, FW = CW - CP * 2 - BW - 10;
let y = BAR + 22;
box(CX, y, CW, 204, TOP, C.card, { border: C.line, radius: 12 });
kicker('FROM  ·  PLEXAMP DOWNLOADS', IX, y + 18, FW, TOP, C.mint);
srcField = field(isDir(DEFAULT_SRC) ? DEFAULT_SRC : '', IX, y + 40, FW, 'Choose Plexamp\'s "Offline" folder…');
plate('Browse…', 'browseSrc:', CX + CW - CP - BW, y + 40, BW, 34, MIN_X | MAX_Y, 'secondary');
srcHint = label('', IX + 2, y + 79, FW, 16, TOP, C.mint, font(11.5, 0.23));
kicker('TO  ·  YOUR MUSIC FOLDER', IX, y + 110, FW, TOP, C.amber);
dstField = field(DEFAULT_DST, IX, y + 132, FW, 'Choose where to copy your music…');
plate('Browse…', 'browseDst:', CX + CW - CP - BW, y + 132, BW, 34, MIN_X | MAX_Y, 'secondary');
label('Copied as Artist  ›  Album  ›  01 - Track, in each file\'s original format. Files already there are never overwritten.',
      IX + 2, y + 171, CW - CP * 2, 16, TOP, C.muted, font(11.5));
y += 204 + 20;

// primary action + progress
copyBtn = plate('Copy Music', 'copyMusic:', M, y, 170, 40, MAX_Y, 'primary');
copyBtn.button.keyEquivalent = '\r';
const PX = M + 170 + 22, PW = W - M - PX;
progLabel = label('', PX, y + 1, PW, 16, TOP, C.muted, font(11.5, 0.23));
progLabel.alignment = 2; // right
progTrack = box(PX, y + 24, PW, 8, TOP, C.bar, { radius: 4, border: C.line });
progFill = box(PX, y + 24, 0, 8, MAX_Y, C.mint, { radius: 4 });
progFill.hidden = true;
y += 40 + 14;
guide = label('Check both folders, then click Copy Music. Your Plexamp downloads are only read, never changed.',
              M, y, W - M * 2, 17, TOP, C.mint, font(12.5, 0.23));
y += 17 + 14;

// log
const STATUS_H = 32;
const logH = H - y - STATUS_H - 18;
box(M, y, W - M * 2, logH, FLEX_W | FLEX_H, C.bar, { border: C.line, radius: 10 });
const scroll = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 0, W - M * 2 - 12, logH - 12));
scroll.hasVerticalScroller = true;
scroll.drawsBackground = false;
scroll.borderType = 0;
const cs = scroll.contentSize;
textView = $.NSTextView.alloc.initWithFrame($.NSMakeRect(0, 0, cs.width, cs.height));
textView.editable = false; textView.richText = true;
textView.drawsBackground = false;
textView.textContainerInset = $.NSMakeSize(6, 6);
textView.autoresizingMask = FLEX_W;
textView.textContainer.widthTracksTextView = true;
scroll.documentView = textView;
add(scroll, M + 6, y + 6, W - M * 2 - 12, logH - 12, FLEX_W | FLEX_H);
logLine('', null, 'Tracks appear here as they\'re copied, sorted into Artist  ›  Album folders.', C.dim);

// status bar
box(0, H - STATUS_H, W, STATUS_H, FLEX_W | MIN_Y, C.bar);
box(0, H - STATUS_H, W, 1, FLEX_W | MIN_Y, rgb('#2c241d'));
statusLabel = label('', M, H - STATUS_H + 8, W - M * 2 - 150, 17, FLEX_W | MIN_Y, C.muted, font(12, 0.23));
setStatus(isDir(DEFAULT_SRC) ? 'Ready — found your Plexamp downloads.' : 'Plexamp downloads not found automatically — click Browse… to choose them.',
          isDir(DEFAULT_SRC) ? C.muted : C.amber);
finderBtn = $.NSButton.buttonWithTitleTargetAction('Show in Finder', ctl, 'showInFinder:');
finderBtn.bordered = false;
finderBtn.attributedTitle = astr('Show in Finder  ›', C.amber, font(12, 0.3));
add(finderBtn, W - M - 140, H - STATUS_H + 6, 140, 20, MIN_X | MIN_Y);
finderBtn.alignment = 2;
finderBtn.hidden = true;
updateSourceHint();

// ---- About window (same layout as the other dustalexw apps) ----------------------
function about() {
  if (aboutWin) { aboutWin.makeKeyAndOrderFront(null); return; }
  const AW = 500, AH = 690;
  const s = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | (1 << 15);
  aboutWin = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, AW, AH), s, $.NSBackingStoreBuffered, false);
  aboutWin.title = `About ${NAME}`;
  aboutWin.titleVisibility = 1;
  aboutWin.titlebarAppearsTransparent = true;
  aboutWin.movableByWindowBackground = true;
  aboutWin.backgroundColor = C.ink;
  aboutWin.releasedWhenClosed = false;
  const av = $.PDCFlippedView.alloc.initWithFrame($.NSMakeRect(0, 0, AW, AH));
  aboutWin.contentView = av;
  const saved = PARENT; PARENT = av;

  if (!icon.isNil()) {
    const iv = $.NSImageView.imageViewWithImage(icon);
    iv.imageScaling = 3;
    add(iv, (AW - 116) / 2, 36, 116, 116, 0);
    try {
      iv.wantsLayer = true;
      const sh = $.NSShadow.alloc.init;
      sh.shadowColor = rgb('#f5b03c', 0.35); sh.shadowBlurRadius = 22; sh.shadowOffset = $.NSMakeSize(0, -4);
      iv.shadow = sh;
    } catch (e) {}
  }
  const t = label('', 20, 162, AW - 40, 34, 0, C.cream, rounded(26, 0.62));
  t.attributedStringValue = centred(brandName(26));
  box((AW - 96) / 2, 204, 96, 4, 0, C.amber, { radius: 2 });
  box((AW - 124) / 2, 220, 124, 24, 0, C.amberSoft, { border: rgb('#f5b03c', 0.35), radius: 12 });
  const v = label(`Version ${VERSION}`, (AW - 124) / 2, 223, 124, 18, 0, C.amber, font(12, 0.3));
  v.alignment = 1;
  wrapped('Your offline music, with real names.', 30, 258, AW - 60, 20, 0, C.cream, font(14, 0.3), true);
  wrapped('Turns Plexamp\'s offline downloads — files named only by random IDs — into Artist › Album › 01 - Track, copied anywhere you like.',
          44, 284, AW - 88, 36, 0, C.muted, font(12), true);

  const FX = 28, FY = 336, FWID = AW - 56;
  box(FX, FY, FWID, 186, 0, C.card, { border: C.line, radius: 12 });
  [
    ['Finds your downloads', 'Reads Plexamp\'s offline library and matches every random-ID file to its track.'],
    ['Real names, tidy folders', 'Copies into Artist › Album › 01 - Track, keeping each file\'s original format.'],
    ['Safe by design', 'Your Plexamp downloads are only read, and files already there are never overwritten.'],
  ].forEach(([head, detail], i) => {
    const ry = FY + 18 + i * 56;
    label(head, FX + 18, ry, FWID - 36, 17, 0, C.amber, font(13, 0.4));
    wrapped(detail, FX + 18, ry + 19, FWID - 36, 30, 0, C.muted, font(11.5), false);
  });

  const LB = (AW - 56 - 16) / 3, LY = FY + 186 + 18;
  plate('Releases', 'openReleases:', 28, LY, LB, 30, 0, 'secondary');
  plate('Source on GitHub', 'openSource:', 28 + LB + 8, LY, LB, 30, 0, 'secondary');
  plate('Report an issue', 'openIssues:', 28 + (LB + 8) * 2, LY, LB, 30, 0, 'secondary');

  wrapped('Based on Plexamp Download Copier by Daniel Rahn  ·  Native window by JavaScript for Automation  ·  Copying by Python 3',
          40, LY + 46, AW - 80, 32, 0, C.dim, font(11), true);
  const close = plate('Close', 'closeAbout:', AW - 28 - 84, AH - 28 - 30, 84, 30, 0, 'secondary');
  close.button.keyEquivalent = '\u001b';

  PARENT = saved;
  aboutWin.center;
  aboutWin.makeKeyAndOrderFront(null);
}

win.center;
win.makeKeyAndOrderFront(null);
app.activateIgnoringOtherApps(true);

// Scripting/testing hooks: PDC_DST prefills the destination, PDC_AUTOSTART=1 starts copying at launch,
// PDC_ABOUT=1 opens the About window.
if (envVar('PDC_DST')) dstField.stringValue = $(envVar('PDC_DST'));
if (envVar('PDC_AUTOSTART') === '1') start();
if (envVar('PDC_ABOUT') === '1') about();

$.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.2, ctl, 'tick:', $(), true);
app.run;
