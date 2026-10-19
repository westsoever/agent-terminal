package main

// The PC view's forms (pcask.go reads them): the choices made so far, the keys that make them, the answers that
// post them, and how the panel draws them. Keys, the same in every form:
//   1-9      tick / pick the item with that number; in verdicts, give the current item that verdict
//   left, right   the other question / item
//   n, p     the next / previous page, when there are more items than rows
//   s        send;  x  decline (tick lists);  r  decline with a reason;  o  write your own answer (questions)
//   a        questions only: give every recommended answer and send; refused when one question has none

import (
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

// pcForm is what the owner chose so far in one request. It lives under the request's id, so the 5-second reread of
// the panel keeps it; a request that changed under it (new sig) starts again.
type pcForm struct {
	sig     string
	page    int             // item rows the panel shows now (the renderer sets it); 0 before the first draw
	top     int             // the first item shown
	sel     map[string]bool // checkbox, tasks: the ticked ids
	q       int             // questions: the current one
	pick    [][]string      // questions: the options picked, per question
	other   []string        // questions: the written answer, per question
	cur     int             // verdicts: the current item
	verdict map[string]string
	reason  map[string]string
}

type pcFormSet struct{ forms map[string]*pcForm }

func newPCForm(sp *PCSpec) *pcForm {
	f := &pcForm{sig: sp.Sig, sel: map[string]bool{}, verdict: map[string]string{}, reason: map[string]string{}}
	switch sp.Kind {
	case "checkbox":
		for _, id := range sp.Default {
			f.sel[id] = true
		}
	case "tasks":
		for _, it := range sp.Items {
			f.sel[it.ID] = true
		}
	case "questions":
		f.pick, f.other = make([][]string, len(sp.Questions)), make([]string, len(sp.Questions))
	case "verdicts":
		for i, it := range sp.Items {
			if _, done := sp.Done[it.ID]; !done {
				f.cur = i
				break
			}
		}
	}
	return f
}

// of returns the form of the request a, a fresh one when there is none or the request changed.
func (s *pcFormSet) of(a *PCAsk) *pcForm {
	if s.forms == nil {
		s.forms = map[string]*pcForm{}
	}
	f := s.forms[a.ID]
	if f == nil || f.sig != a.Spec.Sig {
		f = newPCForm(a.Spec)
		s.forms[a.ID] = f
	}
	return f
}

func (f *pcForm) rows() int {
	if f.page > 0 {
		return f.page
	}
	return 9
}

// turn pages through n items; false when everything fits on one page.
func (f *pcForm) turn(n int, next bool) bool {
	r := f.rows()
	if n <= r {
		return false
	}
	if next {
		f.top = min(f.top+r, ((n-1)/r)*r)
	} else {
		f.top = max(f.top-r, 0)
	}
	return true
}

// toggle ticks or unticks an item. A task needs its parent: ticking one ticks its parents, unticking one
// unticks its children.
func (f *pcForm) toggle(sp *PCSpec, id string) {
	on := !f.sel[id]
	if !on {
		delete(f.sel, id)
	} else {
		f.sel[id] = true
	}
	if sp.Kind != "tasks" {
		return
	}
	parent := map[string]string{}
	for _, it := range sp.Items {
		parent[it.ID] = it.Parent
	}
	if on {
		for p := parent[id]; p != ""; p = parent[p] {
			f.sel[p] = true
		}
		return
	}
	for changed := true; changed; {
		changed = false
		for _, it := range sp.Items {
			if f.sel[it.ID] && it.Parent != "" && !f.sel[it.Parent] {
				delete(f.sel, it.ID)
				changed = true
			}
		}
	}
}

// choose picks option i of the current question. A single-choice pick drops the written answer and goes on to the
// next question.
func (f *pcForm) choose(sp *PCSpec, i int) {
	q := sp.Questions[f.q]
	id := q.Options[i].ID
	if q.Multi {
		for j, p := range f.pick[f.q] {
			if p == id {
				f.pick[f.q] = append(f.pick[f.q][:j:j], f.pick[f.q][j+1:]...)
				return
			}
		}
		f.pick[f.q] = append(f.pick[f.q], id)
		return
	}
	f.pick[f.q], f.other[f.q] = []string{id}, ""
	f.advance(sp)
}

func (f *pcForm) advance(sp *PCSpec) {
	if f.q < len(sp.Questions)-1 {
		f.q++
		f.top = 0
	}
}

func (f *pcForm) answered(i int) bool {
	return len(f.pick[i]) > 0 || strings.TrimSpace(f.other[i]) != ""
}

// pcOwnKey: false when the owner gave the key to the list or the comment box in keys.toml.
func pcOwnKey(ks string, K Keys) bool { return ks != K.Next && ks != K.Prev && ks != K.Reply }

// pcAskKey handles the keys of a request with a form. handled false: the key is none of its keys.
func (m *model) pcAskKey(ks string) (tea.Cmd, bool) {
	it := m.pcSelected()
	if it == nil {
		return nil, false
	}
	d, ok := m.pcDet[it.ID]
	if !ok || d.Err != "" || d.Ask == nil || d.Ask.Spec == nil {
		return nil, false
	}
	a := d.Ask
	digit := len(ks) == 1 && ks[0] >= '1' && ks[0] <= '9'
	if !digit && ks != "left" && ks != "right" && !pcOwnKey(ks, m.cfg.Keys) {
		return nil, false
	}
	if len(a.Options) > 0 && ks != "a" { // a plain question: the numbers answer at once (pcAnswer)
		return nil, false
	}
	if m.pcForms == nil {
		m.pcForms = &pcFormSet{}
	}
	f := m.pcForms.of(a)
	switch a.Spec.Kind {
	case "checkbox", "tasks":
		return m.pcTickKey(*it, a, f, ks, digit)
	case "questions":
		return m.pcQuestionKey(*it, a, f, ks, digit)
	case "verdicts":
		return m.pcVerdictKey(*it, a, f, ks, digit)
	}
	return nil, false
}

func (m *model) pcTickKey(it PCItem, a *PCAsk, f *pcForm, ks string, digit bool) (tea.Cmd, bool) {
	sp := a.Spec
	switch {
	case digit:
		n := int(ks[0] - '0')
		if i := f.top + n - 1; n <= f.rows() && i < len(sp.Items) {
			f.toggle(sp, sp.Items[i].ID)
		} else {
			m.setErr(fmt.Sprintf("no item %d on this page", n))
		}
		return nil, true
	case ks == "n" || ks == "p":
		return nil, f.turn(len(sp.Items), ks == "n")
	case ks == "s":
		return m.pcSend(it, a, f), true
	case ks == "x":
		if sp.NeedReason {
			return m.pcBox(it, "d", ""), true
		}
		return m.pcPostCmd(it, a, "reject", map[string]any{}, "declined"), true
	case ks == "r":
		if sp.NoReason {
			m.setErr("this request takes no reason: x declines it")
			return nil, true
		}
		return m.pcBox(it, "d", ""), true
	}
	return nil, false
}

func (m *model) pcQuestionKey(it PCItem, a *PCAsk, f *pcForm, ks string, digit bool) (tea.Cmd, bool) {
	sp := a.Spec
	q := sp.Questions[f.q]
	switch {
	case digit:
		n := int(ks[0] - '0')
		i := f.top + n - 1
		switch {
		case q.Text:
			m.setErr(fmt.Sprintf("question %d takes a written answer: o writes it", f.q+1))
		case n > f.rows() || i >= len(q.Options):
			m.setErr(fmt.Sprintf("question %d has no option %d on this page", f.q+1, n))
		default:
			f.choose(sp, i)
		}
		return nil, true
	case ks == "left":
		if f.q > 0 {
			f.q, f.top = f.q-1, 0
		}
		return nil, true
	case ks == "right":
		f.advance(sp)
		return nil, true
	case ks == "n" || ks == "p":
		return nil, f.turn(len(q.Options), ks == "n")
	case ks == "o":
		if !q.Other {
			m.setErr(fmt.Sprintf("question %d takes no written answer", f.q+1))
			return nil, true
		}
		return m.pcBox(it, fmt.Sprintf("q%d", f.q), f.other[f.q]), true
	case ks == "s":
		return m.pcSend(it, a, f), true
	case ks == "a":
		pick, err := pcRecommended(sp.Questions)
		if err != nil {
			m.setErr(pcRef(it) + ": " + err.Error())
			return nil, true
		}
		body, err := pcAnswersBody(sp.Questions, pick, nil)
		if err != nil {
			m.setErr(pcRef(it) + ": " + err.Error())
			return nil, true
		}
		return m.pcPostCmd(it, a, "respond", body, "recommended answers sent"), true
	}
	return nil, false
}

func (m *model) pcVerdictKey(it PCItem, a *PCAsk, f *pcForm, ks string, digit bool) (tea.Cmd, bool) {
	sp := a.Spec
	item := sp.Items[f.cur]
	switch {
	case digit:
		n := int(ks[0] - '0')
		if n > len(sp.Verdicts) {
			m.setErr(fmt.Sprintf("no verdict %d: 1-%d", n, len(sp.Verdicts)))
			return nil, true
		}
		if v, done := sp.Done[item.ID]; done {
			m.setErr(fmt.Sprintf("%s has its verdict already (%s)", trunc(item.Label, 30), v))
			return nil, true
		}
		if v := sp.Verdicts[n-1]; sp.ReasonOn[v] { // the verdict counts once its reason is written
			return m.pcBox(it, fmt.Sprintf("v%d.%d", f.cur, n), f.reason[item.ID]), true
		}
		f.verdict[item.ID] = sp.Verdicts[n-1]
		delete(f.reason, item.ID)
		f.next(sp)
		return nil, true
	case ks == "left":
		f.cur = max(0, f.cur-1)
		return nil, true
	case ks == "right":
		f.cur = min(len(sp.Items)-1, f.cur+1)
		return nil, true
	case ks == "n" || ks == "p":
		f.cur = min(max(0, f.cur+map[bool]int{true: f.rows(), false: -f.rows()}[ks == "n"]), len(sp.Items)-1)
		return nil, true
	case ks == "s":
		return m.pcSend(it, a, f), true
	}
	return nil, false
}

// next moves to the next item without a verdict, or stays on the last one.
func (f *pcForm) next(sp *PCSpec) {
	for j := f.cur + 1; j < len(sp.Items); j++ {
		if _, done := sp.Done[sp.Items[j].ID]; !done && f.verdict[sp.Items[j].ID] == "" {
			f.cur = j
			return
		}
	}
}

// pcFormPost is the answer a form gives now: the interaction's endpoint, its body, and what the command line
// reports. An error says what is missing.
func pcFormPost(a *PCAsk, f *pcForm) (path string, body map[string]any, what string, err error) {
	sp := a.Spec
	switch sp.Kind {
	case "checkbox":
		if body, err = pcTickedBody(sp, f.sel); err != nil {
			return
		}
		return "accept", body, fmt.Sprintf("sent %d ticked", len(body["selectedOptionIds"].([]string))), nil
	case "tasks":
		var n int
		if body, n, err = pcTasksBody(sp, f.sel); err != nil {
			return
		}
		return "accept", body, fmt.Sprintf("accepted %d of %d tasks", n, len(sp.Items)), nil
	case "questions":
		if body, err = pcAnswersBody(sp.Questions, f.pick, f.other); err != nil {
			return
		}
		return "respond", body, fmt.Sprintf("sent %d answer(s)", len(sp.Questions)), nil
	case "verdicts":
		var n int
		if body, n, err = pcVerdictsBody(sp, f.verdict, f.reason); err != nil {
			return
		}
		what = fmt.Sprintf("sent %d verdict(s)", n)
		if left := len(sp.Items) - len(sp.Done) - n; left > 0 {
			what += fmt.Sprintf(", %d left", left)
		}
		return "verdicts", body, what, nil
	}
	return "", nil, "", errors.New("agterm can't send this answer")
}

// pcSend posts what the form holds, or says what is missing.
func (m *model) pcSend(it PCItem, a *PCAsk, f *pcForm) tea.Cmd {
	path, body, what, err := pcFormPost(a, f)
	if err != nil {
		m.setErr(pcRef(it) + ": " + err.Error())
		return nil
	}
	return m.pcPostCmd(it, a, path, body, what)
}

// pcPostCmd posts body to the open request's endpoint (accept, reject, respond, verdicts) in the background.
func (m *model) pcPostCmd(it PCItem, a *PCAsk, path string, body map[string]any, what string) tea.Cmd {
	id, ref, aid := it.ID, pcRef(it), a.ID
	m.setStatus(what + " → " + ref + "…")
	return func() tea.Msg {
		if err := pcPost("/api/issues/"+url.PathEscape(id)+"/interactions/"+url.PathEscape(aid)+"/"+path, body); err != nil {
			return pcActedMsg{ref, what, err.Error()}
		}
		return pcActedMsg{ref, what, ""}
	}
}

// pcBox opens the writing box for the selected row. slot says what the text is for: "d" a decline reason, "q<i>"
// the written answer to question i, "v<i>.<n>" the reason for verdict n on item i.
func (m *model) pcBox(it PCItem, slot, prefill string) tea.Cmd {
	target := "pcno:" + it.ID + "@" + slot
	if prefill != "" {
		m.ed.drafts[target] = prefill
	}
	m.mode = mTyping
	return m.ed.open(target, "", m.editorWidth())
}

// pcNoteSlot: the box target's suffix for numbered option n. A decline with a reason on a confirmation keeps the
// plain target; the notes of an approval say which answer they belong to.
func pcNoteSlot(o PCOption, n int) string {
	if o.Arg == "" {
		return ""
	}
	return "#" + strconv.Itoa(n)
}

// pcNoteTarget splits a box target into the row id and what the text is for: "" (a decline on a confirmation),
// "#n" (note for option n) or "@slot" (see pcBox).
func pcNoteTarget(target string) (id, slot string, ok bool) {
	rest, ok := strings.CutPrefix(target, "pcno:")
	if !ok {
		return "", "", false
	}
	if i := strings.LastIndexAny(rest, "#@"); i >= 0 {
		return rest[:i], rest[i:], true
	}
	return rest, "", true
}

// pcNoteFor: the box is open for the row id.
func pcNoteFor(target, id string) bool {
	got, _, ok := pcNoteTarget(target)
	return ok && got == id
}

// pcOptDone is the option's label without the parenthesis, for the line that reports it.
func pcOptDone(label string) string {
	l, _, _ := strings.Cut(label, " (")
	return l
}

// pcNoteSend is what the owner wrote in the box of a request: it posts the answer the note belongs to, or sets
// the written answer / the reason in the form.
func (m *model) pcNoteSend(target, text string) tea.Cmd {
	id, slot, _ := pcNoteTarget(target)
	it := PCItem{ID: id}
	for _, x := range m.pc.Items {
		if x.ID == id {
			it = x
		}
	}
	d := m.pcDet[id]
	ref, ask := pcRef(it), d.Ask
	if ref == "" {
		ref = d.Ref
	}
	if ask == nil {
		m.setErr(ref + ": that request is gone")
		return nil
	}
	post := func(n int, what string) tea.Cmd {
		m.setStatus(what + " → " + ref + "…")
		return func() tea.Msg {
			if err := pcAct(id, ask, n, text); err != nil {
				return pcActedMsg{ref, what, err.Error()}
			}
			return pcActedMsg{ref, what, ""}
		}
	}
	switch {
	case slot == "": // a decline with its reason, on a confirmation
		n := 0
		for i, o := range ask.Options {
			if o.Action == "reason" {
				n = i + 1
			}
		}
		return post(n, "declined")
	case slot[0] == '#': // a numbered answer with a note
		n, _ := strconv.Atoi(slot[1:])
		if n < 1 || n > len(ask.Options) {
			m.setErr(ref + ": no such answer")
			return nil
		}
		return post(n, pcOptDone(ask.Options[n-1].Label))
	}
	if ask.Spec == nil {
		m.setErr(ref + ": that request has no form")
		return nil
	}
	if m.pcForms == nil {
		m.pcForms = &pcFormSet{}
	}
	f, sp := m.pcForms.of(ask), ask.Spec
	switch slot[1] {
	case 'd': // a decline reason on a tick list
		return m.pcPostCmd(it, ask, "reject", map[string]any{"reason": strings.TrimSpace(text)}, "declined")
	case 'q': // the written answer to a question
		if i, err := strconv.Atoi(slot[2:]); err == nil && i >= 0 && i < len(sp.Questions) {
			q := sp.Questions[i]
			f.other[i] = strings.TrimSpace(text)
			if !q.Multi {
				f.pick[i] = nil
			}
			if f.q == i && !q.Multi {
				f.advance(sp)
			}
			m.setStatus(fmt.Sprintf("answer to question %d kept: s sends them all", i+1))
		}
	case 'v': // the reason for a verdict
		i, n, _ := strings.Cut(slot[2:], ".")
		ii, e1 := strconv.Atoi(i)
		nn, e2 := strconv.Atoi(n)
		if e1 == nil && e2 == nil && ii >= 0 && ii < len(sp.Items) && nn >= 1 && nn <= len(sp.Verdicts) {
			f.cur = ii
			f.verdict[sp.Items[ii].ID] = sp.Verdicts[nn-1]
			f.reason[sp.Items[ii].ID] = strings.TrimSpace(text)
			f.next(sp)
			m.setStatus(fmt.Sprintf("%s: %s kept", trunc(sp.Items[ii].Label, 30), sp.Verdicts[nn-1]))
		}
	}
	return nil
}

// pcBoxTitle is the title of the writing box while a PC request's box is open, else "".
func (m model) pcBoxTitle() string {
	if m.mode != mTyping {
		return ""
	}
	id, slot, ok := pcNoteTarget(m.ed.target)
	if !ok {
		return ""
	}
	d := m.pcDet[id]
	switch {
	case slot == "":
		return "─ why you decline (enter declines) "
	case slot[0] == '#':
		if n, err := strconv.Atoi(slot[1:]); err == nil && d.Ask != nil && n >= 1 && n <= len(d.Ask.Options) {
			return "─ note: " + pcOptDone(d.Ask.Options[n-1].Label) + " (enter sends) "
		}
		return "─ your note (enter sends) "
	}
	if d.Ask == nil || d.Ask.Spec == nil {
		return "─ your note (enter sends) "
	}
	sp := d.Ask.Spec
	switch slot[1] {
	case 'd':
		if sp.ReasonLabel != "" {
			return "─ " + sp.ReasonLabel + " (enter declines) "
		}
		return "─ why you decline (enter declines) "
	case 'q':
		n, _ := strconv.Atoi(slot[2:])
		return "─ your own answer to question " + strconv.Itoa(n+1) + " (enter keeps it) "
	case 'v':
		if sp.ReasonLabel != "" {
			return "─ " + sp.ReasonLabel + " (enter keeps it) "
		}
		return "─ why (enter keeps it) "
	}
	return "─ your note (enter sends) "
}

// pcFooterKeys are the footer's key hints for the selected request: the numbers, and the form's own keys.
func (m model) pcFooterKeys() [][2]string {
	answer := [][2]string{{"1-9", "answer"}}
	it := m.pcSelected()
	if it == nil {
		return answer
	}
	d := m.pcDet[it.ID]
	if d.Ask == nil || d.Ask.Spec == nil {
		return answer
	}
	a, sp := d.Ask, d.Ask.Spec
	var keys [][2]string
	switch sp.Kind {
	case "checkbox", "tasks":
		keys = [][2]string{{"1-9", "tick"}, {"s", "send"}, {"x", "decline"}, {"r", "decline+why"}}
	case "questions":
		_, ready := pcRecommended(sp.Questions)
		switch {
		case len(a.Options) > 0: // plain: a number answers at once
			keys = [][2]string{{"1-9", "answer"}}
			if ready == nil {
				keys = append(keys, [2]string{"a", "★ answer"})
			}
		default:
			keys = [][2]string{{"1-9", "pick"}}
			if len(sp.Questions) > 1 {
				keys = append(keys, [2]string{"←→", "question"})
			}
			for _, q := range sp.Questions {
				if q.Other {
					keys = append(keys, [2]string{"o", "own answer"})
					break
				}
			}
			keys = append(keys, [2]string{"s", "send"})
			if ready == nil {
				keys = append(keys, [2]string{"a", "★ answers"})
			}
		}
	case "verdicts":
		keys = [][2]string{{"1-" + strconv.Itoa(len(sp.Verdicts)), "verdict"}, {"←→", "item"}, {"s", "send"}}
	}
	return keys
}
