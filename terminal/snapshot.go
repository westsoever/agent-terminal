package main

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Agent is one live interactive Claude Code session, joined from Claude Code's own session file
// (~/.claude/sessions/<pid>.json: name, status), Kaching's record (~/.agent/sessions/<id>/meta: state, branch,
// transcript) and the process's tty.
type Agent struct {
	SID, Name, Cwd, Branch string
	PID                    int
	Busy                   bool   // Claude Code says busy
	State                  string // Kaching's state: working idle done input blocked ready
	Since                  time.Time
	TTY                    string // ttys005, '' when none
	InTerminal             bool   // the tty is a Terminal.app tab, so the terminal can type into it
	Transcript             string
	CtxPct                 string
	Asking                 bool   // its screen shows a menu now (a question, an approval): it waits for the owner
	Ask                    string // what a "needs input" turn asks the owner (meta ask=), '' when none
}

// Group is where an agent sits in the queue.
func (a Agent) Group() int {
	switch {
	case a.waiting():
		return 0
	case a.Busy || a.State == "working":
		return 1
	default:
		return 2
	}
}

func (a Agent) waiting() bool {
	if a.Asking { // Claude Code calls a session busy while its question is open; the screen says it waits
		return true
	}
	if a.Busy {
		return false
	}
	switch a.State {
	case "input", "blocked", "done", "ready":
		return true
	}
	return false
}

// needsYou: a waiting agent that asks the owner something (a menu on its screen, or its last turn asked) or is
// stuck; the rest of the waiting ones are done.
func (a Agent) needsYou() bool {
	return a.Asking || (a.waiting() && (a.State == "input" || a.State == "blocked"))
}

// Label is the short state word on the desk.
func (a Agent) Label() string {
	if a.Asking {
		return "asks"
	}
	if a.Busy {
		return "working"
	}
	switch a.State {
	case "input":
		return "input"
	case "blocked":
		return "blocked"
	case "done":
		return "done"
	case "ready":
		return "ready"
	case "working":
		return "working"
	}
	return "idle"
}

type claudeSession struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Status    string `json:"status"`
	UpdatedAt int64  `json:"statusUpdatedAt"`
}

// hidden sessions are machinery, not agents the owner manages.
func hidden(cs claudeSession) bool {
	return strings.Contains(cs.Cwd, "/.claude-mem/observer-sessions")
}

// loadAgents builds the agent list. terminalTTYs is the set of ttys that are Terminal.app tabs (may be nil
// when not known yet; then every agent with a tty counts as one).
func loadAgents(terminalTTYs map[string]bool) []Agent {
	dir := filepath.Join(os.Getenv("HOME"), ".claude", "sessions")
	files, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	var out []Agent
	var pids []string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var cs claudeSession
		if json.Unmarshal(b, &cs) != nil || cs.PID == 0 || cs.Kind != "interactive" || hidden(cs) {
			continue
		}
		if syscall.Kill(cs.PID, 0) != nil { // stale file: the process is gone
			continue
		}
		a := Agent{SID: cs.SessionID, Name: cs.Name, Cwd: cs.Cwd, PID: cs.PID, Busy: cs.Status == "busy"}
		if cs.UpdatedAt > 0 {
			a.Since = time.UnixMilli(cs.UpdatedAt)
		}
		meta := readMeta(filepath.Join(agentHome(), "sessions", cs.SessionID, "meta"))
		a.State = meta["state"]
		a.Branch = meta["branch"]
		a.Transcript = meta["transcript"]
		a.CtxPct = meta["ctx_pct"]
		a.Ask = meta["ask"]
		if u, err := strconv.ParseInt(meta["updated"], 10, 64); err == nil && !a.Busy {
			a.Since = time.Unix(u, 0)
		}
		if a.Name == "" {
			a.Name = filepath.Base(a.Cwd) + " " + short(a.SID)
		}
		if a.Transcript == "" {
			a.Transcript = guessTranscript(a.Cwd, a.SID)
		}
		out = append(out, a)
		pids = append(pids, strconv.Itoa(cs.PID))
	}
	ttys := pidTTYs(pids)
	for i := range out {
		out[i].TTY = ttys[out[i].PID]
		out[i].InTerminal = out[i].TTY != "" && (terminalTTYs == nil || terminalTTYs[out[i].TTY])
	}
	sortAgents(out)
	return out
}

// sortAgents: waiting first (the ones that need the owner, then the done ones; oldest first, it has waited
// longest), then working, then idle (newest first).
func sortAgents(a []Agent) {
	sort.SliceStable(a, func(i, j int) bool {
		gi, gj := a[i].Group(), a[j].Group()
		if gi != gj {
			return gi < gj
		}
		if gi == 0 {
			if ni, nj := a[i].needsYou(), a[j].needsYou(); ni != nj {
				return ni
			}
			return a[i].Since.Before(a[j].Since)
		}
		return a[i].Since.After(a[j].Since)
	})
}

func short(sid string) string {
	if len(sid) > 7 {
		return sid[:7]
	}
	return sid
}

func readMeta(path string) map[string]string {
	m := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), "="); ok {
			m[k] = v
		}
	}
	return m
}

// guessTranscript: Claude Code's project folder is the cwd with every non-alphanumeric char as '-'.
func guessTranscript(cwd, sid string) string {
	var b strings.Builder
	for _, r := range cwd {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteRune('-')
		}
	}
	return filepath.Join(os.Getenv("HOME"), ".claude", "projects", b.String(), sid+".jsonl")
}

// pidTTYs maps pid -> tty (ttys005) with one ps call.
func pidTTYs(pids []string) map[int]string {
	m := map[int]string{}
	if len(pids) == 0 {
		return m
	}
	out, err := exec.Command("ps", "-o", "pid=,tty=", "-p", strings.Join(pids, ",")).Output()
	if err != nil && len(out) == 0 {
		return m
	}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) != 2 || f[1] == "??" {
			continue
		}
		if p, err := strconv.Atoi(f[0]); err == nil {
			m[p] = f[1]
		}
	}
	return m
}
