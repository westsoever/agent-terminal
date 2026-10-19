package main

import "testing"

const screenMulti = `❯ Use the AskUserQuestion tool once, with two questions: 1) pick a colour (Red, Blue), 2) pick a size.
  Then reply with my two answers.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Colour  ☐ Size  ✔ Submit  →
Which colour do you pick?
❯ 1. Red
     Pick red
  2. Blue
     Pick blue
  3. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this
Enter to select · Tab/Arrow keys to navigate · Esc to cancel
───────────────────────────────────────────────────────────────────────────────────────────────────────────── agentTerminalQ ─
`

const screenReview = `  Then reply with my two answers.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☒ Colour  ☒ Size  ✔ Submit  →
Review your answers
 ● Which colour do you pick?
   → Red
 ● Which size do you pick?
   → Large
Ready to submit your answers?
❯ 1. Submit answers
  2. Cancel
───────────────────────────────────────────────────────────────────────────────────────────────────────────── agentTerminalQ ─
`

const screenIdle = `⏺ PONG2
✻ Baked for 1s · done 15:02
────────────────────────────────────────────────────────────────────────────────────────────────────────── agentTerminalTest ─
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [Haiku 5.5] medium  ctx: 6%  5h: 17% (2h17m)  7d: 52%
  ⏵⏵ bypass permissions on (shift+tab to cycle)
`

// A numbered list the agent wrote in its message is not a menu on screen.
const screenListInText = `⏺ Two options:
  1. merge and push
  2. merge only
✻ done
────────────────────────────────────────────────────────────────────────────────────────────────────────── a ─
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  [Haiku 5.5] medium
`

func TestPromptMultiQuestion(t *testing.T) {
	p := parsePrompt(screenMulti)
	if len(p.Options) != 4 || p.Options[0] != "Red" || p.Options[3] != "Chat about this" {
		t.Fatalf("options %q", p.Options)
	}
	if p.TypeOpt != 3 {
		t.Fatalf("type something option %d", p.TypeOpt)
	}
	if p.Lines[0] != "←  ☐ Colour  ☐ Size  ✔ Submit  →" || p.Lines[1] != "Which colour do you pick?" {
		t.Fatalf("lines %q", p.Lines)
	}
	for _, l := range p.Lines {
		if len(l) > 0 && l[0] == 0xe2 && l[2] == 0x80 && l[1] == 0x94 { // no rule lines
			t.Fatalf("rule line kept: %q", l)
		}
	}
}

func TestPromptReview(t *testing.T) {
	p := parsePrompt(screenReview)
	if len(p.Options) != 2 || p.Options[0] != "Submit answers" || p.TypeOpt != 0 {
		t.Fatalf("got %+v", p)
	}
	if p.Lines[1] != "Review your answers" {
		t.Fatalf("lines %q", p.Lines)
	}
}

func TestPromptNone(t *testing.T) {
	if p := parsePrompt(screenIdle); len(p.Options) != 0 {
		t.Fatalf("idle screen gave %+v", p)
	}
	if p := parsePrompt(screenListInText); len(p.Options) != 0 {
		t.Fatalf("a list in the message gave %+v", p)
	}
}
