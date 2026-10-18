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
	Win, Tab               int    // its Terminal window and tab (1-based), 0 when unknown
	Lead                   string // the session id of the lead agent when this one is a sub-session, else ''
	Subs                   int    // how many sub-sessions this lead has
	Ask                    string // what a "needs input" turn asks the owner (meta ask=), '' when none
	Bg                     bool   // a background session (claude --bg): no window, kaching types into it by attaching
	Job                    string // a background session's short id (claude attach <job>)
	Closed                 bool   // its turn ended as done and nothing is left: no next action, no blocker, no NEXT.md
}

// canSend: kaching can type into it: a Terminal tab, or a background session.
func (a Agent) canSend() bool { return a.InTerminal || a.Bg }

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
	JobID     string `json:"jobId"`

	Entrypoint string `json:"entrypoint"` // "cli" for an interactive session, "sdk-cli" for a claude -p call
}

// hidden sessions are machinery, not agents the owner manages: claude-mem's observers, and a `claude -p` call
// (the FIND view's AI search), which Claude Code lists as an interactive session while it runs.
func hidden(cs claudeSession) bool {
	return strings.Contains(cs.Cwd, "/.claude-mem/observer-sessions") || cs.Entrypoint == "sdk-cli"
}

// loadAgents builds the agent list. tabs maps the ttys of Terminal.app tabs to their window and tab (nil when
// not known yet; then every agent with a tty counts as one).
func loadAgents(tabs map[string]tabPos, groups [][]string) []Agent {
	dismissed := loadDismissals()
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
		if json.Unmarshal(b, &cs) != nil || cs.PID == 0 || hidden(cs) {
			continue
		}
		bg := cs.Kind == "bg" && cs.SessionID != "" // a background session; an unclaimed spare has no session yet
		if cs.Kind != "interactive" && !bg {
			continue
		}
		if syscall.Kill(cs.PID, 0) != nil { // stale file: the process is gone
			continue
		}
		a := Agent{SID: cs.SessionID, Name: cs.Name, Cwd: cs.Cwd, PID: cs.PID, Busy: cs.Status == "busy", Bg: bg, Job: cs.JobID}
		if bg && a.Job == "" {
			a.Job = short(cs.SessionID)
		}
		if cs.UpdatedAt > 0 {
			a.Since = time.UnixMilli(cs.UpdatedAt)
		}
		meta := readMeta(filepath.Join(agentHome(), "sessions", cs.SessionID, "meta"))
		a.State = meta["state"]
		a.Branch = meta["branch"]
		a.Transcript = meta["transcript"]
		a.CtxPct = meta["ctx_pct"]
		a.Ask = meta["ask"]
		a.Closed = a.State == "done" && !a.Busy && nothingLeft(meta["root"], cs.SessionID)
		if u, err := strconv.ParseInt(meta["updated"], 10, 64); err == nil && !a.Busy {
			a.Since = time.Unix(u, 0)
		}
		if a.Name == "" {
			a.Name = filepath.Base(a.Cwd) + " " + short(a.SID)
		}
		a.Transcript = findTranscript(a.Transcript, a.Cwd, a.SID)
		if dismissed.hides(a) { // x: out of the queue until it has something new (D50)
			continue
		}
		out = append(out, a)
		pids = append(pids, strconv.Itoa(cs.PID))
	}
	ttys := pidTTYs(pids)
	for i := range out {
		out[i].TTY = ttys[out[i].PID]
		pos, ok := tabs[out[i].TTY]
		out[i].InTerminal = !out[i].Bg && out[i].TTY != "" && (tabs == nil || ok) // a background session's pty is the daemon's
		out[i].Win, out[i].Tab = pos.win, pos.tab
	}
	linkFamilies(out, groups)
	sortAgents(out)
	return out
}

// linkFamilies: the agents that share a Terminal window are one family. The one in the leftmost tab is the
// lead; the others are its sub-sessions (a lead opens its workers as tabs of its own window).
func linkFamilies(a []Agent, groups [][]string) {
	lead := map[int]int{} // window -> index of its lead
	for i := range a {
		if a[i].Win == 0 {
			continue
		}
		if j, ok := lead[a[i].Win]; !ok || a[i].Tab < a[j].Tab {
			lead[a[i].Win] = i
		}
	}
	for i := range a {
		a[i].Lead, a[i].Subs = "", 0
	}
	for i := range a {
		if j, ok := lead[a[i].Win]; ok && j != i {
			a[i].Lead = a[j].SID
			a[j].Subs++
		}
	}
	// macOS window tabs: each tab is its own window, so the tab bars say who belongs together. The first tab
	// is the lead. A name that two agents share is skipped (it can't say which one).
	byName := map[string]int{}
	for i := range a {
		if _, dup := byName[a[i].Name]; dup {
			byName[a[i].Name] = -1
		} else {
			byName[a[i].Name] = i
		}
	}
	for _, g := range groups {
		lead := -1
		for k, n := range g {
			i, ok := byName[n]
			if !ok || i < 0 {
				continue
			}
			if lead < 0 {
				lead = i
				continue
			}
			if a[i].Lead == "" && a[i].SID != a[lead].SID {
				a[i].Lead = a[lead].SID
				a[i].Tab = k + 1
				a[lead].Subs++
			}
		}
	}
}

