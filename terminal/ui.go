package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

type view int

const (
	vDesk view = iota
	vWall
	vFiles
	vRepos
	vProposals
	vPaperclip
	vHelp
)

// views in tab-bar order, with their command-line codes.
var tabs = []struct {
	code, label string
	v           view
}{
	{"IN", "inbox", vDesk},
	{"AG", "agents", vWall},
	{"FL", "files", vFiles},
	{"RP", "repos", vRepos},
	{"PR", "proposals", vProposals},
	{"PC", "paperclip", vPaperclip},
}

type mode int

const (
	mKeys mode = iota
	mTyping
	mCommand
	mOpen // waiting for the letter of a file to open
)

type model struct {
	w, h      int
	cfg       Config
	cfgTime   time.Time
	agents    []Agent
	ttys      map[string]bool
	selSID    string
	view      view
	mode      mode
	buf       string // typing or command buffer
	leader    bool   // space was pressed, waiting to see if a leader key follows
	leaderSeq int
	zoom      bool
	listSel   int // selection inside FL / PR / PC lists
	status    string
	statusErr bool
	expect    map[string]time.Time // sid -> when we sent; cleared when it turns busy
	lastCache map[string]cachedLast
	pc        PCState
	pcAt      time.Time
	props     []string
	sync      []string
}

type cachedLast struct {
	size  int64
	mtime time.Time
	last  Last
}

type tickMsg time.Time
type ttysMsg map[string]bool
type sentMsg struct {
	sid, name, what, res string
}
type leaderTimeout int
type pcMsg PCState
type execDone struct{ err error }

func newModel() model {
	cfg, ct, err := loadConfig()
	m := model{cfg: cfg, cfgTime: ct, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}}
	if err != nil {
		m.setErr("keys.toml: " + err.Error())
	}
	m.agents = loadAgents(nil)
	if len(m.agents) > 0 {
		m.selSID = m.agents[0].SID
	}
	return m
}

func (m model) Init() tea.Cmd {
	return tea.Batch(tick(), loadTTYs, tea.SetWindowTitle("kaching"))
}

