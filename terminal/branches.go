package main

// The RP view's branch and worktree panels (D60): b lists a repo's branches, the local ones and the ones on origin
// with no local branch, each against the default branch; w lists its worktrees. On a branch (or a worktree's
// branch) 1 starts an agent that reviews it, 2 one that merges it into the default branch, 3 one that fixes it;
// k writes the agent's task. A merge here is an agent's job, not agterm's: a local branch has no checks and can
// conflict, and the main checkout may have another session's work in it.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Branch is one row of the branch panel.
type Branch struct {
	Name          string // "feature"; a branch on origin only: "origin/feature"
	Remote        bool   // on origin only: no local branch has it as its upstream or its name
	Worktree      string // the folder it is checked out in, "" when none
	Upstream      string // "origin/feature"; "" when it has none
	Gone          bool   // its upstream was deleted on origin
	Push, Pull    int    // commits to push to / pull from its upstream
	Ahead, Behind int    // commits not in the default branch / of the default branch not in it
	At            time.Time
	Subject       string
}

// Worktree is one row of the worktree panel; the repo's own folder is the first.
type Worktree struct {
	Dir      string
	Branch   string // "" when its HEAD is detached
	Head     string // its commit, short
	Main     bool   // the repo's own folder
	Dirty    int    // changed or new files; -1 when git status failed
	Locked   bool
	Prunable bool // its folder is gone: git worktree prune removes it
}

// Branches is what the two panels show of one repo.
type Branches struct {
	Base   string // the default branch the counts are against ("origin/main"); "" when none was found
	Items  []Branch
	Trees  []Worktree
	Err    string
	At     time.Time
	GHOnly bool // read from GitHub: names only
}

func (b Branches) local() (n int) {
	for _, br := range b.Items {
		if !br.Remote {
			n++
		}
	}
	return n
}

// unmerged: the branches with commits that the default branch does not have.
func (b Branches) unmerged() (n int) {
	for _, br := range b.Items {
		if br.Ahead > 0 && !b.isBase(br) {
			n++
		}
	}
	return n
}

// isBase: br is the default branch itself, the local one or the one on origin.
func (b Branches) isBase(br Branch) bool {
	if b.Base == "" {
		return false
	}
	_, name, _ := strings.Cut(b.Base, "/")
	return br.Name == b.Base || br.Name == name || (!strings.Contains(b.Base, "/") && br.Name == b.Base)
}

func (b Branches) find(name string) *Branch {
	for i := range b.Items {
		if b.Items[i].Name == name {
			return &b.Items[i]
		}
	}
	return nil
}

// gitRun runs git in dir, never asking for a password and never taking the index lock (another session may be
// working in that folder); a variable so tests can record the calls.
var gitRun = func(ctx context.Context, dir string, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	c.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0")
	return c.Output()
}

const branchTimeout = 15 * time.Second

// baseRef: the default branch as origin has it, else a local main or master.
func baseRef(ctx context.Context, dir string) string {
	if out, err := gitRun(ctx, dir, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"); err == nil {
		if b := strings.TrimSpace(string(out)); b != "" {
			return b
		}
	}
	for _, b := range []string{"origin/main", "origin/master", "main", "master"} {
		if _, err := gitRun(ctx, dir, "rev-parse", "--verify", "--quiet", b+"^{commit}"); err == nil {
			return b
		}
	}
	return ""
}

// parseTrack reads for-each-ref's %(upstream:track,nobracket): "ahead 1, behind 2", "gone" or "".
func parseTrack(t string) (push, pull int, gone bool) {
	if t == "gone" {
		return 0, 0, true
	}
	for _, p := range strings.Split(t, ",") {
		f := strings.Fields(p)
		if len(f) != 2 {
			continue
		}
		n, _ := strconv.Atoi(f[1])
		switch f[0] {
		case "ahead":
			push = n
		case "behind":
			pull = n
		}
	}
	return push, pull, false
}

