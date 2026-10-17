package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

var askColourToppings = []AskQuestion{
	{Header: "Colour", Text: "Which colour?", Options: []AskOption{{Label: "Red", Rec: true}, {Label: "Blue"}}},
	{Header: "Toppings", Text: "Which toppings?", Multi: true, Options: []AskOption{{Label: "Cheese", Rec: true}, {Label: "Ham"}, {Label: "Egg", Rec: true}}},
}

func TestNewAskOption(t *testing.T) {
	for in, want := range map[string]AskOption{
		"Red (Recommended)":   {Label: "Red", Rec: true},
		"Red (recommended)  ": {Label: "Red", Rec: true},
		"Blue":                {Label: "Blue"},
		"(Recommended) later": {Label: "(Recommended) later"},
	} {
		if got := newAskOption(in, ""); got != want {
			t.Errorf("newAskOption(%q) = %+v, want %+v", in, got, want)
		}
	}
}

// The keys that Claude Code's menu takes (checked against a live session): a number for a single-choice question, the
// numbers then → for a multi-choice one, 1 on the review screen; one single-choice question alone has no review.
func TestQuickKeys(t *testing.T) {
	join := func(k []string) string { return strings.Join(k, " ") }
	got, err := quickKeys(askColourToppings, 0)
	if err != nil || join(got) != "1 pause 1 3 pause right pause 1" {
		t.Fatalf("two questions: %v %v", got, err)
	}
	if got, _ = quickKeys(askColourToppings, 1); join(got) != "1 3 pause right pause 1" {
		t.Errorf("from question 2: %v", got)
	}
	if got, _ = quickKeys(askColourToppings, 2); join(got) != "1" {
		t.Errorf("on the review screen: %v", got)
	}
	if got, _ = quickKeys(askColourToppings[:1], 0); join(got) != "1" {
		t.Errorf("one single-choice question: %v", got)
	}
	if got, _ = quickKeys(askColourToppings[1:], 0); join(got) != "1 3 pause right pause 1" {
		t.Errorf("one multi-choice question: %v", got)
	}
	// no guessing: a question without a recommendation stops it and says which
	qs := []AskQuestion{askColourToppings[0], {Header: "Size", Text: "Which size?", Options: []AskOption{{Label: "S"}, {Label: "L"}}}}
	if got, err = quickKeys(qs, 0); err == nil || !strings.Contains(err.Error(), "Size has no recommended answer") || got != nil {
		t.Errorf("no recommendation: %v %v", got, err)
	}
}

func TestScreenStart(t *testing.T) {
	tab := func(a, b string) []string {
		return []string{"←  " + a + " Colour  " + b + " Toppings  ✔ Submit  →", "Which?"}
	}
	for _, c := range []struct {
		lines []string
		want  int
	}{
		{tab("☐", "☐"), 0},
		{tab("☒", "☐"), 1},
		{tab("☒", "☒"), 2},
		{[]string{"←  ☒ Colour  ☒ Toppings  ✔ Submit  →", "Review your answers"}, 2},
		{[]string{" ☐ Colour", "Which?"}, 0},
	} {
		if got := screenStart(askColourToppings, c.lines); got != c.want {
			t.Errorf("screenStart(%q) = %d, want %d", c.lines, got, c.want)
		}
	}
}

// A background agent's menu is drawn from the transcript and the keys sent: the same lines as a real screen.
func TestAskProgMenu(t *testing.T) {
	p := &askProg{}
	p.reset("t1", 2)
	pr := p.screen(askColourToppings)
	if pr.Lines[0] != "←  ☐ Colour  ☐ Toppings  ✔ Submit  →" || pr.Lines[1] != "Which colour?" || pr.TypeOpt != 3 || len(pr.Options) != 4 {
		t.Fatalf("first question: %+v", pr)
	}
	if pr.Options[0] != "Red (Recommended)" {
		t.Errorf("options %q", pr.Options)
	}
	p.press(askColourToppings, "1") // Red: on to the toppings
	p.press(askColourToppings, "1") // tick Cheese
	p.press(askColourToppings, "3") // tick Egg
	p.press(askColourToppings, "1") // untick Cheese
	pr = p.screen(askColourToppings)
	if p.cur != 1 || pr.Lines[0] != "←  ☒ Colour  ☒ Toppings  ✔ Submit  →" || !strings.Contains(strings.Join(pr.Lines, "\n"), "[✔] Egg") ||
		!strings.Contains(strings.Join(pr.Lines, "\n"), "[ ] Cheese (Recommended)") {
		t.Fatalf("toppings: cur %d\n%s", p.cur, strings.Join(pr.Lines, "\n"))
	}
	p.press(askColourToppings, "right")
	pr = p.screen(askColourToppings)
	review := strings.Join(pr.Lines, "\n")
	if p.cur != 2 || !strings.Contains(review, "Review your answers") || !strings.Contains(review, "→ Red") || !strings.Contains(review, "→ Egg") ||
		pr.Options[0] != "Submit answers" {
		t.Fatalf("review: cur %d\n%s", p.cur, review)
	}
	if p.press(askColourToppings, "1"); !p.done {
		t.Error("1 on the review screen did not finish the menu")
	}
	// one single-choice question: its number submits
	q := &askProg{}
	q.reset("t2", 1)
	q.press(askColourToppings[:1], "2")
	if !q.done {
		t.Error("a lone single-choice question did not finish on its number")
	}
}

