package main

import (
	"strings"
	"testing"
)

// A recorded stream in the shape Claude Code draws: clear, text with rules edge to edge, a menu with a cursor.
func fakeLog(width int) []byte {
	rule := strings.Repeat("▔", width)
	return []byte("\x1b7\x1b8\x1b[2J\x1b[H\x1b[1mClaude Code\x1b[22m\r\n\r\n❯ Reply with just: pong\r\n\r\n⏺ pong\r\n\r\n" +
		rule + "\r\n   \x1b[1mSwitch model?\x1b[22m\r\n   Your next response will be slower\r\n\r\n   ❯ 1. Yes, switch to Sonnet 5.5\r\n     2. No, go back\r\n")
}

func TestLogSize(t *testing.T) {
	if w, h := logSize(fakeLog(160)); w != 160 || h != 50 {
		t.Errorf("size = %dx%d", w, h)
	}
	if w, h := logSize([]byte("\x1b[40;1Hx" + strings.Repeat("─", 90))); w != 90 || h != 40 {
		t.Errorf("size from the cursor row = %dx%d", w, h)
	}
	if w, h := logSize([]byte("no rules")); w != 120 || h != 50 {
		t.Errorf("default size = %dx%d", w, h)
	}
}

// The menu in a log is read like the menu on a Terminal tab's screen, rules of both kinds left out.
func TestScreenFromLog(t *testing.T) {
	screen := strings.Join(screenFromLog(fakeLog(160)), "\n")
	if !strings.Contains(screen, "❯ Reply with just: pong") {
		t.Fatalf("screen = %q", screen)
	}
	p := parsePrompt(screen)
	if len(p.Options) != 2 || p.Options[0] != "Yes, switch to Sonnet 5.5" || p.Options[1] != "No, go back" {
		t.Fatalf("prompt = %+v", p)
	}
	if p.Lines[0] != "   Switch model?" {
		t.Errorf("lines start with %q: the rule above the dialog should cut the menu there", p.Lines[0])
	}
	// the stream asks the terminal a question (cursor position report); nobody answers, the replay must not hang
	if lines := screenFromLog(append([]byte("\x1b[6n\x1b[c"), fakeLog(100)...)); len(lines) == 0 {
		t.Error("no screen")
	}
}

// A background agent whose screen shows a menu waits for the owner, and the menu is the panel's.
func TestBackgroundScreenMenu(t *testing.T) {
	m := newModel()
	m.w, m.h = 150, 40
	m.agents = []Agent{{SID: "b1", Name: "bgm", Cwd: "/tmp", Bg: true, Job: "b1", Transcript: writeTranscript(t, `{"type":"assistant","message":{"content":[{"type":"text","text":"pong"}]}}`)}}
	m.selSID = "b1"
	m.Update(promptMsg{"b1", parsePrompt(strings.Join(screenFromLog(fakeLog(150)), "\n"))})
	mm, _ := m.Update(promptMsg{"b1", parsePrompt(strings.Join(screenFromLog(fakeLog(150)), "\n"))})
	m = mm.(model)
	if !m.agents[0].Asking {
		t.Fatal("the agent with a menu on its screen is not waiting")
	}
	v := escRe.ReplaceAllString(m.View(), "")
	for _, want := range []string{"THE AGENT ASKS", "Switch model?", "1 Yes, switch to Sonnet 5.5", "2 No, go back"} {
		if !strings.Contains(v, want) {
			t.Errorf("view lacks %q", want)
		}
	}
	// answered: the screen is read again, and shows no menu
	mm, _ = m.Update(promptMsg{"b1", Prompt{}})
	m = mm.(model)
	if m.agents[0].Asking {
		t.Error("still waiting after the menu is gone")
	}
}
