package main

// Every start is a background one (D75, no-Terminal phase 2): FIND r resumes an ended session in the background,
// an empty NW starts an agent and opens its screen, PC t is a background agent with its screen open, a folder
// Claude Code does not trust yet is trusted in a short-lived window, and LOGIN signs in in one.

import (
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// bgResume continues the ended session id in dir in the background, under its own id. Phase 0: the id, the job
// and the name stay, the model and the permission mode don't, so o brings them.
func bgResume(dir, id string, o nwOpts) (string, error) {
	o.Dir, o.Resume = dir, id
	return bgStartFn(o, "")
}

// trustNeeded: Claude Code refused to start because it does not trust the folder yet.
func trustNeeded(err string) bool { return strings.Contains(strings.ToLower(err), "not trusted") }

// trustMsg: a start failed on trust; retry starts it again once the owner trusted dir.
type trustMsg struct {
	dir   string
	retry tea.Cmd
}

// bgStartCmd starts a background agent (o.Resume set: continues one); show opens its screen when it runs. A
// folder that is not trusted yet turns into the trust question instead of an error.
func bgStartCmd(o nwOpts, prompt string, show bool) tea.Cmd {
	var start tea.Cmd
	start = func() tea.Msg {
		job, err := bgStartFn(o, prompt)
		switch {
		case err != nil && trustNeeded(err.Error()):
			return trustMsg{o.Dir, start}
		case err != nil:
			return sentMsg{"", "new agent", "start", "error: " + err.Error()}
		}
		return bgStartedMsg{job, o.Dir, show}
	}
	return start
}

// trustKey answers the trust question: yes opens Claude Code in the folder in a short-lived window, where the
// owner answers its own trust question and leaves with /exit; when that window closes, the start runs again.
func (m *model) trustKey(t trustMsg, yes bool) tea.Cmd {
	m.mode, m.trust = mKeys, nil
	if !yes {
		m.setStatus("not started: " + tildify(t.dir) + " is not trusted")
		return nil
	}
	key := "trust:" + t.dir
	if m.after == nil {
		m.after = map[string]tea.Cmd{}
	}
	m.after[key] = t.retry
	m.setStatus("trust " + tildify(t.dir) + " in the new window, then /exit: the agent starts after")
	line := "cd " + shQuote(t.dir) + " && " + shQuote(claudeBin())
	return m.openShortCmd(key, "trust", func() (string, error) { return termShort(line) })
}

// authMsg: true when Claude Code is logged out.
type authMsg bool

// authCheck asks claude auth status; a timeout or a missing claude says nothing.
func authCheck() tea.Msg {
	_, err := runFor(10*time.Second, true, claudeBin(), "auth", "status")
	_, exited := err.(*exec.ExitError)
	return authMsg(exited)
}
