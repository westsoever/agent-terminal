package main

// The folder of /NW: where a new background agent starts, how agterm found that folder, and what is there.
// The box of /NW shows all three, so a wrong folder is seen before the first message is sent.

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// nwFolder is where /NW starts the agent and how agterm found the folder.
type nwFolder struct {
	Dir    string
	Source string // how it was found: "the selected agent miso", "the folder ~/bbq/soii", ...
	Repo   bool   // Dir is inside a git repo
	Branch string // the branch checked out there
	Main   string // for a linked worktree: the main checkout of that repo, else ""
}

// note is the warning the box shows for a folder that is probably not the one meant ("" when it looks right).
func (f nwFolder) note() string {
	switch {
	case f.Dir == os.Getenv("HOME"):
		return "the home folder: no repo, so the agent has no project"
	case !f.Repo:
		return "not a git repo"
	case f.Main != "":
		return "a worktree of " + tildify(f.Main) + ", not the repo's own folder"
	}
	return ""
}

// git runs git in dir and returns its output without the trailing newline.
func git(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0")
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

// info adds the repo facts of the folder. The repo test needs no commit, so it is its own call: a new `git init`
// has no HEAD to read.
func (f nwFolder) info() nwFolder {
	out, err := git(f.Dir, "rev-parse", "--git-dir", "--git-common-dir")
	lines := strings.Split(out, "\n")
	if err != nil || len(lines) < 2 {
		return f
	}
	f.Repo = true
	if b, err := git(f.Dir, "symbolic-ref", "--short", "-q", "HEAD"); err == nil {
		f.Branch = b // on an unborn branch too
	} else if h, err := git(f.Dir, "rev-parse", "--short", "HEAD"); err == nil {
		f.Branch = "detached at " + h
	}
	abs := func(p string) string { // git prints these relative to Dir, and the same folder can be spelled with or without a symlink (/var, /private/var)
		if !filepath.IsAbs(p) {
			p = filepath.Join(f.Dir, p)
		}
		if r, err := filepath.EvalSymlinks(p); err == nil {
			return r
		}
		return filepath.Clean(p)
	}
	// A linked worktree is the one case where the git dir is not the common dir. A submodule or a repo with a
	// separate git dir has the two the same, so it is not mistaken for a worktree.
	if gitDir, common := abs(lines[0]), abs(lines[1]); gitDir != common {
		f.Main = filepath.Dir(common) // the repo's checkout; a bare repo (x/repo.git) has none, so its own folder
		if filepath.Base(common) != ".git" {
			f.Main = common
		}
	}
	return f
}

// repoRoot: the folder of the repo that dir belongs to: the main checkout for a linked worktree, the top of the
// checkout for a folder inside it. dir itself when it is in no repo or the repo is bare and has no checkout.
func repoRoot(dir string) string {
	if f := (nwFolder{Dir: dir}).info(); f.Main != "" && dirExists(filepath.Join(f.Main, ".git")) {
		return f.Main
	}
	if top, err := git(dir, "rev-parse", "--show-toplevel"); err == nil && top != "" {
		return top
	}
	return dir
}

// sameDir: the same folder, however it is spelled (a symlink, /var and /private/var).
func sameDir(a, b string) bool {
	if a == b {
		return true
	}
	ra, err1 := filepath.EvalSymlinks(a)
	rb, err2 := filepath.EvalSymlinks(b)
	return err1 == nil && err2 == nil && ra == rb
}

// resolveNW finds the folder for /NW from the words after it. It never falls back to the home folder:
//   - empty: the selected agent's folder (an error when no agent is selected)
//   - ".", "..", "./x", "../x": relative to the selected agent's folder
//   - "~", "~/x" or an absolute path: that folder
//   - a name: the folder ~/bbq/<name>; else the one folder among ~/bbq and the agents that start with the name,
//     where an agent in a linked worktree counts as its repo's main checkout. Two or more is an error that lists them.
func (m *model) resolveNW(arg string) (nwFolder, error) {
	home := os.Getenv("HOME")
	arg = strings.TrimSpace(arg)
	found := func(dir, source string) (nwFolder, error) {
		return nwFolder{Dir: dir, Source: source}.info(), nil
	}
	rel := arg == "." || arg == ".." || strings.HasPrefix(arg, "./") || strings.HasPrefix(arg, "../")
	switch {
	case arg == "" || rel:
		a := m.sel()
		switch {
		case a == nil && rel:
			return nwFolder{}, errors.New("NW " + arg + ": a relative folder starts at the selected agent's folder, and none is selected")
		case a == nil:
			return nwFolder{}, errors.New("NW: no agent is selected, so write a folder (NW ~/bbq/soii, NW soii) or select an agent")
		case !dirExists(a.Cwd):
			return nwFolder{}, errors.New("NW " + arg + ": the folder of the selected agent " + a.Name + " (" + tildify(a.Cwd) + ") no longer exists, so write a folder")
		}
		dir := filepath.Clean(filepath.Join(a.Cwd, arg))
		if !dirExists(dir) {
			return nwFolder{}, errors.New("NW: no folder " + tildify(dir))
		}
		return found(dir, "the selected agent "+a.Name)
	case arg == "~":
		return found(home, "~")
	case strings.HasPrefix(arg, "~/"):
		arg = filepath.Join(home, arg[2:])
	}
	if filepath.IsAbs(arg) {
		if !dirExists(arg) {
			return nwFolder{}, errors.New("NW: no folder " + tildify(arg))
		}
		return found(filepath.Clean(arg), "the path you wrote")
	}
	bbq := filepath.Join(home, "bbq")
	if p := filepath.Join(bbq, arg); dirExists(p) {
		return found(p, "the folder ~/bbq/"+arg)
	}
	// the folders of ~/bbq and of the agents that start with the name, each folder once
	low := strings.ToLower(arg)
	var dirs, sources []string
	add := func(dir, source string) {
		for i, d := range dirs {
			if sameDir(d, dir) {
				sources[i] += ", " + source
				return
			}
		}
		dirs, sources = append(dirs, dir), append(sources, source)
	}
	if ents, err := os.ReadDir(bbq); err == nil {
		for _, e := range ents {
			if strings.HasPrefix(strings.ToLower(e.Name()), low) && dirExists(filepath.Join(bbq, e.Name())) {
				add(filepath.Join(bbq, e.Name()), "the folder ~/bbq/"+e.Name())
			}
		}
	}
	for _, a := range m.agents {
		if strings.HasPrefix(strings.ToLower(a.Name), low) && dirExists(a.Cwd) {
			add(repoRoot(a.Cwd), "the agent "+a.Name)
		}
	}
	switch len(dirs) {
	case 0:
		return nwFolder{}, errors.New("NW: no folder " + arg + " (a path, a folder in ~/bbq, or an agent's name)")
	case 1:
		return found(dirs[0], sources[0])
	}
	list := make([]string, len(dirs))
	for i, d := range dirs {
		list[i] = tildify(d) + " (" + sources[i] + ")"
	}
	return nwFolder{}, errors.New("NW " + arg + " could be " + strings.Join(list, "; ") + ": write more of the name")
}

// resolveDir: the folder for /NW as a path, "" when there is none (see resolveNW).
func (m *model) resolveDir(arg string) string {
	f, err := m.resolveNW(arg)
	if err != nil {
		return ""
	}
	return f.Dir
}
