package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const remoteJSON = `{"data":[
 {"id":"session_A","title":"cos-worker","session_status":"idle","connection_status":"connected","unread":true,"updated_at":"2026-10-19T12:56:49Z",
  "external_metadata":{"model":"claude-sonnet-5-5","context_usage":{"max_tokens":1000000,"used_tokens":71387},"post_turn_summary":{"status_detail":"opened PR #4","recent_action":"x"}}},
 {"id":"session_B","title":"old","session_status":"archived","connection_status":"connected","updated_at":"2026-10-18T12:00:00Z"},
 {"id":"session_C","title":"away","session_status":"idle","connection_status":"disconnected","updated_at":"2026-10-19T09:00:00Z"},
 {"id":"session_D","title":"busy-one","session_status":"running","connection_status":"connected","updated_at":"2026-10-19T13:30:00Z"}
]}`

// Only active sessions are listed: connected and not archived, the last updated first; a failed read keeps the list.
func TestParseRemote(t *testing.T) {
	st := parseRemote([]byte(remoteJSON))
	if st.Err != "" || len(st.Items) != 2 || st.Items[0].ID != "session_D" || st.Items[1].ID != "session_A" {
		t.Fatalf("items: %+v err %q", st.Items, st.Err)
	}
	a := st.Items[1]
	if a.Label() != "reply" || !a.needsYou() || a.CtxPct != "7%" || a.Summary != "opened PR #4" || a.Model != "claude-sonnet-5-5" {
		t.Fatalf("A: %+v label %s", a, a.Label())
	}
	if l := st.Items[0].Label(); l != "working" || st.Items[0].needsYou() {
		t.Fatalf("D label %s", l)
	}
	kept := st.merge(RemoteState{Err: "remote sessions: HTTP 401"})
	if len(kept.Items) != 2 || kept.Err == "" {
		t.Fatalf("a failed read must keep the last list: %+v", kept)
	}
	if bad := parseRemote([]byte("nope")); bad.Err == "" {
		t.Fatal("bad JSON must be an error")
	}
}

// The REMOTE section sits below DONE, j/l walk from the agents into it, the panel shows the session, r writes to it
// through the CLI, enter opens it on claude.ai/code.
func TestRemoteSection(t *testing.T) {
	oldSend, oldOpen := remoteSendRun, remoteOpen
	defer func() { remoteSendRun, remoteOpen = oldSend, oldOpen }()
	var calls []string
	var fail bool
	remoteSendRun = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, "|"))
		if fail {
			return []byte("Error: device is not bound\n"), errors.New("exit 1")
		}
		return []byte("Sent to cloud session.\n"), nil
	}
	var opened []string
	remoteOpen = func(u string) error { opened = append(opened, u); return nil }

	m := newModel()
	m.w, m.h, m.view = 160, 40, vDesk
	m.agents = []Agent{{SID: "local-1", Name: "miso-01", State: "idle", Since: time.Now()}}
	m.selSID = "local-1"
	mm, _ := m.Update(remoteMsg(parseRemote([]byte(remoteJSON))))
	m = mm.(model)

	v := ansiRe.ReplaceAllString(m.View(), "")
	iDone, iRemote := strings.Index(v, "DONE"), strings.Index(v, "REMOTE")
	if iDone < 0 || iRemote < iDone || !strings.Contains(v, "cos-worker") || strings.Contains(v, "old ") || strings.Contains(v, "away") {
		t.Fatalf("section:\n%s", v)
	}
	press := func(k string) tea.Cmd {
		var msg tea.KeyMsg
		if k == "enter" {
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		} else {
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		mm, cmd := m.Update(msg)
		m = mm.(model)
		return cmd
	}
	press(m.cfg.Keys.Next) // from the one agent into the REMOTE rows
	if m.selSID != "session_D" || m.selRemote() == nil {
		t.Fatalf("sel %q", m.selSID)
	}
	if v = ansiRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "busy-one · remote") || !strings.Contains(v, "claude.ai/code") {
		t.Fatalf("panel:\n%s", v)
	}
	m.refresh() // a refresh of the agents must not take the selection back
	if m.selSID != "session_D" {
		t.Fatalf("refresh moved the selection to %q", m.selSID)
	}
	m.agents = []Agent{{SID: "local-1", Name: "miso-01", State: "idle", Since: time.Now()}} // refresh read this Mac's own
	press(m.cfg.Keys.Next)
	press(m.cfg.Keys.Next) // past the last remote row: back to the first agent
	if m.selSID != "local-1" {
		t.Fatalf("wrap: %q", m.selSID)
	}
	press(m.cfg.Keys.Prev) // and backwards into the last remote row
	if m.selSID != "session_A" {
		t.Fatalf("prev: %q", m.selSID)
	}

	// enter opens it in the browser
	if cmd := press("enter"); cmd == nil {
		t.Fatal("enter must open the session")
	} else {
		cmd()
	}
	if len(opened) != 1 || opened[0] != "https://claude.ai/code/session_A" {
		t.Fatalf("opened %v", opened)
	}

	// reply writes to it through the CLI
	press(m.cfg.Keys.Reply)
	if m.mode != mTyping || m.ed.target != "session_A" {
		t.Fatalf("mode %d target %q", m.mode, m.ed.target)
	}
	m.ed.ta.SetValue("-ok please")
	mm, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(model)
	if cmd == nil || !strings.Contains(m.status, "sending to cos-worker") {
		t.Fatalf("status %q", m.status)
	}
	msg := cmd()
	if len(calls) != 1 || calls[0] != "-p| -ok please|--cloud|session_A" {
		t.Fatalf("calls %q", calls)
	}
	mm, _ = m.Update(msg)
	m = mm.(model)
	if !strings.Contains(m.status, "✓ sent to cos-worker") {
		t.Fatalf("status %q", m.status)
	}

	fail = true
	mm, _ = m.Update(remoteSentMsg{"session_A", "cos-worker", "Error: device is not bound"})
	m = mm.(model)
	if !strings.Contains(m.status, "not sent to cos-worker: Error: device is not bound") || !m.statusErr {
		t.Fatalf("status %q", m.status)
	}

	// the session ended: the selection falls back to an agent
	mm, _ = m.Update(remoteMsg(RemoteState{At: time.Now()}))
	m = mm.(model)
	if m.selSID != "local-1" {
		t.Fatalf("after the session ended: %q", m.selSID)
	}
}
