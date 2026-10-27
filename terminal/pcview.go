package main

// How the PC panel draws a request with a form (pcform.go keeps its state): the block at the bottom (what it asks,
// progress, the items, the keys) under the rows the panel has left, and the full text of the current item in the
// scrolling part above.

import (
	"fmt"
	"strconv"
	"strings"
)

// pcFormView is the form of request a for drawing: the shared one, or a throwaway where the model has no store.
func (m model) pcFormView(a *PCAsk) *pcForm {
	if m.pcForms == nil {
		return (&pcFormSet{}).of(a)
	}
	return m.pcForms.of(a)
}

// pcAnswerHint: the numbered answers' part of the panel's key line; a plain question with a recommendation adds
// the quick key.
func pcAnswerHint(a *PCAsk) string {
	h := "1-" + strconv.Itoa(len(a.Options)) + " answer · "
	if a.Spec != nil {
		if _, err := pcRecommended(a.Spec.Questions); err == nil {
			h += "a ★ answer · "
		}
	}
	return h
}

// pcCount: how many items the current page of the form lists (options of the current question, or all items).
func pcCount(sp *PCSpec, f *pcForm) int {
	if sp.Kind == "questions" {
		return len(sp.Questions[f.q].Options)
	}
	return len(sp.Items)
}

// pcHint: what each key does in this form, one line (the panel wraps it).
func pcHint(a *PCAsk, f *pcForm) string {
	sp := a.Spec
	var h []string
	paged := pcCount(sp, f) > f.rows()
	switch sp.Kind {
	case "checkbox", "tasks":
		send, no := sp.AcceptLabel, sp.RejectLabel
		if send == "" {
			send = "send"
		}
		if no == "" {
			no = "decline"
		}
		if sp.Kind == "tasks" {
			send, no = "accept ticked", "reject"
		}
		h = append(h, "1-9 tick")
		if paged {
			h = append(h, "n/p page")
		}
		h = append(h, "s "+trunc(send, 18), "x "+trunc(no, 18))
		if !sp.NoReason {
			h = append(h, "r "+trunc(no, 12)+" with a reason")
		}
	case "questions":
		q := sp.Questions[f.q]
		if !q.Text {
			h = append(h, "1-9 pick")
		}
		if len(sp.Questions) > 1 {
			h = append(h, "←→ question")
		}
		if paged {
			h = append(h, "n/p page")
		}
		if q.Other {
			h = append(h, "o write your own")
		}
		h = append(h, "s send")
		if _, err := pcRecommended(sp.Questions); err == nil {
			h = append(h, "a ★ answers, send")
		} else {
			for _, qq := range sp.Questions {
				for _, o := range qq.Options {
					if o.Rec {
						h = append(h, "a needs ★ on every question")
						return strings.Join(h, " · ")
					}
				}
			}
		}
	case "verdicts":
		for i, v := range sp.Verdicts {
			h = append(h, strconv.Itoa(i+1)+" "+v)
		}
		h = append(h, "←→ item")
		if paged {
			h = append(h, "n/p page")
		}
		h = append(h, "s send")
	}
	return strings.Join(h, " · ")
}

// pcProgress: the one line above the items.
func pcProgress(sp *PCSpec, f *pcForm) string {
	var t string
	switch sp.Kind {
	case "checkbox":
		t = fmt.Sprintf("%d of %d ticked", len(f.sel), len(sp.Items))
		switch {
		case sp.Min > 0 && sp.Max > 0:
			t += fmt.Sprintf(" · pick %d-%d", sp.Min, sp.Max)
		case sp.Min > 0:
			t += fmt.Sprintf(" · pick at least %d", sp.Min)
		case sp.Max > 0:
			t += fmt.Sprintf(" · pick up to %d", sp.Max)
		}
	case "tasks":
		t = fmt.Sprintf("%d of %d tasks ticked", len(f.sel), len(sp.Items))
	case "questions":
		q := sp.Questions[f.q]
		how := "pick one"
		switch {
		case q.Text:
			how = "write your answer"
		case q.Multi:
			how = "pick any"
		}
		if q.Required && !f.answered(f.q) {
			how += " (needed)"
		}
		t = fmt.Sprintf("question %d of %d · %s", f.q+1, len(sp.Questions), how)
		if len(sp.Questions) > 1 { // which questions have an answer
			t += " "
			for i := range sp.Questions {
				t += map[bool]string{true: "✓", false: "·"}[f.answered(i)]
			}
		}
	case "verdicts":
		decided := 0
		for _, it := range sp.Items {
			if _, done := sp.Done[it.ID]; done || f.verdict[it.ID] != "" {
				decided++
			}
		}
		t = fmt.Sprintf("item %d of %d · %d decided", f.cur+1, len(sp.Items), decided)
	}
	if n, r := pcCount(sp, f), f.rows(); n > r && sp.Kind != "verdicts" {
		t += fmt.Sprintf(" · page %d of %d", f.top/r+1, (n+r-1)/r)
	}
	return t
}

