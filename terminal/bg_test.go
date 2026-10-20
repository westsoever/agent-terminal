package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// The short-lived window quotes the job like any other shell word, so a strange id can't run something else,
// ends its shell after the attach, and reports its tty.
func TestShortWindowScript(t *testing.T) {
	var script string
	old := osascriptRun
	t.Cleanup(func() { osascriptRun = old })
	osascriptRun = func(s string) ([]byte, error) { script = s; return []byte("/dev/ttys042\n"), nil }
	tty, err := shortWindow("j'1; rm")
	if err != nil || tty != "ttys042" {
		t.Fatalf("tty %q err %v", tty, err)
	}
	if want := ` attach 'j'\\''1; rm'; exit"`; !strings.Contains(script, want) || !strings.Contains(script, "return tty of t") {
		t.Errorf("script:\n%s\nwant to contain %s", script, want)
	}
}

// g on a background agent opens one short-lived window; g again raises it; the tick closes it once its attach
// ended, and keeps it while something still runs in it.
func TestShortWindowOnce(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	opened, raised := 0, 0
	oldRun, oldRaise, oldClose := osascriptRun, raiseTabFn, closeIdleFn
	t.Cleanup(func() { osascriptRun, raiseTabFn, closeIdleFn = oldRun, oldRaise, oldClose })
	osascriptRun = func(s string) ([]byte, error) { opened++; return []byte("/dev/ttys042"), nil }
	raiseTabFn = func(tty string) string { raised++; return "ok" }
	idle := false
	closeIdleFn = func(tty string) bool { return idle && tty == "ttys042" }

	m := newModel()
	m.w, m.h = 150, 40
	m.agents = fleet()
	m.selSID = "d" // bg one, job d
	key := func(ks string) tea.Cmd {
		mm, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(ks)})
		m = mm.(model)
		return cmd
	}
	run := func(cmd tea.Cmd) {
		if cmd == nil {
			return
		}
		mm, _ := m.Update(cmd())
		m = mm.(model)
	}
	first := key("g")
	if key("g") != nil {
		t.Error("g while the window opens should do nothing")
	}
	run(first)
	run(key("g"))
	if opened != 1 || raised != 1 || m.short["d"] != "ttys042" {
		t.Fatalf("opened %d raised %d short %v", opened, raised, m.short)
	}
	run(m.closeShorts())
	if m.short["d"] != "ttys042" {
		t.Fatal("closed a window that is still in use")
	}
	idle = true
	run(m.closeShorts())
	if _, ok := m.short["d"]; ok {
		t.Fatal("the window stays recorded after its attach ended")
	}
	run(key("h"))
	if opened != 2 {
		t.Errorf("h after the close did not open a new window: %d", opened)
	}
}
