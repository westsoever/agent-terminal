package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-runewidth"
)

const prJSON = `{"body":"Adds the thing.","headRefName":"feat/x","headRefOid":"abc123","baseRefName":"main","additions":21,"deletions":3,
	"files":[{"path":"a.go","additions":20,"deletions":3},{"path":"b.md","additions":1,"deletions":0}],
	"mergeable":"MERGEABLE","reviewDecision":"",
	"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"},{"status":"IN_PROGRESS","conclusion":""},{"state":"SUCCESS"}],
	"comments":[{"author":{"login":"ana"},"body":"later one","createdAt":"2026-10-17T12:00:00Z"}],
	"reviews":[{"author":{"login":"bo"},"body":"","state":"COMMENTED","submittedAt":"2026-10-17T11:00:00Z"},
		{"author":{"login":"bo"},"body":"fix b","state":"CHANGES_REQUESTED","submittedAt":"2026-10-17T10:00:00Z"}]}`

// The side panel reads gh pr view: branches, size, checks summed up, comments and reviews in time order.
func TestLoadPRDetail(t *testing.T) {
	old := ghPRView
	defer func() { ghPRView = old }()
	ghPRView = func(context.Context, string) ([]byte, error) { return []byte(prJSON), nil }
	d := loadPRDetail("u")
	if d.Err != "" || d.Head != "feat/x" || d.HeadSHA != "abc123" || d.Base != "main" || d.Add != 21 || len(d.Files) != 2 {
		t.Fatalf("detail = %+v", d)
	}
	if d.Checks != "2 passed, 1 failed, 1 running" {
		t.Fatalf("checks = %q", d.Checks)
	}
	if len(d.Thread) != 2 || d.Thread[0].State != "CHANGES_REQUESTED" || d.Thread[1].Body != "later one" {
		t.Fatalf("thread = %+v", d.Thread)
	}
	ghPRView = func(context.Context, string) ([]byte, error) {
		return nil, &exec.ExitError{Stderr: []byte("no\nsuch pr")}
	}
	if d := loadPRDetail("u"); d.Err != "gh pr view: no such pr" {
		t.Fatalf("err = %q", d.Err)
	}
}

func TestRemoteRepo(t *testing.T) {
	for in, want := range map[string]string{
		"https://github.com/technobbq/miso.git\n": "technobbq/miso",
		"https://www.github.com/technobbq/bbqos":  "technobbq/bbqos",
		"git@github.com:WestSoever/Cos.git":       "westsoever/cos",
		"https://gitlab.com/x/y.git":              "",
	} {
		if got := remoteRepo(in); got != want {
			t.Errorf("remoteRepo(%q) = %q, want %q", in, got, want)
		}
	}
}

// The agent runs in the repo's local clone; a folder named like the repo wins over another clone of it.
func TestPRCloneDir(t *testing.T) {
	root := t.TempDir()
	mk := func(name, url string) {
		dir := filepath.Join(root, name)
		os.MkdirAll(dir, 0o755)
		for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "origin", url}} {
			if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
				t.Fatalf("git %v: %s", args, out)
			}
		}
	}
	mk("aaa-copy", "https://github.com/o/ching.git")
	mk("ching", "https://github.com/o/ching.git")
	old := cloneRoots
	defer func() { cloneRoots, cloneCache = old, nil }()
	cloneRoots, cloneCache = func() []string { return []string{root} }, nil
	if got := prCloneDir("O/ching"); got != filepath.Join(root, "ching") {
		t.Fatalf("clone = %q", got)
	}
	if got := prCloneDir("o/none"); got != "" {
		t.Fatalf("no clone = %q", got)
	}
}

func TestPRPrompt(t *testing.T) {
	pr := PullReq{Repo: "o/a", Number: 4, Title: "Add x", URL: "https://github.com/o/a/pull/4"}
	p := prPrompt(pr, PRDetail{Head: "feat/x", Base: "main"}, "review this feature", true)
	for _, want := range []string{"o/a#4: Add x", pr.URL, "feat/x into main", "review this feature", "own git worktree"} {
		if !strings.Contains(p, want) {
			t.Errorf("prompt misses %q:\n%s", want, p)
		}
	}
	if strings.Contains(p, "no clone") {
		t.Errorf("cloned prompt says no clone")
	}
	if p := prPrompt(pr, PRDetail{}, "x", false); !strings.Contains(p, "no clone") {
		t.Errorf("no-clone prompt: %s", p)
	}
}

// While a pull request's panel is being read, moving onto it again starts no second gh; the answer frees it.
func TestPRDetailOneAtATime(t *testing.T) {
	m := newModel()
	m.view, m.prOpen = vPulls, true
	m.pulls = PullsState{Items: []PullReq{{URL: "u"}}}
	if m.prDetailCmd(time.Minute) == nil {
		t.Fatal("first read not started")
	}
	if m.prDetailCmd(0) != nil {
		t.Fatal("second read started while the first runs")
	}
	mm, _ := m.Update(prDetailMsg(PRDetail{URL: "u", At: time.Now()}))
	m = mm.(model)
	if m.prDetailCmd(0) == nil {
		t.Fatal("no read after the first answered")
	}
}

