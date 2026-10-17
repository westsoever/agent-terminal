package main

// Company approvals in the PC view: hiring an agent, a budget over its limit, a CEO strategy, a request to the
// board. They are not issue interactions. Read from the server source (@paperclipai/server dist/routes/approvals.js
// and attention.js, shared dist/validators/approval.js):
//   attention feed   sourceKind "approval", subject {kind "approval", id, title, href /<PREFIX>/approvals/<id>,
//                    metadata {type, requestedByAgentId, issueId}}; only status pending shows there
//   GET  /api/approvals/:id            the row: type, status, payload (redacted), requestedByAgentId, createdAt
//   GET  /api/approvals/:id/comments   the thread, oldest first: {authorAgentId, authorUserId, body, createdAt}
//   GET  /api/approvals/:id/issues     the issues it is linked to
//   POST /api/approvals/:id/approve|reject|request-revision {decisionNote}    pending (or revision requested) only
//   POST /api/approvals/:id/comments {body}
// The row's id in the PC list is "approval:<id>", so every issue-keyed place (panel, comment, answers) tells the
// two apart without a new field.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

const pcApprovalPrefix = "approval:"

// pcApprovalID returns the approval's own id for a PC row id, and whether the row is an approval.
func pcApprovalID(id string) (string, bool) { return strings.CutPrefix(id, pcApprovalPrefix) }

// pcApprovalKinds names an approval's type in the list's status column (11 cells).
var pcApprovalKinds = map[string]string{"hire_agent": "hire agent", "approve_ceo_strategy": "ceo plan",
	"budget_override_required": "budget", "request_board_approval": "board ask"}

func pcApprovalKind(typ string) string {
	if k, ok := pcApprovalKinds[typ]; ok {
		return k
	}
	if typ == "" {
		return "approval"
	}
	return strings.ReplaceAll(typ, "_", " ")
}

// pcInlineApproval: Paperclip's own inbox gives request_board_approval no approve button (attention.js sets
// inlineResolvable false): it carries a reviewed tool action that the approval page shows. kaching follows it.
func pcInlineApproval(typ string) bool { return typ != "request_board_approval" }

// pcApprovalInfo reads the company's pending approvals for the payloads (the feed gives only a title). It asks
// only when the attention feed holds an approval.
func pcApprovalInfo(ctx context.Context, companyID string, att pcAttention) map[string]pcApprovalRaw {
	found := false
	for _, a := range att.Items {
		found = found || a.SourceKind == "approval"
	}
	if !found {
		return nil
	}
	var list []pcApprovalRaw
	if pcGet(ctx, "/api/companies/"+url.PathEscape(companyID)+"/approvals?status=pending", &list) != nil {
		return nil // the rows keep the feed's titles
	}
	info := map[string]pcApprovalRaw{}
	for _, ap := range list {
		info[ap.ID] = ap
	}
	return info
}

// pcApprovalRow is the list row of a pending approval from the attention feed; info (when there is some) names it.
func pcApprovalRow(c pcCompany, subj pcSubject, whyNow string, names map[string]string, info map[string]pcApprovalRaw) PCItem {
	typ := subj.Metadata.Type
	ap, known := info[subj.ID]
	if known {
		typ = ap.Type
	}
	it := PCItem{ID: pcApprovalPrefix + subj.ID, Ref: "APPROVAL", Title: subj.Title, Status: pcApprovalKind(typ),
		Detail: whyNow, Needs: true}
	if known {
		it.Title = pcApprovalTitle(ap.Type, ap.Payload, subj.Title)
	}
	if it.Title == "" {
		it.Title = it.Status
	}
	it.Agent = names[subj.Metadata.RequestedByAgentID]
	href := subj.Href
	if href == "" && c.IssuePrefix != "" {
		href = "/" + c.IssuePrefix + "/approvals/" + subj.ID
	}
	if href != "" {
		it.URL = pcBase + href
	}
	return it
}

// pcRef is what messages call a row: its reference, or for an approval its title (APPROVAL says too little).
func pcRef(it PCItem) string {
	if _, ok := pcApprovalID(it.ID); ok && it.Title != "" {
		return "approval: " + trunc(it.Title, 28)
	}
	return it.Ref
}

