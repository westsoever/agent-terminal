// queue-term.js - the Terminal.app side of queue.sh. Run as: osascript -l JavaScript queue-term.js CMD [ARGS]
// All coordinates are top-left based (y grows down), like Terminal's own window bounds.
//   screens              one line per display, the menu bar display first: "x y w h name fx fy" (x y w h is the
//                        visible frame, without menu bar and Dock; fx fy is the display's own top-left corner)
//   windows              one line per Terminal window: "id x y w h tty1,tty2,... onscreen" (ttys without /dev/;
//                        onscreen is 1 for a window on a desktop now shown, 0 on a hidden desktop or minimised)
//   move ID X Y W H [ID X Y W H ...]
//                        set each window's frame. Moving never raises a window or takes focus; when Terminal's front
//                        window changed anyway, the one that was in front is put back.
//   raise ID TTY         select the tab with that tty, bring the window to the front and activate Terminal
// Prints nothing and exits 0 when Terminal is not running (windows, move, raise never launch it).
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

function run(argv) {
  const cmd = argv[0] || '';
  if (cmd === 'screens') return screens().join('\n');
  const t = term();
  if (!t) return '';
  if (cmd === 'windows') {
    const out = [], on = onscreenIds();
    t.windows().forEach(w => {
      let b, ttys;
      try { b = w.bounds(); ttys = w.tabs.tty(); } catch (e) { return; }   // a closing window
      const list = (ttys || []).filter(Boolean).map(x => String(x).replace('/dev/', ''));
      if (list.length) out.push([w.id(), b.x, b.y, b.width, b.height, list.join(','), on[w.id()] ? 1 : 0].join(' '));
    });
    return out.join('\n');
  }
  if (cmd === 'move') {
    let front = null;
    try { front = t.windows[0].id(); } catch (e) {}
    for (let i = 1; i + 4 < argv.length; i += 5) {
      const w = findWin(t, argv[i]);
      if (!w) continue;
      const want = { x: Number(argv[i + 1]), y: Number(argv[i + 2]), width: Number(argv[i + 3]), height: Number(argv[i + 4]) };
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
    const w = findWin(t, argv[1]);
    if (!w) return '';
    w.tabs().forEach(tab => { if (String(tab.tty()).replace('/dev/', '') === argv[2]) tab.selected = true; });
    w.index = 1;
    t.activate();
    return '';
  }
  return 'usage: queue-term.js screens|windows|move ID X Y W H [...]|raise ID TTY';
}
