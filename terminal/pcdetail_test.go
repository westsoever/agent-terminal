package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// fakeIssue serves one issue (i14) with a thread, a pending confirmation or question, and records the POSTs.
func fakeIssue(t *testing.T, interaction map[string]any, recovery map[string]any) (*httptest.Server, *[]string) {
	t.Helper()
	var mu sync.Mutex
	var posts []string
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any) { _ = json.NewEncoder(w).Encode(v) }
	mux.HandleFunc("/api/issues/i14", func(w http.ResponseWriter, r *http.Request) {
		is := map[string]any{"id": "i14", "identifier": "COS-14", "title": "Clip with Defuddle", "status": "in_review",
			"description": "Make /unbox clip pages."}
		if recovery != nil {
			is["activeRecoveryAction"] = recovery
		}
		reply(w, is)
	})
	mux.HandleFunc("/api/issues/i14/comments", func(w http.ResponseWriter, r *http.Request) {
		reply(w, []map[string]any{ // newest first, as Paperclip sends them
			{"authorType": "user", "body": "looks good", "createdAt": "2026-10-17T19:40:00Z"},
			{"authorType": "agent", "authorAgentId": "a1", "body": "PR #4 is open.", "createdAt": "2026-10-17T19:30:00Z"},
		})
	})
	mux.HandleFunc("/api/issues/i14/interactions", func(w http.ResponseWriter, r *http.Request) {
		if interaction == nil {
			reply(w, []any{})
			return
		}
		reply(w, []any{
			map[string]any{"id": "old", "kind": "request_confirmation", "status": "accepted", "createdAt": "2026-10-17T18:00:00Z"},
			interaction,
		})
	})
	mux.HandleFunc("/api/issues/i14/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		posts = append(posts, strings.TrimPrefix(r.URL.Path, "/api/issues/i14/")+" "+strings.TrimSpace(string(b)))
		mu.Unlock()
		reply(w, map[string]any{"ok": true})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, &posts
}

var confirmation = map[string]any{"id": "x1", "kind": "request_confirmation", "status": "pending", "title": "Review COS-14",
	"createdAt": "2026-10-17T19:31:00Z",
	"payload":   map[string]any{"prompt": "Review the pull request.", "detailsMarkdown": "https://github.com/o/r/pull/4\n\n**What** changed"}}

// The panel has the thread oldest first (the owner's comments marked), and the open confirmation with its answers.
func TestLoadPCDetail(t *testing.T) {
	srv, _ := fakeIssue(t, confirmation, nil)
	withBase(t, srv.URL)
	d := loadPCDetail("i14", map[string]string{"a1": "Librarian"})
	if d.Err != "" || d.Ref != "COS-14" || len(d.Comments) != 2 {
		t.Fatalf("detail = %+v", d)
	}
	if c := d.Comments[0]; c.Author != "Librarian" || c.Board || c.Body != "PR #4 is open." {
		t.Errorf("first comment = %+v", c)
	}
	if c := d.Comments[1]; c.Author != "you" || !c.Board {
		t.Errorf("second comment = %+v", c)
	}
	a := d.Ask
	if a == nil || a.ID != "x1" || a.Prompt != "Review the pull request." || len(a.Options) != 3 || a.Options[0].Label != "approve" {
		t.Fatalf("ask = %+v", a)
	}
}

// 1 approves, 2 declines, 3 declines with the reason written in the box.
func TestPCActConfirmation(t *testing.T) {
	srv, posts := fakeIssue(t, confirmation, nil)
	withBase(t, srv.URL)
	a := loadPCDetail("i14", nil).Ask
	for n, reason := range map[int]string{1: "", 2: "", 3: "the shell snippet is wrong"} {
		if err := pcAct("i14", a, n, reason); err != nil {
			t.Fatal(err)
		}
	}
	got := strings.Join(*posts, "\n")
	for _, want := range []string{"interactions/x1/accept {}", "interactions/x1/reject {}",
		`interactions/x1/reject {"reason":"the shell snippet is wrong"}`} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	if err := pcAct("i14", a, 4, ""); err == nil {
		t.Error("answer 4 of 3 was sent")
	}
}