type pcApprovalRaw struct {
	ID                 string         `json:"id"`
	Type               string         `json:"type"`
	Status             string         `json:"status"`
	Payload            map[string]any `json:"payload"`
	RequestedByAgentID string         `json:"requestedByAgentId"`
	DecisionNote       string         `json:"decisionNote"`
	CreatedAt          time.Time      `json:"createdAt"`
}

type pcApprovalCommentRaw struct {
	AuthorAgentID string    `json:"authorAgentId"`
	AuthorUserID  string    `json:"authorUserId"`
	Body          string    `json:"body"`
	CreatedAt     time.Time `json:"createdAt"`
}

// loadPCApproval reads one approval's panel: its payload as the request, its thread, the issues it belongs to.
func loadPCApproval(aid, rowID string, names map[string]string) PCDetail {
	d := PCDetail{ID: rowID, At: time.Now()}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	esc := url.PathEscape(aid)
	var (
		ap     pcApprovalRaw
		cms    []pcApprovalCommentRaw
		issues []pcIssue
		errs   [3]error
		wg     sync.WaitGroup
	)
	wg.Add(3)
	go func() { defer wg.Done(); errs[0] = pcGet(ctx, "/api/approvals/"+esc, &ap) }()
	go func() { defer wg.Done(); errs[1] = pcGet(ctx, "/api/approvals/"+esc+"/comments", &cms) }()
	go func() { defer wg.Done(); errs[2] = pcGet(ctx, "/api/approvals/"+esc+"/issues", &issues) }()
	wg.Wait()
	if errs[0] != nil {
		d.Err = pcErr(errs[0])
		return d
	}
	title := pcApprovalTitle(ap.Type, ap.Payload, "")
	d.Ref, d.Title, d.Status = "approval: "+trunc(title, 28), title, ap.Status
	sort.SliceStable(cms, func(i, j int) bool { return cms[i].CreatedAt.Before(cms[j].CreatedAt) })
	if len(cms) > pcMaxComments {
		cms = cms[len(cms)-pcMaxComments:]
	}
	for _, c := range cms {
		pc := PCComment{Body: strings.TrimSpace(c.Body), At: c.CreatedAt}
		switch {
		case c.AuthorAgentID != "":
			if pc.Author = names[c.AuthorAgentID]; pc.Author == "" {
				pc.Author = "agent"
			}
		case c.AuthorUserID != "":
			pc.Author, pc.Board = "you", true
		default:
			pc.Author = "system"
		}
		d.Comments = append(d.Comments, pc)
	}

	var head []string
	who := names[ap.RequestedByAgentID]
	switch {
	case who != "" && !ap.CreatedAt.IsZero():
		head = append(head, fmt.Sprintf("Asked by %s, %s ago.", who, age(ap.CreatedAt)))
	case !ap.CreatedAt.IsZero():
		head = append(head, fmt.Sprintf("Asked %s ago.", age(ap.CreatedAt)))
	}
	for _, is := range issues {
		head = append(head, "Linked issue: "+strings.TrimSpace(is.Identifier+" "+is.Title))
	}
	body := pcApprovalText(ap.Type, ap.Payload)
	a := &PCAsk{Kind: "approval", ID: aid, Details: strings.TrimSpace(strings.Join(head, "\n") + "\n\n" + body)}
	switch {
	case ap.Status != "pending":
		a.Prompt = "This approval is " + strings.ReplaceAll(ap.Status, "_", " ") + ": nothing is left to decide."
	case !pcInlineApproval(ap.Type):
		a.Kind = "board approval"
		a.Prompt = "Paperclip does not let you decide this one inline: review its action in the browser first."
	default:
		a.Options = []PCOption{
			{"approve", "apr", "approve"},
			{"reject", "apr", "reject"},
			{"request revision (needs a note)", "reason", "request-revision"},
			{"approve with a note", "reason", "approve"},
			{"reject with a note", "reason", "reject"},
		}
	}
	d.Ask = a
	return d
}

// pcApprovalTitle names an approval: a hire by the agent's name, a budget by its scope, else the payload's title
// or summary, else the feed's title (fallback) or the type.
func pcApprovalTitle(typ string, p map[string]any, fallback string) string {
	switch typ {
	case "hire_agent":
		if n := pcStr(p, "name"); n != "" {
			if r := pcStr(p, "role"); r != "" {
				return "Hire " + n + " (" + r + ")"
			}
			return "Hire " + n
		}
	case "budget_override_required":
		if sc := pcStr(p, "scopeName"); sc != "" {
			return "Budget limit reached: " + sc
		}
	}
	for _, k := range []string{"title", "summary"} {
		if v := pcStr(p, k); v != "" {
			return v
		}
	}
	if fallback != "" {
		return fallback
	}
	return pcApprovalKind(typ)
}