// k opens the panel, k again the comment box for that pull request; esc closes the box, then the panel; a number
// with the panel closed answers nothing.
func TestPRPanelKeys(t *testing.T) {
	m := newModel()
	m.w, m.h, m.view = 160, 40, vPulls
	pr := PullReq{Repo: "o/a", Number: 4, Title: "Add x", URL: "https://github.com/o/a/pull/4", Updated: time.Now()}
	m.pulls = PullsState{Items: []PullReq{pr}, At: time.Now()}
	m.prDet[pr.URL] = PRDetail{URL: pr.URL, At: time.Now(), Head: "feat/x", Base: "main", Body: "Adds the thing."}
	press := func(k string) {
		var msg tea.KeyMsg
		switch k {
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		mm, _ := m.Update(msg)
		m = mm.(model)
	}
	press("1")
	if m.mode != mKeys || m.prOpen {
		t.Fatalf("1 with the panel closed: mode %d open %v", m.mode, m.prOpen)
	}
	press("k")
	if !m.prOpen || m.mode != mKeys {
		t.Fatalf("k: open %v mode %d", m.prOpen, m.mode)
	}
	v := ansiRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "feat/x → main") || !strings.Contains(v, "Adds the thing.") || !strings.Contains(v, "1 review it") {
		t.Fatalf("panel:\n%s", v)
	}
	press("k")
	if m.mode != mTyping || m.ed.target != "pr:"+pr.URL {
		t.Fatalf("k again: mode %d target %q", m.mode, m.ed.target)
	}
	press("esc")
	if m.mode != mKeys || !m.prOpen {
		t.Fatalf("esc in the box: mode %d open %v", m.mode, m.prOpen)
	}
	press("esc")
	if m.prOpen || m.view != vPulls {
		t.Fatalf("esc: open %v view %d", m.prOpen, m.view)
	}
	press("esc")
	if m.view != vDesk {
		t.Fatalf("esc again: view %d", m.view)
	}
}

// The PR view with its panel open fits every screen size.
func TestPRPanelFits(t *testing.T) {
	m := newModel()
	m.view, m.prOpen = vPulls, true
	pr := PullReq{Repo: "westsoever/soii-dev", Number: 4, Title: strings.Repeat("a long title ", 12), URL: "u"}
	m.pulls = PullsState{Items: []PullReq{pr, {Repo: "o/b", Number: 1, URL: "v"}}}
	m.prDet["u"] = PRDetail{URL: "u", At: time.Now(), Head: "h", Base: "main", Body: strings.Repeat("body ", 200),
		Files: []PRFile{{Path: strings.Repeat("dir/", 30) + "f.go", Add: 1}}, Thread: []PRComment{{Author: "a", Body: "b", State: "APPROVED"}}}
	for _, sz := range [][2]int{{80, 24}, {120, 40}, {200, 60}} {
		m.w, m.h = sz[0], sz[1]
		lines := strings.Split(m.View(), "\n")
		if len(lines) != m.h {
			t.Errorf("%dx%d: %d lines", m.w, m.h, len(lines))
		}
		for i, l := range lines {
			if w := runewidth.StringWidth(ansiRe.ReplaceAllString(l, "")); w > m.w {
				t.Errorf("%dx%d line %d: width %d", m.w, m.h, i, w)
			}
		}
	}
}

