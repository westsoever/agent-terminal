// queue-term.js - the Terminal.app side of queue.sh. Run as: osascript -l JavaScript queue-term.js CMD [ARGS]
// All coordinates are top-left based (y grows down), like Terminal's own window bounds.
//   screens              one line per display, the menu bar display first: "x y w h name" (visible frame)
//   windows              one line per Terminal window: "id x y w h tty1,tty2,..." (ttys without /dev/)
//   move ID X Y W H      set the window's frame; does not raise it or take focus
//   raise ID TTY         select the tab with that tty, bring the window to the front and activate Terminal
// Prints nothing and exits 0 when Terminal is not running (windows, move, raise never launch it).
ObjC.import('AppKit');

function screens() {
  const s = $.NSScreen.screens, out = [];
  if (s.count === 0) return out;
  const mainH = s.objectAtIndex(0).frame.size.height;
  for (let i = 0; i < s.count; i++) {
    const sc = s.objectAtIndex(i), v = sc.visibleFrame;
    const y = mainH - (v.origin.y + v.size.height);
    out.push([Math.round(v.origin.x), Math.round(y), Math.round(v.size.width), Math.round(v.size.height),
      sc.localizedName.js.replace(/\s+/g, '_')].join(' '));
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
    const out = [];
    t.windows().forEach(w => {
      let b, ttys;
      try { b = w.bounds(); ttys = w.tabs.tty(); } catch (e) { return; }   // a closing window
      const list = (ttys || []).filter(Boolean).map(x => String(x).replace('/dev/', ''));
      if (list.length) out.push([w.id(), b.x, b.y, b.width, b.height, list.join(',')].join(' '));
    });
    return out.join('\n');
  }
  if (cmd === 'move') {
    const w = findWin(t, argv[1]);
    if (w) w.bounds = { x: Number(argv[2]), y: Number(argv[3]), width: Number(argv[4]), height: Number(argv[5]) };
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
  return 'usage: queue-term.js screens|windows|move ID X Y W H|raise ID TTY';
}
