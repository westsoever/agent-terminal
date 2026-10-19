package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// gitFixture: a clone of a bare origin with branches in every state the panel tells apart, and one worktree.
//
//	main      the default branch, pushed
//	feat      2 commits not in main, never pushed, checked out in the worktree wt-feat (with a changed file)
//	shared    1 commit not in main, pushed, then 1 more commit not pushed
//	old       merged into main, pushed
//	theirs    on origin only (pushed from another clone), 1 commit not in main
func gitFixture(t *testing.T) (dir string) {
	t.Helper()
	root := t.TempDir()
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(root, "gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.WriteFile(filepath.Join(root, "gitconfig"), []byte("[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n"), 0o644)
	git := func(dir string, args ...string) {
		t.Helper()
		if out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	commit := func(dir, msg string) {
		t.Helper()
		os.WriteFile(filepath.Join(dir, strings.ReplaceAll(msg, " ", "-")), []byte(msg), 0o644)
		git(dir, "add", "-A")
		git(dir, "commit", "-qm", msg)
	}
	origin := filepath.Join(root, "origin.git")
	git(root, "init", "-q", "--bare", origin)
	dir = filepath.Join(root, "repo")
	git(root, "clone", "-q", origin, dir)
	commit(dir, "first")
	git(dir, "push", "-q", "-u", "origin", "main")
	git(dir, "remote", "set-head", "origin", "main")

	git(dir, "switch", "-qc", "old")
	commit(dir, "old work")
	git(dir, "push", "-q", "-u", "origin", "old")
	git(dir, "switch", "-q", "main")
	git(dir, "merge", "-q", "--ff-only", "old")
	git(dir, "push", "-q")

	git(dir, "switch", "-qc", "shared")
	commit(dir, "shared one")
	git(dir, "push", "-q", "-u", "origin", "shared")
	commit(dir, "shared two")
	git(dir, "switch", "-q", "main")

	other := filepath.Join(root, "other")
	git(root, "clone", "-q", origin, other)
	git(other, "switch", "-qc", "theirs")
	commit(other, "their work")
	git(other, "push", "-q", "origin", "theirs")
	git(dir, "fetch", "-q")

	os.WriteFile(filepath.Join(dir, ".git", "info", "exclude"), []byte(".claude/\n"), 0o644) // as kaching's own .gitignore has it
	git(dir, "branch", "feat")
	wt := filepath.Join(dir, ".claude", "worktrees", "wt-feat")
	git(dir, "worktree", "add", "-q", wt, "feat")
	commit(wt, "feat one")
	commit(wt, "feat two")
	os.WriteFile(filepath.Join(wt, "wip"), []byte("x"), 0o644)
	return dir
}

func TestLoadBranches(t *testing.T) {
	dir := gitFixture(t)
	st := loadBranches(dir)
	if st.Err != "" || st.Base != "origin/main" {
		t.Fatalf("err %q base %q", st.Err, st.Base)
	}
	var names []string
	for _, b := range st.Items {
		names = append(names, b.Name)
	}
	// main first; then the local ones with work main lacks, the last committed first; then old (merged); then
	// origin's own (theirs; origin/old and origin/shared have their local twins)
	if got := strings.Join(names, " "); got != "main feat shared old origin/theirs" {
		t.Fatalf("order: %s", got)
	}
	feat := st.find("feat")
	if feat.Worktree != filepath.Join(dir, ".claude", "worktrees", "wt-feat") || feat.Ahead != 2 || feat.Upstream != "" || feat.Subject != "feat two" {
		t.Fatalf("feat = %+v", *feat)
	}
	if sh := st.find("shared"); sh.Ahead != 2 || sh.Upstream != "origin/shared" || sh.Push != 1 || sh.Pull != 0 || sh.Worktree != "" {
		t.Fatalf("shared = %+v", *sh)
	}
	if old := st.find("old"); old.Ahead != 0 || old.Push != 0 {
		t.Fatalf("old = %+v", *old)
	}
	if th := st.find("origin/theirs"); !th.Remote || th.Ahead != 1 {
		t.Fatalf("theirs = %+v", *th)
	}
	if st.local() != 4 || st.unmerged() != 3 {
		t.Fatalf("local %d unmerged %d", st.local(), st.unmerged())
	}
	if len(st.Trees) != 2 || !st.Trees[0].Main || st.Trees[1].Branch != "feat" || st.Trees[1].Dirty != 1 || st.Trees[0].Dirty != 0 {
		t.Fatalf("trees = %+v", st.Trees)
	}
	if nb, nw := refCounts(dir); nb != 4 || nw != 1 {
		t.Fatalf("refCounts = %d branches, %d worktrees", nb, nw)
	}
}

func TestParseTrack(t *testing.T) {
	for in, want := range map[string][3]int{"": {0, 0, 0}, "ahead 3": {3, 0, 0}, "behind 2": {0, 2, 0},
		"ahead 1, behind 4": {1, 4, 0}, "gone": {0, 0, 1}} {
		push, pull, gone := parseTrack(in)
		g := 0
		if gone {
			g = 1
		}
		if [3]int{push, pull, g} != want {
			t.Errorf("parseTrack(%q) = %d %d %v", in, push, pull, gone)
		}
	}
}

// A repo on GitHub only: the branch names, page after page.
func TestGHBranches(t *testing.T) {
	old := ghBranches
	t.Cleanup(func() { ghBranches = old })
	ghBranches = func(_ context.Context, remote string) ([]byte, error) {
		return []byte(`[{"name":"main"},{"name":"a"}]` + "\n" + `[{"name":"b"}]`), nil
	}
	st := loadGHBranches("o/r")
	if st.Err != "" || len(st.Items) != 3 || st.Items[2].Name != "origin/b" || !st.Items[2].Remote || !st.GHOnly {
		t.Fatalf("%+v", st)
	}
}

// pressBR presses keys in the RP view; a branch read it starts runs and comes back, an agent it would start does
// not (the last key's command is returned).
func pressBR(t *testing.T, m model, keys ...string) (model, tea.Cmd) {
	t.Helper()
	var cmd tea.Cmd
	for _, k := range keys {
		msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		switch k {
		case "enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		}
		var mm tea.Model
		mm, cmd = m.Update(msg)
		m = mm.(model)
		if cmd != nil && (k == "b" || k == "w" || k == "f") {
			if res, ok := cmd().(branchesMsg); ok {
				mm, _ = m.Update(res)
				m = mm.(model)
			}
		}
	}
	return m, cmd
}

func TestBranchPanelKeys(t *testing.T) {
	got := stubOpen(t)
	dir := gitFixture(t)
	m := repoModel(t, Repo{Name: "repo", Dir: dir, Remote: "o/repo"})
	m, _ = pressBR(t, m, "b")
	p := m.branches
	if p == nil || p.trees || len(p.st.Items) != 5 || m.tree != nil {
		t.Fatalf("b must open the branch panel: %+v", p)
	}
	v := escRe.ReplaceAllString(strings.Join(m.reposView(30), "\n"), "")
	for _, want := range []string{"repo branches", "4 local · 1 on origin only · 3 not in origin/main · 1 worktrees",
		"ON ORIGIN ONLY", "origin/theirs", "not pushed", "↑1", "merged", "+2 −0", "⌂ feat"} {
		if !strings.Contains(v, want) {
			t.Fatalf("the panel must show %q:\n%s", want, v)
		}
	}
	// main: no merge of the default branch
	if m, cmd := pressBR(t, m, "2"); cmd != nil || !m.statusErr || !strings.Contains(m.status, "main is the default branch") {
		t.Fatalf("2 on main: %q", m.status)
	}
	// old is merged: nothing to merge; a review is still started
	m, _ = pressBR(t, m, "l", "l", "l")
	if b := m.branches.branch(); b.Name != "old" {
		t.Fatalf("selected %s", b.Name)
	}
	if m, cmd := pressBR(t, m, "2"); cmd != nil || !strings.Contains(m.status, "old has nothing that origin/main lacks") {
		t.Fatalf("2 on old: %q", m.status)
	}
	if m, cmd := pressBR(t, m, "1"); cmd == nil || !strings.Contains(m.status, "starting an agent on repo:old") {
		t.Fatalf("1 on old: %q", m.status)
	}
	// feat: g has nothing on GitHub; enter opens its worktree; k writes the task
	m, _ = pressBR(t, m, "j", "j")
	if m, _ := pressBR(t, m, "g"); !strings.Contains(m.status, "feat is not on GitHub") {
		t.Fatalf("g on feat: %q", m.status)
	}
	m, _ = pressBR(t, m, "enter")
	if len(*got) != 1 || !strings.HasSuffix((*got)[0].path, "wt-feat") {
		t.Fatalf("enter on feat: %+v", *got)
	}
	if mk, _ := pressBR(t, m, "k"); mk.mode != mTyping || mk.ed.target != "br:feat" {
		t.Fatalf("k: mode %d target %q", mk.mode, mk.ed.target)
	}
	// shared is on GitHub
	m, _ = pressBR(t, m, "l", "g")
	if (*got)[1].path != "https://github.com/o/repo/tree/shared" {
		t.Fatalf("g on shared: %+v", *got)
	}
	// w: the worktrees of the same repo, no read again; 1-3 act on the worktree's branch
	m, _ = pressBR(t, m, "w")
	if !m.branches.trees || len(m.branches.st.Trees) != 2 {
		t.Fatalf("w: %+v", m.branches)
	}
	v = escRe.ReplaceAllString(strings.Join(m.reposView(30), "\n"), "")
	for _, want := range []string{"repo worktrees", "(the clone's own folder)", ".claude/worktrees/wt-feat", "1 changed", "clean"} {
		if !strings.Contains(v, want) {
			t.Fatalf("the worktree panel must show %q:\n%s", want, v)
		}
	}
	m, _ = pressBR(t, m, "l")
	if b := m.branches.branch(); b == nil || b.Name != "feat" {
		t.Fatalf("the worktree's branch: %+v", b)
	}
	if m, cmd := pressBR(t, m, "3"); cmd == nil || !strings.Contains(m.status, "repo:feat") {
		t.Fatalf("3 on the worktree: %q", m.status)
	}
	// esc closes the panel, then the view
	m, _ = pressBR(t, m, "esc")
	if m.branches != nil || m.view != vRepos {
		t.Fatal("esc must close the panel first")
	}
}

func TestBranchPrompt(t *testing.T) {
	r := Repo{Name: "repo", Dir: "/x/repo", Remote: "o/repo"}
	st := Branches{Base: "origin/main"}
	p := branchPrompt(r, st, Branch{Name: "feat", Ahead: 2, Behind: 1}, "fix the tests")
	for _, want := range []string{"Branch feat of repo (o/repo on GitHub), local clone /x/repo.", "not checked out in any worktree",
		"Against origin/main: 2 commits that origin/main does not have, and it is 1 commits behind it.", "My comment on it:\nfix the tests", "your own git worktree"} {
		if !strings.Contains(p, want) {
			t.Fatalf("the prompt must say %q:\n%s", want, p)
		}
	}
	p = branchPrompt(r, st, Branch{Name: "feat", Worktree: "/x/repo/wt"}, "x")
	if !strings.Contains(p, "checked out in the worktree /x/repo/wt") || strings.Contains(p, "your own git worktree") {
		t.Fatalf("a branch in a worktree:\n%s", p)
	}
}