// parseWorktrees reads git worktree list --porcelain.
func parseWorktrees(out string) []Worktree {
	var ts []Worktree
	for _, l := range strings.Split(out, "\n") {
		k, v, _ := strings.Cut(l, " ")
		if k == "worktree" {
			ts = append(ts, Worktree{Dir: filepath.Clean(v), Main: len(ts) == 0})
			continue
		}
		if len(ts) == 0 {
			continue
		}
		t := &ts[len(ts)-1]
		switch k {
		case "HEAD":
			t.Head = v
			if len(v) > 7 {
				t.Head = v[:7]
			}
		case "branch":
			t.Branch = strings.TrimPrefix(v, "refs/heads/")
		case "locked":
			t.Locked = true
		case "prunable":
			t.Prunable = true
		}
	}
	return ts
}

const refFormat = "%(refname)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(worktreepath)%00%(contents:subject)"

// loadBranches reads a clone's branches and worktrees with git; it does not fetch (f does).
func loadBranches(dir string) Branches {
	ctx, cancel := context.WithTimeout(context.Background(), branchTimeout)
	defer cancel()
	st := Branches{At: time.Now(), Base: baseRef(ctx, dir)}
	// git writes real paths: a clone reached through a symlink (/var is /private/var) gets its own spelling back
	real, _ := filepath.EvalSymlinks(dir)
	ours := func(p string) string {
		p = filepath.Clean(p)
		if real != "" && real != dir && (p == real || strings.HasPrefix(p, real+string(filepath.Separator))) {
			return dir + p[len(real):]
		}
		return p
	}
	format := refFormat
	if st.Base != "" {
		format += "%00%(ahead-behind:" + st.Base + ")"
	}
	out, err := gitRun(ctx, dir, "for-each-ref", "--format="+format, "refs/heads", "refs/remotes")
	if err != nil {
		st.Err = ghErr("git for-each-ref", err)
		return st
	}
	var local, remote []Branch
	tracked := map[string]bool{}
	for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		f := strings.Split(l, "\x00")
		if len(f) < 6 {
			continue
		}
		b := Branch{Upstream: f[1], Worktree: f[4], Subject: f[5]}
		if f[4] != "" {
			b.Worktree = ours(f[4])
		}
		if n, err := strconv.ParseInt(f[3], 10, 64); err == nil {
			b.At = time.Unix(n, 0)
		}
		b.Push, b.Pull, b.Gone = parseTrack(f[2])
		if len(f) > 6 {
			if ab := strings.Fields(f[6]); len(ab) == 2 {
				b.Ahead, _ = strconv.Atoi(ab[0])
				b.Behind, _ = strconv.Atoi(ab[1])
			}
		}
		switch ref := f[0]; {
		case strings.HasPrefix(ref, "refs/heads/"):
			b.Name = strings.TrimPrefix(ref, "refs/heads/")
			local = append(local, b)
			if b.Upstream != "" {
				tracked[b.Upstream] = true
			}
		case strings.HasSuffix(ref, "/HEAD"): // origin/HEAD only names the default branch
		default:
			b.Name, b.Remote, b.Upstream = strings.TrimPrefix(ref, "refs/remotes/"), true, ""
			remote = append(remote, b)
		}
	}
	for _, b := range local { // a local branch with no upstream set still has its twin on origin
		tracked["origin/"+b.Name] = true
	}
	for _, b := range remote {
		if !tracked[b.Name] {
			local = append(local, b)
		}
	}
	st.Items = local
	st.sortItems()
	if out, err := gitRun(ctx, dir, "worktree", "list", "--porcelain"); err == nil {
		st.Trees = parseWorktrees(string(out))
	}
	for i := range st.Trees {
		st.Trees[i].Dir = ours(st.Trees[i].Dir)
	}
	for i := range st.Trees {
		t := &st.Trees[i]
		if t.Prunable {
			continue
		}
		out, err := gitRun(ctx, t.Dir, "status", "--porcelain")
		t.Dirty = -1
		if err == nil {
			t.Dirty = len(nonEmpty(strings.Split(string(out), "\n")))
		}
	}
	return st
}

func nonEmpty(ls []string) []string {
	var out []string
	for _, l := range ls {
		if strings.TrimSpace(l) != "" {
			out = append(out, l)
		}
	}
	return out
}

