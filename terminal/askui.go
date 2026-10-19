package main

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// prog is the menu state agterm keeps for a background agent, started afresh for each question set.
func (m *model) prog(sid, id string, n int) *askProg {
	if m.askProg == nil {
		m.askProg = map[string]*askProg{}
	}
	p := m.askProg[sid]
	if p == nil {
		p = &askProg{}
		m.askProg[sid] = p
	}
	if p.id != id || len(p.picks) != n {
		p.reset(id, n)
	}
	return p
}

// bgPrompt shows a background agent's menu: the one on its screen (rebuilt from claude logs), or, until that is
// read, its open question drawn from the transcript and the keys agterm sent (askProg), in the lines of a real
// screen.
func (m *model) bgPrompt(a *Agent) {
	if p, ok := m.bgScr[a.SID]; ok {
		m.prompts[a.SID] = p
		return
	}
	l := m.last(a)
	if len(l.Ask) == 0 {
		delete(m.prompts, a.SID)
		delete(m.askProg, a.SID)
		return
	}
	p := m.prog(a.SID, l.AskID, len(l.Ask))
	if p.done { // submitted: the transcript shows the answer in a moment
		delete(m.prompts, a.SID)
		return
	}
	m.prompts[a.SID] = p.screen(l.Ask)
	m.sawAsk(a.SID, time.Now())
}

func (m *model) agentBySID(sid string) *Agent {
	for i := range m.agents {
		if m.agents[i].SID == sid {
			return &m.agents[i]
		}
	}
	return nil
}

// pressMenu notes a key that goes into a background agent's menu, so the menu drawn next is the one it shows.
func (m *model) pressMenu(a *Agent, k string) {
	if !a.Bg {
		return
	}
	if l := m.last(a); len(l.Ask) > 0 {
		m.prog(a.SID, l.AskID, len(l.Ask)).press(l.Ask, k)
		m.bgPrompt(a)
	}
}

// screenStart is the question a menu on screen is at: the first one still open in its tab line, or the review
// screen (len(qs)).
func screenStart(qs []AskQuestion, lines []string) int {
	tab := ""
	for _, l := range lines {
		if strings.Contains(l, "Review your answers") {
			return len(qs)
		}
		if strings.Contains(l, "✔ Submit") {
			tab = l
		}
	}
	for i, q := range qs {
		if strings.Contains(tab, "☐ "+askName(q, i)) {
			return i
		}
	}
	if tab != "" { // every tab is ticked
		return len(qs)
	}
	return 0
}

// quickApprove takes the recommended answer of every open question of the selected agent and submits.
func (m *model) quickApprove() tea.Cmd {
	a := m.sel()
	if a == nil {
		return nil
	}
	if !a.canSend() {
		m.setErr(a.Name + " isn't in a Terminal tab: look only (g opens it)")
		return nil
	}
	l := m.last(a)
	if len(l.Ask) == 0 {
		m.setErr(a.Name + " asks no question with answers to pick from")
		return nil
	}
	pr, ok := m.prompts[a.SID]
	if !ok {
		m.setErr(a.Name + "'s menu is not on its screen yet: try again in a moment")
		return nil
	}
	from := screenStart(l.Ask, pr.Lines)
	keys, err := quickKeys(l.Ask, from)
	if err != nil {
		m.setErr(a.Name + ": " + err.Error())
		return nil
	}
	if a.Bg {
		m.prog(a.SID, l.AskID, len(l.Ask)).done = true
		delete(m.prompts, a.SID)
		delete(m.bgScr, a.SID)
	}
	return m.deliverAs("quick approve", "", keys)
}

// askSummary is the recommendation list under an agent's menu: each question with its recommended answer, and the
// key that takes them all. qs is nil when the menu is not an AskUserQuestion (a permission prompt).
func askSummary(qs []AskQuestion, in int, key string) []string {
	if len(qs) == 0 {
		return nil
	}
	out := []string{row(in, s("RECOMMENDED", cDark))}
	missing := ""
	for i, q := range qs {
		name := askName(q, i)
		if rec := askRecommendation(q); rec != "" {
			out = append(out, row(in, s("★ ", cOrange), s(padTo(name, 14), cGrey), s(rec, cWhite)))
			continue
		}
		out = append(out, row(in, s("– ", cDark), s(padTo(name, 14), cGrey), s("no recommendation", cDark)))
		if missing == "" {
			missing = name
		}
	}
	if missing != "" {
		out = append(out, row(in, s(key, cDark), s(" quick approve can't run: "+missing+" has no recommendation", cDark)))
		return out
	}
	out = append(out, row(in, s(key, cOrange), s(" quick approve: take the ★ answers and submit", cGrey)))
	return out
}
