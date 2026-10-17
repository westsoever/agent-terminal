package main

// Questions an agent asks the owner (the AskUserQuestion tool): read in full from its transcript, so kaching shows
// every question with its recommended answer, takes all recommended answers with one key (quick approve), and
// can show and answer the menu of a background agent, which has no screen kaching can read.
//
// The keys of Claude Code's menu, checked against a live session (2.1.302):
//   - a single-choice question: its number picks the option and moves on to the next question;
//   - a multi-choice question: each number ticks or unticks an option, → moves on;
//   - after the last question comes "Review your answers", where 1 submits;
//   - one single-choice question alone has no review: its number submits at once.

import (
	"fmt"
	"strconv"
	"strings"
)

// AskQuestion is one question of an open AskUserQuestion.
type AskQuestion struct {
	Header, Text string
	Multi        bool
	Options      []AskOption
}

// AskOption is one answer. The agent marks its recommendation by ending the label with "(Recommended)".
type AskOption struct {
	Label, Desc string
	Rec         bool
}

// recSuffix is how an agent marks the answer it recommends.
const recSuffix = "(recommended)"

func newAskOption(label, desc string) AskOption {
	l := strings.TrimSpace(label)
	rec := strings.HasSuffix(strings.ToLower(l), recSuffix)
	if rec {
		l = strings.TrimSpace(l[:len(l)-len(recSuffix)])
	}
	return AskOption{Label: l, Desc: strings.TrimSpace(desc), Rec: rec}
}

// needsReview: the menu ends on the "Review your answers" screen, except for one single-choice question.
func needsReview(qs []AskQuestion) bool {
	return !(len(qs) == 1 && !qs[0].Multi)
}

// askKeysPause is the key name that waits a moment, so the menu has drawn the next question before the next key.
const askKeysPause = "pause"

// quickKeys are the keys that take the recommended answer of every question from question `from` on and submit.
// An error names the question that has no recommendation: quick approve never guesses.
func quickKeys(qs []AskQuestion, from int) ([]string, error) {
	var keys []string
	add := func(k ...string) {
		if len(keys) > 0 {
			keys = append(keys, askKeysPause)
		}
		keys = append(keys, k...)
	}
	for i := from; i < len(qs); i++ {
		q := qs[i]
		var recs []string
		for n, o := range q.Options {
			if !o.Rec {
				continue
			}
			if n >= 9 {
				return nil, fmt.Errorf("%s: the recommended answer is option %d: pick it yourself", askName(q, i), n+1)
			}
			recs = append(recs, strconv.Itoa(n+1))
		}
		if len(recs) == 0 {
			return nil, fmt.Errorf("%s has no recommended answer: pick it yourself", askName(q, i))
		}
		if !q.Multi {
			add(recs[0])
			continue
		}
		add(recs...)
		add("right")
	}
	if from < len(qs) && needsReview(qs) {
		add("1") // Submit answers
	}
	if from >= len(qs) { // already on the review screen
		add("1")
	}
	return keys, nil
}

func askName(q AskQuestion, i int) string {
	if q.Header != "" {
		return q.Header
	}
	return fmt.Sprintf("question %d", i+1)
}

// askRecommendation: the recommended answers of a question, "Red" or "Cheese, Egg"; "" when it has none.
func askRecommendation(q AskQuestion) string {
	var r []string
	for _, o := range q.Options {
		if o.Rec {
			r = append(r, o.Label)
		}
	}
	return strings.Join(r, ", ")
}

// askProg is where a background agent's menu is, as far as kaching can tell: it counts the keys it sent. A
// new question set (another tool call) starts at the first question.
type askProg struct {
	id    string         // the tool call this belongs to
	cur   int            // the question shown; len(qs) is the review screen
	picks []map[int]bool // per question: the options picked (a multi-choice question ticks several)
	done  bool           // the menu was submitted or cancelled
}

func (p *askProg) reset(id string, n int) {
	p.id, p.cur, p.done = id, 0, false
	p.picks = make([]map[int]bool, n)
}

// press moves the menu state by one key, the way Claude Code's menu does.
func (p *askProg) press(qs []AskQuestion, k string) {
	if p.cur >= len(qs) { // the review screen: 1 submits, 2 cancels, ← goes back
		switch k {
		case "left":
			p.cur--
		case "1", "2":
			p.done = true
		}
		return
	}
	q := qs[p.cur]
	switch {
	case k == "left":
		if p.cur > 0 {
			p.cur--
		}
	case k == "right" || k == "tab":
		p.cur++
	case len(k) == 1 && k[0] >= '1' && k[0] <= '9':
		n := int(k[0] - '0')
		if n > len(q.Options) {
			return // "Type something", "Chat about this": kaching does not follow those
		}
		if q.Multi {
			if p.picks[p.cur] == nil {
				p.picks[p.cur] = map[int]bool{}
			}
			p.picks[p.cur][n-1] = !p.picks[p.cur][n-1]
			return
		}
		p.picks[p.cur] = map[int]bool{n - 1: true}
		if !needsReview(qs) {
			p.done = true // one single-choice question: its number submits
			return
		}
		p.cur++
	}
}

// answered: the question has an answer picked.
func (p *askProg) answered(i int) bool {
	for _, on := range p.picks[i] {
		if on {
			return true
		}
	}
	return false
}

// screen draws the menu as Claude Code draws it, in the lines parsePrompt reads from a real screen, so a background
// agent's menu shows in the same panel as the menu of an agent in a Terminal tab.
func (p *askProg) screen(qs []AskQuestion) Prompt {
	var lines []string
	if len(qs) > 1 || qs[0].Multi {
		tab := "←  "
		for i, q := range qs {
			mark := "☐"
			if p.answered(i) {
				mark = "☒"
			}
			tab += mark + " " + askName(q, i) + "  "
		}
		lines = append(lines, tab+"✔ Submit  →")
	} else {
		lines = append(lines, " ☐ "+askName(qs[0], 0))
	}
	var pr Prompt
	if p.cur >= len(qs) {
		lines = append(lines, "Review your answers")
		for i, q := range qs {
			lines = append(lines, " ● "+q.Text)
			var chosen []string
			for n, o := range q.Options {
				if p.picks[i][n] {
					chosen = append(chosen, o.Label)
				}
			}
			if len(chosen) == 0 {
				chosen = []string{"(no answer)"}
			}
			lines = append(lines, "   → "+strings.Join(chosen, ", "))
		}
		lines = append(lines, "Ready to submit your answers?", "❯ 1. Submit answers", "  2. Cancel")
		pr.Options = []string{"Submit answers", "Cancel"}
		pr.Lines = lines
		return pr
	}
	q := qs[p.cur]
	lines = append(lines, q.Text)
	for n, o := range q.Options {
		cursor := "  "
		if n == 0 {
			cursor = "❯ "
		}
		box := ""
		if q.Multi {
			box = "[ ] "
			if p.picks[p.cur][n] {
				box = "[✔] "
			}
		}
		lab := o.Label
		if o.Rec {
			lab += " (Recommended)"
		}
		lines = append(lines, fmt.Sprintf("%s%d. %s%s", cursor, n+1, box, lab))
		if o.Desc != "" {
			lines = append(lines, "     "+o.Desc)
		}
		pr.Options = append(pr.Options, lab)
	}
	lines = append(lines, fmt.Sprintf("  %d. Type something.", len(q.Options)+1), fmt.Sprintf("  %d. Chat about this", len(q.Options)+2))
	pr.Options = append(pr.Options, "Type something.", "Chat about this")
	pr.TypeOpt = len(q.Options) + 1
	pr.Lines = lines
	return pr
}
