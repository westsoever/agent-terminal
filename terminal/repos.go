package main

// The RP view (D45): the repos on this Mac (git clones one level under ~/bbq and ~, the ones in ~/.agent-repos
// and the sync check's) and the owner's GitHub repos that have no clone here, each with the sync check's note.
// Enter opens the folder, b (or option+enter) the repo on GitHub, k its folders in a side panel, i copies a path.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Repo is one row of the RP view.
type Repo struct {
	Name   string   // the folder's name, or the name on GitHub
	Remote string   // owner/name on GitHub; "" when its origin is elsewhere or missing
	Dir    string   // the local clone; "" when it is on GitHub only
	Needs  string   // the sync check's "needs:" line
	Notes  []string // the sync check's findings ("stash: 1 entry (oldest 20d)")
}

func (r Repo) key() string {
	if r.Dir != "" {
		return r.Dir
	}
	return r.Remote
}

// ghURL: the repo on GitHub, at rel when rel is a folder in it.
func (r Repo) ghURL(rel string) string {
	u := "https://github.com/" + r.Remote
	if rel != "" {
		u += "/tree/HEAD/" + escapePath(rel)
	}
	return u
}

func escapePath(rel string) string {
	parts := strings.Split(filepath.ToSlash(rel), "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

// repoOpen opens a folder, file or URL; a variable so tests see what would open.
var repoOpen = openPath

// copyText puts s on the clipboard; a variable so tests see what would be copied.
var copyText = func(s string) error {
	c := exec.Command("pbcopy")
	c.Stdin = strings.NewReader(s)
	return c.Run()
}

// repoOwners: whose GitHub repos the list adds, the owner's and the org's.
var repoOwners = []string{"westsoever", "technobbq"}

// repoSkip: folders in ~ that are no repos and that macOS guards (looking in them can ask for permission).
var repoSkip = map[string]bool{"Library": true, "Desktop": true, "Documents": true, "Downloads": true, "Movies": true,
	"Music": true, "Pictures": true, "Public": true, "Applications": true, ".Trash": true, "Google Drive": true}

// gitOrigin: the origin URL in dir's .git/config, "" when it has none.
func gitOrigin(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, ".git", "config"))
	if err != nil {
		return ""
	}
	in := false
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "[") {
			in = l == `[remote "origin"]`
			continue
		}
		if k, v, ok := strings.Cut(l, "="); in && ok && strings.TrimSpace(k) == "url" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// syncNote is one repo with findings in sync-check.md.
type syncNote struct {
	path, needs string
	notes       []string
}

// parseSync: the sync check's repos with findings, in its order (the oldest finding first).
func parseSync(lines []string) []syncNote {
	var out []syncNote
	for _, l := range lines {
		switch {
		case strings.HasPrefix(l, "## "):
			out = append(out, syncNote{})
		case len(out) == 0:
		case strings.HasPrefix(l, "path: "):
			out[len(out)-1].path = filepath.Clean(strings.TrimPrefix(l, "path: "))
		case strings.HasPrefix(l, "needs: "):
			out[len(out)-1].needs = strings.TrimPrefix(l, "needs: ")
		case strings.HasPrefix(l, "- "):
			out[len(out)-1].notes = append(out[len(out)-1].notes, strings.TrimPrefix(l, "- "))
		}
	}
	return out
}

