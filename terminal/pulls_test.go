package main

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// The PR view reads gh's JSON, the last updated first; a failing gh shows its error instead of the list.
func TestLoadPulls(t *testing.T) {
	old := ghPulls
	defer func() { ghPulls = old }()
	ghPulls = func(context.Context) ([]byte, error) {
		return []byte(`[
			{"number":4,"title":"old","url":"https://github.com/o/a/pull/4","isDraft":false,"updatedAt":"2026-10-16T10:00:00Z","repository":{"nameWithOwner":"o/a"},"author":{"login":"me"}},
			{"number":12,"title":"new","url":"https://github.com/o/b/pull/12","isDraft":true,"updatedAt":"2026-10-17T19:37:08Z","repository":{"nameWithOwner":"o/b"},"author":{"login":"me"}}]`), nil
	}
	st := loadPulls()
	if st.Err != "" || len(st.Items) != 2 {
		t.Fatalf("pulls = %+v", st)
	}
	if p := st.Items[0]; p.Repo != "o/b" || p.Number != 12 || !p.Draft || p.URL != "https://github.com/o/b/pull/12" {
		t.Fatalf("first = %+v", p)
	}
	ghPulls = func(context.Context) ([]byte, error) { return nil, errors.New("not logged in") }
	if st := loadPulls(); !strings.Contains(st.Err, "not logged in") || len(st.Items) != 0 {
		t.Fatalf("error state = %+v", st)
	}
}

// /pr opens the pull requests, /po the proposals; the agents tab is gone (W still shows the wall).
func TestPullsAndProposalsCodes(t *testing.T) {
	m := newModel()
	m.w, m.h = 160, 40
	mm, _ := m.command("pr")
	if mm.(model).view != vPulls {
		t.Fatalf("/pr: view %d", mm.(model).view)
	}
	mm, _ = m.command("po")
	if mm.(model).view != vProposals {
		t.Fatalf("/po: view %d", mm.(model).view)
	}
	m.pulls = PullsState{Items: []PullReq{{Repo: "o/a", Number: 1}, {Repo: "o/b", Number: 2}}}
	m.w = 200
	bar := escRe.ReplaceAllString(m.tabBar()[1], "")
	if !strings.Contains(bar, "PR pull requests  2") || !strings.Contains(bar, "PO proposals") || strings.Contains(bar, "agents") {
		t.Fatalf("tab bar: %q", bar)
	}
	m.w = 140 // no room for the label: the count stays
	if bar := escRe.ReplaceAllString(m.tabBar()[1], ""); !strings.Contains(bar, "PR  2") {
		t.Fatalf("narrow tab bar: %q", bar)
	}
	mm, _ = m.command("W")
	if mm.(model).view != vWall {
		t.Fatalf("/W: view %d", mm.(model).view)
	}
}
