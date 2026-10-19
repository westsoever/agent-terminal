package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-runewidth"
)

// The requests of an issue that agterm answers with a form. The fake server is the one of pcdetail_test.go
// (issue i14); every POST lands in the list it returns as "<path after /api/issues/i14/> <body>".

func interaction(id, kind string, payload map[string]any, result map[string]any) map[string]any {
	in := map[string]any{"id": id, "kind": kind, "status": "pending", "title": "Needs you", "createdAt": "2026-10-17T19:31:00Z", "payload": payload}
	if result != nil {
		in["result"] = result
	}
	return in
}

func opts(pairs ...string) []any { // id, label, id, label, ...
	var out []any
	for i := 0; i+1 < len(pairs); i += 2 {
		out = append(out, map[string]any{"id": pairs[i], "label": pairs[i+1]})
	}
	return out
}

var (
	checkbox = interaction("c1", "request_checkbox_confirmation", map[string]any{"version": 1, "prompt": "Which notes should I file?",
		"detailsMarkdown": "Three notes came in.", "acceptLabel": "File them", "minSelected": 1, "maxSelected": 2,
		"defaultSelectedOptionIds": []any{"n1"},
		"options": []any{map[string]any{"id": "n1", "label": "Note one"},
			map[string]any{"id": "n2", "label": "Note two", "description": "the long one"}, map[string]any{"id": "n3", "label": "Note three"}}}, nil)

	tasks = interaction("t1", "suggest_tasks", map[string]any{"version": 1, "tasks": []any{
		map[string]any{"clientKey": "a", "title": "Parent task"},
		map[string]any{"clientKey": "b", "parentClientKey": "a", "title": "Child task"},
		map[string]any{"clientKey": "c", "title": "Other task", "description": "with details"}}}, nil)

	questions = interaction("q1", "ask_user_questions", map[string]any{"version": 1, "title": "Setup", "questions": []any{
		map[string]any{"id": "lane", "prompt": "Which lane?", "selectionMode": "single", "required": true,
			"options": opts("r", "research (Recommended)", "h", "hold")},
		map[string]any{"id": "tags", "prompt": "Which tags?", "selectionMode": "multi", "allowOther": true,
			"options": opts("x", "alpha", "y", "beta", "z", "gamma")},
		map[string]any{"id": "why", "prompt": "Why?", "selectionMode": "single", "allowOther": true,
			"options": []any{map[string]any{"id": "paperclip_text_answer", "label": "Type an answer", "freeText": true}}}}}, nil)

	// every question has a recommendation: one in a label, one flagged in the question set (two on the multi question)
	recommended = interaction("q2", "ask_user_questions", map[string]any{"version": 1,
		"questions": []any{
			map[string]any{"id": "lane", "prompt": "Which lane?", "selectionMode": "single", "options": opts("r", "research (Recommended)", "h", "hold")},
			map[string]any{"id": "tags", "prompt": "Which tags?", "selectionMode": "multi", "options": opts("x", "alpha", "y", "beta", "z", "gamma")}},
		"questionSet": map[string]any{"schema": "paperclip.question_set.v1", "questions": []any{
			map[string]any{"id": "lane", "options": []any{map[string]any{"id": "r"}, map[string]any{"id": "h"}}},
			map[string]any{"id": "tags", "options": []any{map[string]any{"id": "x", "recommended": true}, map[string]any{"id": "y"},
				map[string]any{"id": "z", "recommended": true}}}}}}, nil)

	verdicts = interaction("v1", "request_item_verdicts", map[string]any{"version": 1, "prompt": "Where should these go?",
		"detailsMarkdown": "Nothing moves until you decide.", "reasonLabel": "What to do instead",
		"verdicts": []any{"approve", "reject", "defer"}, "requireReasonOn": []any{"reject"},
		"items": []any{
			map[string]any{"id": "i01", "label": "First note", "description": "goes to Backlog", "previewMarkdown": "# Preview one"},
			map[string]any{"id": "i02", "label": "Second note"},
			map[string]any{"id": "i03", "label": "Third note"}}},
		map[string]any{"items": []any{map[string]any{"id": "i03", "verdict": "approve"}}})

	connection = interaction("k1", "connection_intent", map[string]any{"version": 1, "serviceName": "Linear", "requestingAgentName": "Builder"}, nil)
)

