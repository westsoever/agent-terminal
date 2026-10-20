package main

// Background agents: sessions that Claude Code runs without a window (`claude --bg`, listed by `claude agents`).
// /NW starts one. Agent Terminal sends them text the way a person would: it opens `claude attach <id>` in a pty of its
// own, pastes the text, pushes Enter and closes the attach client. The session keeps running.

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/creack/pty"
)

// claudeBin: the claude CLI. Agent Terminal can start from Raycast with a short PATH, so the usual places are tried too.
func claudeBin() string {
	if p, err := exec.LookPath("claude"); err == nil {
		return p
	}
	home := os.Getenv("HOME")
	for _, p := range []string{filepath.Join(home, ".local", "bin", "claude"), filepath.Join(home, ".claude", "local", "claude"),
		"/opt/homebrew/bin/claude", "/usr/local/bin/claude"} {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return "claude"
}

// bgKeys: the bytes a terminal sends for the key names that deliver uses.
var bgKeys = map[string]string{
	"enter": "\r", "left": "\x1b[D", "right": "\x1b[C", "up": "\x1b[A", "down": "\x1b[B", "tab": "\t", "esc": "\x1b",
}

// bgStep is one thing a person does in the attached session: press a key, paste text, wait a moment.
type bgStep struct {
	key, text string
	pause     bool
}

func bgKey(k string) bgStep  { return bgStep{key: k} }
func bgText(t string) bgStep { return bgStep{text: t} }
func bgPause() bgStep        { return bgStep{pause: true} }

// bgSend types text (as one paste, then Enter) or keys into the background session job. "ok" or "error: ...".
func bgSend(job, text string, keys []string) string {
	if keys == nil {
		return bgSteps(job, bgText(text), bgKey("enter"))
	}
	var steps []bgStep
	for _, k := range keys {
		if k == askKeysPause {
			steps = append(steps, bgPause())
			continue
		}
		steps = append(steps, bgKey(k))
	}
	return bgSteps(job, steps...)
}

// bgSteps attaches to the background session job in a pty of its own, does the steps and closes the attach again.
func bgSteps(job string, steps ...bgStep) string {
	cmd := exec.Command(claudeBin(), "attach", job)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 50, Cols: 160})
	if err != nil {
		return "error: " + err.Error()
	}
	defer f.Close()
	var mu sync.Mutex
	var out bytes.Buffer
	lastRead := time.Now()
	exited := make(chan struct{})
	go func() {
		buf := make([]byte, 32<<10)
		for {
			n, err := f.Read(buf)
			mu.Lock()
			out.Write(buf[:n])
			if n > 0 {
				lastRead = time.Now()
			}
			mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	go func() { _ = cmd.Wait(); close(exited) }()
	stop := func() {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-exited:
		case <-time.After(time.Second):
			_ = cmd.Process.Kill()
		}
	}
	// ready: it drew the session and then went quiet for a moment (at most 8 s)
	deadline := time.Now().Add(8 * time.Second)
	for {
		select {
		case <-exited:
			mu.Lock()
			tail := lastLine(out.String())
			mu.Unlock()
			return "error: claude attach ended: " + tail
		case <-time.After(100 * time.Millisecond):
		}
		mu.Lock()
		ready := out.Len() > 0 && time.Since(lastRead) > 400*time.Millisecond
		mu.Unlock()
		if ready || time.Now().After(deadline) {
			break
		}
	}
	for _, st := range steps {
		switch {
		case st.pause:
			time.Sleep(350 * time.Millisecond)
		case st.text != "":
			_, _ = f.Write([]byte("\x1b[200~" + st.text + "\x1b[201~"))
			time.Sleep(300 * time.Millisecond)
		default:
			b, ok := bgKeys[st.key]
			if !ok {
				b = st.key // a digit or a letter
			}
			_, _ = f.Write([]byte(b))
			time.Sleep(150 * time.Millisecond)
		}
	}
	time.Sleep(800 * time.Millisecond)
	stop()
	return "ok"
}

var escRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

