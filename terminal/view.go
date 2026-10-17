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
		body = m.reposView(bodyH)
	case vProposals:
		body = m.proposalsView(bodyH)
	case vPulls:
		body = m.pullsView(bodyH)
	case vRecaps:
		body = m.recapsView(bodyH)
	case vPaperclip:
		body = m.paperclipView(bodyH)
	case vFind:
		body = m.findView(bodyH)
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
		segs  []seg
		alert bool
	}
	pcNeeds := 0
	for _, it := range m.pc.Items {
		if it.Needs {
			pcNeeds++
		}
	}
	nums := map[view]string{vDesk: fmt.Sprint(need),
		vProposals: fmt.Sprint(len(m.props)), vPulls: fmt.Sprint(len(m.pulls.Items)), vPaperclip: fmt.Sprint(pcNeeds)}
	// a view with work that waits for the owner is filled orange: open proposals, Paperclip issues that need you
	alert := map[view]bool{vProposals: len(m.props) > 0, vPaperclip: pcNeeds > 0}
	var cells []cell
	cells = append(cells, cell{[]seg{s("kaching", cWhite)}, false})
	for _, t := range tabs {
		active := m.view == t.v || (t.v == vDesk && m.view == vWall) // the wall (W) is the inbox as tiles
		lbl := cGrey
		if active {
			lbl = cWhite
		}
		code := cOrange
		if alert[t.v] {
			code, lbl = cSel, cSel
		}
		segs := []seg{s(t.code, code), s(" "+t.label, lbl)}
		if n := nums[t.v]; n != "" && n != "0" {
			segs = append(segs, s("  "+n, lbl))
		}
		cells = append(cells, cell{segs, alert[t.v]})
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
		if tw > cw-2 && len(c.segs) == 3 { // too narrow: code and count
			c.segs = []seg{c.segs[0], c.segs[2]}
			tw = segsWidth(c.segs)
		}
		if tw > cw-2 { // still too narrow: code only
			c.segs = c.segs[:1]
			tw = segsWidth(c.segs)
		}
		l := (cw - tw) / 2
		if l < 0 {
			l = 0
		}
		fill := cPlain
		if c.alert {
			fill = cSel
		}
		midSegs = append(midSegs, s(strings.Repeat(" ", l), fill))
		midSegs = append(midSegs, c.segs...)
		midSegs = append(midSegs, s(strings.Repeat(" ", max(0, cw-tw-l)), fill), s("│", cDark))
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
		if url, ok := strings.CutPrefix(m.ed.target, "pr:"); ok {
			if i := m.pulls.index(url); i >= 0 {
				pr := m.pulls.Items[i]
				target = fmt.Sprintf("a new agent on %s#%d", pr.Repo, pr.Number)
			}
		}
		left = []seg{s(" writing to ", cGrey), s(target, cWhite)}
		if group, ok := strings.CutPrefix(m.ed.target, "all:"); ok {
			left = []seg{s(" writing "+m.allHeader(group), cGrey), s("  enter sends it", cGrey)}
		}
		if dir, ok := strings.CutPrefix(m.ed.target, "nw:"); ok {
			left = []seg{s(" new background agent in ", cGrey), s(tildify(dir), cWhite)}
			if o := m.nw.summary(); o != "" {
				left = append(left, s("  "+o, cOrange))
			}
			left = append(left, s("  enter starts it", cGrey))
		}
	case mOpen:
		left = []seg{s(" open file: press its letter", cOrange)}
	case mConfirm:
		left = []seg{s(" No local folder. Open it on GitHub? ", cOrange), s("enter/y yes · esc no", cGrey)}
	default:
		code := tabs[0].code
		for _, t := range tabs {
			if t.v == m.view {
				code = t.code
			}
		}
		if m.view == vFind {
			code = "FIND"
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
	// INPUT, WAITING and DONE are all Group 0 (waiting): INPUT asks the owner something (needsYou), WAITING
	// finished its turn with something still open, DONE finished with nothing left.
	groups := []struct {
		name string
		in   func(Agent) bool
	}{
		{"INPUT", func(a Agent) bool { return a.needsYou() }},
		{"WAITING", func(a Agent) bool { return sectionOf(a) == 1 }},
		{"WORKING", func(a Agent) bool { return a.Group() == 1 }},
		{"IDLE", func(a Agent) bool { return a.Group() == 2 }},
		{"DONE", func(a Agent) bool { return sectionOf(a) == 4 }},
	}
	si := 0
	for gi, g := range groups {
		// every section keeps its header, also when empty: an empty INPUT shows at a glance that nothing needs the owner
		if gi > 0 {
			body = append(body, "")
		}
		body = append(body, row(in, s(" "+g.name, cDark)))
		for i, a := range m.agents {
			if familySection(m.agents, i) != gi {
				continue
			}
			if a.SID == m.selSID {
				si = len(body)
			}
			body = append(body, m.queueRow(in, i, a))
			if a.State == "input" && !a.Busy && a.Ask != "" { // what its last turn asked, under its row
				body = append(body, row(in, s("   ↳ "+trunc(a.Ask, in-5), cText)))
			}
		}
	}
	if vis := h - 2; len(body) > vis && si >= vis { // keep the selected row visible
		body = body[si-vis+1:]
	}
	return box(w, h, []seg{s("AGENTS", cGrey)}, cDark, body)
}

// sectionOf: the queue section an agent belongs to by itself: 0 INPUT, 1 WAITING, 2 WORKING, 3 IDLE, 4 DONE.
func sectionOf(a Agent) int {
	switch {
	case a.needsYou():
		return 0
	case a.Closed && a.Group() == 0:
		return 4
	case a.Group() == 0:
		return 1
	case a.Group() == 1:
		return 2
	}
	return 3
}

// familySection: the section a family is listed in, its most urgent member's (lead and sub-sessions alike).
func familySection(a []Agent, i int) int {
	key := a[i].SID
	if a[i].Lead != "" {
		key = a[i].Lead
	}
	sec := sectionOf(a[i])
	for _, x := range a {
		if (x.SID == key || x.Lead == key) && sectionOf(x) < sec {
			sec = sectionOf(x)
		}
	}
	return sec
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
	if !a.canSend() {
		ns = cDark
	}
	mark := "   "
	if a.Bg { // a background session: no window
		mark = " ◦ "
	}
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

// chatLines is the conversation as panel rows, oldest first: the owner's prompts in white after "› " on a
// slightly lighter band (promptBg), so they stand out from the replies; the agent's
// texts in grey (their tables drawn as tables, in the tables style), a blank row between messages. Only the last
// message when the tail has no conversation.
func chatLines(l Last, in int, tables string) []string {
	chat := l.Chat
	if len(chat) == 0 {
		text := l.Text
		if text == "" {
			text = "(no message yet)"
		}
		chat = []Turn{{Text: text}}
	}
	var out []string
	for i, t := range chat {
		if i > 0 {
			out = append(out, row(in))
		}
		if t.User {
			for j, ml := range collapse(wrap(plain(t.Text), in-2)) {
				lead := "  "
				if j == 0 {
					lead = "› "
				}
				out = append(out, row(in, s(lead, cOrange.Background(promptBg)), s(padTo(ml, in-2), cWhite.Background(promptBg))))
			}
			continue
		}
		out = append(out, textRows(t.Text, in, tables)...)
	}
	return out
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
	// the box of /NW and /ALL is written below the selected agent, with its own title
	newAgent := m.mode == mTyping && (strings.HasPrefix(m.ed.target, "nw:") || strings.HasPrefix(m.ed.target, "all:"))
	if a == nil {
		var body []string
		if newAgent {
			for _, el := range m.ed.lines(in) {
				body = append(body, " "+el+" ")
			}
		}
		return box(w, h, []seg{s("no agent", cGrey)}, cDark, body)
	}
	l := m.last(a)
	title := []seg{s(a.Name, cWhite), s(" · "+tildify(a.Cwd), cGrey)}
	if a.Bg {
		title = append(title, s(" · background "+a.Job, cGrey))
	}
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
		tail = append(tail, askSummary(l.Ask, in, m.cfg.Keys.Quick)...)
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
	if newAgent {
		var hd string
		var who []string
		if group, ok := strings.CutPrefix(m.ed.target, "all:"); ok { // /ALL: one message to a group of agents
			hd = "─ " + m.allHeader(group) + " "
			send, skipped := m.recipients(group)
			who = wrap(names2(send), in)
			if len(skipped) > 0 {
				who = append(who, trunc("left out: "+strings.Join(skipped, ", "), in))
			}
		} else { // /NW: the first message of a new background agent
			dir := tildify(strings.TrimPrefix(m.ed.target, "nw:"))
			hd = "─ new background agent in " + dir + " "
			if o := m.nw.summary(); o != "" {
				hd = "─ new background agent in " + dir + " · " + o + " "
			}
		}
		tail = append(tail, "", row(in, s(hd, cOrange), s(strings.Repeat("─", max(0, in-width(hd))), cOrange)))
		for _, l := range who {
			tail = append(tail, row(in, s(l, cGrey)))
		}
		tail = append(tail, m.ed.lines(in)...)
	} else {
		tail = append(tail, "", row(in, s("─ reply ", cDark), s(strings.Repeat("─", max(0, in-8)), cDark)))
	}
	switch {
	case newAgent:
	case a.Bg && m.mode == mTyping && m.ed.target == a.SID:
		tail = append(tail, m.ed.lines(in)...)
	case a.Bg:
		tail = append(tail, row(in, s("> ", cOrange), s(m.cfg.Keys.Reply+" to write · "+m.cfg.Keys.Goto+" attaches a window · /STOP stops it", cDark)))
	case !a.InTerminal:
		tail = append(tail, row(in, s("not a Terminal tab: look only", cDark)))
	case m.mode == mTyping && m.ed.target == a.SID:
		tail = append(tail, m.ed.lines(in)...)
	default:
		tail = append(tail, row(in, s("> ", cOrange), s(m.cfg.Keys.Reply+" to write", cDark)))
	}
	avail := h - 2 - len(tail)
	var body []string
	if l.Recap != "" { // the recap goes on top: at most a third of the space, the conversation keeps the rest
		rl := wrap(l.Recap, in)
		if most := max(1, avail/3-1); len(rl) > most {
			rl = append(rl[:most-1:most-1], trunc(rl[most-1], in-1)+"…")
		}
		body = append(body, " "+row(in, s("RECAP", cDark), s(" · "+age(l.RecapAt)+" ago", cDark))+" ")
		for _, r := range rl {
			body = append(body, " "+row(in, s(r, cWhite))+" ")
		}
		body = append(body, " "+row(in, s("─ session ", cDark), s(strings.Repeat("─", max(0, in-10)), cDark))+" ")
		avail -= len(rl) + 2
	}
	if avail < 1 {
		avail = 1
	}
	msg := chatLines(l, in, m.cfg.Tables)
	// bottom-anchored: off lines back from the newest; the scroll keys move off, this drawing sets its limits
	most := max(0, len(msg)-avail)
	off := 0
	if c := m.scroll; c != nil {
		if c.sid != a.SID {
			*c = chatScroll{sid: a.SID}
		}
		c.max, c.page = most, avail
		c.off = min(c.off, most)
		off = c.off
	}
	end := len(msg) - off
	start := max(0, end-avail)
	msg = msg[start:end]
	if start > 0 && len(msg) > 1 {
		msg[0] = row(in, s(fmt.Sprintf("↑ %d earlier lines", start), cDark))
	}
	if off > 0 && len(msg) > 1 {
		msg[len(msg)-1] = row(in, s(fmt.Sprintf("↓ %d newer lines", off), cOrange))
	}
	for _, ml := range msg {
		body = append(body, " "+ml+" ")
	}
	for len(body) < h-2-len(tail) {
		body = append(body, "")
	}
	for _, t := range tail {
		body = append(body, " "+t+" ")
	}
	border := cDark
	if a.Group() == 0 {
		border = cOrange
	}
	return boxR(w, h, title, modelTag(l), border, body)
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
	text := l.Text
	if text == "" {
		text = "(no message yet)"
	}
	lines := textRows(text, in, m.cfg.Tables)
	avail := h - 3
	if len(l.Options) > 0 {
		avail--
	}
	if len(lines) > avail {
		lines = lines[len(lines)-avail:]
	}
	for _, t := range lines {
		body = append(body, " "+t+" ")
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
	return boxR(w, h, title, modelTag(l), border, body)
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
		items = append(items, []seg{s(padTo(tildify(f.path), m.w-36), cGrey), s("  "+padTo(f.agent, 18), cDark),
			s(fmt.Sprintf(" %4s", age(f.at)), cDark)})
	}
	return m.listBox(fmt.Sprintf("FILES AGENTS MENTIONED   the last %d, newest first", histMax), items, h, "no files mentioned yet")
}

// recapsView: every agent's latest recap, newest first; the selected one shows it in full.
func (m model) recapsView(h int) []string {
	var items [][]seg
	var details []string
	for _, r := range m.recaps() {
		items = append(items, []seg{s(padTo(r.agent.Name, 18), cWhite), s(" "+padTo(age(r.last.RecapAt), 4), cDark),
			s(" "+r.last.Recap, cGrey)})
		details = append(details, r.last.Recap)
	}
	return m.listBox("RECAPS   what Claude Code summed up while you were away · enter goes to the agent", items, h,
		"no recaps yet: Claude Code writes one when you come back to a session after a while", details...)
}

func (m model) proposalsView(h int) []string {
	var items [][]seg
	for _, p := range m.props {
		items = append(items, []seg{s(p, cGrey)})
	}
	return m.listBox("PROPOSALS   enter show · a approve · x reject · z snooze 7d", items, h, "no open proposals")
}

// pullsView: the open pull requests that involve the owner, the last updated first. With the side panel open
// (k), the list narrows to the left and the selected pull request shows on the right.
func (m model) pullsView(h int) []string {
	if m.prOpen && len(m.pulls.Items) > 0 {
		lw, rw := pcWidths(m.w)
		left, right := m.prList(lw, h), m.prPanel(rw, h)
		out := make([]string, h)
		for i := range out {
			out[i] = " " + left[i] + " " + right[i]
		}
		return out
	}
	title := "PULL REQUESTS   open, that involve you · k opens one · enter opens it in the browser"
	if m.pulls.Err != "" {
		if len(m.pulls.Items) == 0 {
			return m.listBox("PULL REQUESTS", nil, h, m.pulls.Err)
		}
		title = "PULL REQUESTS   from " + age(m.pulls.At) + " ago · " + m.pulls.Err
	}
	var items [][]seg
	for _, pr := range m.pulls.Items {
		ref := fmt.Sprintf("%s#%d", pr.Repo, pr.Number)
		tt := cWhite
		if pr.Draft {
			ref, tt = ref+" draft", cGrey
		}
		items = append(items, []seg{s(padTo(ref, 34), cGrey), s(" "+padTo(age(pr.Updated), 4), cDark), s(" "+pr.Title, tt)})
	}
	empty := "no open pull requests"
	if m.pulls.At.IsZero() {
		empty = "loading…"
	}
	return m.listBox(title, items, h, empty)
}

// prList: the PR view's narrow list, next to the side panel.
func (m model) prList(w, h int) []string {
	in := w - 2
	var body []string
	first := 0
	if vis := h - 2; m.listSel >= vis {
		first = m.listSel - vis + 1
	}
	for i := first; i < len(m.pulls.Items); i++ {
		pr := m.pulls.Items[i]
		ref := fmt.Sprintf("%s#%d", pr.Repo[strings.Index(pr.Repo, "/")+1:], pr.Number)
		if i == m.listSel {
			body = append(body, row(in, s(padTo(fmt.Sprintf(" > %-16s %s", ref, pr.Title), in), cSel)))
			continue
		}
		tt := cWhite
		if pr.Draft {
			tt = cGrey
		}
		body = append(body, row(in, s("   ", cPlain), s(padTo(ref, 16)+" ", cGrey), s(pr.Title, tt)))
	}
	return box(w, h, []seg{s("PULL REQUESTS", cGrey)}, cDark, body)
}

// prPanel: the selected pull request: its state, description, files and thread; the quick comments and the
// comment box stay at the bottom.
func (m model) prPanel(w, h int) []string {
	in := w - 4
	pr := m.pulls.Items[m.listSel]
	title := []seg{s(fmt.Sprintf("%s#%d", pr.Repo, pr.Number), cWhite)}
	if pr.Draft {
		title = append(title, s(" · draft", cGrey))
	}
	d, loaded := m.prDet[pr.URL]
	var msg, tail []string
	for _, l := range wrap(pr.Title, in) {
		msg = append(msg, row(in, s(l, cWhite)))
	}
	switch {
	case !loaded:
		msg = append(msg, "", row(in, s("loading…", cDark)))
	case d.Err != "":
		msg = append(msg, "", row(in, s(d.Err, cOrange)))
	default:
		state := []seg{s(d.Head+" → "+d.Base, cGrey), s(fmt.Sprintf("   +%d -%d in %d files", d.Add, d.Del, len(d.Files)), cDark)}
		msg = append(msg, row(in, state...))
		var flags []seg
		switch d.Mergeable {
		case "MERGEABLE":
			flags = append(flags, s("no conflicts", cGrey))
		case "CONFLICTING":
			flags = append(flags, s("conflicts", cOrange))
		}
		if d.Checks != "" {
			st := cGrey
			if strings.Contains(d.Checks, "failed") {
				st = cOrange
			}
			flags = append(flags, s(" · checks: "+d.Checks, st))
		}
		if d.Review != "" {
			flags = append(flags, s(" · "+strings.ToLower(strings.ReplaceAll(d.Review, "_", " ")), cGrey))
		}
		if len(flags) > 0 {
			msg = append(msg, row(in, flags...))
		}
		if strings.TrimSpace(d.Body) != "" {
			msg = append(msg, "", row(in, s("DESCRIPTION", cDark)))
			msg = append(msg, textRows(d.Body, in, m.cfg.Tables)...)
		}
		if len(d.Files) > 0 {
			msg = append(msg, "", row(in, s("FILES", cDark)))
			for _, f := range d.Files {
				n := fmt.Sprintf(" +%d -%d", f.Add, f.Del)
				msg = append(msg, row(in, s(padTo(f.Path, max(1, in-width(n))), cGrey), s(n, cDark)))
			}
		}
		if len(d.Thread) > 0 {
			msg = append(msg, "", row(in, s("─ thread ", cDark), s(strings.Repeat("─", max(0, in-9)), cDark)))
		}
		for i, c := range d.Thread {
			if i > 0 {
				msg = append(msg, row(in))
			}
			head := []seg{s(c.Author, cGrey), s(" · "+age(c.At)+" ago", cDark)}
			if c.State != "" {
				head = append(head, s(" · "+strings.ToLower(strings.ReplaceAll(c.State, "_", " ")), cOrange))
			}
			msg = append(msg, row(in, head...))
			msg = append(msg, textRows(c.Body, in, m.cfg.Tables)...)
		}
	}
	K := m.cfg.Keys
	tail = append(tail, "", row(in, s("A NEW AGENT WORKS ON IT", cDark)))
	for i, q := range prQuick {
		tail = append(tail, row(in, s(fmt.Sprint(i+1), cOrange), s(" "+q.label, cWhite)))
	}
	box := "─ your comment: the agent's task (enter starts it) "
	tail = append(tail, "", row(in, s(box, cDark), s(strings.Repeat("─", max(0, in-width(box))), cDark)))
	if m.mode == mTyping && m.ed.target == "pr:"+pr.URL {
		tail = append(tail, m.ed.lines(in)...)
	} else {
		scroll := K.Older + "/" + K.Newer
		if K.Older == "up" && K.Newer == "down" {
			scroll = "↑↓"
		}
		tail = append(tail, row(in, s("> ", cOrange), s(K.Reply+" comment · enter opens on GitHub · "+scroll+" scroll · esc closes", cDark)))
	}
	id := pr.URL // a new pull request, or its panel just read, starts at the top
	if loaded {
		id += "@" + d.At.String()
	}
	return boxR(w, h, title, nil, cDark, m.panelBody(m.prScroll, id, true, msg, tail, in, h))
}

// panelBody: a side panel's lines: msg bottom-anchored and scrolled back by c, tail fixed under it. Another id
// starts at the newest line, or at the first with top.
func (m model) panelBody(c *chatScroll, id string, top bool, msg, tail []string, in, h int) []string {
	avail := max(1, h-2-len(tail))
	most := max(0, len(msg)-avail)
	if c == nil {
		c = &chatScroll{}
	}
	fresh := c.sid != id
	if fresh {
		*c = chatScroll{sid: id}
	}
	c.max, c.page = most, avail
	if fresh && top {
		c.off = most
	}
	c.off = min(c.off, most)
	end := len(msg) - c.off
	start := max(0, end-avail)
	msg = msg[start:end]
	if start > 0 && len(msg) > 1 {
		msg[0] = row(in, s(fmt.Sprintf("↑ %d earlier lines", start), cDark))
	}
	if c.off > 0 && len(msg) > 1 {
		more := "newer"
		if top {
			more = "more"
		}
		msg[len(msg)-1] = row(in, s(fmt.Sprintf("↓ %d %s lines", c.off, more), cOrange))
	}
	var body []string
	for _, l := range msg {
		body = append(body, " "+l+" ")
	}
	for len(body) < h-2-len(tail) {
		body = append(body, "")
	}
	for _, t := range tail {
		body = append(body, " "+t+" ")
	}
	return body
}

// pcWidths: the PC view's issue list and side panel outer widths for a screen w wide.
func pcWidths(w int) (lw, rw int) {
	lw = min(max(w*40/100, 40), 72)
	return lw, w - lw - 2
}

// paperclipView: the issues on the left (j/l), the selected issue's context on the right: its request to you
// with numbered answers, the thread, the comment box.
func (m model) paperclipView(h int) []string {
	if m.pc.Err != "" {
		return m.listBox("PAPERCLIP", nil, h, m.pc.Err)
	}
	lw, rw := pcWidths(m.w)
	left := m.pcList(lw, h)
	right := m.pcPanel(rw, h)
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

func (m model) pcList(w, h int) []string {
	in := w - 2
	var body []string
	if len(m.pc.Items) == 0 {
		body = append(body, row(in, s(" loading…", cDark)))
	}
	first := 0
	if vis := h - 2; m.listSel >= vis {
		first = m.listSel - vis + 1
	}
	for i := first; i < len(m.pc.Items); i++ {
		it := m.pc.Items[i]
		status := strings.ReplaceAll(it.Status, "_", " ")
		if i == m.listSel {
			body = append(body, row(in, s(padTo(fmt.Sprintf(" > %-8s %-11s %s", it.Ref, status, it.Title), in), cSel)))
			continue
		}
		st, tt := cGrey, cGrey
		if it.Needs {
			st, tt = cOrange, cWhite
		}
		body = append(body, row(in, s("   ", cPlain), s(padTo(it.Ref, 8)+" ", cWhite), s(padTo(status, 11)+" ", st), s(it.Title, tt)))
	}
	return box(w, h, []seg{s("PAPERCLIP", cGrey)}, cDark, body)
}

// pcPanel: the selected issue. The scroll keys move through its description, thread and request; its question
// and the numbered answers stay at the bottom.
func (m model) pcPanel(w, h int) []string {
	in := w - 4
	it := m.pcSelected()
	if it == nil {
		return box(w, h, []seg{s("no issue", cGrey)}, cDark, nil)
	}
	title := []seg{s(it.Ref, cWhite), s(" · "+strings.ReplaceAll(it.Status, "_", " "), cGrey)}
	if it.Agent != "" {
		title = append(title, s(" · "+it.Agent, cGrey))
	}
	var right []seg
	if it.Cost != "" {
		right = []seg{s(it.Cost, cGrey)}
	}
	d, loaded := m.pcDet[it.ID]
	var msg, tail []string
	msg = append(msg, row(in, s(it.Title, cWhite)))
	if it.Detail != "" {
		msg = append(msg, row(in, s("why it waits: "+it.Detail, cDark)))
	}
	switch {
	case !loaded:
		msg = append(msg, "", row(in, s("loading…", cDark)))
	case d.Err != "":
		msg = append(msg, "", row(in, s(d.Err, cOrange)))
	default:
		if d.Description != "" {
			msg = append(msg, "", row(in, s("DESCRIPTION", cDark)))
			msg = append(msg, textRows(d.Description, in, m.cfg.Tables)...)
		}
		if len(d.Comments) > 0 {
			msg = append(msg, "", row(in, s("─ thread ", cDark), s(strings.Repeat("─", max(0, in-9)), cDark)))
		}
		for i, c := range d.Comments {
			if i > 0 {
				msg = append(msg, row(in))
			}
			who := cGrey
			if c.Board {
				who = cOrange
			}
			msg = append(msg, row(in, s(c.Author, who), s(" · "+age(c.At)+" ago", cDark)))
			if c.Board {
				for _, l := range collapse(wrap(plain(c.Body), in)) {
					msg = append(msg, row(in, s(padTo(l, in), cWhite.Background(promptBg))))
				}
				continue
			}
			msg = append(msg, textRows(c.Body, in, m.cfg.Tables)...)
		}
		if a := d.Ask; a != nil && a.Details != "" {
			msg = append(msg, "", row(in, s("─ the request ", cOrange), s(strings.Repeat("─", max(0, in-14)), cOrange)))
			msg = append(msg, textRows(a.Details, in, m.cfg.Tables)...)
		}
		if a := d.Ask; a != nil && a.Spec != nil && len(a.Options) == 0 { // the current item in full (pcview.go)
			msg = append(msg, m.pcSpecDetail(a, in)...)
		}
	}
	// the bottom: what it asks, the answers, the comment box
	K := m.cfg.Keys
	if loaded && d.Ask != nil && d.Ask.Spec != nil && len(d.Ask.Options) == 0 { // a form: ticks, questions, verdicts (pcview.go)
		room := h - 2 - 3 - 3 // minus the comment box (3 rows) and 3 rows of the thread
		if m.mode == mTyping {
			room -= len(m.ed.lines(in))
		}
		tail = append(tail, m.pcSpecBlock(d.Ask, in, room)...)
	} else if loaded && d.Ask != nil {
		a := d.Ask
		head := "IT ASKS YOU"
		if a.Kind == "recovery" {
			head = "RECOVERY WAITS FOR YOU"
		}
		tail = append(tail, "", row(in, s(head, cDark)))
		if a.Title != "" {
			tail = append(tail, row(in, s(a.Title, cWhite)))
		}
		if a.Prompt != "" {
			pl := wrap(a.Prompt, in)
			if len(pl) > 3 {
				pl = append(pl[:2:2], trunc(pl[2], in-1)+"…")
			}
			for _, l := range pl {
				tail = append(tail, row(in, s(l, cText)))
			}
		}
		for i, o := range a.Options {
			tail = append(tail, row(in, s(fmt.Sprint(i+1), cOrange), s(" "+o.Label, cWhite)))
		}
		if len(a.Options) == 0 {
			for _, l := range wrap("kaching can't answer a "+strings.ReplaceAll(a.Kind, "_", " ")+": enter opens it in Paperclip", in) {
				tail = append(tail, row(in, s(l, cDark)))
			}
		}
	}
	box := "─ comment "
	if t := m.pcBoxTitle(); t != "" {
		box = t
	}
	tail = append(tail, "", row(in, s(box, cDark), s(strings.Repeat("─", max(0, in-width(box))), cDark)))
	if m.mode == mTyping && (m.ed.target == "pc:"+it.ID || pcNoteFor(m.ed.target, it.ID)) {
		tail = append(tail, m.ed.lines(in)...)
	} else {
		scroll := K.Older + "/" + K.Newer
		if K.Older == "up" && K.Newer == "down" {
			scroll = "↑↓"
		}
		hint := K.Reply + " comment · enter opens in Paperclip · " + scroll + " scroll"
		if loaded && d.Ask != nil && len(d.Ask.Options) > 0 {
			hint = pcAnswerHint(d.Ask) + hint
		}
		tail = append(tail, row(in, s("> ", cOrange), s(hint, cDark)))
	}
	// bottom-anchored like the desk: off lines back from the end; a new issue starts at the end
	body := m.panelBody(m.pcScroll, it.ID, false, msg, tail, in, h)
	border := cDark
	if it.Needs {
		border = cOrange
	}
	return boxR(w, h, title, right, border, body)
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
		row2("FL", "the last 30 files the agents wrote about, newest first (enter opens)"),
		row2("RP", "repos: the clones here and your GitHub repos, with the sync check's notes (work you can lose) first"),
		row2("RC", "recaps: what each agent summed up while you were away (enter goes to it)"),
		row2("PR", "pull requests: the open ones that involve you on GitHub, the last updated first; "+K.Reply+" opens one on the right (description, files, thread), "+K.Reply+" again comments: enter starts a new agent with your comment as its task; 1 review it, 2 merge it; enter opens it in the browser"),
		row2("PO", "proposals: enter shows, a approve, x reject, z hide 7 days (the tab is orange while some are open)"),
		row2("PC", "Paperclip issues and company approvals, the selected one's thread on the right: 1-9 answer what it asks (approve, decline, …), "+K.Reply+" comment, enter opens it in the browser (orange while one needs you); the keys below"),
		row2("NW [folder] [opts]", "start a background agent: write its first message, enter starts it (folder: a path, a folder in ~/bbq, an agent's name; none: the selected agent's). Opts, in any place: a model (opus sonnet haiku fable), an effort (low … max), a mode (plan auto bypass accept manual dontask), e.g. NW soii sonnet high"),
		row2("FIND words", "find a session: by its name, then by what was said in it (one message with all the words), then Claude picks (s). See Find below"),
		row2("STOP", "stop the selected background agent (its conversation stays)"),
		row2("ALL group", "one message to a group of agents: waiting (INPUT and WAITING), input, idle or working; agents with a menu on screen are left out"),
		row2("A3, or a name", "select agent 3, or the first agent whose name starts so"),
		row2("HELP, QUIT", "this page; stop kaching (ctrl+c also stops it)"),
		"",
		"## Desk",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous agent"),
		row2(k(K.Waiting), "the agent in INPUT that has waited the longest"),
		row2(k(K.Older)+" / "+k(K.Newer), "scroll the agent's conversation 3 lines back / on (also when zoomed, and while writing on the draft's first / last line)"),
		row2("pgup / pgdown", "a page back / on   ·   home: its start   ·   end: the newest"),
		row2("1-9", "send that numbered answer"),
		row2(K.Quick, "an agent asks questions: take the recommended answer (★, the one the agent marks) of every question and submit; it refuses when a question has none"),
		row2("enter, ←, →", "when the agent asks: confirm, previous / next part"),
		row2(K.Reply, "write a message (keys below); esc keeps it as a draft; sending it sends a window on monitor 1 back"),
		row2(K.Open+" then a-i", "open that file"),
		row2(K.Goto, "show the agent's own Terminal window, where it is; a background agent (◦) gets a new window attached to it"),
		row2(K.Here, "bring its window to monitor 1 and into focus, to type in it; a prompt sends it back"),
		row2(K.Dismiss, "remove a waiting agent from the list, no answer"),
		row2(K.Refresh, "read all data again"),
		"",
		"## Writing a message",
		row2("enter", "send   ·   option+enter, ctrl+j or \\ enter: new line"),
		row2("option+key", "your layout's character: option+l @, option+5 [, option+8 {, option+7 |"),
		row2("@ / /", "suggest the agent's files and the other sessions / commands; tab or enter takes one"),
		row2("@Name text", "a message that starts with a live session's name goes to that session (@\"two words\" for names with spaces); a mention elsewhere stays in the text, and the agent itself passes it on"),
		row2("ctrl+v", "paste a clipboard image (saved, its path goes in); cmd+v pastes text"),
		row2("option+arrows", "move by word   ·   option+backspace: delete a word"),
		"",
		"## Repos (RP)",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous repo"),
		row2("enter", "open its folder; on GitHub only: asks, then enter or y opens it on GitHub"),
		row2("b, opt+enter", "open it on GitHub (option+enter; shift+enter too, where the terminal tells it from enter)"),
		row2(K.Reply, "its folders on the right: "+K.Reply+" goes into a folder or opens a file, h (or backspace) up, enter shows it in Finder, esc closes"),
		"",
		"## Paperclip requests (PC)",
		row2("1-9", "answer; in a list: tick the item; in a question: pick the option; with verdicts: give the current item that verdict"),
		row2("approvals", "1 approve, 2 reject, 3 request revision (needs a note), 4 approve with a note, 5 reject with a note"),
		row2("s", "send the ticks, the answers or the verdicts"),
		row2("x / r", "decline a list of choices or tasks / decline with a reason (the box opens)"),
		row2("← / →", "the previous / next question or item"),
		row2("o", "write your own answer to a question (enter keeps it)"),
		row2("a", "questions: give every ★ recommended answer and send; it says which question has none and sends nothing"),
		row2("n / p", "next / previous page of a long list"),
		"",
		"## Find (/FIND words)",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous result"),
		row2("enter", "a live session: go to it on the desk. An ended one: read the messages that match, with the message before and after (esc closes)"),
		row2("s", "ask Claude which sessions fit (it runs by itself when names and text find nothing)"),
		row2("r", "resume an ended session in a new Terminal window: cd to its folder, claude --resume"),
		"",
		"## Wall (push " + K.Wall + ")",
		row2("1-9", "select that tile"),
		row2(K.Zoom, "tile on the full screen, again to go back (then 1-9 answer)"),
		"",
		"## Fixed messages (desk and wall; space keys: push space, then the key)",
	}
	for _, r := range m.cfg.Replies {
		lines = append(lines, row2(r.Key, fmt.Sprintf("%q", r.Text)))
	}
	lines = append(lines, "",
		"Change keys, messages and how tables show (tables = auto, rule, grid or records) in "+tildify(configPath())+". Save: kaching reloads it.",
		"Full manual: ~/.claude/kaching/docs/kaching-manual.md")
	return m.textView("help", lines, h)
}

// ---- footer

func (m model) footer() []string {
	K := m.cfg.Keys
	key := func(k string) string {
		switch k {
		case " ":
			return "␣"
		case "up":
			return "↑"
		case "down":
			return "↓"
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
		add(&r1, key(K.Waiting), "longest input")
		add(&r1, "esc", "desk")
	case vPaperclip:
		add(&r1, K.Next+" "+K.Prev, "issue")
		for _, kv := range m.pcFooterKeys() { // the numbers, and the keys of a form
			add(&r1, kv[0], kv[1])
		}
		add(&r1, key(K.Older)+key(K.Newer), "scroll")
		add(&r1, K.Reply, "comment")
		add(&r1, "enter", "in browser")
		add(&r1, "esc", "desk")
	case vFind:
		for _, h := range m.findHints() {
			add(&r1, h[0], h[1])
		}
	case vPulls:
		add(&r1, K.Next+" "+K.Prev, "move")
		if m.prOpen {
			add(&r1, K.Reply, "comment → new agent")
			add(&r1, "1-2", "review / merge")
			add(&r1, key(K.Older)+key(K.Newer), "scroll")
			add(&r1, "enter", "in browser")
			add(&r1, "esc", "close")
		} else {
			add(&r1, K.Reply, "open")
			add(&r1, "enter", "in browser")
			add(&r1, "esc", "desk")
			add(&r1, K.Command, "command")
		}
	case vRepos:
		add(&r1, K.Next+" "+K.Prev, "move")
		if m.tree != nil {
			add(&r1, K.Reply, "open")
			add(&r1, "h", "up")
			add(&r1, "enter", "in Finder")
			add(&r1, "b", "on GitHub")
			add(&r1, "esc", "close")
		} else {
			add(&r1, "enter", "open folder")
			add(&r1, "b", "on GitHub")
			add(&r1, K.Reply, "folders")
			add(&r1, "esc", "desk")
			add(&r1, K.Command, "command")
		}
	case vFiles, vProposals, vRecaps:
		add(&r1, K.Next+" "+K.Prev, "move")
		add(&r1, "enter", "open")
		add(&r1, "esc", "desk")
		add(&r1, K.Command, "command")
	default:
		add(&r1, "1-9", "answer")
		if a := m.sel(); a != nil && len(m.last(a).Ask) > 0 {
			add(&r1, K.Quick, "quick approve")
		}
		add(&r1, K.Next+" "+K.Prev, "next/prev")
		add(&r1, key(K.Older)+key(K.Newer), "scroll")
		add(&r1, key(K.Waiting), "longest input")
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
	// the Claude usage on the right of the two key rows; the keys give way
	u := usageRows(m.usage, time.Now())
	uw := max(segsWidth(u[0]), segsWidth(u[1]))
	if kw := m.w - uw - 3; kw >= 20 {
		fit := func(segs []seg) []seg { // whole hints only: drop the last key and label while they don't fit
			for len(segs) > 1 && segsWidth(segs) > kw {
				segs = segs[:max(1, len(segs)-2)]
			}
			return segs
		}
		r1, r2 = fit(r1), fit(r2)
		return []string{cDark.Render(strings.Repeat("─", m.w)),
			row(kw, r1...) + "  " + row(uw, u[0]...) + " ", row(kw, r2...) + "  " + row(uw, u[1]...) + " "}
	}
	return []string{cDark.Render(strings.Repeat("─", m.w)), row(m.w, r1...), row(m.w, r2...)}
}
