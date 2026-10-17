package main

import (
	"fmt"
	"strings"
	"time"
)

const (
	headerH = 5 // tab bar (3) + command line + blank
	footerH = 3 // rule + two key rows
)

func (m model) View() string {
	if m.w < 60 || m.h < 16 {
		return cGrey.Render(fmt.Sprintf("kaching needs at least 60x16 (now %dx%d)", m.w, m.h))
	}
	var lines []string
	lines = append(lines, m.tabBar()...)
	lines = append(lines, m.commandLine(), "")
	bodyH := m.h - headerH - footerH
	var body []string
	switch m.view {
	case vDesk:
		body = m.desk(bodyH)
	case vWall:
		if m.zoom {
			body = m.agentPanel(m.w, bodyH)
		} else {
			body = m.wall(bodyH)
		}
	case vFiles:
		body = m.filesView(bodyH)
	case vRepos:
		body = m.textView("repos", m.sync, bodyH)
	case vProposals:
		body = m.proposalsView(bodyH)
	case vPaperclip:
		body = m.paperclipView(bodyH)
	case vHelp:
		body = m.helpView(bodyH)
	}
	for len(body) < bodyH {
		body = append(body, "")
	}
	lines = append(lines, body[:bodyH]...)
	lines = append(lines, m.footer()...)
	return strings.Join(lines, "\n")
}

func (m model) counts() (live, need int) {
	for _, a := range m.agents {
		live++
		if a.Group() == 0 {
			need++
		}
	}
	return
}

func (m model) tabBar() []string {
	_, need := m.counts()
	type cell struct {
		segs []seg
	}
	nums := map[view]string{vDesk: fmt.Sprint(need), vWall: fmt.Sprint(len(m.agents))}
	var cells []cell
	cells = append(cells, cell{[]seg{s("kaching", cWhite)}})
	for _, t := range tabs {
		active := m.view == t.v || (t.v == vWall && m.view == vWall)
		lbl := cGrey
		if active {
			lbl = cWhite
		}
		segs := []seg{s(t.code, cOrange), s(" "+t.label, lbl)}
		if n := nums[t.v]; n != "" && n != "0" {
			segs = append(segs, s("  "+n, lbl))
		}
		cells = append(cells, cell{segs})
	}
	n := len(cells)
	inner := m.w - (n + 1) // borders
	base, extra := inner/n, inner%n
	top, mid, bot := "┌", "│", "└"
	var midSegs []seg
	midSegs = append(midSegs, s("│", cDark))
	for i, c := range cells {
		cw := base
		if i < extra {
			cw++
		}
		bar := strings.Repeat("─", cw)
		if i < n-1 {
			top += bar + "┬"
			bot += bar + "┴"
		} else {
			top += bar + "┐"
			bot += bar + "┘"
		}
		tw := segsWidth(c.segs)
		if tw > cw-2 { // too narrow: code only
			c.segs = c.segs[:1]
			tw = segsWidth(c.segs)
		}
		l := (cw - tw) / 2
		if l < 0 {
			l = 0
		}
		midSegs = append(midSegs, s(strings.Repeat(" ", l), cPlain))
		midSegs = append(midSegs, c.segs...)
		midSegs = append(midSegs, s(strings.Repeat(" ", max(0, cw-tw-l)), cPlain), s("│", cDark))
	}
	_ = mid
	return []string{cDark.Render(top), row(m.w, midSegs...), cDark.Render(bot)}
}

