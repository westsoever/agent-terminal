package main

import (
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// sends records what transmitFn was asked to send; res is what it answers.
type sends struct {
	mu  sync.Mutex
	got []string
	res string
}

func fakeTransmit(t *testing.T) *sends {
	s := &sends{res: "ok"}
	old := transmitFn
	transmitFn = func(a Agent, text string, keys []string) string {
		s.mu.Lock()
		defer s.mu.Unlock()
		if keys != nil {
			s.got = append(s.got, a.Name+"<-key "+strings.Join(keys, " "))
		} else {
			s.got = append(s.got, a.Name+"<-"+text)
		}
		return s.res
	}
	t.Cleanup(func() { transmitFn = old })
	return s
}

func (s *sends) list() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.got...)
}

// run delivers what a command returns to the model, as Bubble Tea does (one level of batch is enough here).
func run(m model, cmd tea.Cmd) model {
	if cmd == nil {
		return m
	}
	msg := cmd()
	if b, ok := msg.(tea.BatchMsg); ok {
		for _, c := range b {
			if c != nil {
				if mm, ok := c().(sentMsg); ok {
					nm, _ := m.Update(mm)
					m = nm.(model)
				}
			}
		}
		return m
	}
	if sm, ok := msg.(sentMsg); ok {
		nm, _ := m.Update(sm)
		m = nm.(model)
	}
	return m
}

func echoModel(t *testing.T, agents ...Agent) model {
	t.Setenv("AGENT_HOME", t.TempDir())
	m := newModel()
	m.w, m.h = 150, 40
	m.agents = agents
	m.selSID = agents[0].SID
	return m
}

func pressKey(m model, k tea.KeyMsg) (model, tea.Cmd) {
	nm, cmd := m.Update(k)
	return nm.(model), cmd
}

var escKey = tea.KeyMsg{Type: tea.KeyEsc}

// Esc on the desk interrupts the selected agent while it works, like Esc in Claude Code (D79). Once: a second Esc
// right after sends nothing (two in Claude Code open its rewind menu). An idle agent, one with a menu, and a zoom or
// panel that is open first get no Esc.
func TestEscInterruptsOnDesk(t *testing.T) {
	s := fakeTransmit(t)
	m := echoModel(t, Agent{SID: "w", Name: "worker", Cwd: "/tmp", InTerminal: true, Busy: true},
		Agent{SID: "i", Name: "idler", Cwd: "/tmp", InTerminal: true, State: "idle"},
		Agent{SID: "q", Name: "asker", Cwd: "/tmp", InTerminal: true, Busy: true, Asking: true})

	m, cmd := pressKey(m, escKey)
	if cmd == nil {
		t.Fatal("esc on a working agent sent nothing")
	}
	m = run(m, cmd)
	if got := s.list(); len(got) != 1 || got[0] != "worker<-key esc" {
		t.Fatalf("sent %v", got)
	}
	if !strings.Contains(m.status, "worker") || m.statusErr {
		t.Errorf("status %q", m.status)
	}
	m = run(pressKey(m, escKey))
	if got := s.list(); len(got) != 1 {
		t.Fatalf("a second esc right after sent again: %v", got)
	}

	m.selSID = "i"
	m = run(pressKey(m, escKey))
	m.selSID = "q"
	m = run(pressKey(m, escKey))
	if got := s.list(); len(got) != 1 {
		t.Fatalf("esc reached an idle agent or a menu: %v", got)
	}

	m.selSID = "w"
	m.stopped = nil
	m.zoom = true
	m = run(pressKey(m, escKey))
	if m.zoom || len(s.list()) != 1 {
		t.Fatalf("esc with a zoom open: zoom %v, sent %v", m.zoom, s.list())
	}
	m.view = vWall
	m = run(pressKey(m, escKey))
	if m.view != vDesk || len(s.list()) != 1 {
		t.Fatalf("esc on the wall: view %v, sent %v", m.view, s.list())
	}
}