// 2 merges at once with gh pr merge, no agent: pinned to the panel's commit, a merge commit where the repo allows
// one; it refuses on conflicts and on failed or running checks; the merged pull request leaves the list.
func TestPRMergeNow(t *testing.T) {
	old := ghMergeRun
	defer func() { ghMergeRun = old }()
	var calls []string
	allowed := `{"mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true}`
	ghMergeRun = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		if args[0] == "repo" {
			return []byte(allowed), nil
		}
		return nil, nil
	}
	m := newModel()
	m.w, m.h, m.view, m.prOpen = 160, 40, vPulls, true
	pr := PullReq{Repo: "o/a", Number: 4, Title: "Add x", URL: "https://github.com/o/a/pull/4", Updated: time.Now()}
	other := PullReq{Repo: "o/b", Number: 1, Title: "Other", URL: "https://github.com/o/b/pull/1", Updated: time.Now()}
	m.pulls = PullsState{Items: []PullReq{pr, other}, At: time.Now()}
	ready := PRDetail{URL: pr.URL, At: time.Now(), Head: "feat/x", HeadSHA: "abc123", Base: "main", Mergeable: "MERGEABLE", Checks: "2 passed"}
	press := func() tea.Cmd {
		mm, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("2")})
		m = mm.(model)
		return cmd
	}
	if v := ansiRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "2 merge it · now, with gh pr merge (no agent)") {
		t.Fatalf("panel:\n%s", v)
	}
	for _, c := range []struct {
		d     PRDetail
		draft bool
		why   string
	}{
		{PRDetail{URL: pr.URL, At: time.Now(), HeadSHA: "abc123", Mergeable: "CONFLICTING"}, false, "it has conflicts"},
		{PRDetail{URL: pr.URL, At: time.Now(), HeadSHA: "abc123", Checks: "1 passed, 1 failed"}, false, "checks: 1 passed, 1 failed"},
		{PRDetail{URL: pr.URL, At: time.Now(), HeadSHA: "abc123", Checks: "1 running"}, false, "checks: 1 running"},
		{PRDetail{URL: pr.URL, At: time.Now(), Err: "gh pr view: boom"}, false, "its panel has not loaded"},
		{ready, true, "it is a draft"},
	} {
		m.prDet[pr.URL], m.pulls.Items[0].Draft = c.d, c.draft
		press()
		if !strings.Contains(m.status, "not merged: o/a#4: "+c.why) || len(calls) != 0 {
			t.Fatalf("%q: status %q calls %v", c.why, m.status, calls)
		}
	}
	m.prDet[pr.URL], m.pulls.Items[0].Draft = ready, false
	cmd := press()
	if !strings.Contains(m.status, "merging o/a#4") || cmd == nil {
		t.Fatalf("status %q", m.status)
	}
	msg := cmd()
	if want := "pr merge " + pr.URL + " --merge --match-head-commit abc123"; len(calls) != 2 || calls[1] != want {
		t.Fatalf("calls = %q, want %q", calls, want)
	}
	mm, _ := m.Update(msg)
	m = mm.(model)
	if !strings.Contains(m.status, "✓ merged o/a#4 (merge)") || len(m.pulls.Items) != 1 || m.pulls.Items[0].URL != other.URL {
		t.Fatalf("after merge: status %q items %+v", m.status, m.pulls.Items)
	}

	// A repo with squash only; gh's own refusal shows in the status line.
	allowed, calls = `{"mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":false}`, nil
	ghMergeRun = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		if args[0] == "repo" {
			return []byte(allowed), nil
		}
		return []byte("X Pull request o/b#1 is not mergeable:\nthe base branch policy prohibits the merge.\n"), &exec.ExitError{}
	}
	m.prDet[other.URL] = PRDetail{URL: other.URL, At: time.Now(), HeadSHA: "def456"}
	mm, _ = m.Update(press()())
	m = mm.(model)
	if !strings.HasSuffix(calls[1], "--squash --match-head-commit def456") ||
		!strings.Contains(m.status, "not merged: o/b#1: gh pr merge: X Pull request o/b#1 is not mergeable: the base branch policy") ||
		len(m.pulls.Items) != 1 {
		t.Fatalf("squash/refused: calls %q status %q", calls, m.status)
	}
}

// 3 closes at once with gh pr close, no agent and no loaded panel; the closed pull request leaves the list, and
// gh's own refusal shows in the status line.
func TestPRCloseNow(t *testing.T) {
	old := ghMergeRun
	defer func() { ghMergeRun = old }()
	var calls []string
	var fail bool
	ghMergeRun = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		if fail {
			return []byte("GraphQL: Pull request is already closed\n"), &exec.ExitError{}
		}
		return nil, nil
	}
	m := newModel()
	m.w, m.h, m.view, m.prOpen = 160, 40, vPulls, true
	pr := PullReq{Repo: "o/a", Number: 4, Title: "Add x", URL: "https://github.com/o/a/pull/4", Updated: time.Now(), Draft: true}
	other := PullReq{Repo: "o/b", Number: 1, Title: "Other", URL: "https://github.com/o/b/pull/1", Updated: time.Now()}
	m.pulls = PullsState{Items: []PullReq{pr, other}, At: time.Now()}
	press := func() tea.Cmd {
		mm, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("3")})
		m = mm.(model)
		return cmd
	}
	if v := ansiRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "3 close it · now, with gh pr close (no agent)") {
		t.Fatalf("panel:\n%s", v)
	}
	cmd := press() // a draft whose panel has not loaded: close does not need either
	if !strings.Contains(m.status, "closing o/a#4") || cmd == nil {
		t.Fatalf("status %q", m.status)
	}
	msg := cmd()
	if want := "pr close " + pr.URL; len(calls) != 1 || calls[0] != want {
		t.Fatalf("calls = %q, want %q", calls, want)
	}
	mm, _ := m.Update(msg)
	m = mm.(model)
	if !strings.Contains(m.status, "✓ closed o/a#4") || len(m.pulls.Items) != 1 || m.pulls.Items[0].URL != other.URL {
		t.Fatalf("after close: status %q items %+v", m.status, m.pulls.Items)
	}

	fail, calls = true, nil
	mm, _ = m.Update(press()())
	m = mm.(model)
	if !strings.Contains(m.status, "not closed: o/b#1: gh pr close: GraphQL: Pull request is already closed") || len(m.pulls.Items) != 1 {
		t.Fatalf("refused: status %q items %+v", m.status, m.pulls.Items)
	}
}