// A single-choice question is answered with a number; a recovery action for the board gets its three choices.
func TestPCActQuestionAndRecovery(t *testing.T) {
	q := map[string]any{"id": "q1", "kind": "ask_user_questions", "status": "pending", "createdAt": "2026-10-17T19:31:00Z",
		"payload": map[string]any{"questions": []any{map[string]any{"id": "lane", "prompt": "Which lane?", "selectionMode": "single",
			"options": []any{map[string]any{"id": "r", "label": "research"}, map[string]any{"id": "h", "label": "hold"}}}}}}
	srv, posts := fakeIssue(t, q, nil)
	withBase(t, srv.URL)
	a := loadPCDetail("i14", nil).Ask
	if a == nil || a.Prompt != "Which lane?" || len(a.Options) != 2 {
		t.Fatalf("ask = %+v", a)
	}
	if err := pcAct("i14", a, 2, ""); err != nil {
		t.Fatal(err)
	}
	if want := `interactions/q1/respond {"answers":[{"optionIds":["h"],"questionId":"lane"}]}`; (*posts)[0] != want {
		t.Errorf("post = %s, want %s", (*posts)[0], want)
	}

	rec := map[string]any{"id": "r9", "kind": "stranded_assigned_issue", "status": "active", "ownerType": "board", "nextAction": "Choose."}
	srv2, posts2 := fakeIssue(t, nil, rec)
	withBase(t, srv2.URL)
	a = loadPCDetail("i14", nil).Ask
	if a == nil || a.Kind != "recovery" || len(a.Options) != 3 {
		t.Fatalf("recovery ask = %+v", a)
	}
	if err := pcAct("i14", a, 2, ""); err != nil {
		t.Fatal(err)
	}
	if want := `recovery-actions/resolve {"actionId":"r9","outcome":"restored","sourceIssueStatus":"done"}`; (*posts2)[0] != want {
		t.Errorf("post = %s, want %s", (*posts2)[0], want)
	}
}

// In the PC view: the panel shows the selected issue's request and answers; a number posts; 3 opens the reason box.
func TestPaperclipViewKeys(t *testing.T) {
	srv, posts := fakeIssue(t, confirmation, nil)
	withBase(t, srv.URL)
	m := newModel()
	m.w, m.h = 160, 40
	m.view = vPaperclip
	m.pc = PCState{Items: []PCItem{{ID: "i14", Ref: "COS-14", Status: "in_review", Title: "Clip", Needs: true}}}
	m.pcDet["i14"] = loadPCDetail("i14", nil)
	v := escRe.ReplaceAllString(m.View(), "")
	for _, want := range []string{"IT ASKS YOU", "1 approve", "2 decline", "3 decline with a reason", "─ the request", "looks good"} {
		if !strings.Contains(v, want) {
			t.Errorf("view lacks %q", want)
		}
	}
	mm, cmd := m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'1'}})
	m = mm.(model)
	if cmd == nil {
		t.Fatal("1 sent nothing")
	}
	if msg, ok := cmd().(pcActedMsg); !ok || msg.err != "" || (*posts)[0] != "interactions/x1/accept {}" {
		t.Fatalf("msg %+v posts %v", msg, *posts)
	}
	m.pcDet["i14"] = loadPCDetail("i14", nil)
	mm, _ = m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'3'}})
	m = mm.(model)
	if m.mode != mTyping || m.ed.target != "pcno:i14" {
		t.Fatalf("3: mode %v target %q", m.mode, m.ed.target)
	}
	if !strings.Contains(escRe.ReplaceAllString(m.View(), ""), "why you decline") {
		t.Error("no reason box")
	}
}
