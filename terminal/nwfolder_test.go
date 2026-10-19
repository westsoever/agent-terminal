package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// nwRepo makes a git repo with one commit and, when wt is set, a linked worktree of it. Paths are the real ones.
func nwRepo(t *testing.T, dir string, wt string) {
	t.Helper()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@t"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	os.MkdirAll(dir, 0o755)
	run("init", "-q", "-b", "main")
	run("commit", "-q", "--allow-empty", "-m", "first")
	if wt != "" {
		run("worktree", "add", "-q", "-b", "feature", wt)
	}
}

func realPath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// /NW never falls back to the home folder, reads "." and ".." from the selected agent's folder, and says
// where it found the folder and what is there.
func TestResolveNWFolders(t *testing.T) {
	home := realPath(t, t.TempDir())
	t.Setenv("HOME", home)
	bbq := filepath.Join(home, "bbq")
	soii := filepath.Join(bbq, "soii")
	nwRepo(t, soii, "")
	plain := filepath.Join(home, "plain")
	os.MkdirAll(plain, 0o755)
	m := newModel()

	if _, err := m.resolveNW(""); err == nil || !strings.Contains(err.Error(), "no agent is selected") {
		t.Errorf("NW with nothing selected: err %v", err)
	}
	if _, err := m.resolveNW("./x"); err == nil || !strings.Contains(err.Error(), "none is selected") {
		t.Errorf("NW ./x with nothing selected: err %v", err)
	}

	m.agents = []Agent{{SID: "s1", Name: "soii-main", Cwd: soii}}
	m.selSID = "s1"
	f, err := m.resolveNW("")
	if err != nil || f.Dir != soii || f.Branch != "main" || !f.Repo || f.Main != "" || f.note() != "" ||
		f.Source != "the selected agent soii-main" {
		t.Errorf("NW = %+v, %v", f, err)
	}
	if f, err = m.resolveNW("."); err != nil || f.Dir != soii {
		t.Errorf("NW . = %+v, %v", f, err)
	}
	if f, err = m.resolveNW(".."); err != nil || f.Dir != bbq {
		t.Errorf("NW .. = %+v, %v", f, err)
	}
	if _, err = m.resolveNW("./nope"); err == nil {
		t.Error("NW ./nope should be an error")
	}

	f, _ = m.resolveNW("~")
	if f.Dir != home || !strings.Contains(f.note(), "home folder") {
		t.Errorf("NW ~ = %+v note %q", f, f.note())
	}
	f, _ = m.resolveNW("~/plain")
	if f.Dir != plain || f.note() != "not a git repo" {
		t.Errorf("NW ~/plain = %+v note %q", f, f.note())
	}
	f, _ = m.resolveNW("soii")
	if f.Dir != soii || f.Source != "the folder ~/bbq/soii" {
		t.Errorf("NW soii = %+v", f)
	}
}

// A linked worktree: the selected agent's own folder is kept but flagged; a name resolves to the main checkout.
func TestResolveNWWorktree(t *testing.T) {
	home := realPath(t, t.TempDir())
	t.Setenv("HOME", home)
	miso := filepath.Join(home, "bbq", "miso")
	wt := filepath.Join(home, "elsewhere", "miso-feature")
	os.MkdirAll(filepath.Dir(wt), 0o755)
	nwRepo(t, miso, wt)
	m := newModel()
	m.agents = []Agent{{SID: "s1", Name: "miso-feature", Cwd: wt}}
	m.selSID = "s1"

	f, err := m.resolveNW("")
	if err != nil || f.Dir != wt || f.Main != miso || f.Branch != "feature" ||
		!strings.Contains(f.note(), "a worktree of "+tildify(miso)) {
		t.Errorf("NW from a worktree agent = %+v, %v (note %q)", f, err, f.note())
	}
	// the agent's name leads to the repo, not the worktree
	f, err = m.resolveNW("miso-f")
	if err != nil || f.Dir != miso || f.Main != "" || f.note() != "" || f.Source != "the agent miso-feature" {
		t.Errorf("NW miso-f = %+v, %v", f, err)
	}
}

