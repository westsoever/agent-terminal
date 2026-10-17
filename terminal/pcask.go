package main

// The PC view's forms: the requests that need more than one number. What each kind carries and what it posts,
// read from the server source (@paperclipai/shared dist/validators/issue.js, server dist/services/
// issue-thread-interactions.js):
//   request_checkbox_confirmation  options[{id,label,description}], defaultSelectedOptionIds, minSelected, maxSelected,
//                                  acceptLabel, rejectLabel, rejectRequiresReason, allowDeclineReason
//     POST .../accept {selectedOptionIds}     tick; .../reject {reason}  decline
//   suggest_tasks                  tasks[{clientKey, parentClientKey, title, description}]; a child needs its parent
//     POST .../accept {} (all) or {selectedClientKeys}     .../reject {reason}
//   ask_user_questions             questions[{id, prompt, selectionMode single|multi, required, allowOther,
//                                  options[{id,label,freeText}]}]; payload.questionSet (runtime requests) adds
//                                  options[].recommended and answerMode text. The legacy projection drops both.
//     POST .../respond {answers:[{questionId, optionIds, otherText}]}   (the free-text option is never in optionIds)
//   request_item_verdicts          items[{id,label,description,previewMarkdown}], verdicts (approve, reject, defer),
//                                  requireReasonOn; result.items holds the verdicts already given
//     POST .../verdicts {verdicts:[{id, verdict, reason}]}   (some items at a time is allowed; no reject endpoint)
//   connection_intent and any other kind: kaching posts nothing, the browser answers.

import (
	"errors"
	"fmt"
	"strings"
)

// PCSpec is a request with a form: what to tick, step through or judge. Dynamic choices live in pcForm.
type PCSpec struct {
	Kind        string // checkbox, tasks, questions, verdicts
	Items       []PCSpecItem
	Min, Max    int      // checkbox: how many may be ticked (Max 0: no limit)
	Default     []string // checkbox: ticked when it opens
	AcceptLabel string   // what the request calls accepting, "" for send
	RejectLabel string
	ReasonLabel string // what the reason box asks for
	NeedReason  bool   // declining needs a reason
	NoReason    bool   // declining takes no reason
	Questions   []PCQuestion
	Verdicts    []string          // the verdicts, in the order of the number keys
	ReasonOn    map[string]bool   // the verdicts that need a reason
	Done        map[string]string // verdict items that already have a verdict: id -> verdict
	Sig         string            // changes when the request changes under the form, which then starts again
}

// PCSpecItem is a checkbox option, a suggested task or an item that waits for a verdict.
type PCSpecItem struct {
	ID, Label, Desc, Preview, Href string
	Parent                         string // tasks: the clientKey of the task it belongs under
	Depth                          int
}

// PCQuestion is one question of an ask_user_questions request.
type PCQuestion struct {
	ID, Prompt, Help string
	Multi, Required  bool
	Text             bool // a written answer only: no options
	Other            bool // a written answer may stand next to (or instead of) the options
	Options          []PCQOption
}

// PCQOption is one choice. Rec is the request's own recommendation.
type PCQOption struct {
	ID, Label, Desc string
	Rec             bool
}

type pcOptRaw struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description"`
}

// pcPayload is the part of an interaction's payload that kaching reads, for every kind.
type pcPayload struct {
	Prompt          string `json:"prompt"`
	DetailsMarkdown string `json:"detailsMarkdown"`
	Title           string `json:"title"`
	Questions       []struct {
		ID            string `json:"id"`
		Prompt        string `json:"prompt"`
		HelpText      string `json:"helpText"`
		SelectionMode string `json:"selectionMode"`
		Required      bool   `json:"required"`
		AllowOther    bool   `json:"allowOther"`
		Options       []struct {
			ID          string `json:"id"`
			Label       string `json:"label"`
			Description string `json:"description"`
			FreeText    bool   `json:"freeText"`
		} `json:"options"`
	} `json:"questions"`
	QuestionSet *struct {
		Questions []struct {
			ID         string `json:"id"`
			AnswerMode string `json:"answerMode"`
			Options    []struct {
				ID          string `json:"id"`
				Recommended bool   `json:"recommended"`
			} `json:"options"`
		} `json:"questions"`
	} `json:"questionSet"`
	// request_checkbox_confirmation
	Options              []pcOptRaw `json:"options"`
	DefaultSelected      []string   `json:"defaultSelectedOptionIds"`
	MinSelected          int        `json:"minSelected"`
	MaxSelected          *int       `json:"maxSelected"`
	AcceptLabel          string     `json:"acceptLabel"`
	RejectLabel          string     `json:"rejectLabel"`
	RejectRequiresReason bool       `json:"rejectRequiresReason"`
	RejectReasonLabel    string     `json:"rejectReasonLabel"`
	AllowDeclineReason   *bool      `json:"allowDeclineReason"`
	// suggest_tasks
	Tasks []struct {
		ClientKey       string `json:"clientKey"`
		ParentClientKey string `json:"parentClientKey"`
		Title           string `json:"title"`
		Description     string `json:"description"`
	} `json:"tasks"`
	// request_item_verdicts
	Items []struct {
		ID              string `json:"id"`
		Label           string `json:"label"`
		Description     string `json:"description"`
		PreviewMarkdown string `json:"previewMarkdown"`
		Href            string `json:"href"`
	} `json:"items"`
	Verdicts        []string `json:"verdicts"`
	RequireReasonOn []string `json:"requireReasonOn"`
	ReasonLabel     string   `json:"reasonLabel"`
	// connection_intent
	ServiceName         string `json:"serviceName"`
	RequestingAgentName string `json:"requestingAgentName"`
}

