package main

// Instant echo, the queue, ↑ and the interrupt (D79). A message shows in the conversation the moment Enter is
// pushed, not once Claude Code has written it into the transcript and the next tick has read it. A message sent
// while the agent works waits in Claude Code's queue (it writes it to the transcript only when it takes it up), so
// it shows as queued until then. ↑ in an empty box brings back what was sent. Esc stops a working agent's turn, as
// Esc does in Claude Code; a queued message then runs at once (checked on a background session).

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// outMsg is a message agterm sent (or is sending) to an agent that its transcript does not show yet.
type outMsg struct {
	text string
	at   time.Time
	sent bool // typed in; false while it is being typed
	// queued: the agent was already working when it was sent, so it waits for the turn to end (an idle agent
	// that starts this very message is not queueing it)
	queued bool
}

// echoGiveUp: a sent message the transcript never shows (a command with no prompt line, a text Claude Code
// changed) goes after this long while the agent does not work.
const echoGiveUp = time.Minute

// stopGuard: after an Esc agterm sends nothing more for this long, so a second press doesn't reach Claude Code
// (two Escs on an idle prompt open its rewind menu) and closes the box instead.
const stopGuard = 5 * time.Second

// addEcho shows text under agent sid's conversation at once.
func (m *model) addEcho(sid, text string) {
	if sid == "" || strings.TrimSpace(text) == "" {
		return
	}
	if m.out == nil {
		m.out = map[string][]outMsg{}
	}
	a := m.agentBySID(sid)
	m.out[sid] = append(m.out[sid], outMsg{text: text, at: time.Now(), queued: a != nil && a.Group() == 1})
}

// echoSent: the send of text to sid ended. ok: it shows as sent (or queued). Failed: the copy goes and the text
// becomes the agent's draft again, unless the box holds something for it already; true when it did.
func (m *model) echoSent(sid, text string, ok bool) (kept bool) {
	ps := m.out[sid]
	for i, p := range ps {
		if p.sent || p.text != text {
			continue
		}
		if ok {
			ps[i].sent = true
			return false
		}
		m.out[sid] = append(ps[:i:i], ps[i+1:]...)
		open := m.mode == mTyping && m.ed.target == sid
		if strings.TrimSpace(m.ed.drafts[sid]) == "" && !open {
			m.ed.drafts[sid] = text
			saveDrafts(m.ed.drafts)
			return true
		}
		return false
	}
	return false
}

// settleEchoes drops each copy that the agent's transcript now shows (a prompt line with the same text, written
// after it was sent; each line takes one copy), and a sent one the transcript never showed (echoGiveUp).
func (m *model) settleEchoes() {
	for sid, ps := range m.out {
		a := m.agentBySID(sid)
		if a == nil {
			delete(m.out, sid)
			continue
		}
		chat := m.last(a).Chat
		used := map[int]bool{}
		var keep []outMsg
		for _, p := range ps {
			shown := false
			for i, t := range chat {
				if t.User && !used[i] && !t.At.Before(p.at.Add(-2*time.Second)) && sameText(t.Text, p.text) {
					used[i], shown = true, true
					break
				}
			}
			if shown || (p.sent && a.Group() != 1 && time.Since(p.at) > echoGiveUp) {
				continue
			}
			keep = append(keep, p)
		}
		if len(keep) == 0 {
			delete(m.out, sid)
		} else {
			m.out[sid] = keep
		}
	}
}

// sameText: the transcript's prompt is the text sent, give or take spaces and line breaks.
func sameText(prompt, sent string) bool {
	a, b := strings.Join(strings.Fields(prompt), " "), strings.Join(strings.Fields(sent), " ")
	return a == b || (len(b) > 20 && strings.Contains(a, b))
}