const askLineTwo = `{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu9","name":"AskUserQuestion","input":{"questions":[` +
	`{"question":"Which colour?","header":"Colour","multiSelect":false,"options":[{"label":"Red (Recommended)","description":"warm"},{"label":"Blue","description":"cool"}]},` +
	`{"question":"Which toppings?","header":"Toppings","multiSelect":true,"options":[{"label":"Cheese (Recommended)","description":"c"},{"label":"Ham","description":"h"}]}]}}]}}`

func TestReadLastAskQuestions(t *testing.T) {
	l := readLast(writeTranscript(t, askLineTwo), "/")
	if len(l.Ask) != 2 || l.AskID != "tu9" || l.Ask[0].Header != "Colour" || l.Ask[0].Options[0].Label != "Red" || !l.Ask[0].Options[0].Rec ||
		l.Ask[0].Options[0].Desc != "warm" || !l.Ask[1].Multi || l.Ask[1].Options[1].Rec {
		t.Fatalf("ask = %+v", l.Ask)
	}
	if askRecommendation(l.Ask[1]) != "Cheese" {
		t.Errorf("recommendation %q", askRecommendation(l.Ask[1]))
	}
}

// A background agent with an open question is a waiting agent with a menu, and the panel lists its recommendations.
func TestBackgroundAskInPanel(t *testing.T) {
	m := newModel()
	m.w, m.h = 160, 44
	tr := writeTranscript(t, askLineTwo)
	m.agents = []Agent{{SID: "b1", Name: "bgq", Cwd: "/tmp", Bg: true, Job: "b1", Busy: true, Transcript: tr}}
	m.selSID = "b1"
	m.applyPrompts()
	if !m.agents[0].Asking || m.agents[0].Group() != 0 {
		t.Fatalf("not waiting: %+v", m.agents[0])
	}
	v := escRe.ReplaceAllString(m.View(), "")
	for _, want := range []string{"THE AGENT ASKS", "Which colour?", "1 Red (Recommended)", "RECOMMENDED", "★ Colour", "★ Toppings", "quick approve: take the ★ answers"} {
		if !strings.Contains(v, want) {
			t.Errorf("view lacks %q", want)
		}
	}
	// the number key moves the menu on: question 2 shows next
	m.answer(1)
	m.applyPrompts()
	if !strings.Contains(strings.Join(m.prompts["b1"].Lines, "\n"), "Which toppings?") {
		t.Errorf("after 1: %q", m.prompts["b1"].Lines)
	}
	// quick approve sends the rest: toppings from the second question on
	cmd := m.quickApprove()
	if cmd == nil || !m.askProg["b1"].done {
		t.Fatalf("quick approve: cmd %v", cmd != nil)
	}
	if _, still := m.prompts["b1"]; still {
		t.Error("the menu stays after a quick approve")
	}
}

// A question with no recommendation: the panel says so and the key refuses.
func TestQuickApproveRefuses(t *testing.T) {
	noRec := strings.ReplaceAll(askLineTwo, " (Recommended)", "")
	m := newModel()
	m.w, m.h = 140, 40
	m.agents = []Agent{{SID: "b1", Name: "bgq", Cwd: "/tmp", Bg: true, Job: "b1", Busy: true, Transcript: writeTranscript(t, noRec)}}
	m.selSID = "b1"
	m.applyPrompts()
	if cmd := m.quickApprove(); cmd != nil || !m.statusErr || !strings.Contains(m.status, "Colour has no recommended answer") {
		t.Fatalf("status %q err %v", m.status, m.statusErr)
	}
	if v := escRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "quick approve can't run: Colour has no recommendation") {
		t.Error("the panel does not say why")
	}
}

// Live: a real background session asks two questions; quick approve answers both with the recommendations.
// KACHING_LIVE_BG=1 runs it (it uses the owner's Claude account, haiku).
func TestQuickApproveLive(t *testing.T) {
	if os.Getenv("KACHING_LIVE_BG") == "" {
		t.Skip("KACHING_LIVE_BG=1 runs it")
	}
	job, err := bgStart(os.Getenv("HOME"), "Use the AskUserQuestion tool exactly once with two questions. Q1 (header Colour, single select): 'Which colour?' with options 'Red (Recommended)' and 'Blue'. Q2 (header Toppings, multiSelect true): 'Which toppings?' with options 'Cheese (Recommended)', 'Ham', 'Egg (Recommended)'. After I answer, reply with just my two answers.")
	if err != nil {
		t.Fatal(err)
	}
	defer exec.Command(claudeBin(), "rm", job).Run()
	defer bgStop(job)
	m := newModel()
	var a *Agent
	for i := 0; i < 90 && a == nil; i++ {
		time.Sleep(500 * time.Millisecond)
		m.refresh()
		for j := range m.agents {
			if m.agents[j].Bg && m.agents[j].Job == job && len(m.last(&m.agents[j]).Ask) == 2 {
				a = &m.agents[j]
			}
		}
	}
	if a == nil {
		t.Fatal("the question never showed")
	}
	m.selSID = a.SID
	cmd := m.quickApprove()
	if cmd == nil {
		t.Fatalf("no command: %s", m.status)
	}
	if msg := cmd().(sentMsg); msg.res != "ok" {
		t.Fatal(msg.res)
	}
	for i := 0; i < 60; i++ {
		time.Sleep(500 * time.Millisecond)
		b, _ := os.ReadFile(a.Transcript)
		s := string(b)
		if strings.Contains(s, `Which colour?\"=\"Red (Recommended)\"`) && strings.Contains(s, `Which toppings?\"=\"Cheese (Recommended), Egg (Recommended)\"`) {
			return
		}
	}
	t.Fatal("the recommended answers did not reach the session")
}
