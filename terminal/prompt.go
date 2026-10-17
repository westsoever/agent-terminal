package main

import (
	"regexp"
	"strconv"
	"strings"
)

// Prompt is a menu the agent shows on its screen right now: an AskUserQuestion (one question or several, with
// its review step), a plan approval, a permission or trust prompt. Read from the Terminal tab itself, so kaching
// shows exactly what the agent shows, whatever produced it.
type Prompt struct {
	Lines   []string // the prompt as on screen, rule lines left out
	Options []string // option n is Options[n-1]
	TypeOpt int      // the "Type something." option (1-based), 0 when none
}

var (
	optRe  = regexp.MustCompile(`^\s*(❯\s*)?(\d{1,2})\.\s+(.+?)\s*$`)
	hintRe = regexp.MustCompile(`(?i)enter to |esc to |to navigate|tab/arrow`)
)

func isRule(l string) bool {
	l = strings.TrimSpace(l)
	return strings.HasPrefix(l, "────────") || strings.HasPrefix(l, "▔▔▔▔▔▔▔▔")
}

// parsePrompt finds the menu at the bottom of a screen. It counts only when an option carries the ❯ cursor and
// nothing but rules, hints and blank lines follow the last option: a numbered list inside the agent's message,
// or the empty input line, is not a menu.
func parsePrompt(screen string) Prompt {
	lines := strings.Split(strings.TrimRight(screen, "\n"), "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " \t")
	}
	last := -1
	for i := len(lines) - 1; i >= 0; i-- {
		l := lines[i]
		if optRe.MatchString(l) {
			last = i
			break
		}
		if strings.TrimSpace(l) == "" || isRule(l) || hintRe.MatchString(l) {
			continue
		}
		return Prompt{} // something else is the last thing on screen
	}
	if last < 0 {
		return Prompt{}
	}
	first := -1 // option 1 of this menu
	for i := last; i >= 0 && last-i < 60; i-- {
		if m := optRe.FindStringSubmatch(lines[i]); m != nil && m[2] == "1" {
			first = i
			break
		}
	}
	if first < 0 {
		return Prompt{}
	}
	start := 0
	for i := first - 1; i >= 0; i-- {
		if isRule(lines[i]) {
			start = i + 1
			break
		}
	}
	end := len(lines) - 1
	for end > last && (strings.TrimSpace(lines[end]) == "" || isRule(lines[end])) {
		end--
	}
	var p Prompt
	cursor := false
	for _, l := range lines[start : end+1] {
		if isRule(l) {
			continue
		}
		p.Lines = append(p.Lines, l)
		if m := optRe.FindStringSubmatch(l); m != nil {
			n, _ := strconv.Atoi(m[2])
			if n != len(p.Options)+1 {
				continue // a number inside the question text, not the next option
			}
			p.Options = append(p.Options, m[3])
			if m[1] != "" {
				cursor = true
			}
			if strings.HasPrefix(m[3], "Type something") {
				p.TypeOpt = n
			}
		}
	}
	if !cursor || len(p.Options) == 0 {
		return Prompt{}
	}
	if len(p.Lines) > 18 {
		p.Lines = p.Lines[:18]
	}
	return p
}
