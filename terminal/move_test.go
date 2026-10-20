package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const idleScreen = "● done.\n\n────────────────────\n❯ \n────────────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)\n"

// fakeMove replaces every outside call of a move and records them in order.
type fakeMove struct {
	calls  []string
	screen string
	busy   bool
	gone   bool
	opts   []nwOpts
}

func (f *fakeMove) install(t *testing.T) {
	oldScreen, oldType, oldBusy, oldGone, oldClose, oldStart := moveScreenFn, moveTypeFn, moveBusyFn, moveGoneFn, moveCloseFn, bgStartFn
	t.Cleanup(func() {
		moveScreenFn, moveTypeFn, moveBusyFn, moveGoneFn, moveCloseFn, bgStartFn = oldScreen, oldType, oldBusy, oldGone, oldClose, oldStart
	})
	moveScreenFn = func(tty string) string { f.calls = append(f.calls, "screen "+tty); return f.screen }
	moveTypeFn = func(tty, text string) string { f.calls = append(f.calls, "type "+tty+" "+text); return "ok" }
	moveBusyFn = func(pid int) bool { return f.busy }
	moveGoneFn = func(pid int, d time.Duration) bool { f.calls = append(f.calls, "wait"); return f.gone }
	moveCloseFn = func(tty string) string { f.calls = append(f.calls, "close "+tty); return "ok" }
	bgStartFn = func(o nwOpts, prompt string) (string, error) {
		f.calls = append(f.calls, "resume "+o.Resume)
		f.opts = append(f.opts, o)
		return short(o.Resume), nil
	}
}

func termAgent(sid, name string) Agent {
	return Agent{SID: sid, Name: name, Cwd: "/tmp", PID: 4242, TTY: "ttys042", InTerminal: true, State: "idle"}
}

func TestMoveRefusesBusy(t *testing.T) {
	f := &fakeMove{screen: idleScreen, gone: true}
	f.install(t)
	a := termAgent("s1", "miso")
	a.Busy = true
	if _, err := moveToBg(a, nwOpts{}); err == nil || err.Error() != "busy" {
		t.Errorf("busy agent: %v", err)
	}
	// idle in the list, busy by the time the screen was read: nothing typed
	a.Busy, f.busy = false, true
	if _, err := moveToBg(a, nwOpts{}); err == nil || err.Error() != "busy" {
		t.Errorf("busy at send time: %v", err)
	}
	for _, c := range f.calls {
		if strings.HasPrefix(c, "type") {
			t.Errorf("typed into a busy agent: %v", f.calls)
		}
	}
	for _, a := range []Agent{{SID: "b", Name: "bg", Bg: true, Job: "b"}, {SID: "e", Name: "looker"}, {SID: "o", Name: "oc x", InTerminal: true, CLI: "opencode"}} {
		if _, err := moveToBg(a, nwOpts{}); err == nil {
			t.Errorf("%s moved", a.Name)
		}
	}
}

func TestMoveRefusesMenu(t *testing.T) {
	f := &fakeMove{gone: true}
	f.install(t)
	for screen, want := range map[string]string{
		"Do you want to proceed?\n❯ 1. Yes\n  2. No\n\nEsc to cancel\n": "menu",
		"────────\n❯ half a message\n────────\n  ? for shortcuts\n":     "draft",
		"────────\n❯ first line\n  second line\n────────\n":             "draft",
		"error: no Terminal tab for ttys042":                            "error: no Terminal tab for ttys042",
	} {
		f.screen = screen
		if _, err := moveToBg(termAgent("s1", "miso"), nwOpts{}); err == nil || err.Error() != want {
			t.Errorf("%q: %v, want %s", screen, err, want)
		}
	}
	for _, c := range f.calls {
		if strings.HasPrefix(c, "type") {
			t.Errorf("typed into a menu or a draft: %v", f.calls)
		}
	}
	if typedDraft("────────\n❯ Try \"fix lint errors\"\n────────\n") {
		t.Error("the placeholder counts as a draft")
	}
}