// sortItems: the default branch first, then the local branches, then those on origin only; in each, the ones
// with work the default branch lacks first, the last committed first.
func (b *Branches) sortItems() {
	sort.SliceStable(b.Items, func(i, j int) bool {
		x, y := b.Items[i], b.Items[j]
		if bx, by := b.isBase(x) && !x.Remote, b.isBase(y) && !y.Remote; bx != by {
			return bx
		}
		if x.Remote != y.Remote {
			return !x.Remote
		}
		if (x.Ahead > 0) != (y.Ahead > 0) {
			return x.Ahead > 0
		}
		return x.At.After(y.At)
	})
}

// ghBranches lists a repo's branches on GitHub; a variable so tests can hand back their own JSON.
var ghBranches = func(ctx context.Context, remote string) ([]byte, error) {
	return exec.CommandContext(ctx, "gh", "api", "--paginate", "repos/"+remote+"/branches?per_page=100").Output()
}

// loadGHBranches: the branch names of a repo with no clone here.
func loadGHBranches(remote string) Branches {
	ctx, cancel := context.WithTimeout(context.Background(), pullsTimeout)
	defer cancel()
	st := Branches{At: time.Now(), GHOnly: true}
	out, err := ghBranches(ctx, remote)
	if err != nil {
		st.Err = ghErr("gh api", err)
		return st
	}
	// --paginate writes one JSON array per page
	dec := json.NewDecoder(strings.NewReader(string(out)))
	for dec.More() {
		var page []struct {
			Name string `json:"name"`
		}
		if err := dec.Decode(&page); err != nil {
			st.Err = "gh api: " + err.Error()
			return st
		}
		for _, p := range page {
			st.Items = append(st.Items, Branch{Name: "origin/" + p.Name, Remote: true})
		}
	}
	return st
}

// refCounts: a clone's local branches and its worktrees besides its own folder, read from .git without running
// git, for the RP list.
func refCounts(dir string) (branches, trees int) {
	g := filepath.Join(dir, ".git")
	seen := map[string]bool{}
	heads := filepath.Join(g, "refs", "heads")
	filepath.WalkDir(heads, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			rel, _ := filepath.Rel(heads, p)
			seen[filepath.ToSlash(rel)] = true
		}
		return nil
	})
	if b, err := os.ReadFile(filepath.Join(g, "packed-refs")); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if _, ref, ok := strings.Cut(l, " refs/heads/"); ok && !strings.HasPrefix(l, "#") {
				seen[strings.TrimSpace(ref)] = true
			}
		}
	}
	es, _ := os.ReadDir(filepath.Join(g, "worktrees"))
	for _, e := range es {
		if e.IsDir() {
			trees++
		}
	}
	return len(seen), trees
}

// ---- the panel

// branchPanel is the RP side panel of b (branches) or w (worktrees) for the repo selected when it opened.
type branchPanel struct {
	repo    Repo
	trees   bool // w: the worktrees; else b: the branches
	sel     int
	st      Branches
	loading bool
	note    string // a fetch running, or how the last one went
}

type branchesMsg struct {
	key  string
	st   Branches
	note string
}

func (p *branchPanel) load(note string) tea.Cmd {
	p.loading = true
	r := p.repo
	return func() tea.Msg {
		if r.Dir == "" {
			return branchesMsg{r.key(), loadGHBranches(r.Remote), note}
		}
		return branchesMsg{r.key(), loadBranches(r.Dir), note}
	}
}

func (p *branchPanel) n() int {
	if p.trees {
		return len(p.st.Trees)
	}
	return len(p.st.Items)
}

// branch: the selected branch; in the worktree panel the selected worktree's. nil when there is none.
func (p *branchPanel) branch() *Branch {
	if p.trees {
		if p.sel < len(p.st.Trees) && p.st.Trees[p.sel].Branch != "" {
			return p.st.find(p.st.Trees[p.sel].Branch)
		}
		return nil
	}
	if p.sel < len(p.st.Items) {
		return &p.st.Items[p.sel]
	}
	return nil
}