// In the message box Esc interrupts a working agent and the box stays open with the text, so the new instruction
// can go out at once; a second Esc closes the box. Esc closes the suggestions first, and ctrl+c always closes.
func TestEscInterruptsInBox(t *testing.T) {
	s := fakeTransmit(t)
	m := echoModel(t, Agent{SID: "w", Name: "worker", Cwd: "/tmp", InTerminal: true, Busy: true},
		Agent{SID: "i", Name: "idler", Cwd: "/tmp", InTerminal: true, State: "idle"})
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	if m.mode != mTyping {
		t.Fatal("the box did not open")
	}
	m.ed.ta.SetValue("stop, do it the other way")
	if v := panelText(m); !strings.Contains(v, "esc stops its turn") {
		t.Fatalf("the box does not say what esc does while it works:\n%s", v)
	}

	m.ed.comp = []string{"@a"}
	m = run(pressKey(m, escKey))
	if m.mode != mTyping || len(m.ed.comp) != 0 || len(s.list()) != 0 {
		t.Fatalf("esc with suggestions: mode %v comp %v sent %v", m.mode, m.ed.comp, s.list())
	}

	m = run(pressKey(m, escKey))
	if got := s.list(); len(got) != 1 || got[0] != "worker<-key esc" {
		t.Fatalf("sent %v", got)
	}
	if m.mode != mTyping || m.ed.ta.Value() != "stop, do it the other way" {
		t.Fatalf("the box closed or lost its text: mode %v %q", m.mode, m.ed.ta.Value())
	}
	m = run(pressKey(m, escKey))
	if m.mode != mKeys || m.ed.drafts["w"] != "stop, do it the other way" || len(s.list()) != 1 {
		t.Fatalf("a second esc: mode %v draft %q sent %v", m.mode, m.ed.drafts["w"], s.list())
	}

	m.stopped = nil
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	m = run(pressKey(m, tea.KeyMsg{Type: tea.KeyCtrlC}))
	if m.mode != mKeys || len(s.list()) != 1 {
		t.Fatalf("ctrl+c: mode %v sent %v", m.mode, s.list())
	}

	m.selSID = "i"
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	m = run(pressKey(m, escKey))
	if m.mode != mKeys || len(s.list()) != 1 {
		t.Fatalf("esc in the box of an idle agent: mode %v sent %v", m.mode, s.list())
	}
}