// lastLine: the last line of terminal output that has text, without its escape codes.
func lastLine(t string) string {
	lines := strings.Split(escRe.ReplaceAllString(t, ""), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return "(no output)"
}

var bgStartedRe = regexp.MustCompile(`backgrounded\s+·\s+([0-9a-f]+)`)

// nwOpts is how /NW starts a background agent: its folder and, when set, the model, effort and permission mode
// (the claude flags --model, --effort and --permission-mode). Unset ones are left to Claude Code's own defaults.
type nwOpts struct {
	Dir, Model, Effort, Perm string
	Name                     string // the session's name in the list ("" for Claude Code's own)
}

var (
	nwModels  = map[string]bool{"opus": true, "sonnet": true, "haiku": true, "fable": true}
	nwEfforts = map[string]bool{"low": true, "medium": true, "high": true, "xhigh": true, "max": true}
	// nwPerms: the words /NW takes for the permission modes, and the mode each stands for
	nwPerms = map[string]string{"plan": "plan", "auto": "auto", "bypass": "bypassPermissions", "accept": "acceptEdits",
		"manual": "manual", "dontask": "dontAsk"}
)

// parseNW splits the words after /NW: model, effort and permission words are picked out wherever they stand; the
// rest, in order, is the folder. keys.toml's nw_model, nw_effort and nw_permission fill what the words leave open.
func parseNW(arg string, cfg Config) nwOpts {
	o := nwOpts{Model: cfg.NWModel, Effort: cfg.NWEffort, Perm: cfg.NWPerm}
	if p, ok := nwPerms[strings.ToLower(o.Perm)]; ok {
		o.Perm = p
	}
	var dir []string
	for _, w := range strings.Fields(arg) {
		lw := strings.ToLower(w)
		switch {
		case nwModels[lw]:
			o.Model = lw
		case strings.HasPrefix(lw, "claude-"):
			o.Model = w
		case nwEfforts[lw]:
			o.Effort = lw
		case nwPerms[lw] != "":
			o.Perm = nwPerms[lw]
		default:
			dir = append(dir, w)
		}
	}
	o.Dir = strings.Join(dir, " ")
	return o
}

// summary is the options as the command line shows them: "sonnet · high".
func (o nwOpts) summary() string {
	var parts []string
	for _, p := range []string{o.Model, o.Effort, o.Perm} {
		if p != "" {
			parts = append(parts, p)
		}
	}
	return strings.Join(parts, " · ")
}

// args are the claude flags for the options; the prompt follows after "--", so it may start with "/" or "-".
func (o nwOpts) args(prompt string) []string {
	a := []string{"--bg"}
	if o.Name != "" {
		a = append(a, "-n", o.Name)
	}
	if o.Model != "" {
		a = append(a, "--model", o.Model)
	}
	if o.Effort != "" {
		a = append(a, "--effort", o.Effort)
	}
	if o.Perm != "" {
		a = append(a, "--permission-mode", o.Perm)
	}
	return append(a, "--", prompt)
}

// bgStart starts a background session in o.Dir with prompt as its first message. It returns the session's
// short id, or an error with claude's own words (for example, a folder that is not trusted yet).
func bgStart(o nwOpts, prompt string) (string, error) {
	dir := o.Dir
	cmd := exec.Command(claudeBin(), o.args(prompt)...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if m := bgStartedRe.FindStringSubmatch(string(out)); m != nil {
		return m[1], nil
	}
	msg := strings.TrimSpace(escRe.ReplaceAllString(string(out), ""))
	if msg == "" && err != nil {
		msg = err.Error()
	}
	return "", errors.New(firstLine(msg))
}

// bgStop stops a background session; its conversation stays (claude --resume opens it again).
func bgStop(job string) string {
	out, err := exec.Command(claudeBin(), "stop", job).CombinedOutput()
	if err != nil {
		return "error: " + firstLine(strings.TrimSpace(string(out)))
	}
	return "ok"
}

// shortWindow opens the session's own screen in a short-lived Terminal window: claude attach, which ctrl+z ends
// (the session keeps running), and then the window closes (D74). It returns the window's tty.
func shortWindow(job string) (string, error) {
	return termShort(shQuote(claudeBin()) + " attach " + shQuote(job))
}

// termShort opens a new Terminal window running the shell line cmd and then exit, so nothing is left in it once
// cmd ends and the tick closes it (closeIdleFn): Terminal's own setting may keep it open. Returns its tty (ttys012).
func termShort(cmd string) (string, error) {
	out, err := osascriptRun("tell application \"Terminal\"\n\tactivate\n\tset t to do script " + asString(cmd+"; exit") +
		"\n\treturn tty of t\nend tell")
	s := strings.TrimSpace(string(out))
	if err != nil {
		return "", errors.New(firstLine(s))
	}
	return strings.TrimPrefix(s, "/dev/"), nil
}

func firstLine(t string) string {
	t, _, _ = strings.Cut(t, "\n")
	return t
}

// shortMsg: a short-lived window opened (tty) or did not (err).
type shortMsg struct{ job, tty, err string }

// shortClosedMsg: job -> tty of the short-lived windows that the tick closed.
type shortClosedMsg map[string]string

// openShort shows a background agent's own screen in its short-lived window: a new one, or the open one raised, so
// a session never gets two (D74).
func (m *model) openShort(a Agent) tea.Cmd {
	job, name := a.Job, a.Name
	if tty, ok := m.short[job]; ok {
		if tty == "" {
			return nil // still opening
		}
		return func() tea.Msg { return sentMsg{"", name, "go to its screen", raiseTabFn(tty)} }
	}
	if m.short == nil {
		m.short = map[string]string{}
	}
	m.short[job] = ""
	m.setStatus("opening the screen of " + name + " · ctrl+z there closes it")
	return func() tea.Msg {
		tty, err := shortWindow(job)
		if err != nil {
			return shortMsg{job: job, err: err.Error()}
		}
		return shortMsg{job: job, tty: tty}
	}
}

// closeShorts: on each tick, the short-lived windows whose attach ended are closed.
func (m *model) closeShorts() tea.Cmd {
	open := map[string]string{}
	for job, tty := range m.short {
		if tty != "" {
			open[job] = tty
		}
	}
	if len(open) == 0 {
		return nil
	}
	return func() tea.Msg {
		closed := shortClosedMsg{}
		for job, tty := range open {
			if closeIdleFn(tty) {
				closed[job] = tty
			}
		}
		return closed
	}
}
