package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-runewidth"
)

func mkRepo(t *testing.T, dir, origin string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := "[core]\n\tbare = false\n"
	if origin != "" {
		cfg += "[remote \"upstream\"]\n\turl = https://github.com/other/thing.git\n[remote \"origin\"]\n\turl = " + origin + "\n"
	}
	if err := os.WriteFile(filepath.Join(dir, ".git", "config"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
}

func stubGH(t *testing.T, repos map[string]string) {
	t.Helper()
	old := ghRepoList
	t.Cleanup(func() { ghRepoList = old })
	ghRepoList = func(_ context.Context, owner string) ([]byte, error) { return []byte(repos[owner]), nil }
}

// The list: the clones with sync-check notes first in its order, then the other clones by name, then the GitHub
// repos with no clone here. A clone's GitHub twin is not listed twice.
func TestRepoListOrder(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("AGENT_HOME", filepath.Join(home, ".agent"))
	t.Setenv("AGENT_REPOS_FILE", "")
	mkRepo(t, filepath.Join(home, "bbq", "alpha"), "https://github.com/technobbq/alpha.git")
	mkRepo(t, filepath.Join(home, "bbq", "beta"), "")
	mkRepo(t, filepath.Join(home, "Zed"), "git@github.com:westsoever/zed.git")
	mkRepo(t, filepath.Join(home, "far", "gamma"), "https://www.github.com/westsoever/gamma")
	mkRepo(t, filepath.Join(home, "Library", "hidden"), "") // macOS guards ~/Library: never looked in
	os.MkdirAll(filepath.Join(home, "notes"), 0o755)
	sync := []string{"generated: x", "", "## gamma -- oldest 3d", "path: " + filepath.Join(home, "far", "gamma"),
		"needs: 1 stash", "age_h: 70", "- stash: 1 entry (oldest 3d)", "",
		"## alpha -- oldest 1h", "path: " + filepath.Join(home, "bbq", "alpha"), "needs: 2 unpushed commits", "age_h: 1",
		"- unpushed: main +2 (1h)", "", "clean: beta"}
	stubGH(t, map[string]string{
		"westsoever": `[{"nameWithOwner":"westsoever/zed"},{"nameWithOwner":"westsoever/web"}]`,
		"technobbq":  `[{"nameWithOwner":"technobbq/Alpha"},{"nameWithOwner":"technobbq/api"}]`})
	got := repoList(localRepos(sync), loadGHRepos())
	var names []string
	for _, r := range got {
		names = append(names, r.Name)
	}
	if strings.Join(names, " ") != "gamma alpha beta Zed api web" {
		t.Fatalf("order: %v", names)
	}
	if a := got[1]; a.Remote != "technobbq/Alpha" { // GitHub's spelling
		t.Fatalf("alpha = %+v", a)
	}
	if g := got[0]; g.Remote != "westsoever/gamma" || g.Needs != "1 stash" || len(g.Notes) != 1 || g.Dir == "" {
		t.Fatalf("gamma = %+v", g)
	}
	if b := got[2]; b.Remote != "" || b.Needs != "" {
		t.Fatalf("beta = %+v", b)
	}
	if a := got[4]; a.Dir != "" || a.Remote != "technobbq/api" {
		t.Fatalf("api = %+v", a)
	}
	// a failed GitHub read keeps the last list
	ghRepoList = func(context.Context, string) ([]byte, error) { return nil, errors.New("not logged in") }
	kept := GHRepos{Items: []string{"westsoever/web"}}.merge(loadGHRepos())
	if len(kept.Items) != 1 || kept.Err != "gh repo list westsoever: not logged in" {
		t.Fatalf("merge = %+v", kept)
	}
}

type opened struct{ cmd, path string }

func stubOpen(t *testing.T) *[]opened {
	t.Helper()
	var got []opened
	old := repoOpen
	t.Cleanup(func() { repoOpen = old })
	repoOpen = func(cmd, path string) error { got = append(got, opened{cmd, path}); return nil }
	return &got
}

func pressRP(t *testing.T, m model, keys ...string) model {
	t.Helper()
	for _, k := range keys {
		var msg tea.KeyMsg
		switch k {
		case "enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		case "backspace":
			msg = tea.KeyMsg{Type: tea.KeyBackspace}
		case "alt+enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter, Alt: true}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		mm, cmd := m.Update(msg)
		m = mm.(model)
		if cmd != nil { // run what it started (a folder read on GitHub) and hand the result back
			if res := cmd(); res != nil {
				if _, ok := res.(treeMsg); ok {
					mm, _ = m.Update(res)
					m = mm.(model)
				}
			}
		}
	}
	return m
}

func repoModel(t *testing.T, repos ...Repo) model {
	t.Helper()
	t.Setenv("AGENT_HOME", t.TempDir())
	m := newModel()
	m.w, m.h = 160, 40
	m.view, m.repos = vRepos, repos
	return m
}

// Enter opens the folder; a repo on GitHub only asks first, and only enter or y opens it. b and option+enter
// open it on GitHub straight away; shift+enter too, from a terminal that sends it apart from enter.
func TestRepoEnterAndGitHub(t *testing.T) {
	got := stubOpen(t)
	local := Repo{Name: "miso", Remote: "technobbq/miso", Dir: "/x/miso"}
	only := Repo{Name: "web", Remote: "westsoever/web"}
	m := repoModel(t, local, only)
	m = pressRP(t, m, "enter")
	if len(*got) != 1 || (*got)[0] != (opened{"open", "/x/miso"}) {
		t.Fatalf("enter on a clone: %+v", *got)
	}
	m = pressRP(t, m, "l", "enter")
	if m.mode != mConfirm || len(*got) != 1 {
		t.Fatalf("enter on github only: mode %d, opened %+v", m.mode, *got)
	}
	if line := escRe.ReplaceAllString(m.commandLine(), ""); !strings.Contains(line, "No local folder. Open it on GitHub?") {
		t.Fatalf("command line: %q", line)
	}
	m = pressRP(t, m, "esc")
	if m.mode != mKeys || m.view != vRepos || len(*got) != 1 {
		t.Fatalf("esc must only cancel: mode %d view %d %+v", m.mode, m.view, *got)
	}
	m = pressRP(t, m, "enter", "y")
	if len(*got) != 2 || (*got)[1].path != "https://github.com/westsoever/web" {
		t.Fatalf("y: %+v", *got)
	}
	m = pressRP(t, m, "enter", "enter")
	if len(*got) != 3 {
		t.Fatalf("enter, enter: %+v", *got)
	}
	m = pressRP(t, m, "j", "g", "alt+enter")
	if len(*got) != 5 || (*got)[3].path != "https://github.com/technobbq/miso" || (*got)[4] != (*got)[3] {
		t.Fatalf("g, option+enter: %+v", *got)
	}
	mm, _ := m.Update(fakeCSI("?CSI[49 51 59 50 117]?"))
	if m = mm.(model); len(*got) != 6 {
		t.Fatalf("shift+enter (CSI u): %+v", *got)
	}
	// no key in RP reaches the agent behind it: k is the folder panel, not a reply
	if m = pressRP(t, m, "o", "g", "3"); m.mode != mKeys {
		t.Fatalf("mode %d", m.mode)
	}
}

type fakeCSI string

func (f fakeCSI) String() string { return string(f) }

// k shows the repo's folders on the right: folders first, .git hidden; k goes into a folder, k on a file opens
// it, .. and h go up to the folder it came from; esc closes the panel, a second esc goes to the desk.
func TestRepoTree(t *testing.T) {
	got := stubOpen(t)
	root := t.TempDir()
	for _, d := range []string{".git", "src/inner", "docs"} {
		os.MkdirAll(filepath.Join(root, d), 0o755)
	}
	for _, f := range []string{"README.md", "src/main.go", ".gitignore"} {
		os.WriteFile(filepath.Join(root, f), nil, 0o644)
	}
	m := repoModel(t, Repo{Name: "r", Dir: root, Remote: "o/r"})
	m.cfg.OpenCmd = "myopen"
	m = pressRP(t, m, "k")
	names := func() string {
		var n []string
		for _, e := range m.tree.items {
			n = append(n, e.Name)
		}
		return strings.Join(n, " ")
	}
	if m.tree == nil || names() != "docs src .gitignore README.md" {
		t.Fatalf("root: %v", m.tree)
	}
	m = pressRP(t, m, "l", "k")
	if m.tree.rel != "src" || names() != ".. inner main.go" {
		t.Fatalf("src: %q %s", m.tree.rel, names())
	}
	m = pressRP(t, m, "l", "l", "k")
	if len(*got) != 1 || (*got)[0] != (opened{"myopen", filepath.Join(root, "src", "main.go")}) {
		t.Fatalf("k on a file: %+v", *got)
	}
	m = pressRP(t, m, "j", "enter")
	if (*got)[1] != (opened{"open", filepath.Join(root, "src", "inner")}) {
		t.Fatalf("enter on a folder: %+v", *got)
	}
	m = pressRP(t, m, "g")
	if (*got)[2].path != "https://github.com/o/r/tree/HEAD/src" {
		t.Fatalf("g in the panel: %+v", *got)
	}
	m = pressRP(t, m, "j", "j", "k") // .. goes up, back on src
	if m.tree.rel != "" || m.tree.items[m.tree.sel].Name != "src" {
		t.Fatalf("up: %q sel %d", m.tree.rel, m.tree.sel)
	}
	m = pressRP(t, m, "k", "h")
	if m.tree.rel != "" || m.tree.items[m.tree.sel].Name != "src" {
		t.Fatalf("h: %q sel %d", m.tree.rel, m.tree.sel)
	}
	m = pressRP(t, m, "esc")
	if m.tree != nil || m.view != vRepos {
		t.Fatalf("esc: tree %v view %d", m.tree, m.view)
	}
	if m = pressRP(t, m, "esc"); m.view != vDesk {
		t.Fatalf("second esc: view %d", m.view)
	}
}

// A repo on GitHub only shows its folders from gh api; a file there opens its GitHub page.
func TestRepoTreeGitHub(t *testing.T) {
	got := stubOpen(t)
	old := ghContents
	defer func() { ghContents = old }()
	var asked []string
	ghContents = func(_ context.Context, remote, rel string) ([]byte, error) {
		asked = append(asked, remote+":"+rel)
		if rel == "" {
			return []byte(`[{"name":"go.mod","type":"file","html_url":"https://github.com/o/w/blob/main/go.mod"},
				{"name":"cmd","type":"dir","html_url":"https://github.com/o/w/tree/main/cmd"}]`), nil
		}
		return []byte(`[{"name":"main.go","type":"file","html_url":"https://github.com/o/w/blob/main/cmd/main.go"}]`), nil
	}
	m := repoModel(t, Repo{Name: "w", Remote: "o/w"})
	m = pressRP(t, m, "k")
	if len(m.tree.items) != 2 || m.tree.items[0].Name != "cmd" || m.tree.loading {
		t.Fatalf("root: %+v", m.tree)
	}
	m = pressRP(t, m, "k", "l", "k")
	if strings.Join(asked, " ") != "o/w: o/w:cmd" || len(*got) != 1 || (*got)[0].path != "https://github.com/o/w/blob/main/cmd/main.go" {
		t.Fatalf("asked %v opened %+v", asked, *got)
	}
	// an answer for a folder no longer shown is dropped
	mm, _ := m.Update(treeMsg{key: "o/w", rel: "other", items: []treeEntry{{Name: "x"}}})
	if m = mm.(model); m.tree.rel != "cmd" || len(m.tree.items) != 2 {
		t.Fatalf("stale answer applied: %+v", m.tree)
	}
}

// RP fits every size, with and without the folder panel.
func TestRepoViewGeometry(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 60; i++ {
		os.WriteFile(filepath.Join(root, "file-with-a-rather-long-name-"+itoa(i)+".md"), nil, 0o644)
	}
	repos := []Repo{{Name: "a-repo-with-a-very-long-name-indeed", Remote: "technobbq/a-repo-with-a-very-long-name-indeed",
		Dir: root, Needs: "8 commits behind origin", Notes: []string{"behind origin: main -8 (6d)"}}}
	for i := 0; i < 50; i++ {
		repos = append(repos, Repo{Name: "r" + itoa(i), Remote: "o/r" + itoa(i)})
	}
	m := repoModel(t, repos...)
	for _, open := range []bool{false, true} {
		m.tree = nil
		if open {
			m.tree = &repoTree{repo: repos[0]}
			m.tree.show("")
			m.tree.sel = 55
		}
		for _, sz := range [][2]int{{80, 24}, {120, 40}, {200, 60}} {
			m.w, m.h = sz[0], sz[1]
			lines := strings.Split(m.View(), "\n")
			if len(lines) != m.h {
				t.Errorf("panel %v %dx%d: %d lines", open, m.w, m.h, len(lines))
			}
			for i, l := range lines {
				if w := runewidth.StringWidth(ansiRe.ReplaceAllString(l, "")); w > m.w {
					t.Errorf("panel %v %dx%d line %d: width %d", open, m.w, m.h, i, w)
				}
			}
			if open && !strings.Contains(m.View(), "> file-with-a-rather-long-name-") {
				t.Errorf("panel %dx%d: the selected file is not shown", m.w, m.h)
			}
		}
	}
	if os.Getenv("SHOW") != "" {
		m.w, m.h = 160, 30
		t.Log("\n" + ansiRe.ReplaceAllString(m.View(), ""))
	}
}

// i copies a path: the repo's folder in the list, the selected file or folder in the panel (.. is the folder shown),
// the GitHub address for what has no clone.
func TestRepoCopyPath(t *testing.T) {
	var copied []string
	old := copyText
	t.Cleanup(func() { copyText = old })
	copyText = func(s string) error { copied = append(copied, s); return nil }
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "src"), 0o755)
	os.WriteFile(filepath.Join(root, "src", "main.go"), nil, 0o644)
	m := repoModel(t, Repo{Name: "r", Dir: root, Remote: "o/r"}, Repo{Name: "web", Remote: "westsoever/web"})
	m = pressRP(t, m, "i")
	if len(copied) != 1 || copied[0] != root {
		t.Fatalf("i on a clone: %q", copied)
	}
	if line := escRe.ReplaceAllString(m.commandLine(), ""); !strings.Contains(line, "copied ") {
		t.Fatalf("status: %q", line)
	}
	m = pressRP(t, m, "k", "i") // the panel: src is first
	m = pressRP(t, m, "k", "i") // into src: .. is first
	m = pressRP(t, m, "l", "i")
	src := filepath.Join(root, "src")
	if want := []string{root, src, src, filepath.Join(src, "main.go")}; !reflect.DeepEqual(copied, want) {
		t.Fatalf("panel: %q, want %q", copied, want)
	}
	m = pressRP(t, m, "esc", "l", "i")
	if got := copied[len(copied)-1]; got != "https://github.com/westsoever/web" {
		t.Fatalf("i without a clone: %q", got)
	}
	m = pressRP(t, m, "esc")
	if m.view != vDesk {
		t.Fatalf("view %d", m.view)
	}
}

// The list: the 10 repos worked on last, the newest first, then all the others from A to Z; a repo never worked on
// (no time) is never in the first part.
func TestRecentFirst(t *testing.T) {
	now := time.Now()
	var rs []Repo
	for i := 0; i < 13; i++ {
		rs = append(rs, Repo{Name: string(rune('m' - i)), At: now.Add(-time.Duration(i) * time.Hour)})
	}
	rs = append(rs, Repo{Name: "Zero"}, Repo{Name: "alpha"})
	out, n := recentFirst(rs)
	var names []string
	for _, r := range out {
		names = append(names, r.Name)
	}
	if n != 10 || strings.Join(names, " ") != "m l k j i h g f e d a alpha b c Zero" {
		t.Fatalf("n %d order %v", n, names)
	}
	if _, n := recentFirst([]Repo{{Name: "x"}, {Name: "y", At: now}}); n != 1 {
		t.Fatalf("one with a time: n %d", n)
	}
}

// The two parts are headed; the title has no keys (they are in the footer).
func TestRepoListParts(t *testing.T) {
	m := repoModel(t, Repo{Name: "new", Dir: "/x/new", At: time.Now()}, Repo{Name: "old", Dir: "/x/old"})
	m.repoRecent = 1
	v := escRe.ReplaceAllString(strings.Join(m.reposView(12), "\n"), "")
	if !strings.Contains(v, "MOST RECENT · the 1 worked on last") || !strings.Contains(v, "ALL REPOSITORIES · the others, A–Z") {
		t.Fatalf("the parts must be headed:\n%s", v)
	}
	if strings.Contains(v, "enter opens") || strings.Index(v, "new") > strings.Index(v, "ALL REPOSITORIES") {
		t.Fatalf("no keys in the title, new in the first part:\n%s", v)
	}
	m = pressRP(t, m, "k") // the narrow list beside a panel is in parts too
	if v := escRe.ReplaceAllString(strings.Join(m.reposView(12), "\n"), ""); !strings.Contains(v, "MOST RECENT") || !strings.Contains(v, "ALL REPOSITORIES") {
		t.Fatalf("the narrow list:\n%s", v)
	}
}

// A clone was worked on when its HEAD log, or a worktree's, last changed.
func TestGitActive(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".git", "logs"), 0o755)
	os.MkdirAll(filepath.Join(dir, ".git", "worktrees", "w", "logs"), 0o755)
	if !gitActive(dir).IsZero() {
		t.Fatal("no logs: no time")
	}
	main, wt := filepath.Join(dir, ".git", "logs", "HEAD"), filepath.Join(dir, ".git", "worktrees", "w", "logs", "HEAD")
	os.WriteFile(main, nil, 0o644)
	os.WriteFile(wt, nil, 0o644)
	old, newer := time.Now().Add(-48*time.Hour), time.Now().Add(-time.Hour)
	os.Chtimes(main, old, old)
	os.Chtimes(wt, newer, newer)
	if got := gitActive(dir); !got.Equal(newer.Truncate(time.Second)) && got.Sub(newer).Abs() > time.Second {
		t.Fatalf("gitActive = %v, want the worktree's %v", got, newer)
	}
}
