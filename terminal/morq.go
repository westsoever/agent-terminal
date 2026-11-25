package main

// MQ: morq's view (D85). It replaced RC. The lines come from `morq report` (the proposer, the usage gate, the open
// proposals and the runs it executed); the keys shell out to morq: enter shows a proposal, e queues it (morq runs
// it at once, at any usage reading), x drops it. `MO START` / `MO STOP` (also `MQ START`) turn the 30-minute
// proposer on or off; START also runs a round now.

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

type mqMsg []string

var mqIDRe = regexp.MustCompile(`^P\d+$`)

// morqBin: the installed morq (~/.agent/morq/morq), or $MORQ_BIN.
func morqBin() string {
	if b := os.Getenv("MORQ_BIN"); b != "" {
		return b
	}
	return filepath.Join(os.Getenv("HOME"), ".agent", "morq", "morq")
}

// readMorq: `morq report`, one line each; a missing morq says so instead of an empty view.
func readMorq() []string {
	out, err := exec.Command(morqBin(), "report").Output()
	if err != nil && len(out) == 0 {
		return []string{"morq is not installed or failed: " + morqBin() + " report"}
	}
	return strings.Split(strings.TrimRight(string(out), "\n"), "\n")
}

func (m *model) loadMorq() {
	m.mq = readMorq()
	if m.listSel >= len(m.mq) {
		m.listSel = 0
	}
}

// mqID: the proposal id a report line starts with ("P3  open  ..."), "" for other lines.
func mqID(line string) string {
	if f := strings.Fields(line); len(f) > 0 && mqIDRe.MatchString(f[0]) {
		return f[0]
	}
	return ""
}

// mqOpen: proposals waiting for the owner; the MQ tab turns orange while there are any.
func mqOpen(lines []string) int {
	n := 0
	for _, l := range lines {
		if f := strings.Fields(l); len(f) > 1 && mqIDRe.MatchString(f[0]) && f[1] == "open" {
			n++
		}
	}
	return n
}

func (m model) morqView(h int) []string {
	var items [][]seg
	for _, l := range m.mq {
		st := cGrey
		switch {
		case strings.HasPrefix(l, "MORQ") || strings.HasPrefix(l, "GATE") || strings.HasPrefix(l, "PROPOSALS") ||
			strings.HasPrefix(l, "EXECUTED"):
			st = cWhite
		case mqID(l) != "" && strings.Fields(l)[1] == "open":
			st = cOrange
		}
		items = append(items, []seg{s(l, st)})
	}
	return m.listBox("MORQ   enter show · e execute now (any usage) · x drop · MO START / MO STOP the proposer", items, h,
		"morq has nothing to show yet")
}

// morqKey: the MQ view's own keys. done=false lets the key fall through.
func (m *model) morqKey(ks string) (bool, tea.Cmd) {
	if m.listSel >= len(m.mq) {
		return false, nil
	}
	line := m.mq[m.listSel]
	id := mqID(line)
	switch {
	case ks == "enter" && id != "":
		c := shQuote(morqBin()) + " show " + id + " | less -R" // id matched ^P\d+$: safe in the shell line
		return true, tea.ExecProcess(exec.Command("sh", "-c", c), func(err error) tea.Msg { return execDone{err} })
	case ks == "enter":
		if i := strings.Index(line, "https://"); i >= 0 {
			url := strings.Fields(line[i:])[0]
			openPath("open", url)
			m.setStatus("opened " + url)
		}
		return true, nil
	case (ks == "e" || ks == "x") && id != "":
		verb := map[string]string{"e": "queue", "x": "drop"}[ks]
		out, err := exec.Command(morqBin(), verb, id).CombinedOutput()
		m.loadMorq()
		if msg := strings.TrimSpace(string(out)); err != nil {
			m.setErr(msg)
		} else {
			m.setStatus(msg)
		}
		return true, nil
	}
	return false, nil
}

// morqCommand: MO START, MO STOP (and MQ START / MQ STOP).
func (m model) morqCommand(arg string) (tea.Model, tea.Cmd) {
	out, err := exec.Command(morqBin(), "mo", strings.ToLower(arg)).CombinedOutput()
	m.view, m.zoom, m.listSel = vMorq, false, 0
	m.loadMorq()
	if msg := strings.TrimSpace(string(out)); err != nil {
		m.setErr(msg)
	} else {
		m.setStatus(msg)
	}
	return m, nil
}