// pcSpecBlock is the bottom of the panel for a request with a form, in at most room rows: what it asks, the
// progress, the items on this page, the keys. It gives up the blank row, the title and prompt lines, then key
// lines, in that order, while the items would get fewer than 3 rows.
func (m model) pcSpecBlock(a *PCAsk, in, room int) []string {
	sp := a.Spec
	f := m.pcFormView(a)
	room = max(room, 1)
	var q PCQuestion
	if sp.Kind == "questions" {
		q = sp.Questions[f.q]
	}
	var prompt, qprompt []string
	if strings.TrimSpace(a.Prompt) != "" {
		prompt = wrap(a.Prompt, in)
	}
	if sp.Kind == "questions" {
		qprompt = wrap(q.Prompt, in)
	}
	hint := wrap(pcHint(a, f), in)
	n := pcCount(sp, f)
	extra := 0 // the row of the written answer
	if q.Other {
		extra = 1
	}
	blank, head, title := 1, 1, 0
	if a.Title != "" {
		title = 1
	}
	lp, lq, lh := min(len(prompt), 3), min(len(qprompt), 3), min(len(hint), 3)
	want := min(3, n)
	left := func() int { return room - blank - head - title - lp - lq - lh - 1 - extra }
	for _, step := range []func(){
		func() { blank = 0 },
		func() { lp, lq = min(lp, 2), min(lq, 2) },
		func() { title = 0 },
		func() { lp, lq, lh = min(lp, 1), min(lq, 1), min(lh, 2) },
		func() { lh = min(lh, 1) },
		func() { head = 0 },
		func() { lp = 0 },
	} {
		if left() >= want {
			break
		}
		step()
	}
	page := min(9, max(left(), 1))
	if n == 0 {
		page = 1
	}
	f.page = page
	switch {
	case sp.Kind == "verdicts":
		if f.cur < f.top {
			f.top = f.cur
		}
		if f.cur >= f.top+page {
			f.top = f.cur - page + 1
		}
	case n > 0:
		f.top = min(f.top, ((n-1)/page)*page)
	}

	var out []string
	if blank > 0 {
		out = append(out, "")
	}
	if head > 0 {
		out = append(out, row(in, s("IT ASKS YOU", cDark)))
	}
	if title > 0 {
		out = append(out, row(in, s(a.Title, cWhite)))
	}
	for _, l := range prompt[:lp] {
		out = append(out, row(in, s(l, cText)))
	}
	out = append(out, row(in, s(pcProgress(sp, f), cGrey)))
	for _, l := range qprompt[:lq] {
		out = append(out, row(in, s(l, cWhite)))
	}
	out = append(out, m.pcItemRows(a, f, in, page)...)
	for _, l := range hint[:lh] {
		out = append(out, row(in, s(l, cDark)))
	}
	return out
}

// pcItemRows lists the items of the page: tick boxes, the options of the current question, or the verdict list.
func (m model) pcItemRows(a *PCAsk, f *pcForm, in, page int) []string {
	sp := a.Spec
	var out []string
	switch sp.Kind {
	case "checkbox", "tasks":
		for i := f.top; i < min(f.top+page, len(sp.Items)); i++ {
			it := sp.Items[i]
			on := f.sel[it.ID]
			mark, ms, ts := "[ ]", cDark, cGrey
			if on {
				mark, ms, ts = "[x]", cOrange, cWhite
			}
			out = append(out, row(in, s(strconv.Itoa(i-f.top+1), cOrange), s(" "+mark+" ", ms), s(strings.Repeat("· ", min(it.Depth, 3))+it.Label, ts)))
		}
	case "questions":
		q := sp.Questions[f.q]
		for i := f.top; i < min(f.top+page, len(q.Options)); i++ {
			o := q.Options[i]
			on := false
			for _, p := range f.pick[f.q] {
				on = on || p == o.ID
			}
			off, tick := "( )", "(x)" // single choice: round; several: square
			if q.Multi {
				off, tick = "[ ]", "[x]"
			}
			mark, ms, ts := off, cDark, cGrey
			if on {
				mark, ms, ts = tick, cOrange, cWhite
			}
			segs := []seg{s(strconv.Itoa(i-f.top+1), cOrange), s(" "+mark+" ", ms), s(o.Label, ts)}
			if o.Rec {
				segs = append(segs, s(" ★", cOrange))
			}
			out = append(out, row(in, segs...))
		}
		if q.Other {
			text, st := "write your own answer", cGrey
			if t := strings.TrimSpace(f.other[f.q]); t != "" {
				text, st = "own answer: "+strings.ReplaceAll(t, "\n", " "), cWhite
			}
			out = append(out, row(in, s("o", cOrange), s("  "+text, st)))
		}
	case "verdicts":
		for i := f.top; i < min(f.top+page, len(sp.Items)); i++ {
			it := sp.Items[i]
			v, st := f.verdict[it.ID], cGrey
			if d, done := sp.Done[it.ID]; done { // given before: shown dim
				v, st = d, cDark
			} else if v == "reject" {
				st = cOrange
			}
			word := "·"
			if v != "" {
				word = v
			}
			cursor, ls := "  ", cGrey
			if i == f.cur {
				cursor, ls = "> ", cWhite
			}
			out = append(out, row(in, s(cursor, cOrange), s(padTo(word, 8)+" ", st), s(it.Label, ls)))
		}
	}
	return out
}