// pcResult is what an interaction holds once someone answered part of it (verdicts come in item by item).
type pcResult struct {
	Items []struct {
		ID      string `json:"id"`
		Verdict string `json:"verdict"`
	} `json:"items"`
}

// pcRecLabel: a label that ends in "(Recommended)" marks the recommended choice, as Claude Code's own questions
// do. It returns the label without the mark.
func pcRecLabel(label string) (string, bool) {
	l := strings.TrimSpace(label)
	const mark = "(recommended)"
	if len(l) >= len(mark) && strings.EqualFold(l[len(l)-len(mark):], mark) {
		if rest := strings.TrimSpace(l[:len(l)-len(mark)]); rest != "" {
			return rest, true
		}
	}
	return l, false
}

// pcSpecOf reads the form of an open interaction; nil for a kind that has none (and for a malformed one).
func pcSpecOf(in pcInteraction) *PCSpec {
	p := in.Payload
	sp := &PCSpec{}
	switch in.Kind {
	case "request_checkbox_confirmation":
		if len(p.Options) == 0 {
			return nil
		}
		sp.Kind, sp.Min, sp.Default = "checkbox", p.MinSelected, p.DefaultSelected
		if p.MaxSelected != nil {
			sp.Max = *p.MaxSelected
		}
		sp.AcceptLabel, sp.RejectLabel, sp.ReasonLabel = p.AcceptLabel, p.RejectLabel, p.RejectReasonLabel
		sp.NeedReason = p.RejectRequiresReason
		sp.NoReason = p.AllowDeclineReason != nil && !*p.AllowDeclineReason
		for _, o := range p.Options {
			sp.Items = append(sp.Items, PCSpecItem{ID: o.ID, Label: o.Label, Desc: o.Description})
		}
	case "suggest_tasks":
		if len(p.Tasks) == 0 {
			return nil
		}
		sp.Kind = "tasks"
		parent := map[string]string{}
		for _, t := range p.Tasks {
			parent[t.ClientKey] = t.ParentClientKey
		}
		for _, t := range p.Tasks {
			depth := 0
			for k := t.ParentClientKey; k != "" && depth < 8; k = parent[k] {
				depth++
			}
			sp.Items = append(sp.Items, PCSpecItem{ID: t.ClientKey, Label: t.Title, Desc: t.Description, Parent: t.ParentClientKey, Depth: depth})
		}
	case "request_item_verdicts":
		if len(p.Items) == 0 {
			return nil
		}
		sp.Kind, sp.ReasonLabel = "verdicts", p.ReasonLabel
		sp.Verdicts = p.Verdicts
		if len(sp.Verdicts) == 0 {
			sp.Verdicts = []string{"approve", "reject"}
		}
		on := p.RequireReasonOn
		if on == nil {
			on = []string{"reject"}
		}
		sp.ReasonOn = map[string]bool{}
		for _, v := range on {
			sp.ReasonOn[v] = true
		}
		sp.Done = map[string]string{}
		for _, r := range in.Result.Items {
			sp.Done[r.ID] = r.Verdict
		}
		for _, it := range p.Items {
			sp.Items = append(sp.Items, PCSpecItem{ID: it.ID, Label: it.Label, Desc: it.Description, Preview: it.PreviewMarkdown, Href: it.Href})
		}
	case "ask_user_questions":
		sp.Kind = "questions"
		sp.Questions = pcQuestionsOf(p)
		if len(sp.Questions) == 0 {
			return nil
		}
	default:
		return nil
	}
	ids := []string{in.Kind, in.ID}
	for _, it := range sp.Items {
		if _, done := sp.Done[it.ID]; done {
			ids = append(ids, it.ID)
		}
	}
	sp.Sig = strings.Join(ids, "|")
	return sp
}