// echoLines: the messages to a that its transcript doesn't show yet, as the conversation draws a prompt but grey,
// each with where it is: sending…, sent, or queued while the agent works.
func (m model) echoLines(a Agent, in int) []string {
	var out []string
	for _, p := range m.out[a.SID] {
		out = append(out, row(in))
		for j, ml := range collapse(wrap(plain(p.text), in-2)) {
			lead := "  "
			if j == 0 {
				lead = "› "
			}
			out = append(out, row(in, s(lead, cGrey.Background(promptBg)), s(padTo(ml, in-2), cGrey.Background(promptBg))))
		}
		state := "sending…"
		switch {
		case p.sent && p.queued && a.Group() == 1:
			state = "queued · it runs when this turn ends · esc stops the turn, then it runs"
		case p.sent:
			state = "sent"
		}
		out = append(out, row(in, s("  "+state, cDark)))
	}
	return out
}

// canStop: Esc would stop agent a's turn: it works, shows no menu, agterm can type into it, it is Claude Code, and
// no Esc went to it just now.
func (m *model) canStop(a *Agent) bool {
	return a != nil && a.canSend() && a.CLI == "" && a.Group() == 1 && time.Since(m.stopped[a.SID]) > stopGuard
}

// interrupt presses Esc in the selected agent, as Esc in Claude Code stops the running turn.
func (m *model) interrupt() tea.Cmd {
	a := m.sel()
	if m.stopped == nil {
		m.stopped = map[string]time.Time{}
	}
	m.stopped[a.SID] = time.Now()
	return m.deliverAs("interrupt", "", []string{"esc"})
}

// recallState is what ↑ last put into the box: the agent, how far back, and the text, so a further ↑ goes one
// older while the text is unchanged.
type recallState struct {
	sid  string
	idx  int
	text string
}

// history: the messages sent to agent a, newest first: those on their way, then the prompts in its transcript
// (Claude Code's "[Request interrupted" lines left out, a repeat right after itself once).
func (m *model) history(a *Agent) []string {
	var h []string
	add := func(t string) {
		t = strings.TrimSpace(t)
		if t == "" || strings.HasPrefix(t, "[Request interrupted") || (len(h) > 0 && h[len(h)-1] == t) {
			return
		}
		h = append(h, t)
	}
	ps := m.out[a.SID]
	for i := len(ps) - 1; i >= 0; i-- {
		add(ps[i].text)
	}
	chat := m.last(a).Chat
	for i := len(chat) - 1; i >= 0 && len(h) < 100; i-- {
		if chat[i].User {
			add(chat[i].Text)
		}
	}
	return h
}

// recallKey: ↑ in an empty box (or on a text ↑ put there, unchanged) puts the message sent before it into the box;
// ↓ goes back towards the newest and then the empty box. false: the key does what it did before.
func (m *model) recallKey(ks string) bool {
	if (ks != "up" && ks != "down") || len(m.ed.comp) > 0 {
		return false
	}
	a := m.agentBySID(m.ed.target)
	if a == nil {
		return false
	}
	v := m.ed.ta.Value()
	walking := m.recall.sid == a.SID && v == m.recall.text && v != ""
	if ks == "down" {
		if !walking {
			return false
		}
		if m.recall.idx == 0 {
			m.setBox("")
			m.recall = recallState{}
			return true
		}
		m.recall.idx--
	} else {
		switch {
		case v == "":
			m.recall = recallState{sid: a.SID, idx: 0}
		case walking:
			m.recall.idx++
		default:
			return false
		}
	}
	h := m.history(a)
	if len(h) == 0 {
		m.recall = recallState{}
		return false
	}
	m.recall.idx = min(m.recall.idx, len(h)-1)
	m.recall.text = h[m.recall.idx]
	m.setBox(m.recall.text)
	for _, p := range m.out[a.SID] {
		if p.sent && p.queued && a.Group() == 1 && strings.TrimSpace(p.text) == m.recall.text {
			m.setStatus("still queued: enter sends this as another message")
			break
		}
	}
	return true
}

// setBox replaces the text in the box (no suggestions: a recalled /command is a text to send, not to complete).
func (m *model) setBox(t string) {
	m.ed.ta.SetValue(t)
	m.ed.comp = nil
	m.ed.resize(m.editorWidth())
	m.ed.keep()
}