func (m model) commandLine() string {
	live, need := m.counts()
	right := []seg{s(time.Now().Format("15:04"), cGrey), s(fmt.Sprintf("   %d live   ", live), cGrey)}
	if need > 0 {
		right = append(right, s(fmt.Sprintf("%d need you ", need), cOrange))
	} else {
		right = append(right, s("all busy ", cGrey))
	}
	var left []seg
	switch m.mode {
	case mCommand:
		left = []seg{s(" > ", cOrange), s(m.buf, cWhite), s("█", cOrange), s("  <GO>", cGrey)}
	case mTyping:
		target := ""
		if a := m.sel(); a != nil {
			target = a.Name
		}
		if m.view == vPaperclip && m.listSel < len(m.pc.Items) {
			target = m.pc.Items[m.listSel].Ref
		}
		left = []seg{s(" writing to ", cGrey), s(target, cWhite)}
	case mOpen:
		left = []seg{s(" open file: press its letter", cOrange)}
	default:
		code := tabs[0].code
		for _, t := range tabs {
			if t.v == m.view {
				code = t.code
			}
		}
		left = []seg{s(" > ", cOrange), s(code, cWhite), s(" <GO>", cGrey)}
		if m.leader {
			left = append(left, s("   space…", cOrange))
		}
		if m.status != "" {
			st := cGrey
			if m.statusErr {
				st = cOrange
			}
			left = append(left, s("   "+m.status, st))
		}
	}
	rw := segsWidth(right)
	return row(m.w-rw, left...) + row(rw, right...)
}

// ---- desk

// deskWidths: the agent list's and the agent panel's outer widths for a screen w wide.
func deskWidths(w int) (lw, rw int) {
	lw = w * 32 / 100
	if lw < 30 {
		lw = 30
	}
	if lw > 46 {
		lw = 46
	}
	return lw, w - lw - 2
}