// A name that fits several folders is an error that lists them; an exact ~/bbq folder always wins.
func TestResolveNWAmbiguous(t *testing.T) {
	home := realPath(t, t.TempDir())
	t.Setenv("HOME", home)
	for _, n := range []string{"miso", "mine"} {
		os.MkdirAll(filepath.Join(home, "bbq", n), 0o755)
	}
	other := filepath.Join(home, "other")
	os.MkdirAll(other, 0o755)
	m := newModel()
	m.agents = []Agent{{SID: "s1", Name: "mixer", Cwd: other}}

	_, err := m.resolveNW("mi")
	if err == nil {
		t.Fatal("NW mi should be ambiguous")
	}
	for _, want := range []string{"~/bbq/miso", "~/bbq/mine", "~/other", "agent mixer", "write more"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q lacks %q", err, want)
		}
	}
	if f, err := m.resolveNW("miso"); err != nil || f.Dir != filepath.Join(home, "bbq", "miso") {
		t.Errorf("NW miso = %+v, %v", f, err)
	}
	if f, err := m.resolveNW("mix"); err != nil || f.Dir != other {
		t.Errorf("NW mix = %+v, %v", f, err)
	}
	if _, err := m.resolveNW("zzz"); err == nil || !strings.Contains(err.Error(), "no folder zzz") {
		t.Errorf("NW zzz: %v", err)
	}
}

// The /NW box names the folder, its branch and where it came from, and warns when it looks wrong.
func TestNWBoxShowsFolder(t *testing.T) {
	home := realPath(t, t.TempDir())
	t.Setenv("HOME", home)
	soii := filepath.Join(home, "bbq", "soii")
	nwRepo(t, soii, "")
	m := newModel()
	m.w, m.h = 140, 40
	m.agents = []Agent{{SID: "s1", Name: "soii-main", Cwd: soii, InTerminal: true}}
	m.selSID = "s1"

	mm, _ := m.command("NW")
	v := escRe.ReplaceAllString(mm.(model).View(), "")
	for _, want := range []string{"new background agent in " + tildify(soii) + " (main)", "folder: the selected agent soii-main"} {
		if !strings.Contains(v, want) {
			t.Errorf("box lacks %q:\n%s", want, v)
		}
	}
	if strings.Contains(v, "⚠") {
		t.Errorf("a repo's own folder should have no warning:\n%s", v)
	}

	m.mode = mKeys
	mm, _ = m.command("NW ~")
	v = escRe.ReplaceAllString(mm.(model).View(), "")
	if !strings.Contains(v, "⚠ the home folder") {
		t.Errorf("no home warning:\n%s", v)
	}
}

// A repo with no commit is still a repo, a detached HEAD says so, and a submodule or a bare repo's worktree is
// not shown as a worktree of a folder that is no checkout.
func TestNWFolderInfoEdges(t *testing.T) {
	home := realPath(t, t.TempDir())
	t.Setenv("HOME", home)
	gitIn := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "protocol.file.allow=always"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}

	fresh := filepath.Join(home, "fresh")
	os.MkdirAll(fresh, 0o755)
	gitIn(fresh, "init", "-q", "-b", "main")
	if f := (nwFolder{Dir: fresh}).info(); !f.Repo || f.Branch != "main" || f.note() != "" {
		t.Errorf("a repo with no commit = %+v (note %q)", f, f.note())
	}

	repo := filepath.Join(home, "repo")
	nwRepo(t, repo, "")
	gitIn(repo, "checkout", "-q", "--detach")
	if f := (nwFolder{Dir: repo}).info(); !strings.HasPrefix(f.Branch, "detached at ") {
		t.Errorf("detached HEAD branch = %q", f.Branch)
	}
	gitIn(repo, "checkout", "-q", "main")

	super := filepath.Join(home, "super")
	nwRepo(t, super, "")
	gitIn(super, "submodule", "add", "-q", repo, "sub")
	sub := filepath.Join(super, "sub")
	if f := (nwFolder{Dir: sub}).info(); !f.Repo || f.Main != "" || f.note() != "" {
		t.Errorf("a submodule = %+v (note %q)", f, f.note())
	}
	if got := repoRoot(sub); got != sub {
		t.Errorf("repoRoot(submodule) = %q, want itself", got)
	}

	bare := filepath.Join(home, "bare.git")
	gitIn(home, "clone", "-q", "--bare", repo, bare)
	bwt := filepath.Join(home, "bare-wt")
	gitIn(bare, "worktree", "add", "-q", bwt, "main")
	if f := (nwFolder{Dir: bwt}).info(); f.Main != bare {
		t.Errorf("a worktree of a bare repo: Main = %q, want %q", f.Main, bare)
	}
	if got := repoRoot(bwt); got != bwt {
		t.Errorf("repoRoot(bare worktree) = %q, want itself", got)
	}
}