func TestMoveOrder(t *testing.T) {
	dir := t.TempDir()
	tr := filepath.Join(dir, "s1.jsonl")
	lines := []string{
		`{"type":"permission-mode","permissionMode":"bypassPermissions"}`,
		`{"type":"user","permissionMode":"acceptEdits","message":{"content":"hi"}}`,
		`{"type":"assistant","effort":"low","message":{"model":"claude-haiku-4-5","content":[{"type":"text","text":"a"}]}}`,
	}
	if err := os.WriteFile(tr, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := &fakeMove{screen: idleScreen, gone: true}
	f.install(t)
	a := termAgent("s1-0000-1111", "miso")
	a.Transcript = tr
	job, err := moveToBg(a, nwOpts{Model: "claude-sonnet-5-5", Effort: "high"})
	if err != nil || job != short(a.SID) {
		t.Fatalf("move: %q %v", job, err)
	}
	want := []string{"screen ttys042", "type ttys042 /exit", "wait", "resume s1-0000-1111", "close ttys042"}
	if strings.Join(f.calls, "|") != strings.Join(want, "|") {
		t.Errorf("calls %v, want %v", f.calls, want)
	}
	o := f.opts[0]
	if o.Dir != "/tmp" || o.Name != "miso" || o.Model != "claude-haiku-4-5" || o.Effort != "low" || o.Perm != "acceptEdits" {
		t.Errorf("resume options %+v", o)
	}

	// a name Claude Code made up (folder and short id) is not passed on; no transcript keeps the given options
	f.calls, f.opts = nil, nil
	b := termAgent("abcdef12-3456", "")
	b.Name = filepath.Base(b.Cwd) + " " + short(b.SID)
	if _, err := moveToBg(b, nwOpts{Model: "claude-sonnet-5-5"}); err != nil {
		t.Fatal(err)
	}
	if o := f.opts[0]; o.Name != "" || o.Model != "claude-sonnet-5-5" {
		t.Errorf("no name, no transcript: %+v", o)
	}

	// it did not end in time: nothing is resumed and the tab stays
	f.calls, f.gone = nil, false
	if _, err := moveToBg(termAgent("s2", "soii"), nwOpts{}); err == nil || !strings.Contains(err.Error(), "did not end") {
		t.Errorf("not gone: %v", err)
	}
	for _, c := range f.calls {
		if strings.HasPrefix(c, "resume") || strings.HasPrefix(c, "close") {
			t.Errorf("went on after the wait: %v", f.calls)
		}
	}
}

func TestBGAllReport(t *testing.T) {
	m := newModel()
	m.agents = []Agent{
		termAgent("a", "miso"),
		{SID: "b", Name: "worker", Cwd: "/tmp", InTerminal: true, Busy: true},
		termAgent("c", "asker"),
		termAgent("d", "soii"),
		{SID: "e", Name: "bg one", Bg: true, Job: "e"},
	}
	m.prompts = map[string]Prompt{"c": {Options: []string{"yes", "no"}}}
	var moved []string
	old := moveFn
	t.Cleanup(func() { moveFn = old })
	moveFn = func(a Agent, o nwOpts) (string, error) {
		moved = append(moved, a.Name)
		return a.SID, nil
	}
	_, cmd := m.command("BG ALL")
	if cmd == nil {
		t.Fatal("no command")
	}
	msg := cmd()
	if strings.Join(moved, ",") != "miso,soii" {
		t.Errorf("moved %v", moved)
	}
	if got := string(msg.(statusMsg)); got != "moved 2 to the background · skipped: worker (busy), asker (menu)" {
		t.Errorf("report %q", got)
	}

	// BG moves the selected agent; a background one is refused at once
	moved = nil
	m.selSID = "d"
	if _, cmd = m.command("BG"); cmd == nil {
		t.Fatal("BG: no command")
	}
	if msg = cmd(); strings.Join(moved, ",") != "soii" || !strings.Contains(string(msg.(statusMsg)), "soii") {
		t.Errorf("BG: moved %v, %v", moved, msg)
	}
	m.selSID = "e"
	mm, cmd := m.command("BG")
	if m2 := mm.(model); cmd != nil || !m2.statusErr {
		t.Errorf("BG on a background agent: %v %q", cmd, m2.status)
	}
}