func promptLine(text string, at time.Time) string {
	return `{"type":"user","timestamp":"` + at.UTC().Format(time.RFC3339Nano) + `","message":{"content":"` + text + `"}}`
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func panelText(m model) string { return escRe.ReplaceAllString(m.View(), "") }

// A message shows at the bottom of the conversation the moment Enter is pushed (sending…), then sent, and goes
// once the transcript has it; to a working agent it says queued until Claude Code takes it up (D79).
func TestEchoShowsAtOnce(t *testing.T) {
	s := fakeTransmit(t)
	tr := writeTranscript(t, `{"type":"assistant","message":{"content":[{"type":"text","text":"ready when you are"}]}}`)
	m := echoModel(t, Agent{SID: "i", Name: "idler", Cwd: "/tmp", InTerminal: true, State: "idle", Transcript: tr})
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	m.ed.ta.SetValue("run the tests")
	m, cmd := pressKey(m, tea.KeyMsg{Type: tea.KeyEnter})
	if v := panelText(m); !strings.Contains(v, "› run the tests") || !strings.Contains(v, "sending…") {
		t.Fatalf("not shown at once:\n%s", v)
	}
	m = run(m, cmd)
	if len(s.list()) != 1 {
		t.Fatalf("sent %v", s.list())
	}
	if v := panelText(m); !strings.Contains(v, "› run the tests") || !strings.Contains(v, "sent") || strings.Contains(v, "sending…") {
		t.Fatalf("after the send:\n%s", v)
	}
	// Claude Code writes it into the transcript: the grey copy goes, the real one stays
	writeFile(t, tr, `{"type":"assistant","message":{"content":[{"type":"text","text":"ready when you are"}]}}`+"\n"+promptLine("run the tests", time.Now())+"\n")
	m.settleEchoes()
	v := panelText(m)
	if strings.Count(v, "› run the tests") != 1 || strings.Contains(v, "sent ·") || len(m.out["i"]) != 0 {
		t.Fatalf("after the transcript has it:\n%s", v)
	}
}

func TestEchoQueuedWhileWorking(t *testing.T) {
	fakeTransmit(t)
	tr := writeTranscript(t, promptLine("write the story", time.Now().Add(-time.Minute)))
	m := echoModel(t, Agent{SID: "w", Name: "worker", Cwd: "/tmp", InTerminal: true, Busy: true, Transcript: tr})
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	m.ed.ta.SetValue("then say done")
	m = run(pressKey(m, tea.KeyMsg{Type: tea.KeyEnter}))
	if v := panelText(m); !strings.Contains(v, "› then say done") || !strings.Contains(v, "queued") {
		t.Fatalf("not queued:\n%s", v)
	}
	m.settleEchoes() // still not in the transcript: it stays
	if len(m.out["w"]) != 1 {
		t.Fatal("a queued message went before Claude Code took it up")
	}
}

// A send that fails takes the grey copy away and keeps the text as the agent's draft, so nothing is lost.
func TestEchoFailedKeepsDraft(t *testing.T) {
	s := fakeTransmit(t)
	s.res = "error: no window"
	m := echoModel(t, Agent{SID: "i", Name: "idler", Cwd: "/tmp", InTerminal: true, State: "idle"})
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	m.ed.ta.SetValue("are you there")
	m = run(pressKey(m, tea.KeyMsg{Type: tea.KeyEnter}))
	if len(m.out["i"]) != 0 || strings.Contains(panelText(m), "› are you there") {
		t.Fatal("a failed message still shows as sent")
	}
	if m.ed.drafts["i"] != "are you there" || !m.statusErr || !strings.Contains(m.status, "draft") {
		t.Fatalf("draft %q status %q", m.ed.drafts["i"], m.status)
	}
}

// A message the transcript never shows, to an agent that is not working, goes after a while.
func TestEchoGivesUp(t *testing.T) {
	m := echoModel(t, Agent{SID: "i", Name: "idler", Cwd: "/tmp", InTerminal: true, State: "idle"})
	m.out = map[string][]outMsg{"i": {{text: "/config", at: time.Now().Add(-2 * echoGiveUp), sent: true}}}
	m.settleEchoes()
	if len(m.out["i"]) != 0 {
		t.Fatal("kept a message the transcript never shows")
	}
}

// ↑ in an empty box brings back what was sent to the agent, newest first, ready to edit; ↓ goes back towards the
// empty box. An edited text and an agent with nothing sent keep ↑ as it was (scroll, cursor).
func TestUpRecallsSent(t *testing.T) {
	tr := writeTranscript(t, promptLine("first prompt", time.Now().Add(-2*time.Minute)),
		`{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}`,
		promptLine("second prompt", time.Now().Add(-time.Minute)))
	m := echoModel(t, Agent{SID: "i", Name: "idler", Cwd: "/tmp", InTerminal: true, State: "idle", Transcript: tr})
	m.out = map[string][]outMsg{"i": {{text: "third, still on its way", at: time.Now()}}}
	m, _ = pressKey(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(m.cfg.Keys.Reply)})
	up := tea.KeyMsg{Type: tea.KeyUp}
	down := tea.KeyMsg{Type: tea.KeyDown}
	for _, want := range []string{"third, still on its way", "second prompt", "first prompt", "first prompt"} {
		m, _ = pressKey(m, up)
		if got := m.ed.ta.Value(); got != want {
			t.Fatalf("up: %q, want %q", got, want)
		}
	}
	m, _ = pressKey(m, down)
	if got := m.ed.ta.Value(); got != "second prompt" {
		t.Fatalf("down: %q", got)
	}
	m, _ = pressKey(m, down)
	m, _ = pressKey(m, down)
	if got := m.ed.ta.Value(); got != "" {
		t.Fatalf("down past the newest: %q", got)
	}
	m, _ = pressKey(m, up)
	m.ed.ta.SetValue("second prompt, edited")
	m, _ = pressKey(m, up)
	if got := m.ed.ta.Value(); got != "second prompt, edited" {
		t.Fatalf("up on an edited text recalled: %q", got)
	}
	m.ed.ta.SetValue("")
	m.agents[0].Transcript = ""
	m.out = nil
	m.View()
	m, _ = pressKey(m, up)
	if m.ed.ta.Value() != "" {
		t.Fatalf("recalled with nothing sent: %q", m.ed.ta.Value())
	}
}
