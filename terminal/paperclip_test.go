package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

const testCompany = "c1"

func fakePaperclip(t *testing.T, posted *map[string]any) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	reply := func(w http.ResponseWriter, v any) { _ = json.NewEncoder(w).Encode(v) }
	mux.HandleFunc("/api/companies", func(w http.ResponseWriter, r *http.Request) {
		reply(w, []map[string]any{{"id": testCompany, "name": "COS Vault", "issuePrefix": "COS", "status": "active"}})
	})
	mux.HandleFunc("/api/companies/"+testCompany+"/attention", func(w http.ResponseWriter, r *http.Request) {
		reply(w, map[string]any{"items": []map[string]any{
			{"sourceKind": "blocker_attention", "whyNow": "Blocks 0 tasks and needs human attention.",
				"subject": map[string]any{"kind": "issue", "id": "i5", "identifier": "COS-5", "title": "Review skills",
					"status": "blocked", "href": "/COS/issues/COS-5", "metadata": map[string]any{"assigneeAgentId": "a1"}}},
			{"sourceKind": "recovery_action", "whyNow": "Recovery action is assigned to a human owner.",
				"subject": map[string]any{"kind": "recovery_action", "id": "r1", "title": "Choose: repair, retry or resolve.",
					"href": "/COS/issues/COS-5", "metadata": map[string]any{"sourceIssueId": "i5"}},
				"relatedIssue": map[string]any{"kind": "issue", "id": "i5", "identifier": "COS-5", "title": "Review skills", "status": "blocked"}},
		}})
	})
	mux.HandleFunc("/api/companies/"+testCompany+"/issues", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("status"); got != pcOpenStatuses {
			t.Errorf("status filter = %q", got)
		}
		reply(w, []map[string]any{
			{"id": "i5", "identifier": "COS-5", "title": "Review skills", "status": "blocked", "assigneeAgentId": "a1", "updatedAt": "2026-10-16T23:43:15Z"},
			{"id": "i7", "identifier": "COS-7", "title": "Write digest", "status": "in_progress", "assigneeAgentId": "a1", "updatedAt": "2026-10-17T01:00:00Z",
				"activeRun": map[string]any{"status": "running"}},
			{"id": "i8", "identifier": "COS-8", "title": "Older todo", "status": "todo", "updatedAt": "2026-10-15T01:00:00Z"},
		})
	})
	mux.HandleFunc("/api/companies/"+testCompany+"/agents", func(w http.ResponseWriter, r *http.Request) {
		reply(w, []map[string]any{{"id": "a1", "name": "Librarian"}})
	})
	mux.HandleFunc("/api/companies/"+testCompany+"/heartbeat-runs", func(w http.ResponseWriter, r *http.Request) {
		reply(w, []map[string]any{
			{"status": "running", "contextSnapshot": map[string]any{"issueId": "i7"}, "usageJson": map[string]any{"costUsd": 0.10}},
			{"status": "succeeded", "contextSnapshot": map[string]any{"issueId": "i5"}, "usageJson": map[string]any{"costUsd": 0.2}},
			{"status": "succeeded", "contextSnapshot": map[string]any{"issueId": "i5"}, "usageJson": map[string]any{"costUsd": 0.18}},
		})
	})
	mux.HandleFunc("/api/issues/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || !strings.HasSuffix(r.URL.Path, "/comments") {
			http.NotFound(w, r)
			return
		}
		if strings.Contains(r.URL.Path, "/missing/") {
			w.WriteHeader(http.StatusNotFound)
			reply(w, map[string]any{"error": "Issue not found"})
			return
		}
		b, _ := io.ReadAll(r.Body)
		m := map[string]any{}
		_ = json.Unmarshal(b, &m)
		m["path"] = r.URL.Path
		*posted = m
		w.WriteHeader(http.StatusCreated)
		reply(w, map[string]any{"id": "cm1"})
	})
	return httptest.NewServer(mux)
}

func withBase(t *testing.T, base string) {
	t.Helper()
	old := pcBase
	pcBase = base
	t.Cleanup(func() { pcBase = old })
}

func TestLoadPaperclip(t *testing.T) {
	var posted map[string]any
	srv := fakePaperclip(t, &posted)
	defer srv.Close()
	withBase(t, srv.URL)

	st := loadPaperclip()
	if st.Err != "" {
		t.Fatalf("Err = %q", st.Err)
	}
	if len(st.Items) != 3 {
		t.Fatalf("got %d items, want 3 (COS-5 once, COS-7, COS-8): %+v", len(st.Items), st.Items)
	}
	first := st.Items[0]
	if first.Ref != "COS-5" || !first.Needs || first.Agent != "Librarian" || first.Cost != "$0.38" ||
		first.URL != srv.URL+"/COS/issues/COS-5" || first.ID != "i5" {
		t.Errorf("first = %+v", first)
	}
	if !strings.Contains(first.Detail, "needs human attention") || !strings.Contains(first.Detail, "repair, retry") {
		t.Errorf("first.Detail should merge both reasons: %q", first.Detail)
	}
	if st.Items[1].Ref != "COS-7" || st.Items[1].Needs || st.Items[1].Detail != "run running" || st.Items[1].Cost != "$0.10" {
		t.Errorf("second = %+v", st.Items[1])
	}
	if st.Items[2].Ref != "COS-8" || st.Items[2].Detail != "todo" || st.Items[2].URL != srv.URL+"/COS/issues/COS-8" {
		t.Errorf("third = %+v", st.Items[2])
	}
}

func TestLoadPaperclipDown(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	base := srv.URL
	srv.Close() // nothing listens there now
	withBase(t, base)
	st := loadPaperclip()
	if !strings.HasPrefix(st.Err, "Paperclip isn't running") || len(st.Items) != 0 {
		t.Errorf("got %+v", st)
	}
}

func TestPCComment(t *testing.T) {
	var posted map[string]any
	srv := fakePaperclip(t, &posted)
	defer srv.Close()
	withBase(t, srv.URL)

	if err := pcComment("i5", "  please unblock  "); err != nil {
		t.Fatal(err)
	}
	if posted["body"] != "please unblock" || posted["path"] != "/api/issues/i5/comments" {
		t.Errorf("posted %+v", posted)
	}
	if id, _ := posted["clientRequestId"].(string); len(id) != 36 || id[14] != '4' {
		t.Errorf("clientRequestId %q is not a v4 uuid", id)
	}
	if _, ok := posted["authorType"]; ok {
		t.Errorf("must post as the board user, not set authorType: %+v", posted)
	}
	err := pcComment("missing", "x")
	if err == nil || !strings.Contains(err.Error(), "HTTP 404") || !strings.Contains(err.Error(), "Issue not found") {
		t.Errorf("err = %v", err)
	}
	if err := pcComment("i5", "   "); err == nil {
		t.Error("empty comment should fail")
	}
}

// TestPaperclipLive prints what the real instance returns (read-only). Run with PAPERCLIP_LIVE=1.
func TestPaperclipLive(t *testing.T) {
	if os.Getenv("PAPERCLIP_LIVE") == "" {
		t.Skip("set PAPERCLIP_LIVE=1")
	}
	st := loadPaperclip()
	t.Logf("err=%q items=%d", st.Err, len(st.Items))
	for _, it := range st.Items {
		t.Logf("%+v", it)
	}
}