func tick() tea.Cmd {
	return tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func loadTTYs() tea.Msg { return ttysMsg(terminalTTYs()) }

func (m *model) setStatus(t string) { m.status, m.statusErr = t, false }
func (m *model) setErr(t string)    { m.status, m.statusErr = t, true }

func (m *model) refresh() {
	m.agents = loadAgents(m.ttys)
	for sid, at := range m.expect {
		for _, a := range m.agents {
			if a.SID == sid && (a.Busy || transcriptAfter(a.Transcript, at)) {
				m.setStatus("✓ " + a.Name + " is on it")
				delete(m.expect, sid)
			}
		}
		if time.Since(at) > 20*time.Second {
			delete(m.expect, sid)
		}
	}
	if st, err := os.Stat(configPath()); err == nil && st.ModTime().After(m.cfgTime) {
		cfg, ct, err := loadConfig()
		m.cfg, m.cfgTime = cfg, ct
		if err != nil {
			m.setErr("keys.toml: " + err.Error())
		} else {
			m.setStatus("keys.toml reloaded")
		}
	}
	if m.sel() == nil && len(m.agents) > 0 {
		m.selSID = m.agents[0].SID
	}
	m.writeState()
}

// selfTTY is the terminal's own tab (so a hotkey can bring it forward), ” when not in one.
var selfTTY = pidTTYs([]string{fmt.Sprint(os.Getpid())})[os.Getpid()]

// writeState tells the rest of Kaching (the monitor queue, the open hotkey) that the terminal is open and
// which agent is selected: ~/.agent/terminal/open holds pid=, self_tty=, sid= and tty= lines.
func (m *model) writeState() {
	a := m.sel()
	sid, tty := "", ""
	if a != nil {
		sid, tty = a.SID, a.TTY
	}
	p := filepath.Join(agentHome(), "terminal", "open")
	want := fmt.Sprintf("pid=%d\nself_tty=%s\nsid=%s\ntty=%s\n", os.Getpid(), selfTTY, sid, tty)
	if b, err := os.ReadFile(p); err == nil && string(b) == want {
		return
	}
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	_ = os.WriteFile(p+".tmp", []byte(want), 0o644)
	_ = os.Rename(p+".tmp", p)
}

// transcriptAfter: the session wrote to its transcript after t (it reacted to what we sent).
func transcriptAfter(path string, t time.Time) bool {
	st, err := os.Stat(path)
	return err == nil && st.ModTime().After(t.Add(500*time.Millisecond))
}

func removeState() { _ = os.Remove(filepath.Join(agentHome(), "terminal", "open")) }

func (m *model) sel() *Agent {
	for i := range m.agents {
		if m.agents[i].SID == m.selSID {
			return &m.agents[i]
		}
	}
	return nil
}

func (m *model) selIndex() int {
	for i := range m.agents {
		if m.agents[i].SID == m.selSID {
			return i
		}
	}
	return -1
}

func (m *model) last(a *Agent) Last {
	if a == nil || a.Transcript == "" {
		return Last{}
	}
	st, err := os.Stat(a.Transcript)
	if err != nil {
		return Last{}
	}
	if c, ok := m.lastCache[a.Transcript]; ok && c.size == st.Size() && c.mtime.Equal(st.ModTime()) {
		return c.last
	}
	l := readLast(a.Transcript, a.Cwd)
	m.lastCache[a.Transcript] = cachedLast{st.Size(), st.ModTime(), l}
	return l
}

func (m *model) move(d int) {
	if len(m.agents) == 0 {
		return
	}
	i := m.selIndex() + d
	if i < 0 {
		i = len(m.agents) - 1
	}
	if i >= len(m.agents) {
		i = 0
	}
	m.selSID = m.agents[i].SID
	m.writeState()
}

func (m *model) nextWaiting() {
	var w []int
	for i, a := range m.agents {
		if a.Group() == 0 {
			w = append(w, i)
		}
	}
	if len(w) == 0 {
		m.setStatus("nobody is waiting for you")
		return
	}
	cur := m.selIndex()
	for _, i := range w {
		if i > cur {
			m.selSID = m.agents[i].SID
			m.writeState()
			return
		}
	}
	m.selSID = m.agents[w[0]].SID
	m.writeState()
}

// deliver sends text (or keys) to the selected agent in the background.
func (m *model) deliver(what string, keys []string) tea.Cmd {
	a := m.sel()
	if a == nil {
		m.setErr("no agent selected")
		return nil
	}
	if !a.InTerminal {
		m.setErr(a.Name + " isn't in a Terminal tab: look only (g opens it)")
		return nil
	}
	sid, name, tty := a.SID, a.Name, a.TTY
	label := what
	if keys != nil {
		label = "key " + strings.Join(keys, " ")
	}
	m.setStatus("sending to " + name + "…")
	return func() tea.Msg {
		var res string
		if keys != nil {
			res = sendKeys(tty, keys...)
		} else {
			res = sendText(tty, what)
		}
		return sentMsg{sid, name, label, res}
	}
}

func (m *model) answer(n int) tea.Cmd {
	a := m.sel()
	if a == nil {
		return nil
	}
	l := m.last(a)
	if n > len(l.Options) || len(l.Options) == 0 {
		m.setErr(fmt.Sprintf("%s has no option %d", a.Name, n))
		return nil
	}
	if l.Menu {
		return m.deliver("", []string{strconv.Itoa(n)})
	}
	return m.deliver(strconv.Itoa(n), nil)
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		return m, nil
	case tickMsg:
		m.refresh()
		cmds := []tea.Cmd{tick()}
		if time.Time(msg).Second()%10 < 2 {
			cmds = append(cmds, loadTTYs)
		}
		if m.view == vPaperclip && time.Since(m.pcAt) > 5*time.Second {
			m.pcAt = time.Now()
			cmds = append(cmds, func() tea.Msg { return pcMsg(loadPaperclip()) })
		}
		return m, tea.Batch(cmds...)
	case ttysMsg:
		m.ttys = msg
		m.refresh()
		return m, nil
	case pcMsg:
		m.pc = PCState(msg)
		return m, nil
	case sentMsg:
		if msg.res == "ok" {
			m.setStatus("sent " + msg.what + " → " + msg.name)
			m.expect[msg.sid] = time.Now()
		} else {
			m.setErr(msg.name + ": " + msg.res)
		}
		return m, nil
	case leaderTimeout:
		if m.leader && int(msg) == m.leaderSeq {
			m.leader = false
			m.nextWaiting()
		}
		return m, nil
	case execDone:
		m.loadProposals()
		if msg.err != nil {
			m.setErr(msg.err.Error())
		}
		return m, nil
	case tea.KeyMsg:
		return m.key(msg)
	}
	return m, nil
}

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	ks := k.String()
	if ks == "ctrl+c" {
		removeState()
		return m, tea.Quit
	}
	switch m.mode {
	case mTyping, mCommand:
		switch k.Type {
		case tea.KeyEsc:
			m.mode, m.buf = mKeys, ""
			return m, nil
		case tea.KeyEnter:
			buf := strings.TrimSpace(m.buf)
			md := m.mode
			m.mode, m.buf = mKeys, ""
			if buf == "" {
				return m, nil
			}
			if md == mTyping && m.view == vPaperclip {
				if m.listSel >= len(m.pc.Items) {
					return m, nil
				}
				it := m.pc.Items[m.listSel]
				m.setStatus("posting comment on " + it.Ref + "…")
				return m, func() tea.Msg {
					res := "ok"
					if err := pcComment(it.ID, buf); err != nil {
						res = "error: " + err.Error()
					}
					return sentMsg{"", it.Ref, "comment", res}
				}
			}
			if md == mTyping {
				return m, m.deliver(buf, nil)
			}
			return m.command(buf)
		case tea.KeyBackspace:
			if r := []rune(m.buf); len(r) > 0 {
				m.buf = string(r[:len(r)-1])
			}
			return m, nil
		case tea.KeyCtrlU:
			m.buf = ""
			return m, nil
		case tea.KeySpace:
			m.buf += " "
			return m, nil
		case tea.KeyRunes:
			m.buf += string(k.Runes)
			return m, nil
		}
		return m, nil
	case mOpen:
		m.mode = mKeys
		if len(ks) == 1 && ks[0] >= 'a' && ks[0] <= 'i' {
			l := m.last(m.sel())
			i := int(ks[0] - 'a')
			if i < len(l.Files) {
				if err := openPath(m.cfg.OpenCmd, l.Files[i]); err != nil {
					m.setErr(err.Error())
				} else {
					m.setStatus("opened " + tildify(l.Files[i]))
				}
				return m, nil
			}
		}
		m.setErr("no such file")
		return m, nil
	}

	// key mode
	if m.leader {
		m.leader = false
		if r, ok := m.cfg.leaderReply(ks); ok && (m.view == vDesk || m.view == vWall) {
			return m, m.deliver(r.Text, nil)
		}
		m.nextWaiting() // space alone, then an ordinary key
	}
	K := m.cfg.Keys
	switch {
	case ks == K.Command:
		m.mode, m.buf = mCommand, ""
		return m, nil
	case ks == "esc":
		if m.zoom {
			m.zoom = false
		} else {
			m.view = vDesk
		}
		m.status = ""
		return m, nil
	case ks == K.Waiting || (K.Waiting == " " && k.Type == tea.KeySpace):
		m.leader = true
		m.leaderSeq++
		seq := m.leaderSeq
		return m, tea.Tick(450*time.Millisecond, func(time.Time) tea.Msg { return leaderTimeout(seq) })
	case ks == K.Refresh:
		m.refresh()
		return m, loadTTYs
	case ks == K.Wall:
		m.view, m.zoom = vWall, false
		return m, nil
	case ks == "?":
		m.view = vHelp
		return m, nil
	}
	switch m.view {
	case vFiles, vProposals, vPaperclip, vRepos:
		if done, cmd := m.listKey(ks); done {
			return m, cmd
		}
	}
	switch {
	case ks == K.Next || ks == "down":
		m.move(1)
	case ks == K.Prev || ks == "up":
		m.move(-1)
	case len(ks) == 1 && ks[0] >= '1' && ks[0] <= '9':
		if m.view == vWall && !m.zoom {
			i := int(ks[0] - '1')
			if i < len(m.agents) {
				m.selSID = m.agents[i].SID
				m.writeState()
			}
			return m, nil
		}
		return m, m.answer(int(ks[0] - '0'))
	case ks == K.Reply:
		m.mode, m.buf = mTyping, ""
	case ks == K.Open:
		if len(m.last(m.sel()).Files) == 0 {
			m.setErr("no files mentioned")
		} else {
			m.mode = mOpen
		}
	case ks == K.Goto:
		if a := m.sel(); a != nil && a.TTY != "" {
			tty := a.TTY
			return m, func() tea.Msg {
				res := raiseTab(tty)
				return sentMsg{"", a.Name, "go to window", res}
			}
		}
		m.setErr("no Terminal window for this agent")
	case ks == K.Zoom && m.view == vWall:
		m.zoom = !m.zoom
	default:
		if m.view != vDesk && m.view != vWall {
			return m, nil
		}
		if r, ok := m.cfg.directReply(ks); ok {
			return m, m.deliver(r.Text, nil)
		}
	}
	return m, nil
}