func keyMsg(k string) tea.KeyMsg {
	switch k {
	case "left":
		return tea.KeyMsg{Type: tea.KeyLeft}
	case "right":
		return tea.KeyMsg{Type: tea.KeyRight}
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
}

// press sends the keys one by one and returns the model and the command of the last key.
func press(m model, keys ...string) (model, tea.Cmd) {
	var cmd tea.Cmd
	for _, k := range keys {
		var mm tea.Model
		mm, cmd = m.key(keyMsg(k))
		m = mm.(model)
	}
	return m, cmd
}

// write types text into the open box and sends it.
func write(m model, text string) (model, tea.Cmd) {
	m.ed.ta.SetValue(text)
	return press(m, "enter")
}

func acted(t *testing.T, cmd tea.Cmd) pcActedMsg {
	t.Helper()
	if cmd == nil {
		t.Fatal("the key sent nothing")
	}
	msg, ok := cmd().(pcActedMsg)
	if !ok {
		t.Fatalf("the command gave %T, not pcActedMsg", cmd())
	}
	return msg
}

// askModel is the PC view on the fake issue i14 holding the given pending request.
func askModel(t *testing.T, in map[string]any, w, h int) (model, *[]string) {
	t.Helper()
	srv, posts := fakeIssue(t, in, nil)
	withBase(t, srv.URL)
	m := newModel()
	m.w, m.h = w, h
	m.view = vPaperclip
	m.pc = PCState{Items: []PCItem{{ID: "i14", Ref: "COS-14", Status: "in_review", Title: "Clip", Needs: true}}}
	m.pcDet["i14"] = loadPCDetail("i14", nil)
	return m, posts
}

func plainView(m model) string { return escRe.ReplaceAllString(m.View(), "") }

// Each kind shows what it is, its items and the keys, at the smallest and a large screen, and keeps the geometry.
func TestPCAsksRender(t *testing.T) {
	cases := []struct {
		name string
		in   map[string]any
		want []string
	}{
		{"checkbox", checkbox, []string{"IT ASKS YOU", "Which notes should I file?", "1 [x] Note one", "2 [ ] Note two", "1 of 3 ticked", "pick 1-2",
			"1-9 tick", "s File them", "x decline", "r decline with a reason"}},
		{"tasks", tasks, []string{"3 of 3 tasks ticked", "1 [x] Parent task", "· Child task", "s accept ticked", "x reject"}},
		{"questions", questions, []string{"question 1 of 3", "Which lane?", "1 ( ) research ★", "2 ( ) hold", "←→ question", "s send"}},
		{"recommended", recommended, []string{"a ★ answers, send", "1 ( ) research ★"}},
		{"verdicts", verdicts, []string{"item 1 of 3", "1 approve", "2 reject", "3 defer", "←→ item", "s send", "> ·", "First note"}},
		{"connection", connection, []string{"Connect Linear for Builder.", "agterm can't answer a connection intent: enter opens it in Paperclip"}},
	}
	for _, c := range cases {
		for _, sz := range [][2]int{{80, 24}, {160, 40}} {
			m, _ := askModel(t, c.in, sz[0], sz[1])
			raw := m.View()
			lines := strings.Split(raw, "\n")
			if len(lines) != sz[1] {
				t.Errorf("%s %dx%d: %d lines", c.name, sz[0], sz[1], len(lines))
			}
			for i, l := range lines {
				if w := runewidth.StringWidth(escRe.ReplaceAllString(l, "")); w > sz[0] {
					t.Errorf("%s %dx%d line %d: width %d", c.name, sz[0], sz[1], i, w)
				}
			}
			v := escRe.ReplaceAllString(raw, "")
			panel := squash(panelOf(v, sz[0]))
			for _, want := range c.want {
				// at 80 columns the panel is 34 cells wide: a key line wraps, so match without its line breaks
				if !strings.Contains(panel, squash(want)) {
					t.Errorf("%s %dx%d lacks %q:\n%s", c.name, sz[0], sz[1], want, v)
				}
			}
			if !strings.Contains(panel, "comment") { // the panel's own key line stays at the bottom
				t.Errorf("%s %dx%d lost the comment box:\n%s", c.name, sz[0], sz[1], v)
			}
		}
	}
}

// panelOf is the right-hand panel of the PC view's lines (the list is on the left).
func panelOf(v string, w int) string {
	lw, _ := pcWidths(w)
	var out []string
	for _, l := range strings.Split(v, "\n") {
		if r := []rune(l); len(r) > lw+2 && strings.ContainsAny(l, "│") {
			out = append(out, string(r[lw+2:]))
		}
	}
	return strings.Join(out, "\n")
}

// squash drops the panel borders and spacing, so text that wrapped still matches.
func squash(v string) string {
	return strings.Join(strings.Fields(strings.NewReplacer("│", " ", "┌", " ", "└", " ", "┐", " ", "┘", " ", "─", " ").Replace(v)), "")
}

// Numbers tick the options (the request's own defaults first), s sends the ticked ones, x and r decline.
func TestPCCheckbox(t *testing.T) {
	m, posts := askModel(t, checkbox, 160, 40)
	m, _ = press(m, "2", "3") // n1 was ticked from the start: now three, and two is the most
	if !strings.Contains(plainView(m), "3 of 3 ticked") {
		t.Errorf("view:\n%s", plainView(m))
	}
	m, cmd := press(m, "s")
	if cmd != nil || !strings.Contains(m.status, "no more than 2") || !m.statusErr {
		t.Fatalf("three ticked went out: cmd %v status %q", cmd != nil, m.status)
	}
	m, _ = press(m, "3") // untick
	m, cmd = press(m, "s")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "sent 2 ticked" {
		t.Fatalf("msg %+v", msg)
	}
	m, _ = press(m, "1", "2") // none left: below the minimum of one
	if m, cmd = press(m, "s"); cmd != nil || !strings.Contains(m.status, "at least 1") {
		t.Errorf("none ticked: cmd %v status %q", cmd != nil, m.status)
	}
	m, _ = press(m, "3")
	_, cmd = press(m, "x")
	if msg := acted(t, cmd); msg.what != "declined" {
		t.Fatalf("msg %+v", msg)
	}
	m, _ = press(m, "r")
	if m.mode != mTyping || m.ed.target != "pcno:i14@d" || !strings.Contains(plainView(m), "why you decline") {
		t.Fatalf("r: mode %v target %q", m.mode, m.ed.target)
	}
	_, cmd = write(m, "too many at once")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "declined" {
		t.Fatalf("msg %+v", msg)
	}
	want := []string{`interactions/c1/accept {"selectedOptionIds":["n1","n2"]}`, `interactions/c1/reject {}`,
		`interactions/c1/reject {"reason":"too many at once"}`}
	if got := strings.Join(*posts, "\n"); got != strings.Join(want, "\n") {
		t.Errorf("posts:\n%s\nwant:\n%s", got, strings.Join(want, "\n"))
	}
}

// A request that needs a reason on a decline opens the box on x; one that takes none refuses r.
func TestPCCheckboxDeclineRules(t *testing.T) {
	needs := interaction("c2", "request_checkbox_confirmation", map[string]any{"version": 1, "prompt": "p", "rejectRequiresReason": true,
		"rejectReasonLabel": "Why not?", "options": opts("a", "A")}, nil)
	m, _ := askModel(t, needs, 160, 40)
	m, _ = press(m, "x")
	if m.mode != mTyping || !strings.Contains(plainView(m), "Why not? (enter declines)") {
		t.Errorf("x did not open the reason box: mode %v", m.mode)
	}
	none := interaction("c3", "request_checkbox_confirmation", map[string]any{"version": 1, "prompt": "p", "allowDeclineReason": false,
		"options": opts("a", "A")}, nil)
	m, _ = askModel(t, none, 160, 40)
	m, cmd := press(m, "r")
	if cmd != nil || m.mode == mTyping || !m.statusErr {
		t.Errorf("r on a request without reasons: mode %v status %q", m.mode, m.status)
	}
	if strings.Contains(plainView(m), "with a reason") {
		t.Error("the key line offers a reason the request does not take")
	}
}

// Everything starts ticked; a task needs its parent; s sends none (all) or the ticked keys; x rejects.
func TestPCTasks(t *testing.T) {
	m, posts := askModel(t, tasks, 160, 40)
	m, cmd := press(m, "s")
	if msg := acted(t, cmd); msg.what != "accepted 3 of 3 tasks" {
		t.Fatalf("msg %+v", msg)
	}
	m, _ = press(m, "3")
	_, cmd = press(m, "s")
	acted(t, cmd)
	m, _ = press(m, "1") // the parent off: its child goes too
	if v := plainView(m); !strings.Contains(v, "0 of 3 tasks ticked") {
		t.Errorf("parent unticked:\n%s", v)
	}
	m, _ = press(m, "2") // the child on: its parent comes back
	if v := plainView(m); !strings.Contains(v, "2 of 3 tasks ticked") {
		t.Errorf("child ticked:\n%s", v)
	}
	m, _ = press(m, "1") // and off again, with the child: nothing is ticked
	if m, cmd = press(m, "s"); cmd != nil || !strings.Contains(m.status, "at least one task") {
		t.Errorf("none ticked: status %q", m.status)
	}
	_, cmd = press(m, "x")
	acted(t, cmd)
	want := []string{`interactions/t1/accept {}`, `interactions/t1/accept {"selectedClientKeys":["a","b"]}`, `interactions/t1/reject {}`}
	if got := strings.Join(*posts, "\n"); got != strings.Join(want, "\n") {
		t.Errorf("posts:\n%s\nwant:\n%s", got, strings.Join(want, "\n"))
	}
}

// Questions one at a time: a single choice picks and moves on, a multi choice toggles, o writes the free text.
func TestPCQuestions(t *testing.T) {
	m, posts := askModel(t, questions, 160, 40)
	m, cmd := press(m, "s") // the first question needs an answer
	if cmd != nil || !strings.Contains(m.status, "question 1 of 3 needs an answer") {
		t.Fatalf("status %q", m.status)
	}
	m, _ = press(m, "1")
	if v := plainView(m); !strings.Contains(v, "question 2 of 3") || !strings.Contains(v, "Which tags?") {
		t.Fatalf("a single choice did not move on:\n%s", v)
	}
	m, _ = press(m, "1", "3", "o")
	if m.ed.target != "pcno:i14@q1" || !strings.Contains(plainView(m), "your own answer to question 2") {
		t.Fatalf("o: target %q", m.ed.target)
	}
	m, _ = write(m, "delta")
	if !strings.Contains(plainView(m), "own answer: delta") {
		t.Errorf("the written answer is not shown:\n%s", plainView(m))
	}
	m, _ = press(m, "right") // multi: it stays on the question, so go on by hand
	m, _ = press(m, "1")     // the last question takes a written answer only
	if !strings.Contains(m.status, "takes a written answer") {
		t.Errorf("a number on a text question: %q", m.status)
	}
	m, _ = press(m, "o")
	m, _ = write(m, "because")
	m, _ = press(m, "left", "left") // back to the first: the pick is kept
	if v := plainView(m); !strings.Contains(v, "(x) research") {
		t.Errorf("the first answer is lost:\n%s", v)
	}
	_, cmd = press(m, "s")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "sent 3 answer(s)" {
		t.Fatalf("msg %+v", msg)
	}
	want := `interactions/q1/respond {"answers":[{"optionIds":["r"],"questionId":"lane"},` +
		`{"optionIds":["x","z"],"otherText":"delta","questionId":"tags"},{"optionIds":[],"otherText":"because","questionId":"why"}]}`
	if (*posts)[0] != want {
		t.Errorf("post:\n%s\nwant:\n%s", (*posts)[0], want)
	}
}

// a takes every recommended answer and sends; a question without one stops it, by name; nothing is guessed.
func TestPCQuickApprove(t *testing.T) {
	m, posts := askModel(t, recommended, 160, 40)
	v := plainView(m)
	if strings.Contains(v, "research (Recommended)") || !strings.Contains(v, "research ★") {
		t.Errorf("the label's mark should show as ★:\n%s", v)
	}
	_, cmd := press(m, "a")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "recommended answers sent" {
		t.Fatalf("msg %+v", msg)
	}
	want := `interactions/q2/respond {"answers":[{"optionIds":["r"],"questionId":"lane"},{"optionIds":["x","z"],"questionId":"tags"}]}`
	if len(*posts) != 1 || (*posts)[0] != want {
		t.Errorf("posts %v\nwant %s", *posts, want)
	}

	// the multi-question request has no recommendation on its second question
	m, posts = askModel(t, questions, 160, 40)
	m, cmd = press(m, "a")
	if cmd != nil || !m.statusErr || !strings.Contains(m.status, "question 2 of 3 (Which tags?)") || len(*posts) != 0 {
		t.Errorf("a without a recommendation: cmd %v status %q posts %v", cmd != nil, m.status, *posts)
	}
	if strings.Contains(plainView(m), "a ★ answers") {
		t.Error("the key line offers a when it would refuse")
	}
	if !strings.Contains(plainView(m), "a needs ★ on every question") {
		t.Errorf("the key line does not say what a needs:\n%s", plainView(m))
	}

	// two recommendations on a single-choice question: not a recommendation
	two := interaction("q3", "ask_user_questions", map[string]any{"version": 1, "questions": []any{
		map[string]any{"id": "p", "prompt": "Pick", "selectionMode": "single",
			"options": opts("a", "one (Recommended)", "b", "two (recommended)")}}}, nil)
	m, _ = askModel(t, two, 160, 40)
	if m, cmd = press(m, "a"); cmd != nil || !strings.Contains(m.status, "more than one recommended answer") {
		t.Errorf("two recommended: status %q", m.status)
	}

	// an ask without any marker: a refuses, and the screen does not promise it
	plain := interaction("q4", "ask_user_questions", map[string]any{"version": 1, "questions": []any{
		map[string]any{"id": "lane", "prompt": "Which lane?", "selectionMode": "single", "options": opts("r", "research", "h", "hold")}}}, nil)
	m, posts = askModel(t, plain, 160, 40)
	if m, cmd = press(m, "a"); cmd != nil || !strings.Contains(m.status, "no recommended answer for question 1 of 1") || len(*posts) != 0 {
		t.Errorf("a on an ask without markers: status %q", m.status)
	}
	if v := plainView(m); strings.Contains(v, "★") || !strings.Contains(v, "1 research") {
		t.Errorf("a plain question:\n%s", v)
	}
}

// 1-3 judge the current item and move on; a reject needs its reason in the box; the item that has a verdict stays.
func TestPCVerdicts(t *testing.T) {
	m, posts := askModel(t, verdicts, 160, 40)
	if v := plainView(m); !strings.Contains(v, "verdict given") && !strings.Contains(v, "approve  Third note") {
		t.Errorf("the verdict given before is not shown:\n%s", v)
	}
	if m, cmd := press(m, "s"); cmd != nil || !strings.Contains(m.status, "at least one item a verdict") {
		t.Errorf("s with nothing judged: status %q", m.status)
	}
	m, _ = press(m, "1") // First note: approve; the cursor goes to the second
	if v := plainView(m); !strings.Contains(v, "item 2 of 3") {
		t.Fatalf("the cursor did not move:\n%s", v)
	}
	m, _ = press(m, "2")
	if m.ed.target != "pcno:i14@v1.2" || !strings.Contains(plainView(m), "What to do instead (enter keeps it)") {
		t.Fatalf("a reject needs a reason: target %q", m.ed.target)
	}
	m, _ = write(m, "put it in Projects")
	if v := plainView(m); !strings.Contains(v, "2 decided") && !strings.Contains(v, "3 decided") {
		t.Errorf("the verdict with its reason is not counted:\n%s", v)
	}
	m, _ = press(m, "right", "3") // the third note has its verdict from before
	if !m.statusErr || !strings.Contains(m.status, "has its verdict already") {
		t.Errorf("a verdict on a settled item: status %q", m.status)
	}
	if m, _ = press(m, "9"); !strings.Contains(m.status, "no verdict 9") {
		t.Errorf("status %q", m.status)
	}
	_, cmd := press(m, "s")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "sent 2 verdict(s)" {
		t.Fatalf("msg %+v", msg)
	}
	want := `interactions/v1/verdicts {"verdicts":[{"id":"i01","verdict":"approve"},{"id":"i02","reason":"put it in Projects","verdict":"reject"}]}`
	if (*posts)[0] != want {
		t.Errorf("post:\n%s\nwant:\n%s", (*posts)[0], want)
	}

	// some items now, the rest later: the report says how many are left
	m, _ = askModel(t, verdicts, 160, 40)
	m, _ = press(m, "3") // defer the first
	_, cmd = press(m, "s")
	if msg := acted(t, cmd); msg.what != "sent 1 verdict(s), 1 left" {
		t.Errorf("msg %+v", msg)
	}
}

// Paperclip's own refusal reaches the command line, for every kind of form.
func TestPCFormRefusals(t *testing.T) {
	for _, c := range []struct {
		name string
		in   map[string]any
		keys []string
	}{
		{"checkbox", checkbox, []string{"s"}}, {"tasks", tasks, []string{"s"}}, {"questions", questions, []string{"1", "s"}},
		{"verdicts", verdicts, []string{"1", "s"}},
	} {
		srv, _ := fakeIssue(t, c.in, nil)
		front := refusing(t, srv, "Interaction has already been resolved")
		withBase(t, front.URL)
		m := newModel()
		m.w, m.h, m.view = 160, 40, vPaperclip
		m.pc = PCState{Items: []PCItem{{ID: "i14", Ref: "COS-14", Needs: true}}}
		m.pcDet["i14"] = loadPCDetail("i14", nil)
		_, cmd := press(m, c.keys...)
		msg := acted(t, cmd)
		if !strings.Contains(msg.err, "Paperclip refused (HTTP 422): Interaction has already been resolved") {
			t.Errorf("%s: err %q", c.name, msg.err)
		}
		mm, _ := m.Update(msg)
		if m2 := mm.(model); !m2.statusErr || !strings.Contains(m2.status, "Interaction has already been resolved") {
			t.Errorf("%s: status %q", c.name, m2.status)
		}
	}
}

// refusing puts a server in front of srv that refuses every POST with Paperclip's error shape.
func refusing(t *testing.T, srv *httptest.Server, msg string) *httptest.Server {
	t.Helper()
	inner := srv.Config.Handler
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			w.WriteHeader(http.StatusUnprocessableEntity)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": msg})
			return
		}
		inner.ServeHTTP(w, r)
	}))
	t.Cleanup(front.Close)
	return front
}

