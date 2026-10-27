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
		return cGrey.Render(fmt.Sprintf("agterm needs at least 60x16 (now %dx%d)", m.w, m.h))
	}
	var lines []string
	lines = append(lines, m.tabBar()...)
	lines = append(lines, m.commandLine(), "")
	bodyH := m.h - headerH - footerH
	var body []string
	switch m.view {
	case vDesk:
		if m.zoom {
			body = m.agentPanel(m.w, bodyH)
		} else {
			body = m.desk(bodyH)
		}
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
	case vTheme:
		body = m.themeView(bodyH)
	case vHelp, vChangelog:
		body = m.helpView(bodyH)
	}
	for len(body) < bodyH {
		body = append(body, "")
	}
	lines = append(lines, body[:bodyH]...)
	lines = append(lines, m.footer()...)
	if m.mode == mOpen && len(m.openLinks) > 0 { // o: each link shows the number that opens it (D72)
		return numberLinks(strings.Join(lines, "\n"), m.openLinks)
	}
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
	cells = append(cells, cell{[]seg{s("AgentTerminal", cWhite)}, false})
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
		if i == 0 && tw > cw-2 { // the name cell, too narrow for the full name
			c.segs = []seg{s("AT", cWhite)}
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
		if name, ok := strings.CutPrefix(m.ed.target, "br:"); ok && m.branches != nil {
			target = "a new agent on " + m.branches.repo.Name + ":" + name
		}
		left = []seg{s(" writing to ", cGrey), s(target, cWhite)}
		if id, _, ok := pcHandTarget(m.ed.target); ok {
			ref := id
			for _, it := range m.pc.Items {
				if it.ID == id {
					ref = it.Ref
				}
			}
			left = []seg{s(" handing ", cGrey), s(ref, cWhite), s(" over to an agent with your permissions  enter sends it, empty sends the default task", cGrey)}
		}
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
		left = []seg{s(" open: a-i a file", cOrange)}
		if len(m.openLinks) > 0 {
			left = []seg{s(" open: 1-9 the link with that number · a-i a file", cOrange)}
		}
		left = append(left, s(" · esc", cGrey))
	case mConfirm:
		left = []seg{s(" No local folder. Open it on GitHub? ", cOrange), s("enter/y yes · esc no", cGrey)}
		if m.trust != nil {
			left = []seg{s(" Claude Code does not trust "+tildify(m.trust.dir)+" yet. Trust it? ", cOrange),
				s("enter/y opens Claude Code there: answer it, then /exit · esc no", cGrey)}
		}
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
		if m.view == vTheme {
			code = "THEME"
		}
		if m.view == vChangelog {
			code = "CL"
		}
		left = []seg{s(" > ", cOrange), s(code, cWhite), s(" <GO>", cGrey)}
		if m.leader {
			left = append(left, s("   space…", cOrange), s("  "+m.leaderHint(), cGrey))
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
	// REMOTE: the active sessions on other machines, below DONE; the header stays when there are none
	head := " REMOTE"
	if m.remote.Err != "" {
		head += "   " + trunc(m.remote.Err, max(0, in-10))
	}
	body = append(body, "", row(in, s(head, cDark)))
	for _, r := range m.remote.Items {
		if r.ID == m.selSID {
			si = len(body)
		}
		body = append(body, m.remoteRow(in, r))
	}
	if vis := h - 2; len(body) > vis && si >= vis { // keep the selected row visible
		body = body[si-vis+1:]
	}
	return box(w, h, []seg{s("AGENTS", cGrey)}, cDark, body)
}

// remoteRow: one REMOTE session, laid out like an agent's row; ◇ marks it as not in a window of this Mac.
func (m model) remoteRow(in int, r RemoteSession) string {
	stateW, ageW := 8, 4
	nameW := in - 3 - stateW - ageW - 3
	name := trunc(r.Title, nameW)
	label := r.Label()
	st, ns := cDark, cGrey
	if r.needsYou() {
		st, ns = cOrange, cWhite
	}
	if r.ID == m.selSID {
		txt := fmt.Sprintf(" > %-*s %-*s %*s ", nameW, name, stateW, label, ageW, age(r.Updated))
		return row(in, s(padTo(txt, in), cSel))
	}
	return row(in, s(" ◇ ", cPlain), s(padTo(name, nameW), ns), s(" "+padTo(label, stateW), st), s(" "+fmt.Sprintf("%*s", ageW, age(r.Updated)), cDark))
}

// remotePanel: the selected REMOTE session: its state, then its conversation (read with this Mac's trusted-device
// token, D80), scrolled like an agent's; what it last said it did while none is read.
func (m model) remotePanel(r RemoteSession, w, h int) []string {
	in := w - 4
	title := []seg{s(r.Title, cWhite), s(" · remote", cGrey)}
	if r.Model != "" {
		title = append(title, s(" · "+r.Model, cGrey))
	}
	if r.CtxPct != "" {
		title = append(title, s(" · ctx "+r.CtxPct, cGrey))
	}
	st := cGrey
	if r.needsYou() {
		st = cOrange
	}
	msg := []string{row(in, s(r.Label(), st), s(" · "+age(r.Updated)+" ago", cDark)), row(in)}
	c, read := m.remoteChat[r.ID]
	switch {
	case len(c.Turns) > 0 || (read && c.Err == ""):
		msg = append(msg, chatLines(Last{Chat: c.Turns, Text: r.Summary}, in, m.cfg.Tables)...)
	case r.Summary != "":
		msg = append(msg, row(in, s("LAST THING IT SAID IT DID", cDark)))
		for _, l := range wrap(r.Summary, in) {
			msg = append(msg, row(in, s(l, cText)))
		}
	}
	var tail []string
	switch {
	case c.Err != "":
		for _, l := range wrap(c.Err, in) {
			tail = append(tail, row(in, s(l, cOrange)))
		}
	case !read:
		tail = append(tail, row(in, s("reading its messages…", cDark)))
	}
	K := m.cfg.Keys
	tail = append(tail, "", row(in, s("─ reply ", cDark), s(strings.Repeat("─", max(0, in-8)), cDark)))
	if m.mode == mTyping && m.ed.target == r.ID {
		tail = append(tail, m.ed.lines(in)...)
	} else {
		scroll := K.Older + "/" + K.Newer
		if K.Older == "up" && K.Newer == "down" {
			scroll = "↑↓"
		}
		tail = append(tail, row(in, s("> ", cOrange), s(K.Reply+" to write · "+scroll+" scroll · enter opens it on claude.ai/code", cDark)))
	}
	return box(w, h, title, cDark, m.panelBody(m.scroll, r.ID, false, msg, tail, in, h))
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
	if r := m.selRemote(); a == nil && r != nil {
		return m.remotePanel(*r, w, h)
	}
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
	if a.CLI != "" {
		title = append(title, s(" · "+a.CLI, cGrey))
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
			here := m.nwDir.Dir == m.nw.Dir // nwDir describes the folder of this box
			hd = "─ new background agent in " + dir
			if here && m.nwDir.Branch != "" {
				hd += " (" + m.nwDir.Branch + ")"
			}
			if o := m.nw.summary(); o != "" {
				hd += " · " + o
			}
			hd += " "
			if here && m.nwDir.Source != "" {
				who = append(who, trunc("folder: "+m.nwDir.Source, in))
			}
			if n := m.nwDir.note(); here && n != "" {
				who = append(who, trunc("⚠ "+n, in))
			}
		}
		tail = append(tail, "", row(in, s(hd, cOrange), s(strings.Repeat("─", max(0, in-width(hd))), cOrange)))
		for _, l := range who {
			if strings.HasPrefix(l, "⚠") { // the /NW folder warning
				tail = append(tail, row(in, s(l, cOrange)))
				continue
			}
			tail = append(tail, row(in, s(l, cGrey)))
		}
		tail = append(tail, m.ed.lines(in)...)
	} else {
		tail = append(tail, "", row(in, s("─ reply ", cDark), s(strings.Repeat("─", max(0, in-8)), cDark)))
	}
	switch {
	case newAgent:
	case a.canSend() && m.mode == mTyping && m.ed.target == a.SID:
		if _, names := m.helpers(a.SID, m.ed.ta.Value()); len(names) > 0 { // what enter will start first (D70)
			tail = append(tail, row(in, s("@"+strings.Join(names, " @")+" → new background agent in "+tildify(a.Cwd), cOrange)))
		}
		el := m.ed.lines(in)
		if m.canStop(a) && len(m.ed.comp) == 0 { // the hint under the box: what esc and enter do while it works (D79)
			el[len(el)-1] = row(in, s("it works: ⏎ queues it · esc stops its turn · ctrl+c closes the box · ↑ last message", cDark))
		}
		tail = append(tail, el...)
	case a.Bg:
		tail = append(tail, row(in, s("> ", cOrange), s(m.cfg.Keys.Reply+" to write · "+m.cfg.Keys.Goto+" opens its screen (ctrl+z there closes it) · /STOP stops it", cDark)))
	case !a.InTerminal:
		tail = append(tail, row(in, s("not a Terminal tab: look only", cDark)))
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
	msg := append(chatLines(l, in, m.cfg.Tables), m.echoLines(*a, in)...)
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

// recapsView: the agents with a recap, newest recap first, by name on the left; the selected one's recap on the
// right, in full.
func (m model) recapsView(h int) []string {
	rs := m.recaps()
	if len(rs) == 0 {
		return m.listBox("RECAPS", nil, h, "no recaps yet: Claude Code writes one when you come back to a session after a while")
	}
	lw, rw := recapWidths(m.w)
	left, right := m.recapList(rs, lw, h), m.recapPanel(rs[min(m.listSel, len(rs)-1)], rw, h)
	out := make([]string, h)
	for i := range out {
		out[i] = " " + left[i] + " " + right[i]
	}
	return out
}

// recapWidths: the RC view's name list and recap panel outer widths for a screen w wide.
func recapWidths(w int) (lw, rw int) {
	lw = min(max(w*30/100, 30), 44)
	return lw, w - lw - 2
}

// recapList: the RC view's list of names, each with how long ago its recap was written.
func (m model) recapList(rs []agentRecap, w, h int) []string {
	in := w - 2
	var body []string
	first := 0
	if vis := h - 2; m.listSel >= vis {
		first = m.listSel - vis + 1
	}
	for i := first; i < len(rs); i++ {
		a := " " + age(rs[i].last.RecapAt) + " "
		name := padTo(rs[i].agent.Name, max(1, in-3-width(a)))
		if i == m.listSel {
			body = append(body, row(in, s(padTo(" > "+name+a, in), cSel)))
			continue
		}
		body = append(body, row(in, s("   ", cPlain), s(name, cWhite), s(a, cDark)))
	}
	return box(w, h, []seg{s("RECAPS", cGrey)}, cDark, body)
}

// recapPanel: the selected agent's recap in full, with its folder; enter goes to the agent.
func (m model) recapPanel(r agentRecap, w, h int) []string {
	in := w - 4
	title := []seg{s(r.agent.Name, cWhite), s(" · "+age(r.last.RecapAt)+" ago", cDark)}
	msg := []string{row(in, s(tildify(r.agent.Cwd), cDark)), ""}
	for _, l := range wrap(r.last.Recap, in) {
		msg = append(msg, row(in, s(l, cGrey)))
	}
	K := m.cfg.Keys
	scroll := K.Older + "/" + K.Newer
	if K.Older == "up" && K.Newer == "down" {
		scroll = "↑↓"
	}
	tail := []string{"", row(in, s("enter goes to the agent · "+scroll+" scroll · esc desk", cDark))}
	id := r.agent.SID + "@" + r.last.RecapAt.String() // another agent, or a new recap, starts at the top
	return boxR(w, h, title, nil, cDark, m.panelBody(m.rcScroll, id, true, msg, tail, in, h))
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
	tail = append(tail, "")
	for i, q := range prQuick {
		how := " · a new agent works on it"
		switch q.act {
		case "merge":
			how = " · now, with gh pr merge (no agent)"
		case "close":
			how = " · now, with gh pr close (no agent)"
		}
		tail = append(tail, row(in, s(fmt.Sprint(i+1), cOrange), s(" "+q.label, cWhite), s(how, cDark)))
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
			for _, l := range wrap("agterm can't answer a "+strings.ReplaceAll(a.Kind, "_", " ")+": enter opens it in Paperclip", in) {
				tail = append(tail, row(in, s(l, cDark)))
			}
		}
	}
	box := "─ comment "
	if t := m.pcBoxTitle(); t != "" {
		box = t
	} else if t := m.pcHandTitle(); t != "" {
		box = t
	}
	tail = append(tail, "", row(in, s(box, cDark), s(strings.Repeat("─", max(0, in-width(box))), cDark)))
	if m.mode == mTyping && m.ed != nil && (m.ed.target == "pc:"+it.ID || pcNoteFor(m.ed.target, it.ID) || pcHandFor(m.ed.target, it.ID)) {
		tail = append(tail, m.ed.lines(in)...)
	} else {
		scroll := K.Older + "/" + K.Newer
		if K.Older == "up" && K.Newer == "down" {
			scroll = "↑↓"
		}
		hint := K.Reply + " comment · " + K.PCAgent + " agent · " + K.PCTerm + " agent with its screen · enter opens in Paperclip · " + scroll + " scroll"
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

// textBody lays the help page out in two columns: the key (or name) on the left, its text on the right. A text
// that does not fit wraps under itself, never back under the key; a "\n" in a text starts a new line there. A
// "## " line is a heading with a rule; a line with no tab is a plain paragraph (see helpLines).
func (m model) textBody(lines []string) []string {
	in := m.w - 6
	kw := 0
	for _, l := range lines {
		if k, _, ok := strings.Cut(l, "\t"); ok {
			kw = max(kw, width(k))
		}
	}
	kw = min(kw, in/3)
	dw := max(10, min(in-kw-2, 110)) // a line much longer than this is hard to read
	var body []string
	add := func(segs ...seg) { body = append(body, " "+row(in, segs...)+" ") }
	for _, l := range lines {
		switch k, d, ok := strings.Cut(l, "\t"); {
		case ok:
			first := true
			for _, part := range strings.Split(d, "\n") {
				for _, wl := range wrap(part, dw) {
					lead := s(strings.Repeat(" ", kw), cGrey)
					if first {
						lead = s(fmt.Sprintf("%-*s", kw, k), cWhite)
					}
					add(lead, s("  "+wl, cGrey))
					first = false
				}
			}
		case strings.HasPrefix(l, "## "):
			h := strings.TrimPrefix(l, "## ")
			add(s(h+" ", cWhite), s(strings.Repeat("─", max(0, min(in, kw+2+dw)-width(h)-1)), cDark))
		default:
			for _, wl := range wrap(l, in) {
				add(s(wl, cGrey))
			}
		}
	}
	return body
}

// leaderHint lists what the next key does while space waits for it.
func (m model) leaderHint() string {
	var parts []string
	for _, r := range m.cfg.Replies {
		if k, ok := strings.CutPrefix(r.Key, "space "); ok {
			parts = append(parts, k+" "+r.Label)
		}
	}
	if m.cfg.Keys.Waiting == " " {
		parts = append(parts, "space longest input")
	}
	return strings.Join(append(parts, "esc cancel"), " · ")
}

// helpView draws the help page from line m.helpOff on; the title says how to scroll when it does not all fit.
func (m model) helpView(h int) []string {
	body := m.textBody(m.pageLines())
	rows := max(1, h-2)
	off := min(max(m.helpOff, 0), max(0, len(body)-rows))
	name := "HELP"
	if m.view == vChangelog {
		name = "CHANGELOG"
	}
	title := []seg{s(name, cWhite)}
	if len(body) > rows {
		more := ""
		if off+rows < len(body) {
			more = " · more below"
		}
		title = append(title, s("  ↑ ↓ pgup pgdown home end scroll · esc back"+more, cGrey))
	}
	return indent(box(m.w-2, h, title, cDark, body[off:]))
}

// helpLines is the help page as lines for textBody: "## title" a heading, row2(key, text) a row, "" a gap, any
// other line a paragraph.
func (m model) helpLines() []string {
	K := m.cfg.Keys
	k := func(key string) string {
		if key == " " {
			return "space"
		}
		return key
	}
	row2 := func(key, what string) string { return key + "\t" + what }
	nwDefault := parseNW("", m.cfg).summary()
	if nwDefault == "" {
		nwDefault = "Claude Code's own defaults"
	}
	lines := []string{
		"## Views",
		"Push " + K.Command + ", write the code, push enter. esc goes back to the desk.",
		row2("IN", "inbox (the desk): all agents, and the selected one"),
		row2("FL", "the last 30 files the agents wrote about, newest first\nenter opens one"),
		row2("RP", "repos: the clones here and your GitHub repos\nthe 10 worked on last first, then all the others A–Z; the sync check's notes (work you can lose) in orange"),
		row2("RC", "recaps: the agents by name on the left, the selected one's recap in full on the right\nenter goes to the agent"),
		row2("PR", "the open pull requests that involve you on GitHub, the last updated first\n"+
			K.Reply+" opens one on the right (description, files, thread); "+K.Reply+" again comments: enter starts a new agent with your comment as its task\n"+
			"1 review it (a new agent) · 2 merge it (gh pr merge, no agent) · 3 close it (gh pr close, no agent)\n"+
			"enter opens it in the browser"),
		row2("PO", "proposals: enter shows · a approve · x reject · z hide 7 days\nthe tab is orange while some are open"),
		row2("PC", "Paperclip issues and company approvals, the selected one's thread on the right\n"+
			"1-9 answer what it asks (approve, decline, …) · "+K.Reply+" comment\n"+
			K.PCAgent+" / "+K.PCTerm+" hand the issue to a new background agent / one with its screen open (@Name: a running one)\n"+
			"enter opens it in the browser · the tab is orange while one needs you · more keys: Paperclip requests below"),
		"",
		"## Commands",
		"Typed in the same line as the views.",
		row2("NW folder", "start a background agent: write its first message, enter starts it\n"+
			"folder: a path, a folder in ~/bbq, or an agent's name; left out: the selected agent's\n"+
			"options after it, in any order: a model (opus sonnet haiku fable) · an effort (low … max) · a mode (plan auto bypass accept manual dontask)\n"+
			"e.g. NW soii sonnet high"),
		row2("cl in a shell", "cl [name] [prompt]: a background agent in that folder, on NW's options; agterm selects it when it shows"),
		row2("FIND words", "find a session: by its name, then by what was said in it (one message with all the words), then Claude picks (s)\nmore: Find below"),
		row2("STOP", "stop the selected background agent (its conversation stays)"),
		row2("BG", "move the selected Terminal session to the background: /exit, then claude --bg --resume with its id, name, model and mode; its tab closes\n"+
			"only when idle with an empty box and no menu · BG ALL moves every idle one and lists the skipped ones\n"+
			"lost: its background shells, a running /loop, subagents in flight, permissions given for this session, its scrollback"),
		row2("ALL group", "one message to a group of agents: waiting (INPUT and WAITING), input, idle or working\nagents with a menu on screen are left out"),
		row2("A3 or name", "select agent 3, or the first agent whose name starts so"),
		row2("CL", "the changelog: what changed, newest first, from DECISIONS.md (also CHANGELOG)"),
		row2("HELP", "this page"),
		row2("QUIT", "stop agterm (ctrl+c also stops it)"),
		"",
		"## New on 2026-10-22",
		row2("REMOTE chat", "the selected REMOTE session shows its whole conversation, read with this Mac's trusted device (Claude Code's /login enrolls it)\n"+
			"new messages come in every 5 s · "+k(K.Older)+" / "+k(K.Newer)+", pgup / pgdown, home / end scroll"),
		"",
		"## New on 2026-10-21",
		row2("esc", "the selected agent works: stop its turn, as esc in Claude Code (a zoom or panel closes first; a menu gets none)\n"+
			"in the box too: the box stays open with your text · a queued message runs as soon as the turn stops · a second esc within 5 s closes the box"),
		row2("instant", "a message shows in the conversation the moment you push enter, grey: sending…, sent, or queued while the agent works\nit goes once the transcript has it; a failed send becomes the draft again"),
		row2("↑ in the box", "an empty box: the last message sent to the agent, ready to edit (↑ again: the one before, ↓ back)\nenter sends it as a new message; pgup / pgdown scroll"),
		"",
		"## New on 2026-10-19",
		row2(K.Dismiss+" on IDLE", "an idle agent can be dismissed too, for a clean list\nit comes back when it works again"),
		row2("REMOTE", "below DONE: the connected sessions on other machines (Remote Control), active ones only, read every 30 s\n"+
			"this Mac's own windows are not listed: they are agents above\n"+
			k(K.Next)+" / "+k(K.Prev)+" walk into it · "+K.Reply+" writes to the selected one (sent with claude -p --cloud)\n"+
			"enter opens it on claude.ai/code"),
		row2("NW", "never guesses its folder: with none written it uses the selected agent's (an error when none is selected, NW ~ for home)\n"+
			"NW ./x and NW .. start at that folder; NW mis fits ~/bbq and the agents, and lists the folders if it fits several\n"+
			"the box shows the folder, its branch and where it came from; an orange ⚠ marks home, a non-repo and a worktree"),
		row2("THEME", "the accent color, now orange: pick one of 8 (orange amber green cyan blue violet magenta red)\n"+
			k(K.Next)+" / "+k(K.Prev)+" or 1-8 move, the whole screen shows the color under the cursor · enter saves it to keys.toml · esc keeps the old one\n"+
			"THEME green sets one at once"),
		row2("RC", "recaps in full: the agents by name on the left, the selected one's recap on the right"),
		row2("links", "cmd+click opens a link in the text"),
		row2("b, w in RP", "b: the repo's branches, local and on origin only, each against the default branch (+ahead −behind, merged), its upstream (↑ to push, not pushed, gone) and its worktree (⌂)\n"+
			"w: its worktrees with their branch and changed files\n"+
			"1 review it · 2 merge it · 3 fix it · "+K.Reply+" your own task: each a new background agent in the branch's worktree\n"+
			"f fetches origin · g opens GitHub (what b was)"),
		"",
		"## New on 2026-10-18",
		row2("2, 3 in PR", "2 merges it at once (gh pr merge, pinned to the commit shown; refuses on conflicts or failed or running checks)\n3 closes it at once (gh pr close)\nno agent, no confirm"),
		row2("space + key", "space waits for its second key with no time limit: the status line lists the keys, esc cancels, a key bound to nothing ends it\nit used to jump after half a second"),
		row2(strings.Replace(k(K.Waiting), "space", "space space", 1), "the agent in INPUT that has waited the longest (it was space alone)"),
		row2(K.Dismiss, "takes a waiting agent off the list, a background one too\nit keeps running and comes back when it has something new; it does not close the session (STOP stops a background agent)"),
		row2("NW, "+K.PCAgent+", "+K.PCTerm, "agents that agterm starts run on "+nwDefault+" (nw_model, nw_effort, nw_permission in keys.toml)\nwords after NW win"),
		row2(K.PCAgent+" / "+K.PCTerm+" in PC", "hand the selected issue to a new background agent / the same with its screen open, with your permissions\na box text that starts with @Name goes to a session that already runs"),
		row2("i in RP", "copy the path of the repo's folder, or of the selected file or folder"),
		row2("DONE", "an agent that finished with nothing left sits in its own section at the end of the list, below IDLE"),
		"",
		"## Desk",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous agent"),
		row2(strings.Replace(k(K.Waiting), "space", "space space", 1), "the agent in INPUT that has waited the longest\nspace waits for its second key, esc cancels"),
		row2(k(K.Older)+" / "+k(K.Newer), "scroll the agent's conversation a third of a page back / on\nalso when zoomed, and while writing on the draft's first / last line"),
		row2(K.Zoom, "the selected agent on the full screen, again (or esc) to go back"),
		row2("pgup / pgdown", "a page back / on"),
		row2("home / end", "the start / the newest line"),
		row2("1-9", "send that numbered answer"),
		row2(K.Quick, "an agent asks questions: take the recommended answer (★, the one the agent marks) of every question and submit\nit refuses when a question has none"),
		row2("enter, ←, →", "when the agent asks: confirm, previous / next part"),
		row2(K.Reply, "write a message (keys below)\nesc keeps it as a draft; sending it sends a window on monitor 1 back"),
		row2("esc", "stop the selected agent's turn while it works (D79)"),
		row2(K.Open+" then a-i", "open that file"),
		row2(K.Open+" then 1-9", "open a link in the browser: "+K.Open+" puts a number on each link on screen\n(Terminal.app ignores cmd+click on links); works in the PR and PC panels too"),
		row2(K.Goto, "show the agent's own Terminal window, where it is\na background agent (◦): its screen in a short-lived window; ctrl+z there closes it, the agent keeps running"),
		row2(K.Here, "bring its window to monitor 1 and into focus, to type in it\na prompt sends it back; a background agent: as "+K.Goto),
		row2(K.Dismiss, "remove a waiting or idle agent (a background one too) from the list, no answer\nit keeps running and comes back when it has something new"),
		row2(K.Refresh, "read all data again"),
		"",
		"## Writing a message",
		row2("enter", "send; to a working agent it is queued"),
		row2("↑ / ↓", "an empty box: the messages sent before, newest first"),
		row2("esc", "keep the draft and close; while the agent works: stop its turn, the box stays open"),
		row2("new line", "option+enter, ctrl+j, or \\ then enter"),
		row2("option+key", "your layout's character: option+l @, option+5 [, option+8 {, option+7 |"),
		row2("@ and /", "suggest the agent's files and the other sessions / commands; tab or enter takes one\na command with a screen of its own (/config, /mcp, /model with no name…) to a background agent opens its screen too"),
		row2("@Name text", "a message that starts with a live session's name goes to that session (@\"two words\" for names with spaces)\na mention elsewhere stays in the text, and the agent itself passes it on"),
		row2("@NewName", "a name that is no session yet: enter starts it first, as a background helper in the agent's folder\n(NW's model, effort, mode), then sends the message; the box shows it in orange before you send"),
		row2("ctrl+v", "paste a clipboard image (saved, its path goes in)"),
		row2("cmd+v", "paste text"),
		row2("option+arrows", "move by word"),
		row2("option+backspace", "delete a word"),
		"",
		"## Repos (RP)",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous repo"),
		row2("enter", "open its folder; on GitHub only: asks, then enter or y opens it on GitHub"),
		row2("b / w", "the repo's branches / worktrees (1 review · 2 merge · 3 fix · f fetch; more: New on 2026-10-19)"),
		row2("g, opt+enter", "open it on GitHub (option+enter; shift+enter too, where the terminal tells it from enter)"),
		row2(K.Reply, "its folders on the right: "+K.Reply+" goes into a folder or opens a file, h (or backspace) up, enter shows it in Finder, esc closes"),
		row2("i", "copy the path of the repo's folder, or of the selected file or folder in the panel (its GitHub URL without a clone)"),
		"",
		"## Paperclip requests (PC)",
		row2("1-9", "answer; in a list: tick the item; in a question: pick the option; with verdicts: give the current item that verdict"),
		row2("approvals", "1 approve · 2 reject · 3 request revision (needs a note) · 4 approve with a note · 5 reject with a note"),
		row2("s", "send the ticks, the answers or the verdicts"),
		row2("x / r", "decline a list of choices or tasks / decline with a reason (the box opens)"),
		row2("← / →", "the previous / next question or item"),
		row2("o", "write your own answer to a question (enter keeps it)"),
		row2("a", "questions: give every ★ recommended answer and send\nit says which question has none and sends nothing"),
		row2("n / p", "next / previous page of a long list"),
		"",
		"## Find (FIND words)",
		row2(k(K.Next)+" / "+k(K.Prev), "next / previous result"),
		row2("enter", "a live session: go to it on the desk\nan ended one: read the messages that match, with the message before and after (esc closes)"),
		row2("s", "ask Claude which sessions fit (it runs by itself when names and text find nothing)"),
		row2("r", "resume an ended session in the background, in its folder (claude --bg --resume)"),
		row2("LOGIN", "log Claude Code in, in a short-lived window (the footer says when it is logged out)"),
		"",
		"## Wall (push " + K.Wall + ")",
		row2("1-9", "select that tile"),
		row2(K.Zoom, "tile on the full screen, again to go back (then 1-9 answer)"),
		"",
		"## Fixed messages",
		"On the desk and the wall. The space ones: push space, then the key; no time limit, esc cancels.",
	}
	for _, r := range m.cfg.Replies {
		lines = append(lines, row2(r.Key, fmt.Sprintf("%q", r.Text)))
	}
	lines = append(lines, "",
		"## More",
		"Change keys, messages and how tables show (tables = auto, rule, grid or records) in "+tildify(configPath())+". Save: agterm reloads it.",
		"Full manual: ~/.claude/agent-terminal/docs/agent-terminal-manual.md")
	return lines
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
		add(&r1, strings.Replace(key(K.Waiting), "␣", "␣␣", 1), "longest input")
		add(&r1, "esc", "desk")
	case vPaperclip:
		add(&r1, K.Next+" "+K.Prev, "issue")
		for _, kv := range m.pcFooterKeys() { // the numbers, and the keys of a form
			add(&r1, kv[0], kv[1])
		}
		add(&r1, key(K.Older)+key(K.Newer), "scroll")
		add(&r1, K.Reply, "comment")
		add(&r1, K.PCAgent, "agent")
		add(&r1, K.PCTerm, "Terminal")
		add(&r1, K.Open, "link")
		add(&r1, "enter", "in browser")
		add(&r1, "esc", "desk")
	case vTheme:
		add(&r1, K.Next+" "+K.Prev, "color")
		add(&r1, "1-8", "jump")
		add(&r1, "enter", "save")
		add(&r1, "esc", "cancel")
	case vFind:
		for _, h := range m.findHints() {
			add(&r1, h[0], h[1])
		}
	case vPulls:
		add(&r1, K.Next+" "+K.Prev, "move")
		if m.prOpen {
			add(&r1, K.Reply, "comment → new agent")
			add(&r1, "1-3", "review / merge / close")
			add(&r1, key(K.Older)+key(K.Newer), "scroll")
			add(&r1, K.Open, "link")
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
		if m.branches != nil {
			add(&r1, "1-3", "review / merge / fix")
			add(&r1, K.Reply, "task → new agent")
			add(&r1, "f", "fetch")
			add(&r1, "g", "on GitHub")
			if m.branches.trees {
				add(&r1, "b", "branches")
			} else {
				add(&r1, "w", "worktrees")
			}
			add(&r1, "esc", "close")
		} else if m.tree != nil {
			add(&r1, K.Reply, "open")
			add(&r1, "h", "up")
			add(&r1, "enter", "in Finder")
			add(&r1, "g", "on GitHub")
			add(&r1, "esc", "close")
		} else {
			add(&r1, "enter", "open folder")
			add(&r1, K.Reply, "files")
			add(&r1, "b", "branches")
			add(&r1, "w", "worktrees")
			add(&r1, "g", "on GitHub")
			add(&r1, "i", "copy path")
			add(&r1, "esc", "desk")
			add(&r1, K.Command, "command")
		}
	case vRecaps:
		add(&r1, K.Next+" "+K.Prev, "agent")
		add(&r1, key(K.Older)+key(K.Newer), "scroll")
		add(&r1, "enter", "go to it")
		add(&r1, "esc", "desk")
		add(&r1, K.Command, "command")
	case vHelp, vChangelog:
		add(&r1, key(K.Older)+key(K.Newer), "scroll")
		add(&r1, "pgup pgdown", "page")
		add(&r1, "home end", "top/bottom")
		add(&r1, "esc", "desk")
		add(&r1, K.Command, "command")
	case vFiles, vProposals:
		add(&r1, K.Next+" "+K.Prev, "move")
		add(&r1, "enter", "open")
		add(&r1, "esc", "desk")
		add(&r1, K.Command, "command")
	default:
		if m.view == vDesk && !m.zoom && m.canStop(m.sel()) {
			add(&r1, "esc", "stop its turn")
		}
		add(&r1, "1-9", "answer")
		if a := m.sel(); a != nil && len(m.last(a).Ask) > 0 {
			add(&r1, K.Quick, "quick approve")
		}
		add(&r1, K.Next+" "+K.Prev, "next/prev")
		add(&r1, key(K.Older)+key(K.Newer), "scroll")
		add(&r1, K.Zoom, "zoom")
		add(&r1, strings.Replace(key(K.Waiting), "␣", "␣␣", 1), "longest input")
		add(&r1, K.Open, "open file/link")
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
	if m.loggedOut {
		u[0] = []seg{s("Claude Code is logged out · /LOGIN", cOrange)}
	}
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