// listKey handles j/k/enter and the view's own keys in the list views. done=false lets the key fall through.
func (m *model) listKey(ks string) (bool, tea.Cmd) {
	K := m.cfg.Keys
	n := 0
	switch m.view {
	case vFiles:
		n = len(m.allFiles())
	case vProposals:
		n = len(m.props)
	case vPaperclip:
		n = len(m.pc.Items)
	case vRepos:
		return ks == K.Next || ks == K.Prev, nil
	}
	switch ks {
	case K.Next, "down":
		if m.listSel < n-1 {
			m.listSel++
		}
		return true, nil
	case K.Prev, "up":
		if m.listSel > 0 {
			m.listSel--
		}
		return true, nil
	case "enter":
		switch m.view {
		case vFiles:
			if fs := m.allFiles(); m.listSel < len(fs) {
				if err := openPath(m.cfg.OpenCmd, fs[m.listSel].path); err != nil {
					m.setErr(err.Error())
				} else {
					m.setStatus("opened " + tildify(fs[m.listSel].path))
				}
			}
		case vProposals:
			if m.listSel < len(m.props) {
				id := propID(m.props[m.listSel])
				c := exec.Command(proposalsBin(), "show", id)
				return true, tea.ExecProcess(exec.Command("sh", "-c", c.String()+" | less -R"), func(err error) tea.Msg { return execDone{err} })
			}
		case vPaperclip:
			if m.listSel < len(m.pc.Items) {
				openPath("open", m.pc.Items[m.listSel].URL)
			}
		}
		return true, nil
	}
	if m.view == vProposals && m.listSel < len(m.props) {
		id := propID(m.props[m.listSel])
		switch ks {
		case "a": // approve: hand the screen to ching-proposals, which asks for its typed code on /dev/tty
			return true, tea.ExecProcess(exec.Command(proposalsBin(), "approve", id), func(err error) tea.Msg { return execDone{err} })
		case "x":
			out, err := exec.Command(proposalsBin(), "reject", id).CombinedOutput()
			m.loadProposals()
			if err != nil {
				m.setErr(strings.TrimSpace(string(out)))
			} else {
				m.setStatus("rejected " + id)
			}
			return true, nil
		case "z":
			out, err := exec.Command(proposalsBin(), "snooze", id, "7").CombinedOutput()
			m.loadProposals()
			if err != nil {
				m.setErr(strings.TrimSpace(string(out)))
			} else {
				m.setStatus("snoozed " + id + " for 7 days")
			}
			return true, nil
		}
	}
	if m.view == vPaperclip && m.listSel < len(m.pc.Items) && ks == m.cfg.Keys.Reply {
		m.mode, m.buf = mTyping, ""
		return true, nil
	}
	return false, nil
}

