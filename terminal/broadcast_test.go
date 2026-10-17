package main

import (
	"strings"
	"sync"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestMention(t *testing.T) {
	for _, c := range []struct {
		in, name, rest string
		ok             bool
	}{
		{"@miso run the tests", "miso", "run the tests", true},
		{`@"release notes" ship it`, "release notes", "ship it", true},
		{"@miso-MASTER", "miso-MASTER", "", true},
		{"@01\nand a second line", "01", "and a second line", true},
		{"look at @miso", "", "", false},
		{"@ alone", "", "", false},
		{"plain", "", "", false},
	} {
		name, rest, ok := mention(c.in)
		if name != c.name || rest != c.rest || ok != c.ok {
			t.Errorf("mention(%q) = %q %q %v, want %q %q %v", c.in, name, rest, ok, c.name, c.rest, c.ok)
		}
	}
	if mentionQuote("miso-1") != "@miso-1" || mentionQuote("release notes") != `@"release notes"` {
		t.Error("mentionQuote")
	}
}

func fleet() []Agent {
	return []Agent{
		{SID: "a", Name: "miso", Cwd: "/tmp", InTerminal: true, State: "input", Busy: false},
		{SID: "b", Name: "soii", Cwd: "/tmp", InTerminal: true, State: "idle"},
		{SID: "c", Name: "ching", Cwd: "/tmp", InTerminal: true, State: "idle"},
		{SID: "d", Name: "bg one", Cwd: "/tmp", Bg: true, Job: "d", State: "idle"},
		{SID: "e", Name: "looker", Cwd: "/tmp", State: "idle"}, // not in Terminal.app
		{SID: "f", Name: "busy", Cwd: "/tmp", InTerminal: true, Busy: true},
	}
}

func TestRecipients(t *testing.T) {
	m := newModel()
	m.agents = fleet()
	m.prompts = map[string]Prompt{"c": {Options: []string{"yes", "no"}}} // ching shows a menu
	m.applyPrompts()
	send, skipped := m.recipients("idle")
	if got := names(send); !strings.Contains(got, "soii") || !strings.Contains(got, "bg one") || strings.Contains(got, "ching") || strings.Contains(got, "miso") {
		t.Errorf("idle recipients = %s", got)
	}
	if len(skipped) != 1 || !strings.Contains(skipped[0], "looker") { // ching shows a menu: it waits, it is not idle
		t.Errorf("skipped = %v", skipped)
	}
	send, skipped = m.recipients("waiting")
	if !strings.Contains(names(send), "miso") || strings.Contains(names(send), "ching") || len(skipped) != 1 || !strings.Contains(skipped[0], "ching (shows a menu)") {
		t.Errorf("waiting: %s, skipped %v", names(send), skipped)
	}
	if send, _ := m.recipients("working"); names(send) != "busy" {
		t.Errorf("working: %s", names(send))
	}
}

func TestAllCommandAndBroadcast(t *testing.T) {
	var mu sync.Mutex
	var got []string
	old := transmitFn
	transmitFn = func(a Agent, text string, keys []string) string {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, a.Name+"<-"+text)
		if a.Name == "soii" {
			return "error: no window"
		}
		return "ok"
	}
	t.Cleanup(func() { transmitFn = old })

	m := newModel()
	m.w, m.h = 150, 40
	m.agents = fleet()
	m.selSID = "a"
	if mm, _ := m.allCommand("nobody"); !mm.(model).statusErr || mm.(model).mode == mTyping {
		t.Error("an unknown group opened the box")
	}
	mm, _ := m.allCommand("idle")
	m = mm.(model)
	if m.mode != mTyping || m.ed.target != "all:idle" {
		t.Fatalf("mode %v target %q", m.mode, m.ed.target)
	}
	v := escRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "to 3 idle agents (1 left out)") || !strings.Contains(v, "left out: looker (not in Terminal)") {
		t.Errorf("the box does not say who gets it:\n%s", v)
	}
	// send: one after the other; a failure is reported and does not stop the rest
	m.ed.ta.SetValue("commit your work")
	mm2, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm2.(model)
	if cmd == nil || m.mode != mKeys {
		t.Fatalf("no send: mode %v", m.mode)
	}
	msg := cmd().(allMsg)
	if len(msg.sent) != 2 || len(msg.failed) != 1 || !strings.Contains(msg.failed[0], "soii: no window") || len(got) != 3 {
		t.Fatalf("sent %v failed %v got %v", names(msg.sent), msg.failed, got)
	}
	m.sentAll(msg)
	if !m.statusErr || !strings.Contains(m.status, "FAILED: soii: no window") || !strings.Contains(m.status, "sent to 2 agents") {
		t.Errorf("status %q", m.status)
	}
}

