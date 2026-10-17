package main

import (
	_ "embed"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

//go:embed send.js
var sendJS []byte

// sendScript writes the embedded send.js next to the config once per run and returns its path, so the
// binary is self-contained.
func sendScript() string {
	p := filepath.Join(agentHome(), "terminal", "send.js")
	if b, err := os.ReadFile(p); err != nil || string(b) != string(sendJS) {
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		_ = os.WriteFile(p, sendJS, 0o644)
	}
	return p
}

// osa runs send.js with args and returns its one-line answer ("ok", "error: ...", or data).
func osa(args ...string) string {
	out, err := exec.Command("osascript", append([]string{"-l", "JavaScript", sendScript()}, args...)...).CombinedOutput()
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

// terminalTTYs is the set of ttys that are Terminal.app tabs.
func terminalTTYs() map[string]bool {
	m := map[string]bool{}
	for _, l := range strings.Split(osa("ttys"), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "error") {
			m[l] = true
		}
	}
	return m
}

func openPath(cmd, path string) error {
	f := strings.Fields(cmd)
	if len(f) == 0 {
		f = []string{"open"}
	}
	return exec.Command(f[0], append(f[1:], path)...).Start()
}
