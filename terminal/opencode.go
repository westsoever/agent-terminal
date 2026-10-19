package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// opencode sessions on the desk next to Claude Code's (D64). A live one is an `opencode` TUI process with a tty;
// its session is the newest top-level one in opencode's database for the process's folder. The database is read
// with the sqlite3 that macOS ships, read-only, so the terminal needs no SQLite driver.

func opencodeDB() string {
	return filepath.Join(os.Getenv("HOME"), ".local", "share", "opencode", "opencode.db")
}

// ocProc is one running opencode TUI.
type ocProc struct {
	pid      int
	tty, cwd string
}

// opencodeProcs: the running opencode TUIs. `opencode serve` (the background server) and `opencode run`
// (a one-shot call) have no screen to type into and are left out.
func opencodeProcs() []ocProc {
	// pgrep, then ps on its pids only: this runs on every tick, and `ps -A` alone takes 50 ms.
	found, err := exec.Command("pgrep", "-x", "opencode").Output()
	if err != nil {
		return nil
	}
	out, _ := exec.Command("ps", "-o", "pid=,tty=,command=", "-p", strings.Join(strings.Fields(string(found)), ",")).Output()
	var procs []ocProc
	var pids []string
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) < 3 || f[1] == "??" || filepath.Base(f[2]) != "opencode" {
			continue
		}
		if len(f) > 3 && (f[3] == "serve" || f[3] == "run") {
			continue
		}
		pid, err := strconv.Atoi(f[0])
		if err != nil {
			continue
		}
		procs = append(procs, ocProc{pid: pid, tty: f[1]})
		pids = append(pids, f[0])
	}
	if len(procs) == 0 {
		return nil
	}
	cwds := pidCwds(pids)
	for i := range procs {
		procs[i].cwd = cwds[procs[i].pid]
	}
	return procs
}

// pidCwds maps pid -> its working folder with one lsof call.
func pidCwds(pids []string) map[int]string {
	m := map[int]string{}
	out, _ := exec.Command("lsof", "-a", "-d", "cwd", "-Fpn", "-p", strings.Join(pids, ",")).Output()
	pid := 0
	for _, l := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(l, "p"):
			pid, _ = strconv.Atoi(l[1:])
		case strings.HasPrefix(l, "n") && pid != 0:
			m[pid] = l[1:]
		}
	}
	return m
}

// ocSession is one row of opencode's session_v2, with the type of its newest message.
type ocSession struct {
	ID       string `json:"id"`
	Dir      string `json:"directory"`
	Title    string `json:"title"`
	Slug     string `json:"slug"`
	Updated  int64  `json:"time_updated"`
	LastType string `json:"last_type"`
}

// ocQuery runs one read-only query on opencode's database and decodes its rows; nil when the database is
// missing or the query fails.
func ocQuery(sql string, rows any) bool {
	db := opencodeDB()
	if _, err := os.Stat(db); err != nil {
		return false
	}
	out, err := exec.Command("sqlite3", "-readonly", "-json", db, sql).Output()
	if err != nil {
		return false
	}
	if len(strings.TrimSpace(string(out))) == 0 { // sqlite3 -json prints nothing for no rows
		return true
	}
	return json.Unmarshal(out, rows) == nil
}

// loadOpencode: an Agent for every running opencode TUI.
func loadOpencode() []Agent {
	if _, err := os.Stat(opencodeDB()); err != nil { // opencode never ran for this HOME
		return nil
	}
	procs := opencodeProcs()
	if len(procs) == 0 {
		return nil
	}
	var ss []ocSession
	ocQuery(`select s.id, s.directory, coalesce(s.title,'') title, s.slug, s.time_updated,
		coalesce((select type from session_message m where m.session_id = s.id order by seq desc limit 1), '') last_type
		from session_v2 s where s.parent_id is null and s.time_archived is null order by s.time_updated desc`, &ss)
	// shortcut: two TUIs in one folder take that folder's newest sessions newest pid first, and a TUI that
	// resumed an older session shows the newest one; ask opencode's server (service.json) if that gets wrong.
	sort.Slice(procs, func(i, j int) bool { return procs[i].pid > procs[j].pid })
	used := map[string]bool{}
	var out []Agent
	for _, p := range procs {
		a := Agent{SID: "opencode-" + strconv.Itoa(p.pid), Cwd: p.cwd, PID: p.pid, TTY: p.tty, CLI: "opencode"}
		for _, s := range ss {
			if s.Dir != p.cwd || used[s.ID] {
				continue
			}
			used[s.ID] = true
			a.SID, a.Name, a.Since = s.ID, s.Title, time.UnixMilli(s.Updated)
			a.Busy = s.LastType == "user" || s.LastType == "assistant" // the turn ends with an idle message
			if !a.Busy {
				a.State, a.Closed = "done", true // it answered and waits for the next prompt
			}
			if a.Name == "" {
				a.Name = s.Slug
			}
			break
		}
		if a.Name == "" { // no session yet: a TUI that was just opened
			a.Name = filepath.Base(p.cwd)
		}
		a.Name = "oc " + a.Name
		out = append(out, a)
	}
	return out
}

// ocMessage is one user or assistant message of an opencode session.
type ocMessage struct {
	Type    string `json:"type"`
	Created int64  `json:"time_created"`
	Data    string `json:"data"`
}

// readOpencodeLast: the conversation of an opencode session, as the desk shows a Claude Code transcript.
func readOpencodeLast(sid string) Last {
	var l Last
	if !validOCID(sid) {
		return l
	}
	var ms []ocMessage
	ocQuery(`select type, time_created, data from (select * from session_message where session_id = '`+sid+
		`' and type in ('user','assistant') order by seq desc limit `+strconv.Itoa(maxTurns)+`) order by seq`, &ms)
	for _, m := range ms {
		var d struct {
			Text    string `json:"text"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			Model struct {
				ID      string `json:"id"`
				Variant string `json:"variant"`
			} `json:"model"`
		}
		if json.Unmarshal([]byte(m.Data), &d) != nil {
			continue
		}
		at := time.UnixMilli(m.Created)
		if m.Type == "user" {
			if t := strings.TrimSpace(d.Text); t != "" {
				l.Chat = append(l.Chat, Turn{User: true, Text: t, At: at})
			}
			continue
		}
		var parts []string
		for _, c := range d.Content {
			if c.Type == "text" && strings.TrimSpace(c.Text) != "" {
				parts = append(parts, strings.TrimSpace(c.Text))
			}
		}
		if t := strings.Join(parts, "\n\n"); t != "" {
			l.Chat = append(l.Chat, Turn{Text: t, At: at})
			l.Text = t
		}
		if d.Model.ID != "" {
			l.Model, l.Effort = d.Model.ID, d.Model.Variant
		}
	}
	return l
}

// validOCID: an opencode id is safe to put in a query (ses_ and letters, digits, underscores).
func validOCID(id string) bool {
	if !strings.HasPrefix(id, "ses_") {
		return false
	}
	for _, r := range id {
		if !(r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}
