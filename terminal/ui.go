package main

import (
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

type view int

const (
	vDesk view = iota
	vWall
	vFiles
	vRepos
	vProposals
	vPulls
	vRecaps
	vPaperclip
	vHelp
)

// views in tab-bar order, with their command-line codes.
var tabs = []struct {
	code, label string
	v           view
}{
	{"IN", "inbox", vDesk},
	{"FL", "files", vFiles},
	{"RP", "repos", vRepos},
	{"RC", "recaps", vRecaps},
	{"PR", "pull requests", vPulls},
	{"PO", "proposals", vProposals},
	{"PC", "paperclip", vPaperclip},
}

type mode int

const (
	mKeys mode = iota
	mTyping
	mCommand
	mOpen    // waiting for the letter of a file to open
	mConfirm // a yes/no question in the command line: enter or y says yes
)

type model struct {
	w, h       int
	cfg        Config
	cfgTime    time.Time
	agents     []Agent
	ttys       map[string]tabPos
	groups     [][]string
	selSID     string
	view       view
	mode       mode
	buf        string // typing or command buffer
	leader     bool   // space was pressed: the next key picks a "space <k>" reply, however long that takes (esc cancels)
	zoom       bool
	helpOff    int // the HELP page's first line
	listSel    int // selection inside FL / PR / PO / PC lists
	status     string
	statusErr  bool
	expect     map[string]time.Time // sid -> when we sent; cleared when it turns busy
	lastCache  map[string]cachedLast
	pc         PCState
	pcDet      map[string]PCDetail // issue id -> its side panel (PC view)
	pcScroll   *chatScroll         // how far the PC side panel is scrolled back
	pcForms    *pcFormSet          // what the owner chose so far in the requests with a form (pcform.go)
	pcAt       time.Time
	pulls      PullsState          // the PR view: open GitHub pull requests
	pullsAt    time.Time           // when they were last asked for
	remote     RemoteState         // the REMOTE section: active sessions on other machines (D58)
	remoteAt   time.Time           // when they were last asked for
	prOpen     bool                // the PR view's side panel is open (k)
	prDet      map[string]PRDetail // pull request url -> its side panel
	prScroll   *chatScroll         // how far the PR side panel is scrolled back
	rcScroll   *chatScroll         // how far the RC view's recap panel is scrolled back
	badgeAt    time.Time           // when the proposals and Paperclip were last read for the tab bar
	pendingJob string              // a background agent /NW started: selected once it shows in the list
	props      []string
	sync       []string
	repoLocal  []Repo       // RP: the clones on this Mac
	repoGH     GHRepos      // RP: the owners' GitHub repos
	repos      []Repo       // RP: both, as listed
	repoRecent int          // RP: how many of repos are in the first part, MOST RECENT; the others follow from A to Z
	tree       *repoTree    // RP side panel: the selected repo's folders; nil when closed
	branches   *branchPanel // RP side panel: the selected repo's branches or worktrees; nil when closed
	confirmURL string       // mConfirm: what yes opens
	ed         *editor
	prompts    map[string]Prompt   // sid -> the menu its screen shows (selected waiting agents only)
	scroll     *chatScroll         // shared by every copy of the model: View records the limits it drew
	usage      Usage               // the Claude usage limits, read on every tick
	askProg    map[string]*askProg // sid -> where a background agent's menu is (see ask.go)
	nw         nwOpts              // what /NW is starting: its folder, model, effort and permission mode
	nwDir      nwFolder            // where that folder came from and what is there (the box shows it)
	bgScr      map[string]Prompt   // sid -> the menu on a background agent's screen (rebuilt from claude logs)
	files      *fileHistory        // the FL view: the last files the agents mentioned
	find       findState           // the FIND view: the search on the screen
	asked      map[string]askSeen  // sid -> when its menu first showed: a busy agent's wait starts there
	ticks      int
}

// askSeen is when an agent's menu first and last showed on its screen. A menu missed on one read and back within
// askGrace is the same menu: its wait keeps counting from first.
type askSeen struct{ first, last time.Time }

const askGrace = 15 * time.Second

// chatScroll is how far the selected agent's conversation is scrolled back from its newest line. agentPanel
// sets max and page when it draws; another agent (sid) starts at the newest line again.
type chatScroll struct {
	sid            string
	off, max, page int
}

type cachedLast struct {
	size  int64
	mtime time.Time
	last  Last
}

type tickMsg time.Time
type ttysMsg struct {
	tabs   map[string]tabPos
	groups [][]string
}
type sentMsg struct {
	sid, name, what, res string
}
type statusMsg string
type promptMsg struct {
	sid string
	p   Prompt
}
type pcMsg PCState
type propsMsg []string
type pcDetailMsg PCDetail
type pcActedMsg struct{ ref, what, err string }
type bgStartedMsg struct{ job, dir string }
type execDone struct{ err error }

func newModel() model {
	cfg, ct, err := loadConfig()
	m := model{cfg: cfg, cfgTime: ct, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, ed: newEditor(), prompts: map[string]Prompt{}, scroll: &chatScroll{}, files: loadFileHistory(), pcDet: map[string]PCDetail{}, pcScroll: &chatScroll{}, pcForms: &pcFormSet{}, prDet: map[string]PRDetail{}, prScroll: &chatScroll{}, rcScroll: &chatScroll{}, askProg: map[string]*askProg{}, bgScr: map[string]Prompt{}}
	m.ed.drafts = loadDrafts()
	if err != nil {
		m.setErr("keys.toml: " + err.Error())
	}
	m.agents = loadAgents(nil, nil)
	m.usage = loadUsage()
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

func loadTTYs() tea.Msg { return ttysMsg{terminalTabs(), tabGroups()} }

func (m *model) setStatus(t string) { m.status, m.statusErr = t, false }
func (m *model) setErr(t string)    { m.status, m.statusErr = t, true }

func (m *model) refresh() {
	m.agents = loadAgents(m.ttys, m.groups)
	m.usage = loadUsage()
	m.applyPrompts()
	m.noteFiles()
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
	if m.pendingJob != "" {
		for _, a := range m.agents {
			if a.Bg && a.Job == m.pendingJob {
				m.selSID, m.pendingJob = a.SID, ""
			}
		}
	}
	if m.sel() == nil && m.selRemote() == nil && len(m.agents) > 0 {
		m.selSID = m.agents[0].SID
	}
	m.writeState()
}

// selfTTY is the terminal's own tab (so a hotkey can bring it forward), ” when not in one.
var selfTTY = pidTTYs([]string{fmt.Sprint(os.Getpid())})[os.Getpid()]

// writeState tells the rest of Kaching (the monitor queue, the open hotkey) that the terminal is open and
// which agent is selected: ~/.agent/terminal/open holds pid=, self_tty=, sid= and tty= lines.
// readOnly: a --render run must not tell the queue that kaching is open.
var readOnly bool

func (m *model) writeState() {
	if readOnly {
		return
	}
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

// bringHere: the agent's window onto the main display (the monitor queue's `show`, as if the owner dragged it
// there: its cell on the other display stays reserved, dragging it back returns it there), then into focus. With
// the queue off it is only brought into focus where it is.
func bringHere(sid, tty string) string {
	out, _ := exec.Command(queueBin(), "show", sid).CombinedOutput()
	res := raiseTab(tty)
	if res == "ok" && !strings.Contains(string(out), "Shown") {
		return "error: brought into focus, but not moved (" + strings.TrimSpace(string(out)) + ")"
	}
	return res
}

// returnWindow: kaching sent the agent an answer, so a window of it that the queue moved to the main display
// goes back to its cell (queue.sh return, D42). Moving around inside a menu is no answer.
func returnWindow(sid, what string) tea.Cmd {
	switch what {
	case "key left", "key right", "key tab", "key up", "key down":
		return nil
	}
	return func() tea.Msg {
		_ = exec.Command(queueBin(), "return", sid).Run()
		return nil
	}
}

func queueBin() string {
	return filepath.Join(kitDir(), "bin", "queue.sh")
}

// transcriptAfter: the session wrote to its transcript after t (it reacted to what we sent).
func transcriptAfter(path string, t time.Time) bool {
	st, err := os.Stat(path)
	return err == nil && st.ModTime().After(t.Add(500*time.Millisecond))
}

// removeState: kaching closed. It only removes its own open file: opening, quitting or reloading kaching
// never moves, resizes or closes a Terminal window (owner, 2026-10-17). kaching reads the agents and types
// what the owner chose; window placement is the monitor queue's job, on its own events.
func removeState() {
	_ = os.Remove(filepath.Join(agentHome(), "terminal", "open"))
}

func (m *model) sel() *Agent {
	for i := range m.agents {
		if m.agents[i].SID == m.selSID {
			return &m.agents[i]
		}
	}
	return nil
}

// selRemote: the selected REMOTE session (selSID holds its id), nil when an agent or nothing is selected.
func (m *model) selRemote() *RemoteSession {
	if i := m.remote.index(m.selSID); i >= 0 {
		return &m.remote.Items[i]
	}
	return nil
}

// isRemoteID: whether id is a remote session's (they never clash with an agent's uuid).
func (m *model) isRemoteID(id string) bool { return strings.HasPrefix(id, "session_") }

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

// helpScroll scrolls the help page for the scroll keys (up and down 3 lines, a page, the start, the end); false for
// any other key.
func (m *model) helpScroll(ks string) bool {
	K := m.cfg.Keys
	rows := max(1, m.h-headerH-footerH-2)
	last := max(0, len(m.textBody(m.helpLines()))-rows)
	off := m.helpOff
	switch ks {
	case K.Older, K.Prev:
		off -= 3
	case K.Newer, K.Next:
		off += 3
	case "pgup":
		off -= max(1, rows-1)
	case "pgdown":
		off += max(1, rows-1)
	case "home":
		off = 0
	case "end":
		off = last
	default:
		return false
	}
	m.helpOff = min(max(off, 0), last)
	return true
}

// scrollChat scrolls the selected agent's conversation for the scroll keys; false for any other key.
func (m *model) scrollChat(ks string) bool {
	if m.scroll == nil {
		return false
	}
	c := m.scroll
	step := 0
	switch ks {
	case m.cfg.Keys.Older:
		step = 3
	case m.cfg.Keys.Newer:
		step = -3
	case "pgup":
		step = max(1, c.page-1)
	case "pgdown":
		step = -max(1, c.page-1)
	case "home":
		step = c.max
	case "end":
		step = -c.off
	default:
		return false
	}
	if a := m.sel(); a == nil || a.SID != c.sid {
		return true // nothing drawn for this agent yet
	}
	c.off = min(max(0, c.off+step), c.max)
	return true
}

// move selects the next or previous row of the desk: the agents, then the REMOTE sessions below them.
func (m *model) move(d int) {
	ids := make([]string, 0, len(m.agents)+len(m.remote.Items))
	for _, a := range m.agents {
		ids = append(ids, a.SID)
	}
	if m.view == vDesk { // the wall draws agents only
		for _, r := range m.remote.Items {
			ids = append(ids, r.ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	cur := -1
	for i, id := range ids {
		if id == m.selSID {
			cur = i
		}
	}
	i := cur + d
	if i < 0 {
		i = len(ids) - 1
	}
	if i >= len(ids) {
		i = 0
	}
	m.selSID = ids[i]
	m.writeState()
}

// promptKey forwards enter, the arrows left/right and tab to an agent that shows a menu (choose with arrows,
// switch question tabs, confirm), so every menu can be finished from kaching.
func (m *model) promptKey(ks string) (bool, tea.Cmd) {
	a := m.sel()
	if a == nil {
		return false, nil
	}
	if _, ok := m.prompts[a.SID]; !ok {
		return false, nil
	}
	switch ks {
	case "enter", "left", "right", "tab", "shift+tab":
		k := ks
		if k == "shift+tab" {
			k = "left"
		}
		m.pressMenu(a, k)
		return true, m.deliver("", []string{k})
	}
	return false, nil
}

// nextWaiting selects the INPUT agent that has waited the longest: it asked the owner something or is blocked.
// It doesn't cycle: once that one is answered, the next longest is first. Done agents (WAITING) are skipped.
func (m *model) nextWaiting() {
	best := -1
	for i, a := range m.agents {
		if a.needsYou() && (best < 0 || a.Since.Before(m.agents[best].Since)) {
			best = i
		}
	}
	if best < 0 {
		m.setStatus("nobody asks you anything")
		return
	}
	m.selSID = m.agents[best].SID
	m.writeState()
}

// deliver sends text (or keys) to the selected agent in the background.
func (m *model) deliver(what string, keys []string) tea.Cmd {
	return m.deliverAs("", what, keys)
}

// deliverAs is deliver with a name for the status line and the window rule ("" names it after what is sent).
func (m *model) deliverAs(label, what string, keys []string) tea.Cmd {
	a := m.sel()
	if a == nil {
		m.setErr("no agent selected")
		return nil
	}
	if !a.canSend() {
		m.setErr(a.Name + " isn't in a Terminal tab: look only (g opens it)")
		return nil
	}
	ag := *a
	sid, name := a.SID, a.Name
	if label == "" {
		label = what
		if keys != nil {
			label = "key " + strings.Join(keys, " ")
		}
	}
	m.setStatus("sending to " + name + "…")
	return func() tea.Msg {
		return sentMsg{sid, name, label, transmitFn(ag, what, keys)}
	}
}

func (m *model) answer(n int) tea.Cmd {
	a := m.sel()
	if a == nil {
		return nil
	}
	if p, ok := m.prompts[a.SID]; ok && len(p.Options) > 0 {
		if n > len(p.Options) {
			m.setErr(fmt.Sprintf("%s has no option %d", a.Name, n))
			return nil
		}
		m.pressMenu(a, strconv.Itoa(n))
		return m.deliver("", []string{strconv.Itoa(n)})
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
		if m.mode == mTyping {
			m.ed.resize(m.editorWidth())
		}
		return m, nil
	case tickMsg:
		m.ticks++
		m.refresh()
		cmds := []tea.Cmd{tick()}
		if c := m.readPrompt(0); c != nil {
			cmds = append(cmds, c)
		}
		if time.Time(msg).Second()%10 < 2 {
			cmds = append(cmds, loadTTYs)
		}
		every := pullsEvery // the PR tab's count, read slower than what the open view shows
		if m.view == vPulls {
			every = badgeEvery
		}
		if time.Since(m.pullsAt) > every {
			m.pullsAt = time.Now()
			cmds = append(cmds, func() tea.Msg { return pullsMsg(loadPulls()) })
		}
		if time.Since(m.remoteAt) > remoteEvery && !readOnly {
			m.remoteAt = time.Now()
			cmds = append(cmds, func() tea.Msg { return remoteMsg(loadRemote()) })
		}
		if m.view == vPaperclip && time.Since(m.pcAt) > 5*time.Second {
			m.pcAt = time.Now()
			cmds = append(cmds, func() tea.Msg { return pcMsg(loadPaperclip()) })
		}
		if time.Since(m.badgeAt) > badgeEvery { // the PO and PC tabs turn orange on other views too
			m.badgeAt = time.Now()
			cmds = append(cmds, func() tea.Msg { return propsMsg(readProposals()) })
			if m.view != vPaperclip {
				m.pcAt = time.Now()
				cmds = append(cmds, func() tea.Msg { return pcMsg(loadPaperclip()) })
			}
		}
		return m, tea.Batch(cmds...)
	case ttysMsg:
		m.ttys, m.groups = msg.tabs, msg.groups
		m.refresh()
		return m, nil
	case promptMsg:
		if len(msg.p.Options) == 0 {
			delete(m.prompts, msg.sid)
			delete(m.bgScr, msg.sid)
		} else {
			m.prompts[msg.sid] = msg.p
			m.sawAsk(msg.sid, time.Now())
			if a := m.agentBySID(msg.sid); a != nil && a.Bg {
				m.bgScr[msg.sid] = msg.p
			}
		}
		m.applyPrompts()
		return m, nil
	case pcMsg:
		m.pc = PCState(msg)
		if m.listSel >= len(m.pc.Items) && m.view == vPaperclip {
			m.listSel = max(0, len(m.pc.Items)-1)
		}
		return m, m.pcDetailCmd(5 * time.Second)
	case pcDetailMsg:
		m.pcDet[msg.ID] = PCDetail(msg)
		return m, nil
	case prDetailMsg:
		m.prDet[msg.URL] = PRDetail(msg)
		return m, nil
	case prMergedMsg:
		delete(m.prDet, msg.url)
		if msg.err != "" {
			m.setErr("not merged: " + msg.ref + ": " + msg.err)
			return m, m.prDetailCmd(0)
		}
		m.setStatus("✓ merged " + msg.ref + " (" + msg.how + ")")
		m.prDrop(msg.url)
		return m, m.prDetailCmd(time.Minute)
	case prClosedMsg:
		delete(m.prDet, msg.url)
		if msg.err != "" {
			m.setErr("not closed: " + msg.ref + ": " + msg.err)
			return m, m.prDetailCmd(0)
		}
		m.setStatus("✓ closed " + msg.ref)
		m.prDrop(msg.url)
		return m, m.prDetailCmd(time.Minute)
	case pcActedMsg:
		if msg.err != "" {
			m.setErr(msg.ref + ": " + msg.err)
		} else {
			m.setStatus("✓ " + msg.what + " · " + msg.ref)
		}
		m.pcAt = time.Now()
		for id := range m.pcDet { // read the panels again: the request is answered
			delete(m.pcDet, id)
		}
		return m, func() tea.Msg { return pcMsg(loadPaperclip()) }
	case allMsg:
		return m, m.sentAll(msg)
	case bgStartedMsg:
		m.setStatus("✓ background agent " + msg.job + " started in " + tildify(msg.dir) + " · g attaches a window")
		m.pendingJob = msg.job
		m.refresh()
		return m, nil
	case findNamesMsg, findTextMsg, findAIMsg, findPanelMsg:
		return m.findUpdate(msg)
	case remoteMsg:
		m.remote = m.remote.merge(RemoteState(msg))
		if m.selRemote() == nil && m.isRemoteID(m.selSID) { // the selected session is no longer active
			m.selSID = ""
			if len(m.agents) > 0 {
				m.selSID = m.agents[0].SID
			}
			m.writeState()
		}
		return m, nil
	case remoteSentMsg:
		if msg.err != "" {
			m.setErr("not sent to " + msg.title + ": " + msg.err)
			return m, nil
		}
		m.setStatus("✓ sent to " + msg.title + ": read the reply with enter (claude.ai/code)")
		m.remoteAt = time.Time{} // read the list again at the next tick: its state moved
		return m, nil
	case pullsMsg:
		sel := ""
		if m.view == vPulls && m.listSel < len(m.pulls.Items) {
			sel = m.pulls.Items[m.listSel].URL
		}
		m.pulls = m.pulls.merge(PullsState(msg))
		if m.view == vPulls { // the selection stays on its pull request when the order changes
			if i := m.pulls.index(sel); i >= 0 {
				m.listSel = i
			} else if m.listSel >= len(m.pulls.Items) {
				m.listSel = max(0, len(m.pulls.Items)-1)
			}
		}
		return m, nil
	case propsMsg:
		m.props = msg
		if m.listSel >= len(m.props) && m.view == vProposals {
			m.listSel = 0
		}
		return m, nil
	case sentMsg:
		if msg.res == "ok" {
			m.setStatus("sent " + msg.what + " → " + msg.name)
			m.expect[msg.sid] = time.Now()
		} else {
			m.setErr(msg.name + ": " + msg.res)
			delete(m.askProg, msg.sid) // a failed key: the menu may be elsewhere, start from the first question
		}
		delete(m.prompts, msg.sid)
		delete(m.bgScr, msg.sid)
		delete(m.asked, msg.sid) // answered: a menu after this is a new wait
		if msg.res == "ok" && msg.sid != "" {
			return m, tea.Batch(m.readPrompt(500*time.Millisecond), returnWindow(msg.sid, msg.what))
		}
		return m, m.readPrompt(500 * time.Millisecond)
	case statusMsg:
		m.setStatus(string(msg))
		m.refresh()
		return m, nil
	case execDone:
		m.loadProposals()
		if msg.err != nil {
			m.setErr(msg.err.Error())
		}
		return m, nil
	case ghReposMsg, treeMsg, branchesMsg:
		return m.repoMsg(msg)
	case tea.KeyMsg:
		return m.key(msg)
	}
	if m.view == vRepos && m.mode == mKeys && isShiftEnter(msg) {
		m.repoGitHub()
	}
	return m, nil
}

func (m model) key(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	ks := k.String()
	if m.mode == mTyping {
		return m.typingKey(k)
	}
	if ks == "ctrl+c" {
		if m.mode != mKeys { // ctrl+c leaves the command line or file choice; only in key mode does it quit
			m.mode, m.buf = mKeys, ""
			return m, nil
		}
		removeState()
		return m, tea.Quit
	}
	switch m.mode {
	case mCommand:
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
			_ = md
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
	case mConfirm:
		return m.confirmKey(ks)
	}

	// key mode
	K := m.cfg.Keys
	if m.leader { // space waits for its second key with no time limit; esc, or a key that is bound to nothing, ends it
		m.leader = false
		m.status = ""
		switch {
		case ks == "esc":
			return m, nil
		case ks == " " && K.Waiting == " ": // space space
			m.nextWaiting()
			return m, nil
		}
		if r, ok := m.cfg.leaderReply(ks); ok {
			return m, m.deliver(r.Text, nil)
		}
		m.setErr("space " + ks + " is bound to nothing")
		return m, nil
	}
	switch {
	case ks == K.Command:
		m.mode, m.buf = mCommand, ""
		return m, nil
	case ks == "esc" && m.view == vFind && m.find.Panel != nil: // the excerpts close first, then the view
		m.find.Panel = nil
		return m, nil
	case ks == "esc":
		if m.view == vRepos && (m.tree != nil || m.branches != nil) { // the side panel closes first
			m.tree, m.branches = nil, nil
		} else if m.zoom {
			m.zoom = false
		} else if m.view == vPulls && m.prOpen {
			m.prOpen = false
		} else {
			m.view = vDesk
		}
		m.status = ""
		return m, nil
	case ks == " " && (m.view == vDesk || m.view == vWall):
		m.leader = true
		return m, nil
	case ks == K.Waiting && ks != " ":
		m.nextWaiting()
		return m, nil
	case ks == K.Refresh:
		m.refresh()
		return m, loadTTYs
	case ks == K.Wall:
		m.view, m.zoom = vWall, false
		return m, nil
	case ks == "?":
		m.view, m.helpOff = vHelp, 0
		return m, nil
	}
	switch m.view {
	case vFind:
		_, cmd := m.findKey(ks)
		return m, cmd
	case vFiles, vProposals, vPulls, vRecaps, vPaperclip, vRepos:
		if done, cmd := m.listKey(ks); done {
			return m, cmd
		}
	case vDesk, vWall:
		if done, cmd := m.promptKey(ks); done {
			return m, cmd
		}
	}
	switch {
	case m.view == vHelp && m.helpScroll(ks):
	case (m.view == vDesk || m.zoom) && m.scrollChat(ks):
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
	case ks == "enter" && m.view == vDesk && m.selRemote() != nil: // read its reply: the session on claude.ai/code
		r := *m.selRemote()
		return m, func() tea.Msg {
			res := "ok"
			if err := remoteOpen(remoteURL(r.ID)); err != nil {
				res = "error: " + err.Error()
			}
			return sentMsg{"", r.Title, "open on claude.ai/code", res}
		}
	case ks == K.Reply && m.view == vDesk && m.selRemote() != nil:
		m.mode = mTyping
		return m, m.ed.open(m.selRemote().ID, "", m.editorWidth())
	case ks == K.Reply:
		a := m.sel()
		if a == nil {
			return m, nil
		}
		if !a.canSend() {
			m.setErr(a.Name + " isn't in a Terminal tab: look only (g opens it)")
			return m, nil
		}
		m.mode = mTyping
		return m, m.ed.open(a.SID, a.Cwd, m.editorWidth())
	case ks == K.Open:
		if len(m.last(m.sel()).Files) == 0 {
			m.setErr("no files mentioned")
		} else {
			m.mode = mOpen
		}
	case ks == K.Here && (m.view == vDesk || m.view == vWall):
		a := m.sel()
		if a == nil || a.TTY == "" || !a.InTerminal {
			m.setErr("no Terminal window for this agent")
			return m, nil
		}
		sid, tty, name := a.SID, a.TTY, a.Name
		return m, func() tea.Msg { return sentMsg{"", name, "bring here", bringHere(sid, tty)} }
	case ks == K.Goto && m.sel() != nil && m.sel().Bg: // a background session has no window: open one attached to it
		job, name := m.sel().Job, m.sel().Name
		return m, func() tea.Msg { return sentMsg{"", name, "attach in a new window", bgAttachWindow(job)} }
	case ks == K.Goto:
		if a := m.sel(); a != nil && a.TTY != "" {
			tty := a.TTY
			return m, func() tea.Msg {
				res := raiseTab(tty)
				return sentMsg{"", a.Name, "go to window", res}
			}
		}
		m.setErr("no Terminal window for this agent")
	case ks == K.Quick && (m.view == vDesk || m.view == vWall):
		return m, m.quickApprove()
	case ks == K.Dismiss && (m.view == vDesk || m.view == vWall):
		a := m.sel()
		if a == nil || a.Group() != 0 {
			m.setErr("only a waiting agent can be dismissed")
			return m, nil
		}
		sid, tty, bg := a.SID, a.TTY, a.Bg
		txt := "Dismissed " + a.Name + ": it comes back when it has something new"
		dismissAgent(*a, time.Now())
		m.dropAgent(sid)
		m.setStatus(txt)
		if bg || tty == "" { // no Terminal tab, so nothing in the window queue
			return m, nil
		}
		// a Terminal tab leaves the window queue too: a window it brought over goes back to its cell
		return m, func() tea.Msg {
			_ = exec.Command(queueBin(), "dismiss", sid).Run()
			return statusMsg(txt)
		}
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

// readPrompt reads screens for menus: the selected agent's, and every agent Kaching's hooks marked as needing
// input or blocked, or that showed a menu last time. Busy or not: Claude Code calls a session busy while its
// question is open, so the screen is the truth.
// readPrompt reads the screens that can show a menu: the selected agent's, the ones that asked or are blocked,
// the ones that showed a menu, and every other busy one on every second tick (a permission prompt or a question
// comes up mid-turn, while Claude Code still calls the session busy). So an agent with a menu is in INPUT whether
// or not it was ever selected, and one missed read is put right a few seconds later.
func (m *model) readPrompt(delay time.Duration) tea.Cmd {
	var cmds []tea.Cmd
	for _, a := range m.agents {
		if !m.screenWanted(a) {
			continue
		}
		sid, tty, bg, job := a.SID, a.TTY, a.Bg, a.Job
		cmds = append(cmds, func() tea.Msg {
			time.Sleep(delay)
			if bg {
				return promptMsg{sid, parsePrompt(bgScreen(job))}
			}
			return promptMsg{sid, parsePrompt(screenOf(tty))}
		})
	}
	return tea.Batch(cmds...)
}

// applyPrompts marks the agents whose screen shows a menu and sorts them into WAITING.
func (m *model) screenWanted(a Agent) bool {
	_, asked := m.prompts[a.SID]
	if a.Bg { // reading its screen runs claude logs: the selected one now and then, a waiting one at every tick
		return asked || a.State == "input" || a.State == "blocked" || (a.SID == m.selSID && m.ticks%3 == 0)
	}
	busy := a.Busy && m.ticks%2 == 0
	return a.InTerminal && (a.SID == m.selSID || a.State == "input" || a.State == "blocked" || asked || busy)
}

// A busy agent that shows a menu has waited since the menu first showed, not since its turn began.
func (m *model) applyPrompts() {
	for i := range m.agents {
		if a := &m.agents[i]; a.Bg {
			m.bgPrompt(a)
		}
	}
	for i := range m.agents {
		a := &m.agents[i]
		_, a.Asking = m.prompts[a.SID]
		if s, ok := m.asked[a.SID]; ok && a.Asking && a.Busy {
			a.Since = s.first
		}
	}
	sortAgents(m.agents)
}

// sawAsk records that sid's screen shows a menu at now.
func (m *model) sawAsk(sid string, now time.Time) {
	if m.asked == nil {
		m.asked = map[string]askSeen{}
	}
	s, ok := m.asked[sid]
	if !ok || now.Sub(s.last) > askGrace {
		s.first = now
	}
	s.last = now
	m.asked[sid] = s
}

// typingKey: every key while writing goes to the editor; enter sends to the agent (or the Paperclip issue).
func (m model) typingKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	w := m.editorWidth()
	if ks := k.String(); m.ed.scrolls(ks) {
		dir := map[string]string{"up": m.cfg.Keys.Older, "down": m.cfg.Keys.Newer}[ks]
		if dir == "" {
			dir = ks // pgup, pgdown
		}
		m.scrollChat(dir)
		return m, nil
	}
	m.ed.peers = m.peerNames(m.ed.target)
	act, cmd := m.ed.key(k, w)
	switch act {
	case edClose:
		m.ed.close()
		m.mode = mKeys
		if strings.TrimSpace(m.ed.drafts[m.ed.target]) != "" {
			m.setStatus("draft kept: " + m.cfg.Keys.Reply + " opens it again")
		}
		return m, nil
	case edImage:
		if p := pasteImage(); p != "" {
			m.ed.insert(p+" ", w)
			m.setStatus("image saved: " + tildify(p))
		} else {
			m.ed.insert(clipboardText(), w)
		}
		return m, nil
	case edSend:
		text := strings.TrimRight(m.ed.ta.Value(), " \n")
		text = strings.TrimLeft(text, " \n")
		if id, kind, ok := pcHandTarget(m.ed.target); ok { // an empty text hands the issue over with the default task
			cmd, keep := m.pcHandSend(id, kind, text)
			if keep {
				return m, nil
			}
			m.ed.sent()
			m.mode = mKeys
			return m, cmd
		}
		if text == "" {
			return m, nil
		}
		target := m.ed.target
		// a send that can't go out (nobody to write to, a name that is no agent's) keeps the box open and the text
		if group, ok := strings.CutPrefix(target, "all:"); ok {
			send, skipped := m.recipients(group)
			if len(send) == 0 {
				m.setErr("ALL " + group + ": no agent to write to now")
				return m, nil
			}
			m.ed.sent()
			m.mode = mKeys
			m.setStatus(fmt.Sprintf("sending to %d agents…", len(send)))
			return m, broadcast(send, skipped, text)
		}
		if !strings.Contains(target, ":") { // a message to an agent: @Name at its start sends it to that agent
			if cmd, ok := m.routeMention(text); ok {
				if cmd == nil {
					return m, nil
				}
				m.ed.sent()
				m.mode = mKeys
				return m, cmd
			}
		}
		m.ed.sent()
		m.mode = mKeys
		if dir, ok := strings.CutPrefix(target, "nw:"); ok {
			m.setStatus("starting a background agent in " + tildify(dir) + "…")
			o := m.nw
			o.Dir = dir
			return m, func() tea.Msg {
				job, err := bgStart(o, text)
				if err != nil {
					return sentMsg{"", "new agent", "start", "error: " + err.Error()}
				}
				return bgStartedMsg{job, dir}
			}
		}
		if name, ok := strings.CutPrefix(target, "br:"); ok {
			if p := m.branches; p != nil && p.branch() != nil && p.branch().Name == name {
				return m, m.branchStart("", text)
			}
			m.setErr("the branch panel of " + name + " is no longer open")
			return m, nil
		}
		if url, ok := strings.CutPrefix(target, "pr:"); ok {
			if i := m.pulls.index(url); i >= 0 {
				return m, m.prStart(&m.pulls.Items[i], text)
			}
			m.setErr("that pull request is no longer open")
			return m, nil
		}
		if i := m.remote.index(target); i >= 0 { // a message to a remote session: the CLI sends it, no window
			id, title := target, m.remote.Items[i].Title
			m.setStatus("sending to " + title + "…")
			return m, func() tea.Msg {
				if err := remoteSend(id, text); err != nil {
					return remoteSentMsg{id, title, err.Error()}
				}
				return remoteSentMsg{id, title, ""}
			}
		}
		if strings.HasPrefix(target, "pcno:") { // a note on an answer: a decline's reason, an approval's note, a form's text
			return m, m.pcNoteSend(target, text)
		}
		if strings.HasPrefix(target, "pc:") {
			id := strings.TrimPrefix(target, "pc:")
			ref := id
			for _, it := range m.pc.Items {
				if it.ID == id {
					ref = it.Ref
				}
			}
			m.setStatus("posting comment on " + ref + "…")
			return m, func() tea.Msg {
				res := "ok"
				if err := pcComment(id, text); err != nil {
					res = "error: " + err.Error()
				}
				return sentMsg{"", ref, "comment", res}
			}
		}
		if a := m.sel(); a == nil || a.SID != target {
			for _, ag := range m.agents {
				if ag.SID == target {
					m.selSID = ag.SID
				}
			}
		}
		if p, ok := m.prompts[target]; ok && p.TypeOpt > 0 && !strings.Contains(text, "\n") {
			// the agent shows a menu: the reply is its "Type something." answer
			a := m.sel()
			if a != nil && a.Bg {
				sid, name, job, n := a.SID, a.Name, a.Job, p.TypeOpt
				m.pressMenu(a, "right") // a written answer moves on to the next question
				m.setStatus("answering " + name + "…")
				return m, func() tea.Msg {
					return sentMsg{sid, name, "answer", bgSteps(job, bgKey(strconv.Itoa(n)), bgPause(), bgText(text), bgKey("enter"))}
				}
			}
			if a != nil && a.InTerminal {
				sid, name, tty, n := a.SID, a.Name, a.TTY, p.TypeOpt
				m.setStatus("answering " + name + "…")
				return m, func() tea.Msg { return sentMsg{sid, name, "answer", answerTyped(tty, n, text)} }
			}
		}
		return m, m.deliver(text, nil)
	}
	return m, cmd
}

// editorWidth: the reply box's width in the view that shows it.
func (m model) editorWidth() int {
	switch {
	case m.view == vPaperclip || m.view == vPulls:
		_, rw := pcWidths(m.w)
		return rw - 4
	case m.view == vWall:
		return m.w - 4
	case m.view == vRepos:
		lw, _ := pcWidths(m.w)
		return m.w - min(lw, 44) - 2 - 4
	}
	_, rw := deskWidths(m.w)
	return rw - 4
}

// pcSelected: the selected Paperclip row, nil when none.
func (m *model) pcSelected() *PCItem {
	if m.view != vPaperclip || m.listSel >= len(m.pc.Items) {
		return nil
	}
	return &m.pc.Items[m.listSel]
}

// prSelected: the selected pull request in the PR view, nil when none.
func (m *model) prSelected() *PullReq {
	if m.view != vPulls || m.listSel >= len(m.pulls.Items) {
		return nil
	}
	return &m.pulls.Items[m.listSel]
}

// prDetailCmd reads the selected pull request's side panel, while it is open, when it has none or it is older
// than stale.
func (m *model) prDetailCmd(stale time.Duration) tea.Cmd {
	pr := m.prSelected()
	if pr == nil || !m.prOpen {
		return nil
	}
	if d, ok := m.prDet[pr.URL]; ok && time.Since(d.At) < stale {
		return nil
	}
	url := pr.URL
	return func() tea.Msg { return prDetailMsg(loadPRDetail(url)) }
}

// prStart starts a background agent on pr in its repo's local clone (home when there is none), with the
// owner's comment as its task.
func (m *model) prStart(pr *PullReq, comment string) tea.Cmd {
	if pr == nil {
		return nil
	}
	p, d, cfg := *pr, m.prDet[pr.URL], m.cfg
	m.setStatus(fmt.Sprintf("starting an agent on %s#%d…", p.Repo, p.Number))
	return func() tea.Msg {
		dir := prCloneDir(p.Repo)
		cloned := dir != ""
		if !cloned {
			dir = os.Getenv("HOME")
		}
		o := parseNW("", cfg) // the model, effort and mode that keys.toml sets for /NW
		o.Dir = dir
		job, err := bgStart(o, prPrompt(p, d, comment, cloned))
		if err != nil {
			return sentMsg{"", fmt.Sprintf("%s#%d", p.Repo, p.Number), "start", "error: " + err.Error()}
		}
		return bgStartedMsg{job, dir}
	}
}

// prDrop takes a merged or closed pull request off the list at once; GitHub's search can list it a little longer.
func (m *model) prDrop(url string) {
	if i := m.pulls.index(url); i >= 0 {
		m.pulls.Items = append(m.pulls.Items[:i:i], m.pulls.Items[i+1:]...)
		if m.listSel >= len(m.pulls.Items) {
			m.listSel = max(0, len(m.pulls.Items)-1)
		}
	}
}

// prCloseNow closes pr right away with gh pr close, no agent (D56). Unlike a merge it needs no loaded panel and
// has no checks to wait for: a draft, a conflicting or a failing pull request is the usual thing to close.
func (m *model) prCloseNow(pr *PullReq) tea.Cmd {
	if pr == nil {
		return nil
	}
	p := *pr
	ref := fmt.Sprintf("%s#%d", p.Repo, p.Number)
	m.setStatus("closing " + ref + "…")
	return func() tea.Msg {
		if err := prClose(p); err != nil {
			return prClosedMsg{p.URL, ref, err.Error()}
		}
		return prClosedMsg{p.URL, ref, ""}
	}
}

// prMergeNow merges pr right away with gh pr merge, no agent (D55); it refuses, and says why, when its panel shows
// conflicts or checks that failed or still run. A panel that has not loaded is read again.
func (m *model) prMergeNow(pr *PullReq) tea.Cmd {
	if pr == nil {
		return nil
	}
	p, d := *pr, m.prDet[pr.URL]
	ref := fmt.Sprintf("%s#%d", p.Repo, p.Number)
	if why := prMergeBlock(p, d); why != "" {
		m.setErr("not merged: " + ref + ": " + why)
		if d.HeadSHA == "" {
			return m.prDetailCmd(0)
		}
		return nil
	}
	m.setStatus("merging " + ref + "…")
	return func() tea.Msg {
		how, err := prMerge(p, d.HeadSHA)
		if err != nil {
			return prMergedMsg{p.URL, ref, how, err.Error()}
		}
		return prMergedMsg{p.URL, ref, how, ""}
	}
}

// pcDetailCmd reads the selected issue's side panel when it has none or it is older than stale.
func (m *model) pcDetailCmd(stale time.Duration) tea.Cmd {
	it := m.pcSelected()
	if it == nil || it.ID == "" {
		return nil
	}
	if d, ok := m.pcDet[it.ID]; ok && time.Since(d.At) < stale {
		return nil
	}
	id, names := it.ID, m.pc.Names
	return func() tea.Msg { return pcDetailMsg(loadPCDetail(id, names)) }
}

// pcAnswer gives answer n to the selected issue's open request. "decline with a reason" opens the box first.
func (m *model) pcAnswer(n int) tea.Cmd {
	it := m.pcSelected()
	if it == nil {
		return nil
	}
	d, ok := m.pcDet[it.ID]
	if !ok || d.Ask == nil || len(d.Ask.Options) == 0 {
		m.setErr(it.Ref + " asks nothing that kaching can answer: enter opens it in Paperclip")
		return nil
	}
	if n > len(d.Ask.Options) {
		m.setErr(fmt.Sprintf("%s has no answer %d", it.Ref, n))
		return nil
	}
	o := d.Ask.Options[n-1]
	if o.Action == "reason" {
		m.mode = mTyping
		return m.ed.open("pcno:"+it.ID+pcNoteSlot(o, n), "", m.editorWidth())
	}
	id, ref, ask := it.ID, pcRef(*it), d.Ask
	m.setStatus(o.Label + " → " + ref + "…")
	return func() tea.Msg {
		if err := pcAct(id, ask, n, ""); err != nil {
			return pcActedMsg{ref, o.Label, err.Error()}
		}
		return pcActedMsg{ref, o.Label, ""}
	}
}

// pcScrollKey scrolls the PC side panel for the scroll keys; false for any other key.
func (m *model) pcScrollKey(ks string) bool { return m.panelScroll(m.pcScroll, ks) }

// panelScroll scrolls a side panel (PC, PR, RC) for the scroll keys; false for any other key.
func (m *model) panelScroll(c *chatScroll, ks string) bool {
	if c == nil {
		return false
	}
	step := 0
	switch ks {
	case m.cfg.Keys.Older:
		step = 3
	case m.cfg.Keys.Newer:
		step = -3
	case "pgup":
		step = max(1, c.page-1)
	case "pgdown":
		step = -max(1, c.page-1)
	case "home":
		step = c.max
	case "end":
		step = -c.off
	default:
		return false
	}
	c.off = min(max(0, c.off+step), c.max)
	return true
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
	case vPulls:
		n = len(m.pulls.Items)
		if m.prOpen && m.panelScroll(m.prScroll, ks) {
			return true, nil
		}
		if len(ks) == 1 && ks[0] >= '1' && ks[0] <= '9' { // the panel's quick comments; never an agent's answer here
			if i := int(ks[0] - '1'); m.prOpen && i < len(prQuick) {
				switch prQuick[i].act {
				case "merge":
					return true, m.prMergeNow(m.prSelected())
				case "close":
					return true, m.prCloseNow(m.prSelected())
				}
				return true, m.prStart(m.prSelected(), prQuick[i].text)
			}
			if !m.prOpen {
				m.setStatus(K.Reply + " opens the pull request first")
			}
			return true, nil
		}
		if pr := m.prSelected(); pr != nil && ks == K.Reply {
			if !m.prOpen { // k opens the panel, k again the comment box
				m.prOpen = true
				return true, m.prDetailCmd(time.Minute)
			}
			m.mode = mTyping
			return true, m.ed.open("pr:"+pr.URL, "", m.editorWidth())
		}
	case vRecaps:
		n = len(m.recaps())
		if m.panelScroll(m.rcScroll, ks) {
			return true, nil
		}
	case vPaperclip:
		n = len(m.pc.Items)
		if m.pcScrollKey(ks) {
			return true, nil
		}
		if (ks == K.PCAgent || ks == K.PCTerm) && m.pcSelected() != nil { // hand the issue to an agent with your permissions
			if ks == K.PCTerm {
				return true, m.pcHandOpen("t")
			}
			return true, m.pcHandOpen("b")
		}
		if cmd, ok := m.pcAskKey(ks); ok { // a request with a form: ticks, several questions, verdicts (pcform.go)
			return true, cmd
		}
		if len(ks) == 1 && ks[0] >= '1' && ks[0] <= '9' {
			return true, m.pcAnswer(int(ks[0] - '0'))
		}
	case vRepos:
		return m.repoKey(ks)
	}
	switch ks {
	case K.Next, "down":
		if m.listSel < n-1 {
			m.listSel++
		}
		return true, tea.Batch(m.pcDetailCmd(5*time.Second), m.prDetailCmd(time.Minute))
	case K.Prev, "up":
		if m.listSel > 0 {
			m.listSel--
		}
		return true, tea.Batch(m.pcDetailCmd(5*time.Second), m.prDetailCmd(time.Minute))
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
		case vRecaps:
			if rs := m.recaps(); m.listSel < len(rs) {
				m.selSID, m.view = rs[m.listSel].agent.SID, vDesk
				m.writeState()
			}
		case vPaperclip:
			if m.listSel < len(m.pc.Items) {
				openPath("open", m.pc.Items[m.listSel].URL)
			}
		case vPulls:
			if m.listSel < len(m.pulls.Items) {
				pr := m.pulls.Items[m.listSel]
				openPath("open", pr.URL)
				m.setStatus(fmt.Sprintf("opened %s#%d", pr.Repo, pr.Number))
			}
		}
		return true, nil
	}
	if m.view == vProposals && m.listSel < len(m.props) {
		id := propID(m.props[m.listSel])
		switch ks {
		case "a": // approve: hand the screen to kaching-proposals, which asks for its typed code on /dev/tty
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
		m.mode = mTyping
		return true, m.ed.open("pc:"+m.pc.Items[m.listSel].ID, "", m.editorWidth())
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
				return m, m.openRepos()
			case vProposals:
				m.loadProposals()
			case vPulls:
				m.pullsAt = time.Now()
				return m, func() tea.Msg { return pullsMsg(loadPulls()) }
			case vPaperclip:
				m.pcAt = time.Now()
				return m, func() tea.Msg { return pcMsg(loadPaperclip()) }
			}
			return m, nil
		}
	}
	switch {
	case c == "FIND":
		return m.findCommand(code)
	case c == "HELP" || c == "?":
		m.view, m.helpOff = vHelp, 0
	case c == "QUIT" || c == "Q":
		removeState()
		return m, tea.Quit
	case c == "W" || c == "WALL":
		m.view = vWall
	case c == "NW": // a new background agent: the folder, then its first message in the reply box
		_, arg, _ := strings.Cut(strings.TrimSpace(code), " ")
		o := parseNW(arg, m.cfg)
		f, err := m.resolveNW(o.Dir)
		if err != nil {
			m.setErr(err.Error())
			return m, nil
		}
		dir := f.Dir
		o.Dir = dir
		m.nw, m.nwDir = o, f
		m.view, m.zoom, m.mode = vDesk, false, mTyping
		return m, m.ed.open("nw:"+dir, dir, m.editorWidth())
	case c == "ALL":
		_, arg, _ := strings.Cut(strings.TrimSpace(code), " ")
		return m.allCommand(arg)
	case c == "STOP":
		a := m.sel()
		if a == nil || !a.Bg {
			m.setErr("STOP stops a background agent; select one first")
			return m, nil
		}
		job, name := a.Job, a.Name
		return m, func() tea.Msg {
			if res := bgStop(job); res != "ok" {
				return sentMsg{"", name, "stop", res}
			}
			return statusMsg("stopped " + name + " (claude --resume " + job + " opens it again)")
		}
	case len(c) > 1 && c[0] == 'A' && isDigits(c[1:]):
		if n, _ := strconv.Atoi(c[1:]); n >= 1 && n <= len(m.agents) {
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

// kitDir is the Kaching kit: ~/.claude/kaching, or ~/.claude/ching on a machine where install.sh has not run
// since the rename (D35).
func kitDir() string {
	k := filepath.Join(os.Getenv("HOME"), ".claude", "kaching")
	if _, err := os.Stat(k); err != nil {
		if old := filepath.Join(os.Getenv("HOME"), ".claude", "ching"); dirExists(old) {
			return old
		}
	}
	return k
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func isDigits(t string) bool {
	for _, r := range t {
		if r < '0' || r > '9' {
			return false
		}
	}
	return t != ""
}

func proposalsBin() string {
	return filepath.Join(kitDir(), "bin", "kaching-proposals")
}

func propID(line string) string {
	// "skill skill-gitbook-docs-sync: Writes ..." -> skill-gitbook-docs-sync
	f := strings.Fields(line)
	if len(f) >= 2 {
		return strings.TrimSuffix(f[1], ":")
	}
	return ""
}

type agentRecap struct {
	agent Agent
	last  Last
}

// recaps: the agents that have a recap, newest recap first.
func (m *model) recaps() []agentRecap {
	var out []agentRecap
	for i := range m.agents {
		if l := m.last(&m.agents[i]); l.Recap != "" {
			out = append(out, agentRecap{m.agents[i], l})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].last.RecapAt.After(out[j].last.RecapAt) })
	return out
}

// badgeEvery: how often the tab bar reads the proposals and Paperclip, and the PR view its pull requests.
const badgeEvery = 30 * time.Second

// readProposals: the learner's open proposals, one "kind id: ..." line each.
func readProposals() []string {
	out, _ := exec.Command(proposalsBin(), "list").Output()
	var props []string
	for _, l := range strings.Split(string(out), "\n") { // open proposals are the indented "kind id: ..." lines
		if strings.HasPrefix(l, "  ") && !strings.HasPrefix(l, "  (") && strings.Contains(l, ":") {
			props = append(props, strings.TrimSpace(l))
		}
	}
	return props
}

func (m *model) loadProposals() {
	m.props = readProposals()
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
	at          time.Time
}

// allFiles: the FL view's files, newest mention first; files that are gone are left out.
func (m *model) allFiles() []fileRef {
	var out []fileRef
	if m.files == nil {
		return out
	}
	for _, it := range m.files.items {
		if _, err := os.Stat(it.Path); err == nil {
			out = append(out, fileRef{it.Path, it.Agent, it.At})
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
