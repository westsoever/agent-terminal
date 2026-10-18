package main

// The FIND view: the state of a search, the messages its three tiers send back, the keys, and the drawing.
// The search itself is in find.go (names, text) and findai.go (AI).

import (
	"context"
	"fmt"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// vFind is the FIND view. It has no tab: /FIND opens it. (Kept out of the view list in ui.go on purpose.)
const vFind view = 1000

// findState is the search on the screen. The tiers fill it in as their messages arrive; a message of an older
// search (another Seq) is dropped.
type findState struct {
	Query               string
	Terms               []string
	Seq                 int
	ctx                 context.Context // ends when the search is replaced: its tiers and the AI call stop
	cancel              context.CancelFunc
	Names, Text, AI     []findHit
	NamesDone, TextDone bool
	Partial             bool // the text tier ran out of time
	AIState             int  // 0: not asked, 1: asking Claude, 2: answered
	AIErr               string
	Panel               *findPanel // the excerpts of the selected session, over the list
}

// findPanel is the read-only excerpts of an ended session.
type findPanel struct {
	ID      string
	Loading bool
	Err     string
	Head    string
	Groups  [][]excerptTurn
	sc      *findScroll // how far it is scrolled; the drawing sets max and page
}

type findScroll struct{ off, max, page int }

type findNamesMsg struct {
	seq  int
	hits []findHit
}
type findTextMsg struct {
	seq  int
	hits []findHit
	st   textStats
}
type findAIMsg struct {
	seq  int
	hits []findHit
	err  error
}
type findPanelMsg struct {
	seq int
	p   findPanel
}

// findCommand is /FIND <words>: it opens the view and starts the names and text tiers. With no words the view
// only says how to use it.
func (m model) findCommand(code string) (tea.Model, tea.Cmd) {
	_, arg, _ := strings.Cut(strings.TrimSpace(code), " ")
	m.view, m.zoom, m.listSel = vFind, false, 0
	if len(parseQuery(arg)) == 0 {
		if m.find.cancel != nil {
			m.find.cancel()
		}
		m.find = findState{Seq: m.find.Seq + 1}
		return m, nil
	}
	return m, m.startFind(strings.TrimSpace(arg))
}

// startFind begins a search: the names and the text tier at once, each with its own message.
func (m *model) startFind(query string) tea.Cmd {
	if m.find.cancel != nil {
		m.find.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.find = findState{Query: query, Terms: parseQuery(query), Seq: m.find.Seq + 1, ctx: ctx, cancel: cancel}
	seq, terms := m.find.Seq, m.find.Terms
	agents := append([]Agent(nil), m.agents...) // the desk's slice changes under the goroutines otherwise
	sessions := sync.OnceValue(listSessions)
	return tea.Batch(
		func() tea.Msg { return findNamesMsg{seq, searchNames(ctx, terms, agents, sessions())} },
		func() tea.Msg {
			hits, st := searchText(ctx, terms, sessions())
			return findTextMsg{seq, hits, st}
		})
}

// startAI asks Claude about the same query. It does nothing when it is asking already.
func (m *model) startAI() tea.Cmd {
	f := &m.find
	if f.Query == "" {
		m.setErr("write /FIND and some words first")
		return nil
	}
	if f.AIState == 1 {
		return nil
	}
	f.AIState, f.AIErr = 1, ""
	ctx, seq, query := f.ctx, f.Seq, f.Query
	if ctx == nil {
		ctx = context.Background()
	}
	agents := append([]Agent(nil), m.agents...)
	return func() tea.Msg {
		hits, err := searchAI(ctx, query, agents, listSessions())
		return findAIMsg{seq, hits, err}
	}
}

// findUpdate takes the messages of a search.
func (m model) findUpdate(msg tea.Msg) (tea.Model, tea.Cmd) {
	f := &m.find
	switch msg := msg.(type) {
	case findNamesMsg:
		if msg.seq != f.Seq {
			return m, nil
		}
		f.Names, f.NamesDone = msg.hits, true
	case findTextMsg:
		if msg.seq != f.Seq {
			return m, nil
		}
		f.Text, f.TextDone, f.Partial = msg.hits, true, msg.st.Partial
	case findAIMsg:
		if msg.seq != f.Seq {
			return m, nil
		}
		f.AIState = 2
		if msg.err != nil {
			f.AIErr = msg.err.Error()
			m.setErr("asking Claude failed: " + f.AIErr)
		} else {
			f.AI = msg.hits
			m.listSel = 0 // the answer of Claude is on top
			if len(msg.hits) == 0 {
				m.setStatus("Claude found no session for these words")
			}
		}
	case findPanelMsg:
		if msg.seq == f.Seq && f.Panel != nil && f.Panel.ID == msg.p.ID {
			msg.p.sc = f.Panel.sc
			f.Panel = &msg.p
		}
		return m, nil
	}
	m.listSel = min(m.listSel, max(0, len(f.merged())-1))
	if f.NamesDone && f.TextDone && f.AIState == 0 && len(f.Names)+len(f.Text) == 0 { // nothing: the next tier
		m.setStatus("nothing in the names or the text: asking Claude…")
		return m, m.startAI()
	}
	return m, nil
}

// merged is every hit once: a session found by more than one tier has the tiers' parts together. The answer of
// Claude comes first, then the sessions with the words in their name, then those with them in their text;
// the newest first in each.
func (f findState) merged() []findHit {
	at := map[string]int{}
	var out []findHit
	for _, tier := range [][]findHit{f.Names, f.Text, f.AI} {
		for _, h := range tier {
			i, ok := at[h.ID]
			if !ok {
				at[h.ID] = len(out)
				out = append(out, h)
				continue
			}
			x := &out[i]
			x.Tier |= h.Tier
			if h.Snippet != "" {
				x.Who, x.Snippet, x.Count, x.At = h.Who, h.Snippet, h.Count, h.At
			}
			if h.Why != "" {
				x.Why = h.Why
			}
			for _, p := range []struct{ to, from *string }{{&x.Name, &h.Name}, {&x.Cwd, &h.Cwd}, {&x.Path, &h.Path}, {&x.Branch, &h.Branch}} {
				if *p.to == "" {
					*p.to = *p.from
				}
			}
		}
	}
	rank := func(h findHit) int {
		switch {
		case h.Tier&tierAI != 0:
			return 0
		case h.Tier&tierName != 0:
			return 1
		}
		return 2
	}
	sort.SliceStable(out, func(i, j int) bool {
		if ri, rj := rank(out[i]), rank(out[j]); ri != rj {
			return ri < rj
		}
		return out[i].At.After(out[j].At)
	})
	return out
}

// status is the header's progress words.
func (f findState) status() string {
	var p []string
	switch {
	case f.Query == "":
		return ""
	case !f.NamesDone && !f.TextDone:
		p = append(p, "searching…")
	default:
		names, text := fmt.Sprintf("%d in names", len(f.Names)), fmt.Sprintf("%d in text", len(f.Text))
		if !f.NamesDone {
			names = "searching names…"
		}
		if !f.TextDone {
			text = "searching text…"
		} else if f.Partial {
			text += " (partial: the time ran out)"
		}
		p = append(p, names+", "+text)
	}
	switch {
	case f.AIState == 1:
		p = append(p, "asking Claude…")
	case f.AIErr != "":
		p = append(p, "Claude failed")
	case f.AIState == 2:
		p = append(p, fmt.Sprintf("%d from AI", len(f.AI)))
	}
	return strings.Join(p, ", ")
}

// label is the name the desk shows for a live agent, else the name in the transcript, else the short id.
func (m *model) label(h findHit) string {
	if a := m.liveAgent(h.ID); a != nil && a.Name != "" {
		return a.Name
	}
	return h.label()
}

// liveAgent: the desk's agent with this session id, nil when the session has ended.
func (m *model) liveAgent(id string) *Agent {
	for i := range m.agents {
		if m.agents[i].SID == id {
			return &m.agents[i]
		}
	}
	return nil
}

// selectedHit: the hit under the cursor.
func (m *model) selectedHit() (findHit, bool) {
	hits := m.find.merged()
	if m.listSel < 0 || m.listSel >= len(hits) {
		return findHit{}, false
	}
	return hits[m.listSel], true
}

// findKey handles the keys of the FIND view. Every key is taken: none falls through to the desk (a digit
// would answer the selected agent).
func (m *model) findKey(ks string) (bool, tea.Cmd) {
	K := m.cfg.Keys
	if p := m.find.Panel; p != nil {
		sc := p.sc
		switch ks {
		case K.Next, "down":
			sc.off = min(sc.off+1, sc.max)
		case K.Prev, "up":
			sc.off = max(sc.off-1, 0)
		case "pgdown":
			sc.off = min(sc.off+max(1, sc.page-1), sc.max)
		case "pgup":
			sc.off = max(sc.off-max(1, sc.page-1), 0)
		case "home":
			sc.off = 0
		case "end":
			sc.off = sc.max
		case "r":
			return true, m.findResume()
		}
		return true, nil
	}
	switch ks {
	case K.Next, "down":
		m.listSel = min(m.listSel+1, max(0, len(m.find.merged())-1))
	case K.Prev, "up":
		m.listSel = max(m.listSel-1, 0)
	case "enter":
		h, ok := m.selectedHit()
		if !ok {
			return true, nil
		}
		if a := m.liveAgent(h.ID); a != nil {
			m.selSID, m.view = a.SID, vDesk
			m.writeState()
			return true, nil
		}
		if h.Path == "" {
			m.setErr(m.label(h) + " has no transcript to read")
			return true, nil
		}
		m.find.Panel = &findPanel{ID: h.ID, Loading: true, sc: &findScroll{}}
		return true, findPanelCmd(m.find.Seq, h, m.find.Terms)
	case "s":
		return true, m.startAI()
	case "r":
		return true, m.findResume()
	}
	return true, nil
}

// findPanelCmd reads the excerpts of an ended session in the background.
func findPanelCmd(seq int, h findHit, terms []string) tea.Cmd {
	return func() tea.Msg {
		p := findPanel{ID: h.ID}
		groups, all, err := loadExcerpts(h.Path, terms)
		switch {
		case err != nil:
			p.Err = "cannot read the transcript: " + err.Error()
		case all > 0:
			p.Groups = groups
			p.Head = fmt.Sprintf("%d messages have all the words. The newest %d are here, each with the message before and after.", all, min(all, excerptMax))
			if all == 1 {
				p.Head = "1 message has all the words. It is here, with the message before and after."
			}
		default: // an AI or name hit: no one message has the words; show how it began and how it ended
			head, _ := readHead(h.Path)
			if first := firstPrompt(head); first != "" {
				p.Groups = append(p.Groups, []excerptTurn{{User: true, Text: first}})
			}
			if last := lastAgentText(readEnd(h.Path, aiTail, nil)); last != "" {
				p.Groups = append(p.Groups, []excerptTurn{{Text: last}})
			}
			p.Head = "No one message has all the words. This is how the session began and how it ended."
			if h.Why != "" {
				p.Head = "Claude: " + h.Why
			}
		}
		return findPanelMsg{seq, p}
	}
}

// findResume opens a new Terminal window that resumes the selected ended session (the explicit r key).
func (m *model) findResume() tea.Cmd {
	h, ok := m.selectedHit()
	if !ok {
		return nil
	}
	if m.liveAgent(h.ID) != nil {
		m.setErr(m.label(h) + " is live: enter selects it")
		return nil
	}
	if !dirExists(h.Cwd) {
		m.setErr("cannot resume " + m.label(h) + ": its folder " + tildify(h.Cwd) + " is gone")
		return nil
	}
	cwd, id, name := h.Cwd, h.ID, m.label(h)
	m.setStatus("opening " + name + " in a new window…")
	return func() tea.Msg { return sentMsg{"", name, "resume in a new window", resumeWindow(cwd, id)} }
}

// osascriptRun runs AppleScript; a variable so a test can see the script.
var osascriptRun = func(script string) ([]byte, error) { return exec.Command("osascript", "-e", script).CombinedOutput() }

// resumeWindow opens a new Terminal window running `cd <cwd> && claude --resume <id>`. "ok" or "error: ...".
func resumeWindow(cwd, id string) string {
	if out, err := osascriptRun(resumeScript(claudeBin(), cwd, id)); err != nil {
		return "error: " + firstLine(strings.TrimSpace(string(out)))
	}
	return "ok"
}

// resumeScript is the AppleScript for resumeWindow: the shell command has every word in single quotes, and the
// AppleScript string around it has its backslashes and double quotes escaped.
func resumeScript(bin, cwd, id string) string {
	cmd := "cd " + shQuote(cwd) + " && " + shQuote(bin) + " --resume " + shQuote(id)
	return "tell application \"Terminal\"\n\tactivate\n\tdo script " + asString(cmd) + "\nend tell"
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func asString(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

// findRenderSync runs the names and text tiers to the end, for kaching --render.
func (m model) findRenderSync() model {
	if m.find.Query == "" {
		return m
	}
	sessions := listSessions()
	m.find.Names = searchNames(context.Background(), m.find.Terms, m.agents, sessions)
	var st textStats
	m.find.Text, st = searchText(context.Background(), m.find.Terms, sessions)
	m.find.NamesDone, m.find.TextDone, m.find.Partial = true, true, st.Partial
	return m
}

// ---- drawing

// hlSegs cuts the text into runs: the words of the query in hl, the rest in base.
func hlSegs(text string, terms []string, base, hl lipgloss.Style) []seg {
	r, low := []rune(text), []rune(fold(text))
	mark := make([]bool, len(r))
	for _, t := range terms {
		tr := []rune(t)
		for i := indexRunes(low, tr, 0); i >= 0; i = indexRunes(low, tr, i+len(tr)) {
			for k := i; k < i+len(tr); k++ {
				mark[k] = true
			}
		}
	}
	var out []seg
	for i := 0; i < len(r); {
		j := i
		for j < len(r) && mark[j] == mark[i] {
			j++
		}
		st := base
		if mark[i] {
			st = hl
		}
		out = append(out, s(string(r[i:j]), st))
		i = j
	}
	return out
}

// fmtDate is the date of a message: "Oct 12 14:03", with the year for another year.
func fmtDate(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	t = t.Local()
	if t.Year() == time.Now().Year() {
		return t.Format("Jan 2 15:04")
	}
	return t.Format("2006-01-02")
}

func tagOf(h findHit) string {
	var p []string
	for _, t := range []struct {
		bit  uint8
		name string
	}{{tierAI, "AI"}, {tierName, "name"}, {tierText, "text"}} {
		if h.Tier&t.bit != 0 {
			p = append(p, t.name)
		}
	}
	tag := strings.Join(p, "+")
	if h.Tier == tierText && h.Count > 1 {
		tag += fmt.Sprintf(" ×%d", h.Count)
	}
	return tag
}

func (m model) findView(h int) []string {
	f := m.find
	title := []seg{s("FIND", cWhite)}
	if f.Query != "" {
		title = append(title, s(" \""+f.Query+"\"", cWhite), s("   "+f.status(), cGrey))
	}
	if f.Panel != nil {
		return m.findPanelView(h, title)
	}
	in := m.w - 6
	hits := f.merged()
	var lines []string // the rows, two for a hit that has something to show under its line
	selTop, selEnd := 0, 0
	nameW, cwdW := m.findCols(hits, in)
	if len(hits) == 0 {
		for _, l := range wrap(m.findEmpty(), in) {
			lines = append(lines, " "+row(in, s(l, cDark))+" ")
		}
	}
	for i, hit := range hits {
		if i == m.listSel {
			selTop = len(lines)
		}
		lines = append(lines, m.findHitRows(hit, in, i == m.listSel, nameW, cwdW)...)
		if i == m.listSel {
			selEnd = len(lines)
		}
	}
	first := max(0, selEnd-(h-2)) // the selected hit stays in view
	if selTop < first {
		first = selTop
	}
	if first < len(lines) {
		lines = lines[first:]
	}
	return indent(box(m.w-2, h, title, cDark, lines))
}

// findEmpty: what the view says when it has no hits.
func (m model) findEmpty() string {
	f := m.find
	switch {
	case f.Query == "":
		return "FIND looks for a session by its name, then by what was said in it, then asks Claude. Write " +
			m.cfg.Keys.Command + "FIND and some words, for example " + m.cfg.Keys.Command + "FIND kaching resume. A session is a hit when one message has all the words."
	case !f.NamesDone || !f.TextDone:
		return "searching the names and every transcript…"
	case f.AIState == 1:
		return "nothing in the names or the text. Asking Claude…"
	case f.AIErr != "":
		return "nothing in the names or the text, and Claude failed: " + f.AIErr + ". s asks again."
	case f.AIState == 2:
		return "nothing found, and Claude finds no session for these words."
	}
	return "nothing in the names or the text. s asks Claude."
}

const findTagW, findDateW = 10, 12

// findCols: the widths of the name and folder columns, the same for every row: as wide as the longest, within
// what the screen leaves (a wide screen keeps the columns together; the snippet under a row uses the width).
func (m model) findCols(hits []findHit, in int) (nameW, cwdW int) {
	rest := in - 3 - 2 - findTagW - 1 - findDateW - 1
	for _, h := range hits {
		nameW, cwdW = max(nameW, width(m.label(h))), max(cwdW, width(tildify(h.Cwd)))
	}
	nameW = min(nameW, max(16, rest*45/100), 32)
	cwdW = min(cwdW, max(0, rest-nameW-1), 40)
	if cwdW < 8 { // no room for the folder: the name gets it
		nameW, cwdW = max(0, min(rest, 40)), 0
	}
	return
}

// findHitRows: the rows of one hit. The first has the tag, the name, the folder and the date; under it the
// message that matched (with the words lit) or the reason Claude gave.
func (m model) findHitRows(hit findHit, in int, selected bool, nameW, cwdW int) []string {
	mark := "  "
	if m.liveAgent(hit.ID) != nil {
		mark = "● "
	}
	cwd := ""
	if cwdW > 0 {
		cwd = " " + padTo(tildify(hit.Cwd), cwdW)
	}
	label := m.label(hit)
	tag, name, date := padTo(tagOf(hit), findTagW), padTo(label, nameW), padTo(fmtDate(hit.At), findDateW)
	var r1 string
	if selected {
		r1 = " " + row(in, s(padTo(" > "+mark+tag+" "+name+cwd+" "+date, in), cSel)) + " "
	} else {
		tagSt := cGrey
		if hit.Tier&tierAI != 0 {
			tagSt = cOrange
		}
		markSt := cOrange
		r1 = " " + row(in, s("   ", cPlain), s(mark, markSt), s(tag+" ", tagSt), s(name, cWhite), s(cwd, cDark), s(" "+date, cDark)) + " "
	}
	rows := []string{r1}
	if hit.Why != "" {
		rows = append(rows, " "+row(in, s("     ", cPlain), s(padTo("Claude", 7), cOrange), s(hit.Why, cText))+" ")
	}
	if hit.Snippet != "" {
		who := padTo(hit.Who, 7)
		segs := append([]seg{s("     ", cPlain), s(who, cDark)}, hlSegs(hit.Snippet, m.find.Terms, cGrey, cWhite)...)
		rows = append(rows, " "+row(in, segs...)+" ")
	}
	return rows
}

// findPanelView: the excerpts of the selected session, a read-only page the scroll keys move through.
func (m model) findPanelView(h int, title []seg) []string {
	p := m.find.Panel
	in := m.w - 6
	hit, _ := m.selectedHit()
	t := []seg{s(m.label(hit), cWhite), s(" · "+tildify(hit.Cwd), cGrey), s(" · "+fmtDate(hit.At), cGrey)}
	var rows []string
	switch {
	case p.Loading:
		rows = append(rows, row(in, s("reading the transcript…", cDark)))
	case p.Err != "":
		rows = append(rows, row(in, s(p.Err, cOrange)))
	default:
		for _, l := range wrap(p.Head, in) {
			rows = append(rows, row(in, s(l, cDark)))
		}
		for _, g := range p.Groups {
			rows = append(rows, "")
			hd := "─ " + fmtDate(g[0].At) + " "
			rows = append(rows, row(in, s(hd, cDark), s(strings.Repeat("─", max(0, in-width(hd))), cDark)))
			for k, tn := range g {
				if k > 0 {
					rows = append(rows, row(in))
				}
				rows = append(rows, m.excerptRows(tn, in)...)
			}
		}
	}
	avail := max(1, h-2)
	most := max(0, len(rows)-avail)
	sc := p.sc
	if sc == nil {
		sc = &findScroll{}
	}
	sc.max, sc.page = most, avail
	sc.off = min(sc.off, most)
	end := min(len(rows), sc.off+avail)
	view := append([]string(nil), rows[sc.off:end]...)
	if sc.off > 0 && len(view) > 1 {
		view[0] = row(in, s(fmt.Sprintf("↑ %d earlier lines", sc.off), cDark))
	}
	if end < len(rows) && len(view) > 1 {
		view[len(view)-1] = row(in, s(fmt.Sprintf("↓ %d more lines", len(rows)-end), cOrange))
	}
	body := make([]string, len(view))
	for i, l := range view {
		body[i] = " " + l + " "
	}
	return indent(box(m.w-2, h, t, cDark, body))
}

// excerptRows: one message as rows. Your prompts have the band and the "› " of the desk; the words of the query are lit.
func (m model) excerptRows(tn excerptTurn, in int) []string {
	n := 280
	if tn.Match {
		n = 700
	}
	text := strings.TrimSpace(clean(tn.Text)) // a short message keeps its lines; a long one is cut to a window of the match
	if utf8.RuneCountInString(text) > n {
		text = makeSnippet(text, m.find.Terms, n)
	}
	var out []string
	if tn.User {
		band := cWhite.Background(promptBg)
		for j, l := range wrap(plain(text), in-2) {
			lead := "  "
			if j == 0 {
				lead = "› "
			}
			segs := append([]seg{s(lead, cOrange.Background(promptBg))}, hlSegs(l, m.find.Terms, band, cOrange.Background(promptBg).Bold(true))...)
			segs = append(segs, s(strings.Repeat(" ", max(0, in-segsWidth(segs))), band))
			out = append(out, row(in, segs...))
		}
		return out
	}
	for _, l := range wrap(plain(text), in) {
		out = append(out, row(in, hlSegs(l, m.find.Terms, cText, cWhite)...))
	}
	return out
}

// findHints: the keys the footer shows for the view.
func (m model) findHints() [][2]string {
	K := m.cfg.Keys
	if m.find.Panel != nil {
		return [][2]string{{K.Next + " " + K.Prev, "scroll"}, {"r", "resume"}, {"esc", "back"}, {K.Command, "command"}}
	}
	return [][2]string{{K.Next + " " + K.Prev, "move"}, {"enter", "open"}, {"s", "AI"}, {"r", "resume"}, {"esc", "desk"}, {K.Command, "command"}}
}
