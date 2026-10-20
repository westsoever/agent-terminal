package main

// Moving a Terminal session to the background (D76, no-Terminal phase 3, owner decision 1). BG on an idle Terminal
// session with no menu and no draft on its screen types /exit into its tab, waits for its process to end, continues
// it with claude --bg --resume under the same id and name, on the model, effort and permission mode its transcript
// last names, and closes the tab once only the shell is left. BG ALL does it for every idle Terminal session in
// turn. A moved session loses its background shells and monitors, a running /loop, subagents in flight, the
// permissions granted for this session and its scrollback; its next turn starts with a cold prompt cache.

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// exitWait is how long a move waits for the session's process to end after /exit.
const exitWait = 20 * time.Second

// The outside calls of a move; tests replace them.
var (
	moveFn       = moveToBg
	moveScreenFn = screenOf
	moveTypeFn   = sendText
	moveBusyFn   = sessionBusy
	moveGoneFn   = waitGone
	moveCloseFn  = closeTab
)

// closeTab closes a Terminal tab once only the shell runs in it: its window when it is the window's only tab,
// else the shell is told to exit. "ok", "busy" or "error: ...".
func closeTab(tty string) string { return osa("closetab", tty) }

// sessionFile is Claude Code's record of a running session: ~/.claude/sessions/<pid>.json.
func sessionFile(pid int) string {
	return filepath.Join(os.Getenv("HOME"), ".claude", "sessions", strconv.Itoa(pid)+".json")
}

// sessionBusy reads the session's status now, not as the last refresh saw it.
func sessionBusy(pid int) bool {
	b, err := os.ReadFile(sessionFile(pid))
	if err != nil {
		return false
	}
	var cs claudeSession
	return json.Unmarshal(b, &cs) == nil && cs.Status == "busy"
}

// waitGone waits up to d for the session's process to end (its record goes, or the pid is gone).
func waitGone(pid int, d time.Duration) bool {
	for end := time.Now().Add(d); ; time.Sleep(250 * time.Millisecond) {
		if _, err := os.Stat(sessionFile(pid)); os.IsNotExist(err) || syscall.Kill(pid, 0) != nil {
			return true
		}
		if time.Now().After(end) {
			return false
		}
	}
}

// typedDraft: the input box at the bottom of a Claude Code screen holds text the owner has not sent. /exit typed
// after it would be sent as part of that message. Claude Code's own placeholder (Try "…") is no draft.
func typedDraft(screen string) bool {
	lines := strings.Split(strings.TrimRight(screen, "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if !strings.HasPrefix(l, "❯") || i == 0 || !isRule(lines[i-1]) {
			continue
		}
		text := strings.TrimSpace(strings.TrimPrefix(l, "❯"))
		if text != "" {
			return !strings.HasPrefix(text, `Try "`)
		}
		for _, n := range lines[i+1:] {
			if isRule(n) {
				break
			}
			if strings.TrimSpace(n) != "" {
				return true
			}
		}
		return false
	}
	return false
}

var permModeRe = regexp.MustCompile(`"permissionMode":"([A-Za-z]+)"`)

// lastPermMode is the permission mode the transcript names last, ” when none.
func lastPermMode(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	mode := ""
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 64*1024*1024)
	for sc.Scan() {
		if m := permModeRe.FindSubmatch(sc.Bytes()); m != nil {
			mode = string(m[1])
		}
	}
	return mode
}

// moveToBg moves one Terminal session to the background and returns its job. The error is why it did not move:
// "busy", "menu", "draft", or what went wrong. Nothing is typed unless the session is idle with an empty box.
func moveToBg(a Agent, o nwOpts) (string, error) {
	switch {
	case a.Bg:
		return "", errors.New("already in the background")
	case !a.InTerminal:
		return "", errors.New("not in a Terminal tab")
	case a.CLI != "":
		return "", errors.New("not a Claude Code session")
	case a.Busy:
		return "", errors.New("busy")
	}
	screen := moveScreenFn(a.TTY)
	switch {
	case strings.HasPrefix(screen, "error"):
		return "", errors.New(screen)
	case len(parsePrompt(screen).Options) > 0:
		return "", errors.New("menu")
	case typedDraft(screen):
		return "", errors.New("draft")
	case moveBusyFn(a.PID):
		return "", errors.New("busy")
	}
	if res := moveTypeFn(a.TTY, "/exit"); res != "ok" {
		return "", errors.New(res)
	}
	if !moveGoneFn(a.PID, exitWait) {
		return "", errors.New("did not end " + exitWait.String() + " after /exit; its tab shows why")
	}
	if a.Name != filepath.Base(a.Cwd)+" "+short(a.SID) { // a name of its own, not the one agterm made up
		o.Name = a.Name
	}
	if l := readLast(a.Transcript, a.Cwd); l.Model != "" { // the model it ran on, not keys.toml's
		o.Model, o.Effort = l.Model, l.Effort
	}
	if p := lastPermMode(a.Transcript); p != "" {
		o.Perm = p
	}
	job, err := bgResume(a.Cwd, a.SID, o)
	if err != nil {
		return "", errors.New(err.Error() + " (claude --resume " + a.SID + " opens it by hand)")
	}
	moveCloseFn(a.TTY)
	return job, nil
}

// bgCommand is BG (the selected agent) and BG ALL (every idle Terminal agent). The moves run one after the other
// in the command, never in Update.
func (m *model) bgCommand(arg string) tea.Cmd {
	o := parseNW("", m.cfg)
	if !strings.EqualFold(strings.TrimSpace(arg), "ALL") {
		a := m.sel()
		if a == nil || !a.InTerminal || a.Bg {
			m.setErr("BG moves a Terminal session to the background; select one first (BG ALL moves every idle one)")
			return nil
		}
		ag := *a
		m.setStatus("moving " + ag.Name + " to the background…")
		return func() tea.Msg {
			job, err := moveFn(ag, o)
			if err != nil {
				return sentMsg{"", ag.Name, "move", "not moved: " + err.Error()}
			}
			return statusMsg("moved " + ag.Name + " to the background (" + job + ") · g opens its screen")
		}
	}
	var todo []Agent
	var skipped []string
	for _, a := range m.agents {
		switch {
		case !a.InTerminal || a.Bg || a.CLI != "":
		case a.Busy:
			skipped = append(skipped, a.Name+" (busy)")
		case len(m.prompts[a.SID].Options) > 0:
			skipped = append(skipped, a.Name+" (menu)")
		default:
			todo = append(todo, a)
		}
	}
	m.setStatus("moving " + strconv.Itoa(len(todo)) + " to the background…")
	return func() tea.Msg {
		n := 0
		for _, a := range todo {
			if _, err := moveFn(a, o); err != nil {
				skipped = append(skipped, a.Name+" ("+err.Error()+")")
				continue
			}
			n++
		}
		s := "moved " + strconv.Itoa(n) + " to the background"
		if len(skipped) > 0 {
			s += " · skipped: " + strings.Join(skipped, ", ")
		}
		return statusMsg(s)
	}
}
