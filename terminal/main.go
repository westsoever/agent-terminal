// agterm: the agent terminal. One keyboard-only screen for every Claude Code agent on this Mac.
// Design: docs/superpowers/specs/2026-10-17-agent-terminal-design.md.
//
//	agterm                 open the desk
//	agterm --render WxH    print one frame of the desk at that size and exit (for checks and screenshots)
//	                 --view CODE   picks another view (FL RP RC PR PO PC HELP, or "FIND words": the names and
//	                               text tiers run first)
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// legacyEnv lets a variable under an older name (KACHING_*, before D65; CHING_*, before D35) stand for its
// AGENT_TERMINAL_* name when that one is unset; KACHING_* wins over CHING_*.
func legacyEnv() {
	for _, prefix := range []string{"KACHING_", "CHING_"} {
		for _, kv := range os.Environ() {
			k, v, _ := strings.Cut(kv, "=")
			rest, ok := strings.CutPrefix(k, prefix)
			if !ok {
				continue
			}
			if _, set := os.LookupEnv("AGENT_TERMINAL_" + rest); !set {
				os.Setenv("AGENT_TERMINAL_"+rest, v)
			}
		}
	}
}

func main() {
	legacyEnv()
	render := flag.String("render", "", "print one frame at WxH and exit")
	code := flag.String("view", "", "with --render: the view's code")
	flag.Parse()
	if *render != "" {
		var w, h int
		if _, err := fmt.Sscanf(strings.ToLower(*render), "%dx%d", &w, &h); err != nil {
			fmt.Fprintln(os.Stderr, "--render wants WxH, e.g. 140x40")
			os.Exit(2)
		}
		readOnly = true
		lipgloss.SetColorProfile(termenv.ANSI256)
		m := newModel()
		m.w, m.h = w, h
		m.ttys, m.groups = terminalTabs(), tabGroups()
		m.refresh()
		m.props, m.pc = readProposals(), loadPaperclip()
		m.status = ""
		if *code != "" {
			mm, _ := m.command(*code)
			m = mm.(model)
			if m.view == vFind { // only here: the tiers run in the background in the program
				m = m.findRenderSync()
			}
			if m.view == vPulls { // only here: it asks GitHub
				m.pulls = loadPulls()
			}
			if m.view == vRepos {
				m.repoGH = loadGHRepos()
				m.setRepos()
			}
			if m.view == vPaperclip {
				m.pc = loadPaperclip()
				if it := m.pcSelected(); it != nil {
					m.pcDet[it.ID] = loadPCDetail(it.ID, m.pc.Names)
				}
			}
		}
		fmt.Println(m.View())
		return
	}
	defer removeState()
	if _, err := tea.NewProgram(newModel(), tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "agterm:", err)
		os.Exit(1)
	}
}
