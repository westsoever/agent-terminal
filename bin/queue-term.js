// queue-term.js - the Terminal.app side of queue.sh. Run as: osascript -l JavaScript queue-term.js CMD [ARGS]
// All coordinates are top-left based (y grows down), like Terminal's own window bounds.
//   screens              one line per display, the menu bar display first: "x y w h name fx fy" (x y w h is the
//                        visible frame, without menu bar and Dock; fx fy is the display's own top-left corner)
//   windows              one line per Terminal or Ghostty window: "id x y w h tty1,tty2,... onscreen" (ttys without
//                        /dev/; onscreen is 1 for a window on a desktop now shown, 0 on a hidden desktop or minimised).
//                        A Ghostty window's id is its tab-group address in decimal (tab-group-c492debc0 -> 52879...),
//                        far above any Terminal window number, so ids stay numbers. Ghostty has no frame in its
//                        scripting, so the frame comes from System Events, matched by the window title: a window whose
//                        title is shared (or that is on another desktop) shows as "0 0 0 0 ... 0" and is left alone.
//   move ID X Y W H [ID X Y W H ...]
//                        set each window's frame. Moving never raises a window or takes focus; when Terminal's front
//                        window changed anyway, the one that was in front is put back.
//   raise ID TTY         select the tab with that tty, bring the window to the front and activate the app
// Prints nothing and exits 0 when the app is not running (windows, move, raise never launch it).
ObjC.import('AppKit');
ObjC.import('CoreGraphics');

function onscreenIds() { // window numbers on the desktops now shown (Terminal's window id is its window number)
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1 /* on screen only */, 0))) || [];
  const ids = {};
  list.forEach(w => { if (w.kCGWindowOwnerName === 'Terminal') ids[w.kCGWindowNumber] = 1; });
  return ids;
}

function displayTop(b) { // top edge (top-left coordinates) of the display holding the centre of frame b; 0 if none
  const s = $.NSScreen.screens;
  if (s.count === 0) return 0;
  const mainH = s.objectAtIndex(0).frame.size.height, cx = b.x + b.width / 2, cy = b.y + b.height / 2;
  for (let i = 0; i < s.count; i++) {
    const f = s.objectAtIndex(i).frame, top = mainH - (f.origin.y + f.size.height);
    if (cx >= f.origin.x && cx < f.origin.x + f.size.width && cy >= top && cy < top + f.size.height) return top;
  }
  return 0;
}

function screens() {
  const s = $.NSScreen.screens, out = [];
  if (s.count === 0) return out;
  const m = s.objectAtIndex(0), mainH = m.frame.size.height;
  // with "Displays have separate Spaces" every display shows a menu bar, but only the main one's is taken off
  // its visible frame: take the same height off any other display whose visible frame starts at its very top
  const menuH = (m.frame.origin.y + mainH) - (m.visibleFrame.origin.y + m.visibleFrame.size.height);
  for (let i = 0; i < s.count; i++) {
    const sc = s.objectAtIndex(i), v = sc.visibleFrame, f = sc.frame;
    let y = mainH - (v.origin.y + v.size.height), h = v.size.height;
    const fy = mainH - (f.origin.y + f.size.height);
    if (i > 0 && Math.abs(y - fy) < 1) { y += menuH; h -= menuH; }
    out.push([Math.round(v.origin.x), Math.round(y), Math.round(v.size.width), Math.round(h),
      sc.localizedName.js.replace(/\s+/g, '_'), Math.round(f.origin.x), Math.round(fy)].join(' '));
  }
  return out;
}

function term() {
  const t = Application('Terminal');
  return t.running() ? t : null;
}

function findWin(t, id) {
  const w = t.windows.byId(Number(id));
  try { w.id(); return w; } catch (e) { return null; }
}

const GHOSTTY_MIN = 1e9; // below: a Terminal window number; from here: a Ghostty tab-group address

function ghostty() {
  const g = Application('Ghostty');
  return g.running() ? g : null;
}

function ghosttyId(w) { return parseInt(String(w.id()).replace('tab-group-', ''), 16); }

function ghosttyTtys(w) { // every terminal of the window (splits too), without /dev/
  const out = [];
  w.tabs().forEach(tab => tab.terminals().forEach(tm => { const x = String(tm.tty()).replace('/dev/', ''); if (x) out.push(x); }));
  return out;
}