// pcSpecDetail is the text of the current item, in the scrolling part of the panel: the full labels and
// descriptions that a row cannot show.
func (m model) pcSpecDetail(a *PCAsk, in int) []string {
	sp := a.Spec
	f := m.pcFormView(a)
	var out []string
	rule := func(t string) {
		out = append(out, "", row(in, s("─ "+t+" ", cDark), s(strings.Repeat("─", max(0, in-width(t)-3)), cDark)))
	}
	para := func(text string, st seg) {
		for _, l := range collapse(wrap(plain(text), in)) {
			out = append(out, row(in, s(l, st.st)))
		}
	}
	switch sp.Kind {
	case "checkbox", "tasks":
		var lines []string
		for i, it := range sp.Items {
			if it.Desc == "" && width(it.Label)+6 <= in {
				continue
			}
			for j, l := range wrap(plain(it.Label), in-3-2*min(it.Depth, 3)) {
				num := "   "
				if j == 0 {
					num = fmt.Sprintf("%-3d", i+1)
				}
				lines = append(lines, row(in, s(num, cOrange), s(strings.Repeat("  ", min(it.Depth, 3))+l, cWhite)))
			}
			for _, l := range collapse(wrap(plain(it.Desc), in-3)) {
				lines = append(lines, row(in, s("   "+l, cDark)))
			}
		}
		if len(lines) > 0 {
			rule("items")
			out = append(out, lines...)
		}
	case "questions": // the prompt is in the bottom block; here what it cannot hold: a long prompt, the help, the descriptions
		q := sp.Questions[f.q]
		var lines []seg
		long := len(wrap(plain(q.Prompt), in)) > 2
		for i, o := range q.Options {
			if o.Desc != "" {
				lines = append(lines, s(fmt.Sprintf("%-3d", i+1), cOrange), s(o.Label+": ", cWhite), s(o.Desc, cDark))
			}
		}
		if long || q.Help != "" || len(lines) > 0 {
			rule(fmt.Sprintf("question %d of %d", f.q+1, len(sp.Questions)))
		}
		if long {
			para(q.Prompt, s("", cWhite))
		}
		if q.Help != "" {
			para(q.Help, s("", cDark))
		}
		for i := 0; i+2 < len(lines); i += 3 {
			out = append(out, row(in, lines[i], lines[i+1], lines[i+2]))
		}
	case "verdicts":
		it := sp.Items[f.cur]
		rule(fmt.Sprintf("item %d of %d", f.cur+1, len(sp.Items)))
		para(it.Label, s("", cWhite))
		if v, done := sp.Done[it.ID]; done {
			out = append(out, row(in, s("verdict given: "+v, cOrange)))
		}
		if it.Desc != "" {
			para(it.Desc, s("", cDark))
		}
		if it.Preview != "" {
			rows := textRows(it.Preview, in, m.cfg.Tables)
			const most = 14
			if len(rows) > most {
				out = append(out, "")
				out = append(out, rows[:most]...)
				out = append(out, row(in, s(fmt.Sprintf("… %d more lines: enter opens it in Paperclip", len(rows)-most), cDark)))
			} else {
				out = append(out, "")
				out = append(out, rows...)
			}
		}
		if it.Href != "" {
			out = append(out, row(in, s(it.Href, cDark)))
		}
	}
	return out
}
