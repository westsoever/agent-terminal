package main

// /ALL <group>: one message to every agent in a group, and @SessionName: a message that starts with an agent's name
// goes to that agent; an @Name that is no session yet starts one as a helper (D70).

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// groups /ALL takes, and who is in each (the sections of the agent list).
var allGroups = []struct{ name, what string }{
	{"waiting", "agents that wait for you (INPUT and WAITING)"},
	{"input", "agents that ask you something (INPUT)"},
	{"idle", "idle agents"},
	{"working", "working agents"},
}

func inGroup(a Agent, group string) bool {
	switch group {
	case "waiting":
		return a.Group() == 0
	case "input":
		return a.needsYou()
	case "idle":
		return a.Group() == 2
	case "working":
		return a.Group() == 1
	}
	return false
}

// transmitFn is transmit; tests replace it.
var transmitFn = transmit

// transmit types text (or presses keys) into agent a and returns "ok" or "error: ...".
func transmit(a Agent, text string, keys []string) string {
	switch {
	case a.Bg:
		return bgSend(a.Job, text, keys)
	case keys != nil:
		return sendKeys(a.TTY, keys...)
	}
	return sendText(a.TTY, text)
}

// recipients: the agents of a group that /ALL writes to. An agent that shows a menu is left out (a message typed
// into a menu is no message), and so is one that agterm can't type into.
func (m *model) recipients(group string) (send []Agent, skipped []string) {
	for _, a := range m.agents {
		if !inGroup(a, group) {
			continue
		}
		switch {
		case !a.canSend():
			skipped = append(skipped, a.Name+" (not in Terminal)")
		case m.prompts[a.SID].Options != nil:
			skipped = append(skipped, a.Name+" (shows a menu)")
		default:
			send = append(send, a)
		}
	}
	return
}

// allMsg is the answer of a broadcast: who got the message and who did not.
type allMsg struct {
	sent    []Agent
	failed  []string
	skipped []string
}

// broadcast types text into each agent in turn (one after the other: each Terminal window briefly comes to the
// front for its Enter).
func broadcast(send []Agent, skipped []string, text string) tea.Cmd {
	return func() tea.Msg {
		out := allMsg{skipped: skipped}
		for _, a := range send {
			if res := transmitFn(a, text, nil); res == "ok" {
				out.sent = append(out.sent, a)
			} else {
				out.failed = append(out.failed, a.Name+": "+strings.TrimPrefix(res, "error: "))
			}
		}
		return out
	}
}

func names2(as []Agent) string { return names(as) }

func names(as []Agent) string {
	var n []string
	for _, a := range as {
		n = append(n, a.Name)
	}
	return strings.Join(n, ", ")
}

// allCommand opens the message box for the agents of group.
func (m model) allCommand(arg string) (tea.Model, tea.Cmd) {
	group := strings.ToLower(strings.TrimSpace(arg))
	known := false
	var list []string
	for _, g := range allGroups {
		list = append(list, g.name)
		known = known || g.name == group
	}
	if !known {
		m.setErr("ALL " + strings.Join(list, " | ") + ": the agents it writes to")
		return m, nil
	}
	if send, _ := m.recipients(group); len(send) == 0 {
		m.setErr("ALL " + group + ": no agent to write to")
		return m, nil
	}
	m.view, m.zoom, m.mode = vDesk, false, mTyping
	cwd := ""
	if a := m.sel(); a != nil {
		cwd = a.Cwd
	}
	return m, m.ed.open("all:"+group, cwd, m.editorWidth())
}

// allHeader is the box title of a broadcast: who gets the message.
func (m model) allHeader(group string) string {
	send, skipped := m.recipients(group)
	h := fmt.Sprintf("to %d %s agents", len(send), group)
	if len(skipped) > 0 {
		h += fmt.Sprintf(" (%d left out)", len(skipped))
	}
	return h
}

// sentAll reports a broadcast on the command line and sends the windows that the queue moved back home.
func (m *model) sentAll(msg allMsg) tea.Cmd {
	var cmds []tea.Cmd
	for _, a := range msg.sent {
		m.expect[a.SID] = time.Now()
		cmds = append(cmds, returnWindow(a.SID, "text"))
	}
	text := fmt.Sprintf("✓ sent to %d agents: %s", len(msg.sent), names(msg.sent))
	if len(msg.skipped) > 0 {
		text += " · left out: " + strings.Join(msg.skipped, ", ")
	}
	if len(msg.failed) > 0 {
		m.setErr(text + " · FAILED: " + strings.Join(msg.failed, ", "))
	} else {
		m.setStatus(text)
	}
	return tea.Batch(cmds...)
}

var mentionRe = regexp.MustCompile(`^@(?:"([^"]+)"|([A-Za-z0-9_-]+))(?:\s+|$)`)

// mention splits a message that starts with @SessionName (or @"Session name") into the name and the rest.
func mention(text string) (name, rest string, ok bool) {
	m := mentionRe.FindStringSubmatch(text)
	if m == nil {
		return "", "", false
	}
	name = m[1]
	if name == "" {
		name = m[2]
	}
	return name, strings.TrimSpace(text[len(m[0]):]), true
}

// agentNamed finds the live agent that name (any case) is. n counts the agents with that name: more than one
// is ambiguous.
func (m *model) agentNamed(name string) (a Agent, n int) {
	for _, x := range m.agents {
		if strings.EqualFold(x.Name, name) {
			a, n = x, n+1
		}
	}
	return
}

