package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// No first message: no "--" for claude; a resume names the session.
func TestStartArgs(t *testing.T) {
	if got := strings.Join(nwOpts{Resume: "abc", Model: "sonnet"}.args(""), " "); got != "--bg --resume abc --model sonnet" {
		t.Errorf("args %q", got)
	}
}

// startModel: a model with the NW box open on dir, the starts and the windows recorded.
func startModel(t *testing.T, fails int) (*model, *[]string, *[]string) {
	t.Setenv("AGENT_HOME", t.TempDir())
	var starts, scripts []string
	oldStart, oldRun, oldClose := bgStartFn, osascriptRun, closeIdleFn
	t.Cleanup(func() { bgStartFn, osascriptRun, closeIdleFn = oldStart, oldRun, oldClose })
	bgStartFn = func(o nwOpts, prompt string) (string, error) {
		starts = append(starts, o.Dir+"|"+prompt)
		if len(starts) <= fails {
			return "", errors.New("Workspace not trusted. Run claude in this folder once.")
		}
		return "ab12cd34", nil
	}
	osascriptRun = func(s string) ([]byte, error) { scripts = append(scripts, s); return []byte("/dev/ttys042"), nil }
	closeIdleFn = func(string) bool { return true }
	m := newModel()
	m.w, m.h = 150, 40
	m.mode = mTyping
	m.ed.open("nw:/tmp/proj", "/tmp/proj", m.editorWidth())
	return &m, &starts, &scripts
}

func (m *model) feedAll(cmd tea.Cmd) {
	for cmd != nil {
		mm, next := m.Update(cmd())
		*m, cmd = mm.(model), next
	}
}

// Enter on an empty NW box starts the agent with no first message and opens its screen.
func TestNWEmptyOpensScreen(t *testing.T) {
	m, starts, scripts := startModel(t, 0)
	mm, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	*m = mm.(model)
	m.feedAll(cmd)
	if strings.Join(*starts, ",") != "/tmp/proj|" || len(*scripts) != 1 || !strings.Contains((*scripts)[0], "attach 'ab12cd34'; exit") {
		t.Fatalf("starts %v scripts %v", *starts, *scripts)
	}
}

// A folder Claude Code does not trust: the command line asks; yes opens claude there in a short-lived window, and
// once it closes the start runs again. No sends nothing.
func TestTrustAsk(t *testing.T) {
	m, starts, scripts := startModel(t, 1)
	m.ed.ta.SetValue("do the thing")
	mm, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	*m = mm.(model)
	m.feedAll(cmd)
	if m.mode != mConfirm || !strings.Contains(escRe.ReplaceAllString(m.View(), ""), "does not trust /tmp/proj yet") {
		t.Fatalf("no trust question: mode %v", m.mode)
	}
	mm, cmd = m.key(tea.KeyMsg{Type: tea.KeyEnter})
	*m = mm.(model)
	m.feedAll(cmd)
	if len(*scripts) != 1 || !strings.Contains((*scripts)[0], `cd '/tmp/proj' && `) || m.short["trust:/tmp/proj"] != "ttys042" {
		t.Fatalf("scripts %v short %v", *scripts, m.short)
	}
	m.feedAll(m.closeShorts()) // the owner trusted it and left with /exit
	if strings.Join(*starts, ",") != "/tmp/proj|do the thing,/tmp/proj|do the thing" || m.pendingJob != "ab12cd34" {
		t.Fatalf("not started again: %v pending %q", *starts, m.pendingJob)
	}

	m, starts, _ = startModel(t, 1)
	m.ed.ta.SetValue("x")
	mm, cmd = m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	*m = mm.(model)
	m.feedAll(cmd)
	mm, cmd = m.key(tea.KeyMsg{Type: tea.KeyEsc})
	*m = mm.(model)
	if cmd != nil || m.mode != mKeys || len(*starts) != 1 {
		t.Errorf("no: cmd %v mode %v starts %v", cmd != nil, m.mode, *starts)
	}
}

// Logged out: the footer says so instead of the usage.
func TestLoggedOutFooter(t *testing.T) {
	m, _, _ := startModel(t, 0)
	m.mode = mKeys
	mm, _ := m.Update(authMsg(true))
	if v := escRe.ReplaceAllString(mm.(model).View(), ""); !strings.Contains(v, "Claude Code is logged out · /LOGIN") {
		t.Errorf("footer:\n%s", v)
	}
}

func TestScreenCommand(t *testing.T) {
	for in, want := range map[string]bool{"/config": true, "/model": true, " /mcp ": true, "/memory": true, "/login": true,
		"/model sonnet": false, "/compact": false, "/clear": false, "config": false, "fix /config": false} {
		if screenCommand(in) != want {
			t.Errorf("screenCommand(%q) = %v", in, !want)
		}
	}
}

// /config to a background agent is typed, then its screen opens; to a Terminal agent it only goes as text.
func TestScreenCommandOpensScreen(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	var sent []string
	opened := 0
	oldSend, oldRun := transmitFn, osascriptRun
	t.Cleanup(func() { transmitFn, osascriptRun = oldSend, oldRun })
	transmitFn = func(a Agent, text string, keys []string) string { sent = append(sent, a.Name+"<-"+text); return "ok" }
	osascriptRun = func(s string) ([]byte, error) { opened++; return []byte("/dev/ttys042"), nil }
	for _, c := range []struct {
		sid     string
		windows int
	}{{"d", 1}, {"a", 0}} { // bg one, miso in Terminal
		m := newModel()
		m.w, m.h = 150, 40
		m.agents = fleet()
		m.selSID = c.sid
		m.mode = mTyping
		m.ed.open(c.sid, "/tmp", m.editorWidth())
		m.ed.ta.SetValue("/config")
		opened = 0
		_, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
		runAll(cmd)
		if opened != c.windows {
			t.Errorf("%s: %d windows, want %d", c.sid, opened, c.windows)
		}
	}
	if strings.Join(sent, ",") != "bg one<-/config,miso<-/config" {
		t.Errorf("sent %v", sent)
	}
}

// runAll runs a command and the commands of a batch or a sequence in it (their messages are slices of commands).
func runAll(cmd tea.Cmd) {
	if cmd == nil {
		return
	}
	if v := reflect.ValueOf(cmd()); v.Kind() == reflect.Slice {
		for i := 0; i < v.Len(); i++ {
			if c, ok := v.Index(i).Interface().(tea.Cmd); ok {
				runAll(c)
			}
		}
	}
}
