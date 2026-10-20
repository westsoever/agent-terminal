package main

import (
	"context"
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

//go:embed send.js
var sendJS []byte

var sendOnce sync.Once

// sendScript writes the embedded send.js next to the config once per run and returns its path, so the
// binary is self-contained. Written to a temp file and renamed, so a parallel osascript never runs half of it.
func sendScript() string {
	p := filepath.Join(agentHome(), "terminal", "send.js")
	sendOnce.Do(func() {
		if b, err := os.ReadFile(p); err == nil && string(b) == string(sendJS) {
			return
		}
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		if os.WriteFile(p+".tmp", sendJS, 0o644) == nil {
			_ = os.Rename(p+".tmp", p)
		}
	})
	return p
}

// cmdCtx is exec.CommandContext with a WaitDelay: a leftover child (ssh, git-remote-https) holding the pipe
// must not keep the call waiting past the kill.
func cmdCtx(ctx context.Context, name string, args ...string) *exec.Cmd {
	c := exec.CommandContext(ctx, name, args...)
	c.WaitDelay = 2 * time.Second
	return c
}

// runFor runs a command for at most d, so a hung osascript, keychain dialog or `claude logs` can't pile up a
// new process every tick. combined adds stderr to the output.
func runFor(d time.Duration, combined bool, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	c := cmdCtx(ctx, name, args...)
	run := c.Output
	if combined {
		run = c.CombinedOutput
	}
	out, err := run()
	if ctx.Err() != nil {
		return out, fmt.Errorf("timeout after %s", d)
	}
	return out, err
}

// osa runs send.js with args and returns its one-line answer ("ok", "error: ...", or data). Typing waits up
// to ~5s inside send.js for the text to leave the input box, so it gets longer than the reads.
func osa(args ...string) string {
	d := 5 * time.Second
	if len(args) > 0 && (args[0] == "text" || args[0] == "keys" || args[0] == "answer") {
		d = 15 * time.Second
	}
	out, err := runFor(d, true, "osascript", append([]string{"-l", "JavaScript", sendScript()}, args...)...)
	if err != nil && strings.HasPrefix(err.Error(), "timeout") {
		return "error: " + err.Error()
	}
	s := strings.TrimSpace(string(out))
	if err != nil && s == "" {
		return "error: " + err.Error()
	}
	return s
}

func sendText(tty, text string) string { return osa("text", tty, text) }
func sendKeys(tty string, keys ...string) string {
	return osa(append([]string{"keys", tty}, keys...)...)
}
func raiseTab(tty string) string { return osa("raise", tty) }
func screenOf(tty string) string { return osa("screen", tty) }
func answerTyped(tty string, n int, text string) string {
	return osa("answer", tty, strconv.Itoa(n), text)
}

// tabPos is where a tty sits in Terminal: its window and its tab's place in that window (1-based).
type tabPos struct{ win, tab int }

// terminalTabs: every Terminal.app tab by tty.
func terminalTabs() map[string]tabPos {
	m := map[string]tabPos{}
	for _, l := range strings.Split(osa("tabs"), "\n") {
		f := strings.Fields(l)
		if len(f) != 3 || strings.HasPrefix(l, "error") {
			continue
		}
		w, _ := strconv.Atoi(f[1])
		t, _ := strconv.Atoi(f[2])
		m[f[0]] = tabPos{w, t}
	}
	return m
}

// tabGroups: the macOS window-tab bars of Terminal, each as the session names of its tabs in order. A tab's
// title is "<folder> — <spinner> <session name> — <process>"; the name is its middle part without the spinner.
func tabGroups() [][]string {
	var out [][]string
	for _, l := range strings.Split(osa("tabgroups"), "\n") {
		if l == "" || strings.HasPrefix(l, "error") {
			continue
		}
		var names []string
		for _, title := range strings.Split(l, "\t") {
			names = append(names, titleName(title))
		}
		out = append(out, names)
	}
	return out
}

func titleName(title string) string {
	parts := strings.Split(title, " — ")
	if len(parts) < 2 {
		return ""
	}
	n := strings.TrimSpace(parts[1])
	if r := []rune(n); len(r) > 2 && !unicode.IsLetter(r[0]) && !unicode.IsDigit(r[0]) && r[1] == ' ' {
		n = string(r[2:]) // the spinner Claude Code puts in front of the name
	}
	return n
}

func openPath(cmd, path string) error {
	f := strings.Fields(cmd)
	if len(f) == 0 {
		f = []string{"open"}
	}
	return exec.Command(f[0], append(f[1:], path)...).Start()
}
