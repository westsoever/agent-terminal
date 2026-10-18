package main

// Dismissed agents (D50): x takes a waiting agent out of the queue, in whichever section it sits, until it has
// something new to say. ~/.agent/terminal/dismissed.json maps a session id to the time of the dismissal; the agent
// stays hidden while its last event is not newer than that. It works for a background agent too, which has no
// Terminal tab and so is not in the window queue.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type dismissals map[string]int64

func dismissedPath() string { return filepath.Join(agentHome(), "terminal", "dismissed.json") }

func loadDismissals() dismissals {
	d := dismissals{}
	if b, err := os.ReadFile(dismissedPath()); err == nil {
		_ = json.Unmarshal(b, &d)
	}
	return d
}

// hides: the owner dismissed this agent and it is still waiting with nothing new since.
func (d dismissals) hides(a Agent) bool {
	at, ok := d[a.SID]
	return ok && a.Group() == 0 && a.Since.Unix() <= at
}

// dismissAgent records that the owner dismissed a at now (at the agent's own last event when its clock is ahead).
// Entries older than 30 days go.
func dismissAgent(a Agent, now time.Time) {
	d := loadDismissals()
	at := now.Unix()
	if s := a.Since.Unix(); s > at {
		at = s
	}
	d[a.SID] = at
	for sid, t := range d {
		if now.Unix()-t > 30*24*3600 {
			delete(d, sid)
		}
	}
	p := dismissedPath()
	b, err := json.MarshalIndent(d, "", "  ")
	if err != nil || os.MkdirAll(filepath.Dir(p), 0o700) != nil {
		return
	}
	if os.WriteFile(p+".tmp", b, 0o600) == nil {
		_ = os.Rename(p+".tmp", p)
	}
}

// dropAgent takes an agent out of the list at once and moves the selection to the one below it (the one above
// when it was the last), so the row goes without waiting for the next read.
func (m *model) dropAgent(sid string) {
	i := -1
	for j := range m.agents {
		if m.agents[j].SID == sid {
			i = j
			break
		}
	}
	if i < 0 {
		return
	}
	out := make([]Agent, 0, len(m.agents)-1)
	out = append(append(out, m.agents[:i]...), m.agents[i+1:]...)
	m.agents = out
	if m.selSID == sid {
		m.selSID = ""
		if len(out) > 0 {
			m.selSID = out[min(i, len(out)-1)].SID
		}
		m.writeState()
	}
}
