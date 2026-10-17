// send.js - deliver the owner's input to a Claude Code session in a Terminal.app tab, as if typed there.
// Run as: osascript -l JavaScript send.js CMD TTY [ARGS]   (TTY like ttys005, without /dev/)
//   text TTY TEXT        type TEXT into the tab (Terminal scripting, no focus change), then press Enter; a TEXT
//                        with line breaks goes in as one bracketed paste
//   keys TTY KEY...      press keys: 0-9, enter, esc, tab, up, down, left, right, backspace
//   raise TTY            select the tab, bring its window to the front and activate Terminal (the `g` key)
//   ttys                 every Terminal tab's tty, one per line (which sessions can be typed into)
//   screen TTY           what the tab shows now (its visible text), for reading a menu the agent shows
//   answer TTY N TEXT    in a menu, pick option N (its "Type something." line) and type TEXT; the newline that
//                        do script adds submits it, so no extra Enter
// Typing text needs no focus. A key press is posted to Terminal's process, so the tab's window is put in front
// of Terminal's other windows for ~0.1 s and the window that was in front is put back (the brief flicker the
// owner accepted, design 2026-10-17). `do script` alone does not submit reliably: Claude Code treats a long
// burst as a paste and keeps its newline, so Enter is always pressed separately.
// Prints "ok" or "error: <why>" and exits 0 either way, so the caller reads one line.
ObjC.import('AppKit');
ObjC.import('CoreGraphics');

const CODES = { '0': 29, '1': 18, '2': 19, '3': 20, '4': 21, '5': 23, '6': 22, '7': 26, '8': 28, '9': 25,
  enter: 36, esc: 53, tab: 48, up: 126, down: 125, left: 123, right: 124, backspace: 51 };

function findTab(t, tty) { // [window, tab] whose tab has /dev/<tty>
  const want = '/dev/' + tty;
  const wins = t.windows();
  for (let i = 0; i < wins.length; i++) {
    let ttys;
    try { ttys = wins[i].tabs.tty(); } catch (e) { continue; }
    for (let j = 0; j < (ttys || []).length; j++) if (ttys[j] === want) return [wins[i], wins[i].tabs[j]];
  }
  return [null, null];
}

// inInputBox: Claude Code's input box is the text between the last two rule lines (────) on screen. True
// when it still holds the start of text.
function inInputBox(tab, text) {
  let lines;
  try { lines = tab.contents().split('\n'); } catch (e) { return false; }
  const rules = [];
  lines.forEach((l, i) => { if (/^\s*─{8}/.test(l)) rules.push(i); });
  if (rules.length < 2) return false;
  const a = rules[rules.length - 2], b = rules[rules.length - 1];
  const box = lines.slice(a + 1, b).join(' ').replace(/\s+/g, ' ');
  const want = text.split('\n')[0].replace(/\s+/g, ' ').trim().slice(0, 24);
  return want.length > 0 && box.includes(want);
}

// frontIs: wait up to 0.5 s until the frontmost on-screen Terminal window (window server order) is id.
function frontIs(id) {
  for (let i = 0; i < 25; i++) {
    const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))) || [];
    const top = list.find(w => w.kCGWindowOwnerName === 'Terminal' && w.kCGWindowLayer === 0);
    if (top && top.kCGWindowNumber === id) return true;
    delay(0.02);
  }
  return false;
}

function press(t, win, tab, keys) {
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.apple.Terminal');
  if (apps.count === 0) return 'error: Terminal not running';
  const pid = apps.objectAtIndex(0).processIdentifier;
  let prev = null;
  try { prev = t.windows[0].id(); } catch (e) {}
  tab.selected = true;
  win.index = 1;
  // A key event goes to Terminal's front window: wait until that is really this window, and send nothing
  // when it never gets there (a key must never land in another session or in kaching itself).
  if (!frontIs(win.id())) {
    if (prev !== null && prev !== win.id()) { try { t.windows.byId(prev).index = 1; } catch (e) {} }
    return 'error: could not bring its window to the front, no key sent';
  }
  for (const k of keys) {
    const c = CODES[k];
    if (c === undefined) return 'error: unknown key ' + k;
    [true, false].forEach(d => $.CGEventPostToPid(pid, $.CGEventCreateKeyboardEvent(null, c, d)));
    delay(0.02);
  }
  delay(0.05);
  if (prev !== null && prev !== win.id()) { try { t.windows.byId(prev).index = 1; } catch (e) {} }
  return 'ok';
}

function run(argv) {
  const [cmd, tty] = argv;
  const t = Application('Terminal');
  if (!t.running()) return cmd === 'ttys' ? '' : 'error: Terminal not running';
  if (cmd === 'ttys') {
    const out = [];
    t.windows().forEach(w => {
      let ttys;
      try { ttys = w.tabs.tty(); } catch (e) { return; }
      (ttys || []).filter(Boolean).forEach(x => out.push(String(x).replace('/dev/', '')));
    });
    return out.join('\n');
  }
  const [win, tab] = findTab(t, tty || '');
  if (!win) return 'error: no Terminal tab for ' + tty;
  try {
    if (cmd === 'text') {
      const text = argv.slice(2).join(' ');
      if (!text) return 'error: empty text';
      // several lines go in as one bracketed paste, so Claude Code keeps the line breaks instead of
      // submitting at the first one
      t.doScript(text.includes('\n') ? '\u001b[200~' + text + '\u001b[201~' : text, { in: tab });
      // Enter, then make sure the text left the input box: an Enter that lands while Claude Code still
      // treats the burst as a paste is swallowed. Retried with growing waits; a short text that the
      // newline of do script already submitted needs no Enter at all.
      for (let i = 0; i < 5; i++) {
        delay(0.3 + 0.3 * i);
        if (!inInputBox(tab, text)) return 'ok';
        const r = press(t, win, tab, ['enter']);
        if (r !== 'ok') return r;
      }
      delay(0.6);
      return inInputBox(tab, text) ? 'error: typed but not submitted (press enter in its window)' : 'ok';
    }
    if (cmd === 'keys') return press(t, win, tab, argv.slice(2));
    if (cmd === 'screen') return tab.contents();
    if (cmd === 'answer') {
      const r = press(t, win, tab, [argv[2]]);
      if (r !== 'ok') return r;
      delay(0.4);
      const text = argv.slice(3).join(' ');
      if (!text) return 'error: empty text';
      t.doScript(text, { in: tab });
      return 'ok';
    }
    if (cmd === 'raise') {
      tab.selected = true; win.index = 1; t.activate();
      return 'ok';
    }
  } catch (e) {
    return 'error: ' + e.message;
  }
  return 'error: unknown command ' + cmd;
}