func (m model) command(code string) (tea.Model, tea.Cmd) {
	c := strings.ToUpper(strings.Fields(code)[0])
	for _, t := range tabs {
		if c == t.code {
			m.view, m.zoom, m.listSel = t.v, false, 0
			switch t.v {
			case vRepos:
				m.loadSync()
			case vProposals:
				m.loadProposals()
			case vPaperclip:
				m.pcAt = time.Now()
				return m, func() tea.Msg { return pcMsg(loadPaperclip()) }
			}
			return m, nil
		}
	}
	switch {
	case c == "HELP" || c == "?":
		m.view = vHelp
	case c == "QUIT" || c == "Q":
		removeState()
		return m, tea.Quit
	case c == "W" || c == "WALL":
		m.view = vWall
	case strings.HasPrefix(c, "A"):
		if n, err := strconv.Atoi(c[1:]); err == nil && n >= 1 && n <= len(m.agents) {
			m.selSID = m.agents[n-1].SID
			m.view = vDesk
			m.writeState()
			return m, nil
		}
		m.setErr("no agent " + c[1:])
	default:
		// a name: select the first agent whose name starts with it
		for _, a := range m.agents {
			if strings.HasPrefix(strings.ToLower(a.Name), strings.ToLower(code)) {
				m.selSID, m.view = a.SID, vDesk
				m.writeState()
				return m, nil
			}
		}
		m.setErr("unknown code " + c + " (HELP lists them)")
	}
	return m, nil
}