// dir: the folder the selected row is in: its worktree, else the repo's own.
func (p *branchPanel) dir() string {
	if p.trees && p.sel < len(p.st.Trees) {
		return p.st.Trees[p.sel].Dir
	}
	if b := p.branch(); b != nil && b.Worktree != "" {
		return b.Worktree
	}
	return p.repo.Dir
}

// branchQuick: the panel's number keys, each an agent with that task, like 1 in the PR panel.
var branchQuick = []struct{ label, act, text string }{
	{"review it", "review", "Review this branch: what does it change against the default branch, does it do what it says, and is the code right? Read it with git log and git diff; do not change it. Tell me what you find."},
	{"merge it", "merge", "Merge this branch into the default branch and push it, by my merge rules: git fetch first, merge or rebase, never force push, never reset away commits you did not make; on a conflict keep both sides' intent and stop and ask me when that is not clear. If the branch has an open pull request, merge that. Afterwards check that nothing from origin was dropped and tell me what went in."},
	{"fix it", "fix", "Fix this branch so that it can be merged: bring it up to date with the default branch, resolve the conflicts, make the build and the tests pass, and finish its work where it is clear what is left. Ask me when it is not. Commit on the branch; do not merge it."},
}

// branchBlock: why an agent is not started on b for act, "" when it is.
func branchBlock(p *branchPanel, b *Branch, act string) string {
	switch {
	case p.repo.Dir == "":
		return "no clone of " + p.repo.Name + " here"
	case b == nil && p.trees:
		return "its HEAD is detached: no branch"
	case b == nil:
		return "no branch selected"
	case act == "merge" && p.st.isBase(*b):
		return b.Name + " is the default branch"
	case act == "merge" && p.st.Base != "" && b.Ahead == 0:
		return b.Name + " has nothing that " + p.st.Base + " lacks"
	}
	return ""
}

// branchPrompt: the first message of the agent that works on branch b of repo r, with task as what to do.
func branchPrompt(r Repo, st Branches, b Branch, task string) string {
	var w strings.Builder
	fmt.Fprintf(&w, "Branch %s of %s", b.Name, r.Name)
	if r.Remote != "" {
		fmt.Fprintf(&w, " (%s on GitHub)", r.Remote)
	}
	fmt.Fprintf(&w, ", local clone %s.\n", r.Dir)
	switch {
	case b.Remote:
		fmt.Fprintf(&w, "It is on origin only (%s): no local branch.\n", b.Name)
	case b.Worktree == r.Dir:
		w.WriteString("It is checked out in the clone's own folder.\n")
	case b.Worktree != "":
		fmt.Fprintf(&w, "It is checked out in the worktree %s.\n", b.Worktree)
	default:
		w.WriteString("It is not checked out in any worktree.\n")
	}
	if st.Base != "" {
		fmt.Fprintf(&w, "Against %s: %d commits that %s does not have, and it is %d commits behind it.\n", st.Base, b.Ahead, st.Base, b.Behind)
	}
	fmt.Fprintf(&w, "\nMy comment on it:\n%s\n\n", task)
	if b.Worktree == "" {
		w.WriteString("If you change or test code, do it in your own git worktree of the branch, not in the main checkout. ")
	}
	w.WriteString("Report back here.")
	return w.String()
}

// branchStart starts a background agent on the panel's selected branch, in its worktree (the clone's own folder
// when it has none), with task as its comment.
func (m *model) branchStart(act, task string) tea.Cmd {
	p := m.branches
	b := p.branch()
	if why := branchBlock(p, b, act); why != "" {
		m.setErr("no agent started: " + why)
		return nil
	}
	r, st, br, dir, cfg := p.repo, p.st, *b, b.Worktree, m.cfg
	if dir == "" {
		dir = r.Dir
	}
	m.setStatus("starting an agent on " + r.Name + ":" + br.Name + "…")
	return func() tea.Msg {
		o := parseNW("", cfg)
		o.Dir = dir
		job, err := bgStart(o, branchPrompt(r, st, br, task))
		if err != nil {
			return sentMsg{"", r.Name + ":" + br.Name, "start", "error: " + err.Error()}
		}
		return bgStartedMsg{job, dir}
	}
}