// localRepos: the clones on this Mac with the sync check's notes, those with notes first in its order, then by name.
func localRepos(sync []string) []Repo {
	home := os.Getenv("HOME")
	var dirs []string
	for _, root := range cloneRoots() {
		es, _ := os.ReadDir(root)
		for _, e := range es {
			if e.IsDir() && !(root == home && repoSkip[e.Name()]) {
				dirs = append(dirs, filepath.Join(root, e.Name()))
			}
		}
	}
	list := os.Getenv("AGENT_REPOS_FILE")
	if list == "" {
		list = filepath.Join(home, ".agent-repos")
	}
	if b, err := os.ReadFile(list); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			l, _, _ = strings.Cut(l, "#")
			if l = strings.TrimSpace(l); l != "" {
				if strings.HasPrefix(l, "~/") {
					l = filepath.Join(home, l[2:])
				}
				dirs = append(dirs, l)
			}
		}
	}
	notes := parseSync(sync)
	rank := map[string]int{}
	for i, n := range notes {
		dirs = append(dirs, n.path)
		rank[n.path] = i
	}
	seen := map[string]bool{}
	var out []Repo
	for _, d := range dirs {
		d = filepath.Clean(d)
		if seen[d] || !dirExists(filepath.Join(d, ".git")) {
			continue
		}
		seen[d] = true
		r := Repo{Name: filepath.Base(d), Dir: d, Remote: remoteRepo(gitOrigin(d))}
		if i, ok := rank[d]; ok {
			r.Needs, r.Notes = notes[i].needs, notes[i].notes
		}
		out = append(out, r)
	}
	sort.SliceStable(out, func(i, j int) bool {
		ri, iok := rank[out[i].Dir]
		rj, jok := rank[out[j].Dir]
		if iok != jok {
			return iok
		}
		if iok {
			return ri < rj
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

// GHRepos: the owners' GitHub repos (owner/name), not archived.
type GHRepos struct {
	Err   string // the last read failed; Items are still the last good list
	Items []string
	At    time.Time
}

type ghReposMsg GHRepos

// ghRepoList lists one owner's repos; a variable so tests can hand back their own JSON.
var ghRepoList = func(ctx context.Context, owner string) ([]byte, error) {
	return exec.CommandContext(ctx, "gh", "repo", "list", owner, "--no-archived", "--limit", "300",
		"--json", "nameWithOwner").Output()
}

func ghErr(what string, err error) string {
	msg := err.Error()
	if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
		msg = string(ee.Stderr)
	}
	return what + ": " + strings.Join(strings.Fields(msg), " ")
}

func loadGHRepos() GHRepos {
	ctx, cancel := context.WithTimeout(context.Background(), pullsTimeout)
	defer cancel()
	st := GHRepos{At: time.Now()}
	for _, o := range repoOwners {
		out, err := ghRepoList(ctx, o)
		if err != nil {
			return GHRepos{Err: ghErr("gh repo list "+o, err)}
		}
		var raw []struct {
			NameWithOwner string `json:"nameWithOwner"`
		}
		if err := json.Unmarshal(out, &raw); err != nil {
			return GHRepos{Err: "gh repo list " + o + ": " + err.Error()}
		}
		for _, r := range raw {
			st.Items = append(st.Items, r.NameWithOwner)
		}
	}
	return st
}

// merge takes a new read: a failed one keeps the last good list and shows its error with it.
func (g GHRepos) merge(n GHRepos) GHRepos {
	if n.Err != "" {
		g.Err = n.Err
		return g
	}
	return n
}

// repoList: the local clones (in localRepos' order), then the GitHub repos with no clone here, by name. A clone
// takes its owner/name as GitHub writes it (remoteRepo gives it in lower case).
func repoList(local []Repo, gh GHRepos) []Repo {
	named := map[string]string{}
	for _, nw := range gh.Items {
		named[strings.ToLower(nw)] = nw
	}
	out := append([]Repo(nil), local...)
	have := map[string]bool{}
	for i, r := range out {
		have[strings.ToLower(r.Remote)] = true
		if nw, ok := named[strings.ToLower(r.Remote)]; ok {
			out[i].Remote = nw
		}
	}
	var only []Repo
	for _, nw := range gh.Items {
		if have[strings.ToLower(nw)] {
			continue
		}
		have[strings.ToLower(nw)] = true
		_, name, _ := strings.Cut(nw, "/")
		only = append(only, Repo{Name: name, Remote: nw})
	}
	sort.SliceStable(only, func(i, j int) bool { return strings.ToLower(only[i].Name) < strings.ToLower(only[j].Name) })
	return append(out, only...)
}

// ---- the folder panel

type treeEntry struct {
	Name string
	Dir  bool
	URL  string // on GitHub only: the file's page
}

// repoTree is the RP side panel: one folder of the repo selected when it opened.
type repoTree struct {
	repo    Repo
	rel     string // the folder shown, relative to the repo ("" its root)
	sel     int
	items   []treeEntry // ".." first below the root, then folders, then files
	err     string
	loading bool
	back    string // after a move up: the folder to select once it is read
}

type treeMsg struct {
	key, rel string
	items    []treeEntry
	err      string
}

// sortTree: folders first, then files, each by name; .git and .DS_Store left out.
func sortTree(es []treeEntry) []treeEntry {
	out := es[:0]
	for _, e := range es {
		if e.Name != ".git" && e.Name != ".DS_Store" {
			out = append(out, e)
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Dir != out[j].Dir {
			return out[i].Dir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out
}

func readTree(root, rel string) ([]treeEntry, error) {
	dir := filepath.Join(root, rel)
	es, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []treeEntry
	for _, e := range es {
		isDir := e.IsDir()
		if e.Type()&os.ModeSymlink != 0 {
			isDir = dirExists(filepath.Join(dir, e.Name()))
		}
		out = append(out, treeEntry{Name: e.Name(), Dir: isDir})
	}
	return sortTree(out), nil
}

// ghContents reads one folder of a repo on GitHub; a variable so tests can hand back their own JSON.
var ghContents = func(ctx context.Context, remote, rel string) ([]byte, error) {
	p := "repos/" + remote + "/contents"
	if rel != "" {
		p += "/" + escapePath(rel)
	}
	return exec.CommandContext(ctx, "gh", "api", p).Output()
}

func loadGHTree(remote, rel string) treeMsg {
	ctx, cancel := context.WithTimeout(context.Background(), pullsTimeout)
	defer cancel()
	m := treeMsg{key: remote, rel: rel}
	out, err := ghContents(ctx, remote, rel)
	if err != nil {
		m.err = ghErr("gh api", err)
		return m
	}
	var raw []struct {
		Name    string `json:"name"`
		Type    string `json:"type"`
		HTMLURL string `json:"html_url"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		m.err = "gh api: " + err.Error()
		return m
	}
	for _, r := range raw {
		m.items = append(m.items, treeEntry{Name: r.Name, Dir: r.Type == "dir", URL: r.HTMLURL})
	}
	m.items = sortTree(m.items)
	return m
}

// show reads folder rel into the panel: a local one now, one on GitHub in the background.
func (t *repoTree) show(rel string) tea.Cmd {
	t.rel, t.sel, t.items, t.err = rel, 0, nil, ""
	if t.repo.Dir == "" {
		t.loading = true
		remote := t.repo.Remote
		return func() tea.Msg { return loadGHTree(remote, rel) }
	}
	es, err := readTree(t.repo.Dir, rel)
	if err != nil {
		t.err = err.Error()
	}
	t.set(es)
	return nil
}

func (t *repoTree) set(es []treeEntry) {
	t.loading = false
	if t.rel != "" {
		es = append([]treeEntry{{Name: "..", Dir: true}}, es...)
	}
	t.items = es
	for i, e := range es {
		if t.back != "" && e.Name == t.back {
			t.sel = i
		}
	}
	t.back = ""
}

func (t *repoTree) up() tea.Cmd {
	if t.rel == "" {
		return nil
	}
	parent := filepath.Dir(t.rel)
	if parent == "." {
		parent = ""
	}
	t.back = filepath.Base(t.rel)
	return t.show(parent)
}

// ---- keys

func (m *model) repoSel() *Repo {
	if m.listSel >= len(m.repos) {
		return nil
	}
	return &m.repos[m.listSel]
}

// openRepos reads the RP list again: the clones and the sync check now, GitHub in the background.
func (m *model) openRepos() tea.Cmd {
	m.loadSync()
	m.repoLocal, m.tree = localRepos(m.sync), nil
	m.setRepos()
	return func() tea.Msg { return ghReposMsg(loadGHRepos()) }
}

// setRepos builds the list again; the selection stays on its repo.
func (m *model) setRepos() {
	sel := ""
	if r := m.repoSel(); r != nil {
		sel = r.key()
	}
	m.repos = repoList(m.repoLocal, m.repoGH)
	for i, r := range m.repos {
		if sel != "" && r.key() == sel {
			m.listSel = i
			return
		}
	}
	if m.listSel >= len(m.repos) {
		m.listSel = max(0, len(m.repos)-1)
	}
}

func (m model) repoMsg(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case ghReposMsg:
		m.repoGH = m.repoGH.merge(GHRepos(msg))
		if m.view == vRepos {
			m.setRepos()
		}
	case treeMsg:
		if t := m.tree; t != nil && t.repo.key() == msg.key && t.rel == msg.rel {
			t.err = msg.err
			t.set(msg.items)
		}
	}
	return m, nil
}

// isShiftEnter: shift+enter from a terminal that tells it apart. Bubble Tea v1 has no key for it and hands the
// sequence over unparsed: CSI 13;2u (the kitty and iTerm2 CSI u form) or CSI 27;2;13~ (xterm's modifyOtherKeys).
func isShiftEnter(msg tea.Msg) bool {
	st, ok := msg.(fmt.Stringer)
	if !ok {
		return false
	}
	switch st.String() {
	case "?CSI[49 51 59 50 117]?", "?CSI[50 55 59 50 59 49 51 126]?":
		return true
	}
	return false
}

// repoGitHub opens the selected repo on GitHub, at the panel's folder when the panel is open.
func (m *model) repoGitHub() {
	r := m.repoSel()
	rel := ""
	if m.tree != nil {
		r, rel = &m.tree.repo, m.tree.rel
	}
	switch {
	case r == nil:
	case r.Remote == "":
		m.setErr(r.Name + " has no GitHub origin")
	default:
		repoOpen("open", r.ghURL(rel))
		m.setStatus("opened " + r.ghURL(rel))
	}
}

// copyOut copies a path or URL for the owner to paste.
func (m *model) copyOut(s string) {
	if s == "" {
		return
	}
	if err := copyText(s); err != nil {
		m.setErr(err.Error())
		return
	}
	m.setStatus("copied " + tildify(s))
}

// repoKey: the RP keys. Every key ends here, so none acts on the selected agent behind the view.
func (m *model) repoKey(ks string) (bool, tea.Cmd) {
	if m.tree != nil {
		return true, m.treeKey(ks)
	}
	K := m.cfg.Keys
	r := m.repoSel()
	switch ks {
	case K.Next, "down":
		if m.listSel < len(m.repos)-1 {
			m.listSel++
		}
	case K.Prev, "up":
		if m.listSel > 0 {
			m.listSel--
		}
	case "enter":
		switch {
		case r == nil:
		case r.Dir != "":
			if err := repoOpen("open", r.Dir); err != nil {
				m.setErr(err.Error())
			} else {
				m.setStatus("opened " + tildify(r.Dir))
			}
		case r.Remote != "":
			m.mode, m.confirmURL = mConfirm, r.ghURL("")
		}
	case "b", "alt+enter":
		m.repoGitHub()
	case "i": // copy the folder's path, or its GitHub URL when there is no clone
		switch {
		case r == nil:
		case r.Dir != "":
			m.copyOut(r.Dir)
		case r.Remote != "":
			m.copyOut(r.ghURL(""))
		}
	case K.Reply:
		if r != nil {
			m.tree = &repoTree{repo: *r}
			return true, m.tree.show("")
		}
	}
	return true, nil
}

// treeKey: the keys while the folder panel is open.
func (m *model) treeKey(ks string) tea.Cmd {
	K := m.cfg.Keys
	t := m.tree
	var e *treeEntry
	if t.sel < len(t.items) {
		e = &t.items[t.sel]
	}
	path := func(name string) string { return filepath.Join(t.repo.Dir, t.rel, name) }
	switch ks {
	case K.Next, "down":
		if t.sel < len(t.items)-1 {
			t.sel++
		}
	case K.Prev, "up":
		if t.sel > 0 {
			t.sel--
		}
	case "home":
		t.sel = 0
	case "end":
		t.sel = max(0, len(t.items)-1)
	case "backspace", "left", "h":
		return t.up()
	case "b", "alt+enter":
		m.repoGitHub()
	case "i": // copy the selected file's or folder's path (its GitHub URL on a repo without a clone)
		switch {
		case e == nil:
		case e.URL != "":
			m.copyOut(e.URL)
		case t.repo.Dir == "" && e.Name == "..":
			m.copyOut(t.repo.ghURL(t.rel))
		case t.repo.Dir == "":
			m.copyOut(t.repo.ghURL(filepath.Join(t.rel, e.Name)))
		case e.Name == "..":
			m.copyOut(path(""))
		default:
			m.copyOut(path(e.Name))
		}
	case K.Reply: // into a folder; a file opens
		switch {
		case e == nil:
		case e.Name == "..":
			return t.up()
		case e.Dir:
			return t.show(filepath.Join(t.rel, e.Name))
		case e.URL != "":
			repoOpen("open", e.URL)
			m.setStatus("opened " + e.URL)
		default:
			if err := repoOpen(m.cfg.OpenCmd, path(e.Name)); err != nil {
				m.setErr(err.Error())
			} else {
				m.setStatus("opened " + tildify(path(e.Name)))
			}
		}
	case "enter": // the folder in Finder, a file with the opener; on GitHub only: its page
		switch {
		case e == nil:
		case e.URL != "":
			repoOpen("open", e.URL)
			m.setStatus("opened " + e.URL)
		case t.repo.Dir == "":
			m.repoGitHub()
		case e.Name == "..":
			repoOpen("open", path(""))
			m.setStatus("opened " + tildify(path("")))
		case e.Dir:
			repoOpen("open", path(e.Name))
			m.setStatus("opened " + tildify(path(e.Name)))
		default:
			if err := repoOpen(m.cfg.OpenCmd, path(e.Name)); err != nil {
				m.setErr(err.Error())
			} else {
				m.setStatus("opened " + tildify(path(e.Name)))
			}
		}
	}
	return nil
}

// confirmKey answers "No local folder. Open it on GitHub?": enter or y opens it, any other key does not.
func (m model) confirmKey(ks string) (tea.Model, tea.Cmd) {
	u := m.confirmURL
	m.mode, m.confirmURL = mKeys, ""
	if ks == "enter" || ks == "y" {
		repoOpen("open", u)
		m.setStatus("opened " + u)
	} else {
		m.setStatus("not opened")
	}
	return m, nil
}

// ---- view

// reposView: the repos; with the panel open, the list narrows to the left and the folder shows on the right.
func (m model) reposView(h int) []string {
	K := m.cfg.Keys
	gh := ""
	switch {
	case m.repoGH.Err != "":
		gh = " · " + m.repoGH.Err
	case m.repoGH.At.IsZero():
		gh = " · reading GitHub…"
	}
	if m.tree == nil {
		var items [][]seg
		var details []string
		for _, r := range m.repos {
			remote, where, wst := r.Remote, tildify(r.Dir), cDark
			if remote == "" {
				remote = "–"
			}
			if r.Dir == "" {
				where = "github only"
			}
			items = append(items, []seg{s(padTo(r.Name, 20), cWhite), s(" "+padTo(remote, 28), cGrey),
				s(" "+padTo(where, 32), wst), s(" "+r.Needs, cOrange)})
			d := r.Notes
			if r.Needs != "" && len(d) == 0 {
				d = []string{"needs: " + r.Needs}
			}
			details = append(details, strings.Join(d, " · "))
		}
		title := "REPOS   enter opens the folder · b on GitHub · i copy path · " + K.Reply + " its folders" + gh
		empty := "no repos found in ~/bbq or ~"
		return m.listBox(title, items, h, empty, details...)
	}
	lw, rw := pcWidths(m.w)
	lw = min(lw, 44)
	rw = m.w - lw - 2
	left, right := m.repoList(lw, h), m.repoPanel(rw, h)
	out := make([]string, h)
	for i := range out {
		l, r := "", ""
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			r = right[i]
		}
		out[i] = " " + l + " " + r
	}
	return out
}

// repoList: the narrow list beside the panel; ! marks a sync-check note, ◦ a repo on GitHub only.
func (m model) repoList(w, h int) []string {
	in := w - 2
	var body []string
	first := 0
	if vis := h - 2; m.listSel >= vis {
		first = m.listSel - vis + 1
	}
	for i := first; i < len(m.repos); i++ {
		r := m.repos[i]
		mark, mst := "  ", cPlain
		if r.Needs != "" {
			mark, mst = "! ", cOrange
		} else if r.Dir == "" {
			mark, mst = "◦ ", cDark
		}
		if i == m.listSel { // the panel has the keys: its row is the orange one
			body = append(body, row(in, s(" ", cPlain), s(mark, mst), s(r.Name, cWhite)))
			continue
		}
		body = append(body, row(in, s(" ", cPlain), s(mark, mst), s(r.Name, cDark)))
	}
	return box(w, h, []seg{s("REPOS", cGrey)}, cDark, body)
}

// repoPanel: the folder shown, ".." to go up; the keys at the bottom.
func (m model) repoPanel(w, h int) []string {
	K := m.cfg.Keys
	t := m.tree
	in := w - 4
	title := []seg{s(t.repo.Name, cWhite), s(" /"+filepath.ToSlash(t.rel), cGrey)}
	right := []seg{s(t.repo.Remote, cGrey)}
	if t.repo.Remote == "" {
		right = []seg{s("no GitHub origin", cDark)}
	}
	var head []string
	if t.repo.Needs != "" {
		head = append(head, row(in, s("needs: "+t.repo.Needs, cOrange)))
	}
	if t.repo.Dir == "" {
		head = append(head, row(in, s("github only: no local folder", cDark)))
	}
	if len(head) > 0 {
		head = append(head, "")
	}
	var rows []string
	switch {
	case t.loading:
		rows = append(rows, row(in, s("loading…", cDark)))
	case t.err != "":
		rows = append(rows, row(in, s(t.err, cOrange)))
	case len(t.items) == 0:
		rows = append(rows, row(in, s("empty folder", cDark)))
	}
	tail := []string{"", row(in, s("> ", cOrange), s(K.Reply+" opens · h up · enter in Finder · b GitHub · i copy path · esc closes", cDark))}
	avail := max(1, h-2-len(head)-len(tail))
	first := 0
	if t.sel >= avail {
		first = t.sel - avail + 1
	}
	for i := first; i < len(t.items) && len(rows) < avail; i++ {
		e := t.items[i]
		name, st := e.Name, cGrey
		if e.Dir {
			st = cWhite
			if name != ".." {
				name += "/"
			}
		}
		if i == t.sel {
			rows = append(rows, row(in, s(padTo("> "+name, in), cSel)))
			continue
		}
		rows = append(rows, row(in, s("  "+name, st)))
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
	border := cDark
	if t.repo.Needs != "" {
		border = cOrange
	}
	return boxR(w, h, title, right, border, body)
}