func proposalsBin() string {
	return filepath.Join(os.Getenv("HOME"), ".claude", "ching", "bin", "ching-proposals")
}

func propID(line string) string {
	// "skill skill-gitbook-docs-sync: Writes ..." -> skill-gitbook-docs-sync
	f := strings.Fields(line)
	if len(f) >= 2 {
		return strings.TrimSuffix(f[1], ":")
	}
	return ""
}

func (m *model) loadProposals() {
	out, _ := exec.Command(proposalsBin(), "list").Output()
	m.props = nil
	for _, l := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(l) != "" && strings.Contains(l, ":") {
			m.props = append(m.props, strings.TrimSpace(l))
		}
	}
	if m.listSel >= len(m.props) {
		m.listSel = 0
	}
}

func (m *model) loadSync() {
	b, _ := os.ReadFile(filepath.Join(agentHome(), "sync-check.md"))
	m.sync = strings.Split(strings.TrimSpace(string(b)), "\n")
}

type fileRef struct {
	path, agent string
}

func (m *model) allFiles() []fileRef {
	var out []fileRef
	seen := map[string]bool{}
	for i := range m.agents {
		l := m.last(&m.agents[i])
		for j := len(l.Files) - 1; j >= 0; j-- {
			if !seen[l.Files[j]] {
				seen[l.Files[j]] = true
				out = append(out, fileRef{l.Files[j], m.agents[i].Name})
			}
		}
	}
	return out
}

func tildify(p string) string {
	h := os.Getenv("HOME")
	if strings.HasPrefix(p, h) {
		return "~" + p[len(h):]
	}
	return p
}

func age(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	return fmt.Sprintf("%dd", int(d.Hours()/24))
}