// openBranches opens the b or w panel on r; the folder panel closes.
func (m *model) openBranches(r *Repo, trees bool) tea.Cmd {
	if r == nil {
		return nil
	}
	if p := m.branches; p != nil && p.repo.key() == r.key() { // b ↔ w on the same repo: no read again
		p.trees, p.sel = trees, 0
		m.tree = nil
		return nil
	}
	if trees && r.Dir == "" {
		m.setErr(r.Name + " has no clone here: no worktrees")
		return nil
	}
	m.tree = nil
	m.branches = &branchPanel{repo: *r, trees: trees}
	return m.branches.load("")
}

// branchFetch fetches origin in the background (pruning the branches deleted there) and reads the panel again.
func (m *model) branchFetch() tea.Cmd {
	p := m.branches
	if p.repo.Dir == "" {
		return p.load("")
	}
	p.note = "fetching origin…"
	r := p.repo
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		note := "fetched " + time.Now().Format("15:04")
		if _, err := gitRun(ctx, r.Dir, "fetch", "--prune", "--quiet", "origin"); err != nil {
			note = ghErr("git fetch", err)
		}
		return branchesMsg{r.key(), loadBranches(r.Dir), note}
	}
}

// branchGitHub opens the selected branch on GitHub, the repo when no branch is selected.
func (m *model) branchGitHub() {
	p := m.branches
	b := p.branch()
	switch {
	case p.repo.Remote == "":
		m.setErr(p.repo.Name + " has no GitHub origin")
	case b == nil:
		m.repoGitHub()
	default:
		name := b.Name
		if b.Remote {
			_, name, _ = strings.Cut(name, "/")
		} else if b.Upstream != "" && !b.Gone {
			_, name, _ = strings.Cut(b.Upstream, "/")
		} else {
			m.setErr(b.Name + " is not on GitHub")
			return
		}
		u := "https://github.com/" + p.repo.Remote + "/tree/" + escapePath(name)
		repoOpen("open", u)
		m.setStatus("opened " + u)
	}
}

// branchKey: the keys while the branch or worktree panel is open.
func (m *model) branchKey(ks string) tea.Cmd {
	K := m.cfg.Keys
	p := m.branches
	switch ks {
	case K.Next, "down":
		if p.sel < p.n()-1 {
			p.sel++
		}
	case K.Prev, "up":
		if p.sel > 0 {
			p.sel--
		}
	case "home":
		p.sel = 0
	case "end":
		p.sel = max(0, p.n()-1)
	case "b":
		return m.openBranches(&p.repo, false)
	case "w":
		return m.openBranches(&p.repo, true)
	case K.Reply:
		if why := branchBlock(p, p.branch(), ""); why != "" {
			m.setErr("no agent started: " + why)
			return nil
		}
		m.mode = mTyping
		return m.ed.open("br:"+p.branch().Name, "", m.editorWidth())
	case "f":
		return m.branchFetch()
	case "g", "alt+enter":
		m.branchGitHub()
	case "i": // the branch's name; in the worktree panel the folder's path
		switch {
		case p.trees && p.sel < len(p.st.Trees):
			m.copyOut(p.st.Trees[p.sel].Dir)
		case p.branch() != nil:
			m.copyOut(p.branch().Name)
		}
	case "enter": // the folder the row is in, in Finder
		if d := p.dir(); d != "" {
			repoOpen("open", d)
			m.setStatus("opened " + tildify(d))
		}
	default:
		if len(ks) == 1 && ks[0] >= '1' && ks[0] <= '9' {
			if i := int(ks[0] - '1'); i < len(branchQuick) {
				return m.branchStart(branchQuick[i].act, branchQuick[i].text)
			}
		}
	}
	return nil
}

// ---- view

