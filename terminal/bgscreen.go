package main

// The screen of a background agent, rebuilt from `claude logs <id>` (its recent terminal output) with a terminal
// emulator. Nothing attaches to the session, so nothing about it changes: the same text parsePrompt reads from a
// Terminal tab, whatever menu the agent shows (a question, an approval, "Switch model?").

import (
	"io"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/x/vt"
)

var (
	cupRe  = regexp.MustCompile(`\x1b\[(\d+);\d+[Hf]`)
	ruleRe = regexp.MustCompile(`[─━▔]{20,}`)
)

// logSize guesses the pty size the output was drawn for: the width is the last rule Claude Code drew (it
// draws them edge to edge), the height the lowest row it addressed. A pty nobody attached to has no other mark.
func logSize(raw []byte) (w, h int) {
	w, h = 120, 50
	if rules := ruleRe.FindAllString(string(raw), -1); len(rules) > 0 { // the last one: the size it has now
		if n := len([]rune(rules[len(rules)-1])); n >= 40 && n <= 400 {
			w = n
		}
	}
	rows := 0
	for _, m := range cupRe.FindAllSubmatch(raw, -1) {
		if n, _ := strconv.Atoi(string(m[1])); n > rows && n < 400 {
			rows = n
		}
	}
	if rows >= 24 {
		h = rows
	}
	return
}

// screenFromLog replays terminal output into an emulator and returns the screen's lines.
func screenFromLog(raw []byte) []string {
	w, h := logSize(raw)
	em := vt.NewEmulator(w, h)
	go io.Copy(io.Discard, em) // the emulator answers the queries in the stream; nobody needs the answers
	defer em.Close()
	done := make(chan struct{})
	go func() { _, _ = em.Write(raw); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
	return strings.Split(em.String(), "\n")
}

// bgScreen is the screen of the background agent job as text, "" when it can't be read.
func bgScreen(job string) string {
	out, err := exec.Command(claudeBin(), "logs", job).Output()
	if err != nil && len(out) == 0 {
		return ""
	}
	return strings.Join(screenFromLog(out), "\n")
}
