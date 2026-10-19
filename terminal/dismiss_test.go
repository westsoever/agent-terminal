package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// x takes a waiting agent out of the queue, a background one too (it has no Terminal tab); the agent comes back
// when it has something new, and one that is still working is not touched.
func TestDismissBackgroundAgent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("AGENT_HOME", filepath.Join(home, ".agent"))
	sess := filepath.Join(home, ".claude", "sessions")
	os.MkdirAll(sess, 0o755)
	pid := strconv.Itoa(os.Getpid())
	for i, sid := range []string{"aaaa1111", "bbbb2222"} {
		os.WriteFile(filepath.Join(sess, strconv.Itoa(i)+".json"), []byte(`{"pid":`+pid+`,"sessionId":"`+sid+`","cwd":"/tmp","kind":"bg","jobId":"`+sid+`","name":"bg-`+sid+`","status":"idle"}`), 0o644)
	}
	meta := func(sid string, updated time.Time) {
		dir := filepath.Join(home, ".agent", "sessions", sid)
		os.MkdirAll(dir, 0o755)
		os.WriteFile(filepath.Join(dir, "meta"), []byte("state=input\nask=Review it?\nupdated="+strconv.FormatInt(updated.Unix(), 10)+"\n"), 0o644)
	}
	meta("aaaa1111", time.Now().Add(-time.Hour))
	meta("bbbb2222", time.Now().Add(-30*time.Minute))
	m := newModel()
	m.mode = mKeys
	if len(m.agents) != 2 || m.agents[0].Group() != 0 {
		t.Fatalf("agents: %+v", m.agents)
	}
	m.selSID = m.agents[0].SID
	first, second := m.agents[0].SID, m.agents[1].SID
	mm, cmd := m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("x")})
	m = mm.(model)
	if cmd != nil {
		t.Fatalf("a background agent has no window queue to leave, but x started a command")
	}
	if len(m.agents) != 1 || m.agents[0].SID != second || m.selSID != second || m.statusErr {
		t.Fatalf("after x: agents %+v, selected %q, status %q (error %v)", m.agents, m.selSID, m.status, m.statusErr)
	}
	// a fresh read keeps it away
	if got := loadAgents(map[string]tabPos{}, nil); len(got) != 1 || got[0].SID != second {
		t.Fatalf("read again: %+v", got)
	}
	// it finishes another turn: back in the list
	meta(first, time.Now().Add(time.Minute))
	if got := loadAgents(map[string]tabPos{}, nil); len(got) != 2 {
		t.Fatalf("with something new: %+v", got)
	}
}

// A dismissed agent that is working again is shown; it is hidden again only by a new x.
func TestDismissedWorkingAgentShows(t *testing.T) {
	a := Agent{SID: "s1", State: "input", Since: time.Unix(1000, 0)}
	d := dismissals{"s1": 2000}
	if !d.hides(a) {
		t.Fatal("waiting, nothing new since: hidden")
	}
	a.Busy = true
	if d.hides(a) {
		t.Fatal("busy: shown")
	}
	a.Busy, a.Since = false, time.Unix(2001, 0)
	if d.hides(a) {
		t.Fatal("new event: shown")
	}
}

// An idle agent can be dismissed too (D67): hidden while idle with nothing new, shown once it works again.
func TestDismissIdleAgent(t *testing.T) {
	a := Agent{SID: "s1", State: "idle", Since: time.Unix(1000, 0)}
	if a.Group() != 2 {
		t.Fatalf("group %d, want idle", a.Group())
	}
	d := dismissals{"s1": 2000}
	if !d.hides(a) {
		t.Fatal("idle, nothing new since: hidden")
	}
	a.State = "working"
	if d.hides(a) {
		t.Fatal("working: shown")
	}
}