// peerNames: the other live agents, for @ suggestions.
func (m *model) peerNames(exceptSID string) []string {
	var out []string
	for _, a := range m.agents {
		if a.SID != exceptSID {
			out = append(out, a.Name)
		}
	}
	return out
}

// mentionQuote is how a name goes after @: in quotes when it holds more than letters, digits, - and _.
func mentionQuote(name string) string {
	if regexp.MustCompile(`^[A-Za-z0-9_-]+$`).MatchString(name) {
		return "@" + name
	}
	return `@"` + name + `"`
}

// routeMention: a message that starts with @Name goes to that agent, without the mention. handled is false when it
// doesn't start with the name of a live agent (then it is an ordinary message, a file mention maybe).
func (m *model) routeMention(text string) (cmd tea.Cmd, handled bool) {
	name, rest, ok := mention(text)
	if !ok {
		return nil, false
	}
	a, n := m.agentNamed(name)
	switch {
	case n == 0:
		return nil, false
	case n > 1:
		m.setErr(fmt.Sprintf("%d sessions are named %s: select one and write to it", n, a.Name))
		return nil, true
	case rest == "":
		m.setErr("write a message after @" + a.Name)
		return nil, true
	case !a.canSend():
		m.setErr(a.Name + " isn't in a Terminal tab: look only (g opens it)")
		return nil, true
	case m.prompts[a.SID].Options != nil:
		m.setErr(a.Name + " shows a menu: answer it first")
		return nil, true
	}
	m.setStatus("sending to " + a.Name + "…")
	return func() tea.Msg {
		return sentMsg{a.SID, a.Name, rest, transmitFn(a, rest, nil)}
	}, true
}

// helperRe: a word that is an @Name, maybe followed by punctuation ("use @helper." or "@a, @b"). @file.md is no name.
var helperRe = regexp.MustCompile(`^@([A-Za-z0-9_-]+)[.,;:!?)]*$`)

// bgStartFn is bgStart; tests replace it.
var bgStartFn = bgStart

// helpers: the @Names in a message to agent sid that are no session yet, so sending it starts each as a background
// helper in that agent's folder first (D70). None when the agent can't take the message now (no window, a menu):
// the message then goes, or fails, as before. A name of a file in the folder or of a REMOTE session is no helper.
func (m *model) helpers(sid, text string) (a Agent, names []string) {
	for _, x := range m.agents {
		if x.SID == sid {
			a = x
		}
	}
	if a.SID == "" || !a.canSend() || m.prompts[sid].Options != nil {
		return a, nil
	}
	seen := map[string]bool{}
	for _, w := range strings.Fields(text) {
		sm := helperRe.FindStringSubmatch(w)
		if sm == nil || seen[strings.ToLower(sm[1])] {
			continue
		}
		name := sm[1]
		seen[strings.ToLower(name)] = true
		if _, n := m.agentNamed(name); n > 0 || m.remoteNamed(name) {
			continue
		}
		if _, err := os.Stat(filepath.Join(a.Cwd, name)); err == nil {
			continue
		}
		names = append(names, name)
	}
	return a, names
}

func (m *model) remoteNamed(name string) bool {
	for _, r := range m.remote.Items {
		if strings.EqualFold(r.Title, name) {
			return true
		}
	}
	return false
}

// helpersMsg: the helpers of a message started (err "" ) or one failed; then the message is not sent.
type helpersMsg struct {
	sid, text string
	names     []string // the helpers that started
	err       string
}

// startHelpers starts each name as a background session in a's folder, on the /NW defaults, briefed to wait for a.
func (m *model) startHelpers(a Agent, names []string, text string) tea.Cmd {
	m.setStatus("starting " + strings.Join(names, ", ") + " in " + tildify(a.Cwd) + "…")
	o := parseNW("", m.cfg)
	o.Dir = a.Cwd
	return func() tea.Msg {
		for i, n := range names {
			o.Name = n
			brief := "You are " + n + ", a helper session for the session " + a.Name + ". Wait: " + a.Name +
				" sends you your task. Report back to " + a.Name + " when it is done."
			if _, err := bgStartFn(o, brief); err != nil {
				return helpersMsg{a.SID, text, names[:i], n + ": " + err.Error()}
			}
		}
		return helpersMsg{sid: a.SID, text: text, names: names}
	}
}

// helpersStarted sends the message once its helpers run; when one failed, the message stays as the agent's draft.
func (m *model) helpersStarted(msg helpersMsg) tea.Cmd {
	var a Agent
	for _, x := range m.agents {
		if x.SID == msg.sid {
			a = x
		}
	}
	m.refresh() // the helpers show in the list now
	if msg.err != "" {
		started := ""
		if len(msg.names) > 0 {
			started = " (started: " + strings.Join(msg.names, ", ") + ")"
		}
		m.setErr("helper not started, message kept as draft" + started + ": " + msg.err)
		return nil
	}
	if a.SID == "" {
		m.setErr("started " + strings.Join(msg.names, ", ") + "; the agent has gone, message kept as draft")
		return nil
	}
	if strings.TrimSpace(m.ed.drafts[msg.sid]) == msg.text && !(m.mode == mTyping && m.ed.target == msg.sid) {
		delete(m.ed.drafts, msg.sid)
		saveDrafts(m.ed.drafts)
	}
	m.setStatus("started " + strings.Join(msg.names, ", ") + " · sending to " + a.Name + "…")
	return func() tea.Msg { return sentMsg{a.SID, a.Name, msg.text, transmitFn(a, msg.text, nil)} }
}