// @Name at the start of a message sends the rest to that session; the box stays open when it can't.
func TestRouteMention(t *testing.T) {
	var sentTo, sentText string
	old := transmitFn
	transmitFn = func(a Agent, text string, keys []string) string { sentTo, sentText = a.Name, text; return "ok" }
	t.Cleanup(func() { transmitFn = old })

	m := newModel()
	m.agents = append(fleet(), Agent{SID: "g", Name: "twin", Cwd: "/tmp", InTerminal: true}, Agent{SID: "h", Name: "Twin", Cwd: "/tmp", InTerminal: true})
	m.selSID = "a"
	cmd, ok := m.routeMention("@soii run the tests again")
	if !ok || cmd == nil {
		t.Fatal("not routed")
	}
	if msg := cmd().(sentMsg); msg.res != "ok" || msg.name != "soii" || sentTo != "soii" || sentText != "run the tests again" {
		t.Errorf("msg %+v to %q text %q", msg, sentTo, sentText)
	}
	if cmd, ok = m.routeMention(`@"bg one" status?`); !ok || cmd == nil {
		t.Error("quoted name not routed")
	}
	for _, c := range []struct{ text, err string }{
		{"@soii", "write a message after @soii"},
		{"@looker hello", "look only"},
		{"@twin hello", "2 sessions are named"},
	} {
		if cmd, ok = m.routeMention(c.text); !ok || cmd != nil || !m.statusErr || !strings.Contains(m.status, c.err) {
			t.Errorf("%q: ok %v cmd %v status %q", c.text, ok, cmd != nil, m.status)
		}
	}
	if _, ok = m.routeMention("@README.md explain this"); ok {
		t.Error("a file mention was taken for a session")
	}
	if _, ok = m.routeMention("tell @soii to stop"); ok {
		t.Error("a mention in the middle was routed")
	}
}

// The box keeps its text when the name is no live session's... and sends when it is.
func TestMentionKeepsBoxOnError(t *testing.T) {
	m := newModel()
	m.w, m.h = 140, 40
	m.agents = fleet()
	m.selSID = "a"
	m.mode = mTyping
	m.ed.open("a", "/tmp", 80)
	m.ed.ta.SetValue("@looker hello")
	mm, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(model)
	if cmd != nil || m.mode != mTyping || m.ed.ta.Value() != "@looker hello" {
		t.Errorf("box closed or text lost: mode %v value %q", m.mode, m.ed.ta.Value())
	}
}

// Typing @ suggests the other sessions (a few, first), then files; a name with spaces is quoted, also while typed.
func TestEditorSessionSuggestions(t *testing.T) {
	e := newEditor()
	e.peers = []string{"miso", "soii", "release notes", "ching"}
	e.cwd = t.TempDir()
	e.open("a", e.cwd, 60)
	e.ta.SetValue("@mi")
	e.suggest()
	if len(e.comp) == 0 || e.comp[0] != "@miso" || e.compDesc["@miso"] != "session" {
		t.Fatalf("comp %q desc %q", e.comp, e.compDesc)
	}
	e.ta.SetValue("@rel")
	e.suggest()
	if len(e.comp) == 0 || e.comp[0] != `@"release notes"` {
		t.Fatalf("comp %q", e.comp)
	}
	e.ta.SetValue(`ask @"release no`)
	e.suggest()
	if len(e.comp) != 1 || e.comp[0] != `@"release notes"` || e.compTok != `@"release no` {
		t.Fatalf("open quote: comp %q tok %q", e.comp, e.compTok)
	}
	e.accept()
	if e.ta.Value() != `ask @"release notes" ` {
		t.Errorf("value %q", e.ta.Value())
	}
}