func (m model) desk(h int) []string {
	lw, rw := deskWidths(m.w)
	left := m.queuePanel(lw, h)
	right := m.agentPanel(rw, h)
	out := make([]string, h)
	for i := 0; i < h; i++ {
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

func (m model) queuePanel(w, h int) []string {
	in := w - 2
	var body []string
	groups := []string{"WAITING", "WORKING", "IDLE"}
	si := 0
	for g, name := range groups {
		first := true
		for i, a := range m.agents {
			if FamilyGroup(m.agents, i) != g {
				continue
			}
			if first {
				if len(body) > 0 {
					body = append(body, "")
				}
				body = append(body, row(in, s(" "+name, cDark)))
				first = false
			}
			if a.SID == m.selSID {
				si = len(body)
			}
			body = append(body, m.queueRow(in, i, a))
		}
	}
	if len(m.agents) == 0 {
		body = append(body, row(in, s(" no live agents", cDark)))
	}
	if vis := h - 2; len(body) > vis && si >= vis { // keep the selected row visible
		body = body[si-vis+1:]
	}
	return box(w, h, []seg{s("AGENTS", cGrey)}, cDark, body)
}

func (m model) queueRow(in, i int, a Agent) string {
	selected := a.SID == m.selSID
	stateW, ageW := 8, 4
	nameW := in - 3 - stateW - ageW - 3
	name := a.Name
	if width(name) > nameW {
		name = trunc(name, nameW)
	}
	label := a.Label()
	st, ns := cGrey, cGrey
	switch {
	case a.Group() == 0:
		st = cOrange
		ns = cWhite
	case a.Group() == 2:
		st, ns = cDark, cDark
	}
	if !a.InTerminal {
		ns = cDark
	}
	mark := "   "
	if a.Lead != "" { // a sub-session: indented under its lead
		mark = "   └ "
		nameW -= 2
		if width(name) > nameW {
			name = trunc(name, nameW)
		}
	} else if a.Subs > 0 {
		name = trunc(name, nameW-4) + fmt.Sprintf(" +%d", a.Subs)
	}
	if selected {
		lead := " > "
		if a.Lead != "" {
			lead = " > └ "
		}
		txt := fmt.Sprintf("%s%-*s %-*s %*s ", lead, nameW, name, stateW, label, ageW, age(a.Since))
		return row(in, s(padTo(txt, in), cSel))
	}
	_ = i
	return row(in, s(mark, cPlain), s(padTo(name, nameW), ns), s(" "+padTo(label, stateW), st), s(" "+fmt.Sprintf("%*s", ageW, age(a.Since)), cDark))
}

func padTo(t string, w int) string {
	if width(t) > w {
		return trunc(t, w)
	}
	return t + strings.Repeat(" ", w-width(t))
}

func trunc(t string, w int) string {
	if width(t) <= w {
		return t
	}
	r := []rune(t)
	for width(string(r))+1 > w && len(r) > 0 {
		r = r[:len(r)-1]
	}
	return string(r) + "…"
}

// agentPanel is the selected agent: its last message, its options, the files it named, the reply line.
func (m model) agentPanel(w, h int) []string {
	a := m.sel()
	in := w - 4 // 2 borders + 1 space margin each side
	if a == nil {
		return box(w, h, []seg{s("no agent", cGrey)}, cDark, nil)
	}
	l := m.last(a)
	title := []seg{s(a.Name, cWhite), s(" · "+tildify(a.Cwd), cGrey)}
	if a.Branch != "" {
		title = append(title, s(" · "+a.Branch, cGrey))
	}
	var tail []string // options, files, reply: pinned to the bottom
	if p, ok := m.prompts[a.SID]; ok && len(p.Options) > 0 {
		tail = append(tail, "", row(in, s("THE AGENT ASKS", cDark)))
		for _, pl := range p.Lines {
			if mm := optRe.FindStringSubmatch(pl); mm != nil {
				mark := "  "
				if mm[1] != "" {
					mark = "❯ "
				}
				tail = append(tail, row(in, s(mark, cOrange), s(mm[2], cOrange), s(" "+mm[3], cWhite)))
				continue
			}
			st := cGrey
			if strings.ContainsAny(pl, "☐☒✔←→") || strings.HasSuffix(strings.TrimSpace(pl), "?") {
				st = cWhite
			}
			tail = append(tail, row(in, s(pl, st)))
		}
		hint := "1-9 pick · ←/→ other question · enter confirms"
		if p.TypeOpt > 0 {
			hint += " · " + m.cfg.Keys.Reply + " writes your own answer"
		}
		tail = append(tail, row(in, s(hint, cDark)))
	} else if len(l.Options) > 0 {
		tail = append(tail, "")
		if l.Question != "" {
			for _, ql := range wrap(l.Question, in) {
				tail = append(tail, row(in, s(ql, cWhite)))
			}
		}
		// options on one line when they fit, else one per line
		var one []seg
		for i, o := range l.Options {
			one = append(one, s(fmt.Sprint(i+1), cOrange), s(" "+o+"   ", cWhite))
		}
		if segsWidth(one) <= in {
			tail = append(tail, row(in, one...))
		} else {
			for i, o := range l.Options {
				tail = append(tail, row(in, s(fmt.Sprint(i+1), cOrange), s(" "+o, cWhite)))
			}
		}
	}
	if len(l.Files) > 0 {
		tail = append(tail, "", row(in, s("FILES IT MENTIONED", cDark)))
		for i, f := range l.Files {
			tail = append(tail, row(in, s(string(rune('a'+i)), cOrange), s("  "+tildify(f), cGrey)))
		}
	}
	tail = append(tail, "", row(in, s("─ reply ", cDark), s(strings.Repeat("─", max(0, in-8)), cDark)))
	switch {
	case !a.InTerminal:
		tail = append(tail, row(in, s("not a Terminal tab: look only", cDark)))
	case m.mode == mTyping && m.ed.target == a.SID:
		tail = append(tail, m.ed.lines(in)...)
	default:
		tail = append(tail, row(in, s("> ", cOrange), s(m.cfg.Keys.Reply+" to write", cDark)))
	}
	avail := h - 2 - len(tail)
	var msg []string
	text := plain(l.Text)
	if text == "" {
		text = "(no message yet)"
	}
	for _, ml := range collapse(wrap(text, in)) {
		msg = append(msg, ml)
	}
	if avail < 1 {
		avail = 1
	}
	if len(msg) > avail { // the end of the message is where the question is
		msg = msg[len(msg)-avail:]
		msg[0] = "…"
	}
	var body []string
	for _, ml := range msg {
		body = append(body, " "+row(in, s(ml, cGrey))+" ")
	}
	for len(body) < avail {
		body = append(body, "")
	}
	for _, t := range tail {
		body = append(body, " "+t+" ")
	}
	border := cDark
	if a.Group() == 0 {
		border = cOrange
	}
	return box(w, h, title, border, body)
}

// ---- wall

func (m model) wall(h int) []string {
	n := len(m.agents)
	if n == 0 {
		return []string{row(m.w, s(" no live agents", cDark))}
	}
	gap := 2
	cols := (m.w + gap) / (42 + gap)
	if cols < 1 {
		cols = 1
	}
	if cols > n {
		cols = n
	}
	tw := (m.w - 2 - gap*(cols-1)) / cols
	rows := (n + cols - 1) / cols
	th := (h - (rows - 1)) / rows
	if th < 7 {
		th = 7
	}
	fit := (h + 1) / (th + 1) // rows that fit
	first := 0                // scroll so the selected tile's row is shown
	if si := m.selIndex(); si >= 0 && si/cols >= fit {
		first = si/cols - fit + 1
	}
	var out []string
	for r := first; r < rows && r < first+fit; r++ {
		var tiles [][]string
		for c := 0; c < cols; c++ {
			i := r*cols + c
			if i >= n {
				tiles = append(tiles, nil)
				continue
			}
			tiles = append(tiles, m.tile(i, tw, th))
		}
		for k := 0; k < th; k++ {
			line := " "
			for c, t := range tiles {
				if c > 0 {
					line += strings.Repeat(" ", gap)
				}
				if t == nil {
					line += strings.Repeat(" ", tw)
				} else {
					line += t[k]
				}
			}
			out = append(out, line)
		}
		out = append(out, "")
	}
	return out
}

func (m model) tile(i, w, h int) []string {
	a := m.agents[i]
	l := m.last(&a)
	in := w - 4
	st := cGrey
	switch a.Group() {
	case 0:
		st = cOrange
	case 2:
		st = cDark
	}
	border := cDark
	if a.SID == m.selSID {
		border = cOrange
	}
	title := []seg{s(fmt.Sprint(i+1), cOrange), s(" "+a.Name, cWhite), s("  "+a.Label(), st)}
	var body []string
	text := plain(l.Text)
	if text == "" {
		text = "(no message yet)"
	}
	lines := collapse(wrap(text, in))
	avail := h - 3
	if len(l.Options) > 0 {
		avail--
	}
	if len(lines) > avail {
		lines = lines[len(lines)-avail:]
	}
	for _, t := range lines {
		body = append(body, " "+row(in, s(t, cGrey))+" ")
	}
	for len(body) < avail {
		body = append(body, "")
	}
	if len(l.Options) > 0 {
		var o []seg
		for k, op := range l.Options {
			o = append(o, s(fmt.Sprint(k+1), cOrange), s(" "+trunc(op, 14)+"  ", cWhite))
		}
		body = append(body, " "+row(in, o...)+" ")
	}
	body = append(body, " "+row(in, s("> ", border))+" ")
	return box(w, h, title, border, body)
}

// ---- list views

func (m model) listBox(title string, items [][]seg, h int, empty string, details ...string) []string {
	in := m.w - 6
	var body []string
	if len(items) == 0 {
		body = append(body, " "+row(in, s(empty, cDark))+" ")
	}
	first := 0
	if m.listSel >= h-2 {
		first = m.listSel - (h - 3)
	}
	for i := first; i < len(items); i++ {
		if i == m.listSel {
			t := ""
			for _, sg := range items[i] {
				t += sg.t
			}
			body = append(body, " "+row(in, s(padTo(" > "+t, in), cSel))+" ")
			if i < len(details) && details[i] != "" {
				for _, dl := range wrap(details[i], in-3) {
					body = append(body, " "+row(in, s("   "+dl, cGrey))+" ")
				}
			}
		} else {
			body = append(body, " "+row(in, append([]seg{s("   ", cPlain)}, items[i]...)...)+" ")
		}
	}
	return indent(box(m.w-2, h, []seg{s(title, cWhite)}, cDark, body))
}

func indent(lines []string) []string {
	for i := range lines {
		lines[i] = " " + lines[i] + " "
	}
	return lines
}

func (m model) filesView(h int) []string {
	var items [][]seg
	for _, f := range m.allFiles() {
		items = append(items, []seg{s(padTo(tildify(f.path), m.w-30), cGrey), s("  "+f.agent, cDark)})
	}
	return m.listBox("FILES AGENTS MENTIONED", items, h, "no files mentioned yet")
}

func (m model) proposalsView(h int) []string {
	var items [][]seg
	for _, p := range m.props {
		items = append(items, []seg{s(p, cGrey)})
	}
	return m.listBox("PROPOSALS   enter show · a approve · x reject · z snooze 7d", items, h, "no open proposals")
}

func (m model) paperclipView(h int) []string {
	if m.pc.Err != "" {
		return m.listBox("PAPERCLIP", nil, h, m.pc.Err)
	}
	var items [][]seg
	for _, it := range m.pc.Items {
		st := cGrey
		if it.Needs {
			st = cOrange
		}
		items = append(items, []seg{
			s(padTo(it.Ref, 9), cWhite), s(padTo(it.Status, 12), st), s(padTo(it.Agent, 14), cGrey),
			s(padTo(it.Cost, 7), cDark), s(it.Title, cGrey), s("  "+it.Detail, cDark),
		})
	}
	var details []string
	for _, it := range m.pc.Items {
		details = append(details, it.Detail)
	}
	if m.mode == mTyping && m.listSel < len(m.pc.Items) {
		ed := m.ed.lines(m.w - 6)
		eh := len(ed) + 2
		var body []string
		for _, l := range ed {
			body = append(body, " "+l+" ")
		}
		list := m.listBox("PAPERCLIP   "+m.cfg.Keys.Reply+" comment · enter open in browser", items, h-eh, "loading…", details...)
		return append(list, indent(box(m.w-2, eh, []seg{s("COMMENT ON "+m.pc.Items[m.listSel].Ref, cWhite)}, cOrange, body))...)
	}
	return m.listBox("PAPERCLIP   "+m.cfg.Keys.Reply+" comment · enter open in browser", items, h, "loading…", details...)
}

func (m model) textView(title string, lines []string, h int) []string {
	in := m.w - 6
	var body []string
	for _, l := range lines {
		st := cGrey
		if strings.HasPrefix(l, "## ") {
			st = cWhite
			l = strings.TrimPrefix(l, "## ")
		}
		if width(l) <= in { // keep its spacing: columns stay aligned
			body = append(body, " "+row(in, s(l, st))+" ")
			continue
		}
		for _, wl := range wrap(l, in) {
			body = append(body, " "+row(in, s(wl, st))+" ")
		}
	}
	return indent(box(m.w-2, h, []seg{s(strings.ToUpper(title), cWhite)}, cDark, body))
}

func (m model) helpView(h int) []string {
	K := m.cfg.Keys
	k := func(key string) string {
		if key == " " {
			return "space"
		}
		return key
	}
	row2 := func(key, what string) string { return fmt.Sprintf("%-14s %s", key, what) }
	lines := []string{
		"## Go to a view: push " + K.Command + ", write the code, push enter. esc goes back to the desk.",
		row2("IN", "inbox (the desk): all agents and the selected agent"),
		row2("AG or "+K.Wall, "agents (the wall): all agents as tiles"),
		row2("FL", "files the agents wrote about (enter opens)"),
		row2("RP", "repos with work that you can lose"),
		row2("PR", "proposals: enter shows, a approve, x reject, z hide 7 days"),
		row2("PC", "Paperclip issues: "+K.Reply+" comment, enter opens in the browser"),
		row2("A3, or a name", "select agent 3, or the first agent whose name starts so"),
		row2("HELP, QUIT", "this page; stop kaching (ctrl+c also stops it)"),
		"",
		"## Desk",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous agent"),
		row2(k(K.Waiting), "next agent that waits for you"),
		row2("1-9", "send that numbered answer"),
		row2("enter, ←, →", "when the agent asks: confirm, previous / next part"),
		row2(K.Reply, "write a message (keys below); esc keeps it as a draft"),
		row2(K.Open+" then a-i", "open that file"),
		row2(K.Goto, "show the agent's own Terminal window, where it is"),
		row2(K.Here, "bring its window to monitor 1 and into focus, to type in it"),
		row2(K.Dismiss, "remove a waiting agent from the list, no answer"),
		row2(K.Refresh, "read all data again"),
		"",
		"## Writing a message",
		row2("enter", "send   ·   option+enter, ctrl+j or \\ enter: new line"),
		row2("option+key", "your layout's character: option+l @, option+5 [, option+8 {, option+7 |"),
		row2("@ / /", "suggest the agent's files / commands; tab or enter takes one"),
		row2("ctrl+v", "paste a clipboard image (saved, its path goes in); cmd+v pastes text"),
		row2("option+arrows", "move by word   ·   option+backspace: delete a word"),
		"",
		"## Wall",
		row2("1-9", "select that tile"),
		row2(K.Zoom, "tile on the full screen, again to go back (then 1-9 answer)"),
		"",
		"## Fixed messages (desk and wall; space keys: push space, then the key)",
	}
	for _, r := range m.cfg.Replies {
		lines = append(lines, row2(r.Key, fmt.Sprintf("%q", r.Text)))
	}
	lines = append(lines, "",
		"Change keys and messages in "+tildify(configPath())+". Save: kaching reloads it.",
		"Full manual: ~/.claude/kaching/docs/kaching-manual.md")
	return m.textView("help", lines, h)
}

// ---- footer

func (m model) footer() []string {
	K := m.cfg.Keys
	key := func(k string) string {
		if k == " " {
			return "␣"
		}
		return k
	}
	r1 := []seg{s(" ", cPlain)}
	add := func(segs *[]seg, k, label string) {
		*segs = append(*segs, s(k, cOrange), s(" "+label+"   ", cGrey))
	}
	switch m.view {
	case vWall:
		add(&r1, "1-9", "select")
		add(&r1, K.Zoom, "zoom")
		add(&r1, K.Next+" "+K.Prev, "next/prev")
		add(&r1, key(K.Waiting), "next waiting")
		add(&r1, "esc", "desk")
	case vFiles, vProposals, vPaperclip, vRepos:
		add(&r1, K.Next+" "+K.Prev, "move")
		add(&r1, "enter", "open")
		add(&r1, "esc", "desk")
		add(&r1, K.Command, "command")
	default:
		add(&r1, "1-9", "answer")
		add(&r1, K.Next+" "+K.Prev, "next/prev")
		add(&r1, key(K.Waiting), "next waiting")
		add(&r1, K.Open+" a-i", "open file")
		add(&r1, K.Goto, "go to window")
		add(&r1, K.Here, "bring here")
		add(&r1, K.Dismiss, "dismiss")
		add(&r1, K.Reply, "type reply")
		add(&r1, K.Command, "command")
		add(&r1, "?", "help")
	}
	r2 := []seg{s(" ", cPlain)}
	for _, r := range m.cfg.Replies {
		add(&r2, strings.Replace(r.Key, "space ", "␣", 1), r.Label)
	}
	return []string{cDark.Render(strings.Repeat("─", m.w)), row(m.w, r1...), row(m.w, r2...)}
}
