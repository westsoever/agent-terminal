package main

// Background agents: sessions that Claude Code runs without a window (`claude --bg`, listed by `claude agents`).
// /NW starts one. Kaching sends them text the way a person would: it opens `claude attach <id>` in a pty of its
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

	"github.com/creack/pty"
)

// claudeBin: the claude CLI. Kaching can start from Raycast with a short PATH, so the usual places are tried too.
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

// bgStart starts a background session in dir with prompt as its first message. It returns the session's
// short id, or an error with claude's own words (for example, a folder that is not trusted yet).
func bgStart(dir, prompt string) (string, error) {
	cmd := exec.Command(claudeBin(), "--bg", prompt)
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

// bgAttachWindow opens a new Terminal window attached to the session, for the owner to type in it.
func bgAttachWindow(job string) string {
	script := `tell application "Terminal"
	activate
	do script "` + claudeBin() + ` attach ` + job + `"
end tell`
	if out, err := exec.Command("osascript", "-e", script).CombinedOutput(); err != nil {
		return "error: " + firstLine(strings.TrimSpace(string(out)))
	}
	return "ok"
}

func firstLine(t string) string {
	t, _, _ = strings.Cut(t, "\n")
	return t
}

// resolveDir: the folder for /NW. Empty: the selected agent's folder, else home. A path (/..., ~/...), a folder
// in ~/bbq, or the folder of an agent whose name starts with arg. ” when none is found.
func (m *model) resolveDir(arg string) string {
	home := os.Getenv("HOME")
	arg = strings.TrimSpace(arg)
	if arg == "" {
		if a := m.sel(); a != nil && dirExists(a.Cwd) {
			return a.Cwd
		}
		return home
	}
	switch {
	case arg == "~":
		return home
	case strings.HasPrefix(arg, "~/"):
		arg = filepath.Join(home, arg[2:])
	}
	if filepath.IsAbs(arg) {
		if dirExists(arg) {
			return filepath.Clean(arg)
		}
		return ""
	}
	if p := filepath.Join(home, "bbq", arg); dirExists(p) {
		return p
	}
	for _, a := range m.agents {
		if strings.HasPrefix(strings.ToLower(a.Name), strings.ToLower(arg)) && dirExists(a.Cwd) {
			return a.Cwd
		}
	}
	return ""
}