func pcStr(p map[string]any, k string) string {
	switch v := p[k].(type) {
	case string:
		return strings.TrimSpace(v)
	case float64:
		return fmt.Sprint(v)
	}
	return ""
}

func pcCents(v any) string {
	if f, ok := v.(float64); ok {
		return fmt.Sprintf("$%.2f", f/100)
	}
	return ""
}

// pcApprovalText lays an approval's payload out as the approval page does (fields the page shows, by type).
func pcApprovalText(typ string, p map[string]any) string {
	var l []string
	add := func(label, v string) {
		if v != "" {
			l = append(l, label+": "+v)
		}
	}
	list := func(label, key string) {
		var items []string
		if arr, ok := p[key].([]any); ok {
			for _, x := range arr {
				if s, ok := x.(string); ok && strings.TrimSpace(s) != "" {
					items = append(items, strings.TrimSpace(s))
				}
			}
		}
		if len(items) == 0 {
			return
		}
		l = append(l, "", label+":")
		for _, it := range items {
			l = append(l, "- "+strings.TrimLeft(strings.TrimPrefix(strings.TrimPrefix(it, "- "), "* "), " "))
		}
	}
	switch typ {
	case "hire_agent":
		add("Name", pcStr(p, "name"))
		add("Role", pcStr(p, "role"))
		add("Title", pcStr(p, "title"))
		add("Capabilities", pcStr(p, "capabilities"))
		add("Adapter", pcStr(p, "adapterType"))
		add("Budget", pcMonth(p["budgetMonthlyCents"]))
		if arr, ok := p["desiredSkills"].([]any); ok {
			var sk []string
			for _, x := range arr {
				if s, ok := x.(string); ok && strings.TrimSpace(s) != "" {
					sk = append(sk, strings.TrimSpace(s))
				}
			}
			add("Skills", strings.Join(sk, ", "))
		}
	case "budget_override_required":
		scope := pcStr(p, "scopeName")
		if scope == "" {
			scope = pcStr(p, "scopeType")
		}
		add("Scope", scope)
		add("Window", strings.ReplaceAll(pcStr(p, "windowKind"), "_", " "))
		add("Metric", strings.ReplaceAll(pcStr(p, "metric"), "_", " "))
		add("Limit", pcCents(p["budgetAmount"]))
		add("Seen", pcCents(p["observedAmount"]))
		add("Guidance", pcStr(p, "guidance"))
	case "request_board_approval":
		add("Title", pcStr(p, "title"))
		add("Summary", pcStr(p, "summary"))
		add("Recommended action", pcStr(p, "recommendedAction"))
		add("On approval", pcStr(p, "nextActionOnApproval"))
		list("Risks", "risks")
		if c := pcStr(p, "proposedComment"); c != "" {
			l = append(l, "", "Proposed comment:", c)
		}
	default: // approve_ceo_strategy: the plan text; anything else: what the payload says
		add("Title", pcStr(p, "title"))
		for _, k := range []string{"plan", "description", "strategy", "text"} {
			if v := pcStr(p, k); v != "" {
				l = append(l, "", v)
				break
			}
		}
	}
	if len(l) == 0 && len(p) > 0 {
		b, _ := json.MarshalIndent(p, "", "  ")
		return string(b)
	}
	return strings.Join(l, "\n")
}

func pcMonth(v any) string {
	if f, ok := v.(float64); ok && f > 0 {
		return fmt.Sprintf("$%.2f a month", f/100)
	}
	return ""
}

// pcActApproval posts the owner's answer to an approval. A revision needs its note; the other answers may have one.
func pcActApproval(aid string, o PCOption, note string) error {
	note = strings.TrimSpace(note)
	if o.Arg == "request-revision" && note == "" {
		return errors.New("write what to change first")
	}
	body := map[string]any{}
	if note != "" {
		body["decisionNote"] = note
	}
	return pcPost("/api/approvals/"+url.PathEscape(aid)+"/"+o.Arg, body)
}