// branchCols: the columns of a branch row, as segs: against the default branch, against its upstream, its age.
func branchCols(st Branches, b Branch) (vs, up seg) {
	switch {
	case st.GHOnly || st.Base == "":
		vs = s("", cDark)
	case st.isBase(b):
		vs = s("default", cDark)
	case b.Ahead == 0:
		vs = s("merged", cDark)
	default:
		vs = s(fmt.Sprintf("+%d −%d", b.Ahead, b.Behind), cOrange)
	}
	switch {
	case b.Remote:
		up = s("", cDark)
	case b.Gone:
		up = s("gone", cOrange)
	case b.Upstream == "":
		up = s("not pushed", cOrange)
	case b.Push > 0 && b.Pull > 0:
		up = s(fmt.Sprintf("↑%d ↓%d", b.Push, b.Pull), cOrange)
	case b.Push > 0:
		up = s(fmt.Sprintf("↑%d", b.Push), cOrange)
	case b.Pull > 0:
		up = s(fmt.Sprintf("↓%d", b.Pull), cGrey)
	default:
		up = s("pushed", cDark)
	}
	return vs, up
}

// branchRows: the branch panel's rows, the local ones and then a header and the ones on origin only.
func (m model) branchRows(in, avail int) []string {
	p := m.branches
	nw := min(32, max(12, in/3))
	var rows []string
	selLine := 0
	for i, b := range p.st.Items {
		if b.Remote && (i == 0 || !p.st.Items[i-1].Remote) {
			if i > 0 {
				rows = append(rows, "")
			}
			rows = append(rows, row(in, s("ON ORIGIN ONLY", cGrey)))
		}
		mark := "  "
		if b.Worktree != "" {
			mark = "⌂ "
		}
		vs, up := branchCols(p.st, b)
		line := []seg{s(mark+padTo(b.Name, nw), cWhite), s(" "+padTo(vs.t, 10), vs.st), s(" "+padTo(up.t, 10), up.st),
			s(fmt.Sprintf(" %4s ", age(b.At)), cDark), s(b.Subject, cGrey)}
		if b.Remote || (p.st.Base != "" && b.Ahead == 0 && !p.st.isBase(b)) {
			line[0].st = cGrey
		}
		if i == p.sel {
			selLine = len(rows)
			t := ""
			for _, sg := range line {
				t += sg.t
			}
			rows = append(rows, row(in, s(padTo("> "+t, in), cSel)))
			continue
		}
		rows = append(rows, row(in, append([]seg{s("  ", cPlain)}, line...)...))
	}
	return scrollTo(rows, selLine, avail)
}

// treeRows: the worktree panel's rows: its folder, its branch, its changed files, its branch against the default.
func (m model) treeRows(in, avail int) []string {
	p := m.branches
	var rows []string
	for i, t := range p.st.Trees {
		where := tildify(t.Dir)
		if rel, err := filepath.Rel(p.repo.Dir, t.Dir); err == nil && !t.Main && !strings.HasPrefix(rel, "..") {
			where = rel
		}
		if t.Main {
			where = "(the clone's own folder)"
		}
		br, bst := t.Branch, cWhite
		if br == "" {
			br, bst = "detached at "+t.Head, cGrey
		}
		dirty, dst := "clean", cDark
		switch {
		case t.Prunable:
			dirty, dst = "folder gone", cOrange
		case t.Dirty < 0:
			dirty, dst = "?", cDark
		case t.Dirty > 0:
			dirty, dst = fmt.Sprintf("%d changed", t.Dirty), cOrange
		}
		vs := s("", cDark)
		if b := p.st.find(t.Branch); b != nil {
			vs, _ = branchCols(p.st, *b)
		}
		ww := min(44, max(16, in*2/5))
		line := []seg{s("⌂ "+padTo(where, ww), cWhite), s(" "+padTo(br, 26), bst), s(" "+padTo(dirty, 11), dst), s(" "+vs.t, vs.st)}
		if t.Locked {
			line = append(line, s("  locked", cDark))
		}
		if i == p.sel {
			tx := ""
			for _, sg := range line {
				tx += sg.t
			}
			rows = append(rows, row(in, s(padTo("> "+tx, in), cSel)))
			continue
		}
		rows = append(rows, row(in, append([]seg{s("  ", cPlain)}, line...)...))
	}
	return scrollTo(rows, p.sel, avail)
}

// scrollTo: at most avail of rows, with line sel among them.
func scrollTo(rows []string, sel, avail int) []string {
	first := 0
	if sel >= avail {
		first = sel - avail + 1
	}
	if first >= len(rows) {
		return nil
	}
	return rows[first:min(len(rows), first+avail)]
}