// System Events' window for each Ghostty window: matched by title, only where the title is unique on both sides.
// Returns [{ win: ghostty window, ax: System Events window or null }].
function ghosttyWindows(g) {
  const wins = g.windows().filter(w => { try { w.id(); return true; } catch (e) { return false; } });
  let ax = [];
  try { ax = Application('System Events').processes.byName('Ghostty').windows(); } catch (e) {}
  const titles = ax.map(a => { try { return a.title(); } catch (e) { return null; } });
  const names = wins.map(w => w.name());
  const count = (list, x) => list.filter(y => y === x).length;
  return wins.map((w, i) => {
    const n = names[i], at = titles.indexOf(n);
    return { win: w, ax: at >= 0 && count(names, n) === 1 && count(titles, n) === 1 ? ax[at] : null };
  });
}

function ghosttyLines(g) {
  const out = [];
  ghosttyWindows(g).forEach(({ win, ax }) => {
    let line;
    try {
      const ttys = ghosttyTtys(win).join(',');
      if (!ttys) return;
      if (!ax || ax.attributes.byName('AXMinimized').value()) { out.push([ghosttyId(win), 0, 0, 0, 0, ttys, 0].join(' ')); return; }
      const p = ax.position(), s = ax.size();
      line = [ghosttyId(win), p[0], p[1], s[0], s[1], ttys, 1].join(' ');
    } catch (e) { return; }   // a closing window
    out.push(line);
  });
  return out;
}

function ghosttyMove(g, id, x, y, w, h) {
  const hit = ghosttyWindows(g).find(e => ghosttyId(e.win) === id);
  if (!hit || !hit.ax) return;
  // size first, then place, then once more: a size change at a display edge shifts the window
  const set = () => { hit.ax.position = [x, y]; hit.ax.size = [w, h]; hit.ax.position = [x, y]; };
  try { set(); } catch (e) {}
}

function ghosttyRaise(g, tty) { // focus the terminal with that tty: selects its tab, fronts its window
  for (const w of g.windows()) {
    for (const tab of w.tabs()) {
      for (const tm of tab.terminals()) {
        if (String(tm.tty()).replace('/dev/', '') === tty) { g.focus(tm); g.activate(); return; }
      }
    }
  }
}

function run(argv) {
  const cmd = argv[0] || '';
  if (cmd === 'screens') return screens().join('\n');
  const t = term(), g = ghostty();
  if (cmd === 'windows') {
    const out = [], on = t ? onscreenIds() : {};
    if (t) t.windows().forEach(w => {
      let b, ttys;
      try { b = w.bounds(); ttys = w.tabs.tty(); } catch (e) { return; }   // a closing window
      const list = (ttys || []).filter(Boolean).map(x => String(x).replace('/dev/', ''));
      if (list.length) out.push([w.id(), b.x, b.y, b.width, b.height, list.join(','), on[w.id()] ? 1 : 0].join(' '));
    });
    return out.concat(g ? ghosttyLines(g) : []).join('\n');
  }
  if (cmd === 'move') {
    let front = null;
    try { if (t) front = t.windows[0].id(); } catch (e) {}
    for (let i = 1; i + 4 < argv.length; i += 5) {
      const n = argv.slice(i, i + 5).map(Number);
      if (n[0] >= GHOSTTY_MIN) { if (g) ghosttyMove(g, n[0], n[1], n[2], n[3], n[4]); continue; }
      const w = t && findWin(t, argv[i]);
      if (!w) continue;
      const want = { x: n[1], y: n[2], width: n[3], height: n[4] };
      // Terminal reads y from the top of the main display but sets it from the top of the display the window is
      // on now, so take that display's top off; check, and once more from wherever the window landed
      const set = () => { const top = displayTop(w.bounds()); w.bounds = Object.assign({}, want, { y: want.y - top }); };
      set();
      const got = w.bounds();
      if (Math.abs(got.x - want.x) > 2 || Math.abs(got.y - want.y) > 2) set();
    }
    try { if (front !== null && t.windows[0].id() !== front) { const f = findWin(t, front); if (f) f.index = 1; } } catch (e) {}
    return '';
  }
  if (cmd === 'raise') {
    if (Number(argv[1]) >= GHOSTTY_MIN) { if (g) ghosttyRaise(g, argv[2]); return ''; }
    const w = t && findWin(t, argv[1]);
    if (!w) return '';
    w.tabs().forEach(tab => { if (String(tab.tty()).replace('/dev/', '') === argv[2]) tab.selected = true; });
    w.index = 1;
    t.activate();
    return '';
  }
  return 'usage: queue-term.js screens|windows|move ID X Y W H [...]|raise ID TTY';
}