// connection_intent and a kind agterm does not know: no key posts anything; the panel says to open it.
func TestPCUnknownKindsPostNothing(t *testing.T) {
	future := interaction("f1", "something_new", map[string]any{"version": 1, "prompt": "A request from a later Paperclip."}, nil)
	for _, in := range []map[string]any{connection, future} {
		m, posts := askModel(t, in, 160, 40)
		if a := m.pcDet["i14"].Ask; a == nil || len(a.Options) != 0 || a.Spec != nil {
			t.Fatalf("%v: ask %+v", in["kind"], a)
		}
		for _, k := range []string{"1", "2", "9", "s", "x", "a", "o", "left"} {
			var cmd tea.Cmd
			if m, cmd = press(m, k); cmd != nil {
				t.Errorf("%v: key %q sent a command", in["kind"], k)
			}
		}
		if len(*posts) != 0 {
			t.Errorf("%v: posted %v", in["kind"], *posts)
		}
		if v := plainView(m); !strings.Contains(v, "enter opens it in Paperclip") {
			t.Errorf("%v: the panel does not say to open it:\n%s", in["kind"], v)
		}
	}
}

// A form survives the panel's reread every five seconds, and starts again when the request changed.
func TestPCFormSurvivesReread(t *testing.T) {
	m, _ := askModel(t, checkbox, 160, 40)
	m, _ = press(m, "2")
	m.pcDet["i14"] = loadPCDetail("i14", nil) // a new PCAsk object, the same request
	if v := plainView(m); !strings.Contains(v, "2 of 3 ticked") {
		t.Errorf("the tick was lost on the reread:\n%s", v)
	}
	a := m.pcDet["i14"].Ask
	a.Spec.Sig += "|changed"
	if f := m.pcForms.of(a); len(f.sel) != 1 {
		t.Errorf("a changed request kept the old ticks: %v", f.sel)
	}
}