// branchDetail: the selected branch in words, below the rows.
func (m model) branchDetail(in int) []string {
	p := m.branches
	b := p.branch()
	if b == nil {
		return nil
	}
	var where string
	switch {
	case b.Remote:
		where = "on origin only"
	case b.Worktree == p.repo.Dir:
		where = "checked out in the clone's own folder"
	case b.Worktree != "":
		where = "in the worktree " + tildify(b.Worktree)
	default:
		where = "not checked out"
	}
	var up string
	switch {
	case b.Remote || p.st.GHOnly:
	case b.Gone:
		up = " · its upstream " + b.Upstream + " was deleted"
	case b.Upstream == "":
		up = " · not on GitHub: only here"
	default:
		up = fmt.Sprintf(" · %s: %d to push, %d to pull", b.Upstream, b.Push, b.Pull)
	}
	out := []string{row(in, s(b.Name, cWhite), s(" · "+where+up, cGrey))}
	if p.st.Base != "" && !p.st.GHOnly {
		vs := fmt.Sprintf("%d commits not in %s, %d behind it", b.Ahead, p.st.Base, b.Behind)
		if p.st.isBase(*b) {
			vs = "the default branch"
		}
		out = append(out, row(in, s(vs, cGrey), s(" · last commit "+age(b.At)+": ", cDark), s(b.Subject, cGrey)))
	}
	return out
}

// branchPanelView: the b or w panel beside the narrow repo list.
func (m model) branchPanelView(w, h int) []string {
	K := m.cfg.Keys
	p := m.branches
	in := w - 4
	st := p.st
	what := "branches"
	if p.trees {
		what = "worktrees"
	}
	title := []seg{s(p.repo.Name, cWhite), s(" "+what, cGrey)}
	var counts []seg
	if !st.At.IsZero() && st.Err == "" {
		c := fmt.Sprintf("%d local", st.local())
		if r := len(st.Items) - st.local(); r > 0 {
			c += fmt.Sprintf(" · %d on origin only", r)
		}
		if st.Base != "" && !st.GHOnly {
			c += fmt.Sprintf(" · %d not in %s", st.unmerged(), st.Base)
		}
		if len(st.Trees) > 1 {
			c += fmt.Sprintf(" · %d worktrees", len(st.Trees)-1)
		}
		counts = []seg{s(c, cGrey)}
	}
	var head []string
	if st.GHOnly {
		head = append(head, row(in, s("github only: the names on GitHub; clone it to see more and to work on them", cDark)), "")
	}
	if p.note != "" {
		head = append(head, row(in, s(p.note, cDark)), "")
	}
	tail := []string{""}
	if !p.trees {
		tail = append(tail, m.branchDetail(in)...)
	}
	if m.mode == mTyping && strings.HasPrefix(m.ed.target, "br:") {
		tail = append(tail, "")
		tail = append(tail, m.ed.lines(in)...)
	}
	keys := "1 review · 2 merge · 3 fix · " + K.Reply + " own task · f fetch · g GitHub · "
	if p.trees {
		keys += "b branches"
	} else {
		keys += "w worktrees"
	}
	tail = append(tail, "", row(in, s("> ", cOrange), s(keys+" · esc closes", cDark)))
	avail := max(1, h-2-len(head)-len(tail))
	var rows []string
	switch {
	case p.loading && st.At.IsZero():
		rows = append(rows, row(in, s("reading…", cDark)))
	case st.Err != "":
		rows = append(rows, row(in, s(st.Err, cOrange)))
	case p.n() == 0 && p.trees:
		rows = append(rows, row(in, s("no worktrees", cDark)))
	case p.n() == 0:
		rows = append(rows, row(in, s("no branches", cDark)))
	case p.trees:
		rows = m.treeRows(in, avail)
	default:
		rows = m.branchRows(in, avail)
	}
	var body []string
	for _, l := range append(head, rows...) {
		body = append(body, " "+l+" ")
	}
	for len(body) < h-2-len(tail) {
		body = append(body, "")
	}
	for _, l := range tail {
		body = append(body, " "+l+" ")
	}
	return boxR(w, h, title, counts, cDark, body)
}
