package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeApprovals serves a company with two pending approvals (a hire, and a request to the board) in the attention
// feed, the approvals endpoints, and records every POST as "<path after /api/> <body>". The approval "apx" is one
// that Paperclip refuses: it is no longer pending.
func fakeApprovals(t *testing.T) (*httptest.Server, *[]string) {
	t.Helper()
	var mu sync.Mutex
	var posts []string
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any) { _ = json.NewEncoder(w).Encode(v) }
	feed := func(id, typ, title string) map[string]any {
		return map[string]any{"sourceKind": "approval", "whyNow": "Approval is pending a board decision.", "severity": "medium",
			"subject": map[string]any{"kind": "approval", "id": id, "title": title, "identifier": nil, "status": "pending",
				"href": "/COS/approvals/" + id, "metadata": map[string]any{"type": typ, "requestedByAgentId": "a1", "issueId": "i3"}}}
	}
	hire := map[string]any{"id": "ap1", "type": "hire_agent", "status": "pending", "requestedByAgentId": "a1", "createdAt": "2026-10-17T19:00:00Z",
		"payload": map[string]any{"name": "Scout", "role": "researcher", "title": "Research scout", "capabilities": "finds things",
			"adapterType": "claude_local", "budgetMonthlyCents": 2500, "desiredSkills": []any{"web", "notes"}}}
	board := map[string]any{"id": "ap2", "type": "request_board_approval", "status": "pending", "requestedByAgentId": "a1", "createdAt": "2026-10-17T19:10:00Z",
		"payload": map[string]any{"title": "Approve high-risk tool action: gmail.send", "summary": "gmail.send needs formal board approval.",
			"recommendedAction": "Approve only if the reviewed arguments match.", "risks": []any{"- The tool sends mail.", "It cannot be undone."}}}
	done := map[string]any{"id": "ap3", "type": "hire_agent", "status": "approved", "payload": map[string]any{"name": "Old hire"}}
	byID := map[string]map[string]any{"ap1": hire, "ap2": board, "ap3": done}
	mux.HandleFunc("/api/companies", func(w http.ResponseWriter, r *http.Request) {
		reply(w, []map[string]any{{"id": "c1", "name": "COS Vault", "issuePrefix": "COS", "status": "active"}})
	})
	mux.HandleFunc("/api/companies/c1/attention", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]any{"items": []any{feed("ap1", "hire_agent", "hire agent"), feed("ap2", "request_board_approval", "Approve high-risk tool action: gmail.send")}})
	})
	mux.HandleFunc("/api/companies/c1/approvals", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("status") != "pending" {
			t.Errorf("approvals filter = %q", r.URL.Query().Get("status"))
		}
		reply(w, []any{hire, board})
	})
	mux.HandleFunc("/api/companies/c1/issues", func(w http.ResponseWriter, r *http.Request) { reply(w, []any{}) })
	mux.HandleFunc("/api/companies/c1/agents", func(w http.ResponseWriter, r *http.Request) { reply(w, []map[string]any{{"id": "a1", "name": "CEO"}}) })
	mux.HandleFunc("/api/companies/c1/heartbeat-runs", func(w http.ResponseWriter, r *http.Request) { reply(w, []any{}) })
	mux.HandleFunc("/api/approvals/", func(w http.ResponseWriter, r *http.Request) {
		rest := strings.TrimPrefix(r.URL.Path, "/api/approvals/")
		id, what, _ := strings.Cut(rest, "/")
		if r.Method == http.MethodPost {
			b, _ := io.ReadAll(r.Body)
			mu.Lock()
			posts = append(posts, strings.TrimPrefix(r.URL.Path, "/api/")+" "+strings.TrimSpace(string(b)))
			mu.Unlock()
			if id == "apx" {
				w.WriteHeader(http.StatusUnprocessableEntity)
				reply(w, map[string]any{"error": "Only pending or revision requested approvals can be approved"})
				return
			}
			reply(w, map[string]any{"id": id})
			return
		}
		ap, ok := byID[id]
		if !ok {
			http.NotFound(w, r)
			return
		}
		switch what {
		case "":
			reply(w, ap)
		case "comments":
			reply(w, []any{map[string]any{"authorAgentId": "a1", "body": "Needed for the research queue.", "createdAt": "2026-10-17T19:05:00Z"}})
		case "issues":
			reply(w, []any{map[string]any{"id": "i3", "identifier": "COS-3", "title": "Hire a scout"}})
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &posts
}

// Pending approvals are rows that need the owner, named by their payload, with the requesting agent.
func TestApprovalRows(t *testing.T) {
	srv, _ := fakeApprovals(t)
	withBase(t, srv.URL)
	st := loadPaperclip()
	if st.Err != "" || len(st.Items) != 2 {
		t.Fatalf("state %+v", st)
	}
	hire := st.Items[0]
	if hire.ID != "approval:ap1" || hire.Ref != "APPROVAL" || hire.Status != "hire agent" || !hire.Needs || hire.Agent != "CEO" ||
		hire.Title != "Hire Scout (researcher)" || hire.URL != srv.URL+"/COS/approvals/ap1" {
		t.Errorf("hire row = %+v", hire)
	}
	if b := st.Items[1]; b.ID != "approval:ap2" || b.Status != "board ask" || !b.Needs || b.Title != "Approve high-risk tool action: gmail.send" {
		t.Errorf("board row = %+v", b)
	}
	if got := pcRef(hire); got != "approval: Hire Scout (researcher)" {
		t.Errorf("ref = %q", got)
	}
}

// The panel of an approval: what it is (payload as the approval page shows it), the thread, the five answers.
func TestApprovalPanel(t *testing.T) {
	srv, _ := fakeApprovals(t)
	withBase(t, srv.URL)
	st := loadPaperclip()
	for _, sz := range [][2]int{{80, 24}, {160, 40}} {
		m := newModel()
		m.w, m.h, m.view, m.pc = sz[0], sz[1], vPaperclip, st
		m.pcDet["approval:ap1"] = loadPCDetail("approval:ap1", st.Names)
		d := m.pcDet["approval:ap1"]
		if d.Err != "" || len(d.Comments) != 1 || d.Comments[0].Author != "CEO" {
			t.Fatalf("detail %+v", d)
		}
		raw := m.View()
		for i, l := range strings.Split(raw, "\n") {
			if w := len([]rune(escRe.ReplaceAllString(l, ""))); w > sz[0] {
				t.Errorf("%dx%d line %d: width %d", sz[0], sz[1], i, w)
			}
		}
		panel := squash(panelOf(escRe.ReplaceAllString(raw, ""), sz[0]))
		if !strings.Contains(escRe.ReplaceAllString(raw, ""), "APPROVAL · hire agent · CEO") {
			t.Errorf("%dx%d: the panel title is missing:\n%s", sz[0], sz[1], escRe.ReplaceAllString(raw, ""))
		}
		for _, want := range []string{"IT ASKS YOU", "1 approve", "2 reject", "3 request revision", "4 approve with a note", "5 reject with a note"} {
			if !strings.Contains(panel, squash(want)) {
				t.Errorf("%dx%d lacks %q:\n%s", sz[0], sz[1], want, escRe.ReplaceAllString(raw, ""))
			}
		}
		if sz[0] == 160 { // the request itself is in the scrolling part, which is long enough here
			for _, want := range []string{"Name: Scout", "Role: researcher", "Budget: $25.00 a month", "Skills: web, notes", "Linked issue: COS-3 Hire a scout",
				"Asked by CEO", "Needed for the research queue.", "k comment"} {
				if !strings.Contains(panel, squash(want)) {
					t.Errorf("160x40 lacks %q:\n%s", want, escRe.ReplaceAllString(raw, ""))
				}
			}
		}
	}
}

// Every answer posts to its own endpoint with the note as decisionNote; a revision needs its note.
func TestApprovalActions(t *testing.T) {
	srv, posts := fakeApprovals(t)
	withBase(t, srv.URL)
	a := loadPCDetail("approval:ap1", nil).Ask
	if a == nil || a.Kind != "approval" || len(a.Options) != 5 {
		t.Fatalf("ask = %+v", a)
	}
	cases := []struct {
		n    int
		note string
		want string // "" when it must be refused
	}{
		{1, "", `approvals/ap1/approve {}`},
		{2, "", `approvals/ap1/reject {}`},
		{3, "cap the spend", `approvals/ap1/request-revision {"decisionNote":"cap the spend"}`},
		{3, "  ", ""},
		{4, "go ahead, but watch the cost", `approvals/ap1/approve {"decisionNote":"go ahead, but watch the cost"}`},
		{5, "we do not need a scout", `approvals/ap1/reject {"decisionNote":"we do not need a scout"}`},
	}
	for _, c := range cases {
		before := len(*posts)
		err := pcAct("approval:ap1", a, c.n, c.note)
		if c.want == "" {
			if err == nil || len(*posts) != before {
				t.Errorf("answer %d with note %q was not refused (err %v)", c.n, c.note, err)
			}
			continue
		}
		if err != nil || len(*posts) != before+1 || (*posts)[before] != c.want {
			t.Errorf("answer %d: err %v, posts %v, want %s", c.n, err, (*posts)[before:], c.want)
		}
	}
	// Paperclip's refusal comes back as it said it
	bad := &PCAsk{Kind: "approval", ID: "apx", Options: a.Options}
	if err := pcAct("approval:apx", bad, 1, ""); err == nil ||
		!strings.Contains(err.Error(), "Paperclip refused (HTTP 422): Only pending or revision requested approvals can be approved") {
		t.Errorf("refusal: %v", err)
	}
	// and a comment on the approval goes to its own thread, with only the text
	if err := pcComment("approval:ap1", "one question first"); err != nil {
		t.Fatal(err)
	}
	if got := (*posts)[len(*posts)-1]; got != `approvals/ap1/comments {"body":"one question first"}` {
		t.Errorf("comment post = %s", got)
	}
}

// In the view: 1 and 2 post at once, 3 and 4 and 5 open the box for their note, and the note goes with the answer.
func TestApprovalKeys(t *testing.T) {
	srv, posts := fakeApprovals(t)
	withBase(t, srv.URL)
	m := newModel()
	m.w, m.h, m.view = 160, 40, vPaperclip
	m.pc = loadPaperclip()
	m.pcDet["approval:ap1"] = loadPCDetail("approval:ap1", m.pc.Names)

	_, cmd := press(m, "2")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "reject" || msg.ref != "approval: Hire Scout (researcher)" {
		t.Fatalf("msg %+v", msg)
	}
	m, _ = press(m, "3")
	if m.mode != mTyping || m.ed.target != "pcno:approval:ap1#3" || !strings.Contains(plainView(m), "note: request revision (enter sends)") {
		t.Fatalf("3: mode %v target %q\n%s", m.mode, m.ed.target, plainView(m))
	}
	m, cmd = write(m, "name the budget")
	if msg := acted(t, cmd); msg.err != "" || msg.what != "request revision" {
		t.Fatalf("msg %+v", msg)
	}
	m, _ = press(m, "4")
	if m.ed.target != "pcno:approval:ap1#4" {
		t.Fatalf("4: target %q", m.ed.target)
	}
	_, cmd = write(m, "fine")
	acted(t, cmd)
	want := []string{`approvals/ap1/reject {}`, `approvals/ap1/request-revision {"decisionNote":"name the budget"}`, `approvals/ap1/approve {"decisionNote":"fine"}`}
	if got := strings.Join(*posts, "\n"); got != strings.Join(want, "\n") {
		t.Errorf("posts:\n%s\nwant:\n%s", got, strings.Join(want, "\n"))
	}
}

// Paperclip's inbox gives a request to the board no approve button (it carries a tool action to review): agterm
// shows it and sends the owner to the browser. No key posts.
func TestApprovalBoardRequestIsNotAnswered(t *testing.T) {
	srv, posts := fakeApprovals(t)
	withBase(t, srv.URL)
	m := newModel()
	m.w, m.h, m.view = 160, 40, vPaperclip
	m.pc = loadPaperclip()
	m.listSel = 1
	m.pcDet["approval:ap2"] = loadPCDetail("approval:ap2", m.pc.Names)
	a := m.pcDet["approval:ap2"].Ask
	if a == nil || len(a.Options) != 0 || a.Spec != nil || a.Kind != "board approval" {
		t.Fatalf("ask = %+v", a)
	}
	for _, k := range []string{"1", "2", "3", "4", "5", "s", "a"} {
		if _, cmd := press(m, k); cmd != nil {
			t.Errorf("key %q sent a command", k)
		}
	}
	if len(*posts) != 0 {
		t.Errorf("posted %v", *posts)
	}
	v := plainView(m)
	for _, want := range []string{"does not let you decide this one inline", "Recommended action: Approve only if the reviewed arguments match.", "- The tool sends mail.", "- It cannot be undone.",
		"agterm can't answer a board approval: enter opens it in Paperclip"} {
		if !strings.Contains(squash(panelOf(v, 160)), squash(want)) {
			t.Errorf("panel lacks %q:\n%s", want, v)
		}
	}
}

// An approval that is not pending any more says so and offers nothing; the payloads read as the approval page shows them.
func TestApprovalNotPendingAndText(t *testing.T) {
	srv, _ := fakeApprovals(t)
	withBase(t, srv.URL)
	if a := loadPCDetail("approval:ap3", nil).Ask; a == nil || len(a.Options) != 0 || !strings.Contains(a.Prompt, "approved") {
		t.Errorf("ask = %+v", a)
	}
	text := pcApprovalText("budget_override_required", map[string]any{"scopeName": "Builder", "windowKind": "calendar_month_utc",
		"metric": "billed_cents", "budgetAmount": 5000.0, "observedAmount": 5120.0, "guidance": "Raise the budget."})
	for _, want := range []string{"Scope: Builder", "Window: calendar month utc", "Limit: $50.00", "Seen: $51.20", "Guidance: Raise the budget."} {
		if !strings.Contains(text, want) {
			t.Errorf("budget text lacks %q:\n%s", want, text)
		}
	}
	if got := pcApprovalText("something_else", map[string]any{"x": 1.0}); !strings.Contains(got, `"x": 1`) {
		t.Errorf("an unknown type shows its payload: %q", got)
	}
}