// More items than rows: the numbers and n/p work page by page.
func TestPCPaging(t *testing.T) {
	var o []any
	for i := 1; i <= 12; i++ {
		o = append(o, map[string]any{"id": fmt.Sprintf("o%02d", i), "label": fmt.Sprintf("Option %02d", i)})
	}
	big := interaction("c9", "request_checkbox_confirmation", map[string]any{"version": 1, "prompt": "p", "options": o}, nil)
	m, posts := askModel(t, big, 160, 40)
	v := plainView(m)
	if !strings.Contains(v, "page 1 of 2") || !strings.Contains(v, "n/p page") || strings.Contains(v, "Option 10") {
		t.Fatalf("first page:\n%s", v)
	}
	m, _ = press(m, "n", "1") // the 10th option
	if v := plainView(m); !strings.Contains(v, "page 2 of 2") || !strings.Contains(v, "1 [x] Option 10") {
		t.Fatalf("second page:\n%s", v)
	}
	_, cmd := press(m, "s")
	acted(t, cmd)
	if want := `interactions/c9/accept {"selectedOptionIds":["o10"]}`; (*posts)[0] != want {
		t.Errorf("post %s want %s", (*posts)[0], want)
	}
}

// Suggested tasks decline with a reason too: r opens the box, the text goes as the rejection reason.
func TestPCTasksDeclineWithReason(t *testing.T) {
	m, posts := askModel(t, tasks, 160, 40)
	m, _ = press(m, "r")
	if m.ed.target != "pcno:i14@d" {
		t.Fatalf("r: target %q", m.ed.target)
	}
	_, cmd := write(m, "not now")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "declined" {
		t.Fatalf("msg %+v", msg)
	}
	if want := `interactions/t1/reject {"reason":"not now"}`; (*posts)[0] != want {
		t.Errorf("post %s want %s", (*posts)[0], want)
	}
}

// A label that ends in (Recommended) is the recommendation; the mark is not part of the label.
func TestPCRecLabel(t *testing.T) {
	for _, c := range []struct {
		in    string
		label string
		rec   bool
	}{
		{"research (Recommended)", "research", true},
		{"research (recommended) ", "research", true},
		{"Recommended reading", "Recommended reading", false},
		{"(Recommended)", "(Recommended)", false},
		{"plain", "plain", false},
	} {
		if label, rec := pcRecLabel(c.in); label != c.label || rec != c.rec {
			t.Errorf("pcRecLabel(%q) = %q, %v; want %q, %v", c.in, label, rec, c.label, c.rec)
		}
	}
}