// pcQuestionsOf reads the questions: the legacy list is what the server validates against, the question set (when
// the request has one) adds the recommendations and the written-answer questions.
func pcQuestionsOf(p pcPayload) []PCQuestion {
	rec, text := map[string]bool{}, map[string]bool{}
	if p.QuestionSet != nil {
		for _, q := range p.QuestionSet.Questions {
			text[q.ID] = q.AnswerMode == "text"
			for _, o := range q.Options {
				if o.Recommended {
					rec[q.ID+"/"+o.ID] = true
				}
			}
		}
	}
	var out []PCQuestion
	for _, q := range p.Questions {
		pq := PCQuestion{ID: q.ID, Prompt: strings.TrimSpace(q.Prompt), Help: strings.TrimSpace(q.HelpText),
			Multi: q.SelectionMode == "multi", Required: q.Required, Other: q.AllowOther}
		for _, o := range q.Options {
			if o.FreeText { // "Other": a written answer, never an option id
				pq.Other = true
				continue
			}
			label, byLabel := pcRecLabel(o.Label)
			pq.Options = append(pq.Options, PCQOption{ID: o.ID, Label: label, Desc: strings.TrimSpace(o.Description), Rec: rec[q.ID+"/"+o.ID] || byLabel})
		}
		if len(pq.Options) == 0 || text[q.ID] {
			pq.Text, pq.Other = true, true
		}
		out = append(out, pq)
	}
	return out
}

// pcPlainQuestion: one single-choice question with nothing to write: a number answers it at once.
func pcPlainQuestion(qs []PCQuestion) bool {
	return len(qs) == 1 && !qs[0].Multi && !qs[0].Other && !qs[0].Text
}

// pcRecommended gives the recommended answer to every question, or says which question has none. It never guesses:
// a question with no recommendation, or a single-choice question with two, is refused.
func pcRecommended(qs []PCQuestion) ([][]string, error) {
	out := make([][]string, len(qs))
	for i, q := range qs {
		var ids []string
		for _, o := range q.Options {
			if o.Rec {
				ids = append(ids, o.ID)
			}
		}
		where := fmt.Sprintf("question %d of %d (%s)", i+1, len(qs), trunc(q.Prompt, 40))
		switch {
		case len(ids) == 0:
			return nil, errors.New("no recommended answer for " + where + ": answer it yourself")
		case len(ids) > 1 && !q.Multi:
			return nil, errors.New("more than one recommended answer for " + where + ": pick one yourself")
		}
		out[i] = ids
	}
	return out, nil
}

// pcAnswersBody is the respond body for the chosen options and written answers (one slot per question).
func pcAnswersBody(qs []PCQuestion, pick [][]string, other []string) (map[string]any, error) {
	var answers []map[string]any
	for i, q := range qs {
		ids := []string{}
		if i < len(pick) {
			ids = append(ids, pick[i]...)
		}
		text := ""
		if i < len(other) {
			text = strings.TrimSpace(other[i])
		}
		if q.Required && len(ids) == 0 && text == "" {
			return nil, fmt.Errorf("question %d of %d needs an answer (%s)", i+1, len(qs), trunc(q.Prompt, 40))
		}
		a := map[string]any{"questionId": q.ID, "optionIds": ids}
		if text != "" {
			a["otherText"] = text
		}
		answers = append(answers, a)
	}
	return map[string]any{"answers": answers}, nil
}

// pcTickedBody is the accept body of a checkbox request: the ticked options, within its limits.
func pcTickedBody(sp *PCSpec, sel map[string]bool) (map[string]any, error) {
	ids := []string{}
	for _, it := range sp.Items {
		if sel[it.ID] {
			ids = append(ids, it.ID)
		}
	}
	if len(ids) < sp.Min {
		return nil, fmt.Errorf("tick at least %d option(s): %d ticked", sp.Min, len(ids))
	}
	if sp.Max > 0 && len(ids) > sp.Max {
		return nil, fmt.Errorf("tick no more than %d option(s): %d ticked", sp.Max, len(ids))
	}
	return map[string]any{"selectedOptionIds": ids}, nil
}

// pcTasksBody is the accept body of a suggest_tasks request: none when every task is ticked (all of them),
// else the ticked clientKeys.
func pcTasksBody(sp *PCSpec, sel map[string]bool) (map[string]any, int, error) {
	keys := []string{}
	for _, it := range sp.Items {
		if sel[it.ID] {
			keys = append(keys, it.ID)
		}
	}
	switch {
	case len(keys) == 0:
		return nil, 0, errors.New("tick at least one task to accept")
	case len(keys) == len(sp.Items):
		return map[string]any{}, len(keys), nil
	}
	return map[string]any{"selectedClientKeys": keys}, len(keys), nil
}

// pcVerdictsBody is the verdicts body for the items judged now (items that have a verdict already stay out).
func pcVerdictsBody(sp *PCSpec, verdict, reason map[string]string) (map[string]any, int, error) {
	var vs []map[string]any
	for _, it := range sp.Items {
		v := verdict[it.ID]
		if _, done := sp.Done[it.ID]; done || v == "" {
			continue
		}
		r := strings.TrimSpace(reason[it.ID])
		if sp.ReasonOn[v] && r == "" {
			return nil, 0, fmt.Errorf("%s needs a reason (%s)", v, trunc(it.Label, 40))
		}
		e := map[string]any{"id": it.ID, "verdict": v}
		if r != "" {
			e["reason"] = r
		}
		vs = append(vs, e)
	}
	if len(vs) == 0 {
		return nil, 0, errors.New("give at least one item a verdict first (1-" + fmt.Sprint(len(sp.Verdicts)) + ")")
	}
	return map[string]any{"verdicts": vs}, len(vs), nil
}