// nothingLeft: the session's checkpoint names no next action and no blocker, and its NEXT.md is empty or
// missing; the same test kaching-watch.sh uses to leave a finished session alone. The state folder is the repo's
// .agent when it has a GOAL.md, else the session's own folder under ~/.agent.
func nothingLeft(root, sid string) bool {
	dir := filepath.Join(agentHome(), "sessions", sid)
	if root != "" {
		if _, err := os.Stat(filepath.Join(root, ".agent", "GOAL.md")); err == nil {
			dir = filepath.Join(root, ".agent")
		}
	}
	for _, k := range []string{"next_action", "blocker"} {
		if checkpointValue(filepath.Join(dir, "STATE.md"), k) != "" {
			return false
		}
	}
	if b, err := os.ReadFile(filepath.Join(dir, "NEXT.md")); err == nil && strings.TrimSpace(string(b)) != "" {
		return false
	}
	return true
}

// checkpointValue: the first `key:` line inside the ching:checkpoint block of a STATE.md, ” when it is
// missing, blank or a "nothing here" sentinel (none, (none), none.), as bin/lib.sh checkpoint_get and open_value.
func checkpointValue(path, key string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	in := false
	for _, l := range strings.Split(string(b), "\n") {
		switch {
		case strings.HasPrefix(l, "<!-- ching:checkpoint -->"):
			in = true
		case strings.HasPrefix(l, "<!-- /ching:checkpoint -->"):
			in = false
		case in && strings.HasPrefix(l, key+":"):
			v := strings.TrimSpace(strings.TrimPrefix(l, key+":"))
			switch strings.ToLower(v) {
			case "", "none", "(none)", "none.":
				return ""
			}
			return v
		}
	}
	return ""
}

// sortAgents: by queue section (see sectionOf): INPUT and WAITING oldest first, it has waited longest, then
// working, idle and done newest first. A family stays together: the lead, then its
// sub-sessions in tab order. The family sorts by its most urgent member, so a sub-session that waits
// brings its family up.
func sortAgents(a []Agent) {
	sort.SliceStable(a, func(i, j int) bool {
		si, sj := sectionOf(a[i]), sectionOf(a[j])
		if si != sj {
			return si < sj
		}
		if si <= 1 {
			return a[i].Since.Before(a[j].Since)
		}
		return a[i].Since.After(a[j].Since)
	})
	pos := map[string]int{} // family key -> its first (most urgent) position
	key := func(x Agent) string {
		if x.Lead != "" {
			return x.Lead
		}
		return x.SID
	}
	for i, x := range a {
		if _, ok := pos[key(x)]; !ok {
			pos[key(x)] = i
		}
	}
	sort.SliceStable(a, func(i, j int) bool {
		ki, kj := key(a[i]), key(a[j])
		if ki != kj {
			return pos[ki] < pos[kj]
		}
		if (a[i].Lead == "") != (a[j].Lead == "") {
			return a[i].Lead == "" // the lead first
		}
		return a[i].Tab < a[j].Tab
	})
}

// FamilyGroup: the group a family is listed under (its most urgent member's), for the lead and its subs alike.
func FamilyGroup(a []Agent, i int) int {
	key := a[i].SID
	if a[i].Lead != "" {
		key = a[i].Lead
	}
	g := a[i].Group()
	for _, x := range a {
		if (x.SID == key || x.Lead == key) && x.Group() < g {
			g = x.Group()
		}
	}
	return g
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

// findTranscript: the transcript file of a session. The path in meta is the one from the session's start; when
// the session changed folder since (EnterWorktree, cd), Claude Code keeps writing under the new folder's project
// dir and the recorded file is stale. Then try the current cwd's project dir, then any project dir.
func findTranscript(recorded, cwd, sid string) string {
	if recorded != "" {
		if _, err := os.Stat(recorded); err == nil {
			return recorded
		}
	}
	guess := guessTranscript(cwd, sid)
	if _, err := os.Stat(guess); err == nil {
		return guess
	}
	if hits, _ := filepath.Glob(filepath.Join(os.Getenv("HOME"), ".claude", "projects", "*", sid+".jsonl")); len(hits) > 0 {
		return hits[0]
	}
	if recorded != "" {
		return recorded
	}
	return guess
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
