package main

// The PC view's side panel: one issue's context (its description, the thread, what it asks the owner) and the
// answers kaching can give from the keyboard. Endpoints, read from the server source (@paperclipai/server
// dist/routes/issues.js, shared dist/validators/issue.js):
//   GET  /api/issues/:id                                    the issue, with activeRecoveryAction
//   GET  /api/issues/:id/comments                           the thread, newest first
//   GET  /api/issues/:id/interactions                       requests on the thread (status pending = open)
//   POST /api/issues/:id/interactions/:iid/accept {}        approve a request_confirmation
//   POST /api/issues/:id/interactions/:iid/reject {reason}  decline it
//   POST /api/issues/:id/interactions/:iid/respond {answers:[{questionId, optionIds}]}  answer ask_user_questions
//   POST /api/issues/:id/recovery-actions/resolve {actionId, outcome, sourceIssueStatus}  a recovery action

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// PCDetail is what the side panel shows for one issue.
type PCDetail struct {
	ID, Ref, Title, Status, Description string
	Comments                            []PCComment // oldest first
	Ask                                 *PCAsk      // what it asks the owner now, nil when nothing
	Err                                 string
	At                                  time.Time // when it was read
}

type PCComment struct {
	Author string
	Board  bool // written by the owner (the board user)
	Body   string
	At     time.Time
}

// PCAsk is the open request on the issue: a confirmation, a question, or a recovery action for the board.
type PCAsk struct {
	Kind    string // request_confirmation, ask_user_questions, recovery, or another interaction kind
	ID      string // the interaction's or the recovery action's id
	Title   string
	Prompt  string
	Details string
	Options []PCOption // numbered answers; none: kaching can't answer this kind, the browser can
}

// PCOption is one numbered answer and what it posts.
type PCOption struct {
	Label  string
	Action string // accept, reject, reason (decline, with a reason written first), answer, recover
	Arg    string // answer: questionId/optionId; recover: outcome/sourceIssueStatus
}

type pcIssueFull struct {
	ID              string `json:"id"`
	Identifier      string `json:"identifier"`
	Title           string `json:"title"`
	Status          string `json:"status"`
	Description     string `json:"description"`
	AssigneeAgentID string `json:"assigneeAgentId"`
	Recovery        *struct {
		ID         string `json:"id"`
		Kind       string `json:"kind"`
		Status     string `json:"status"`
		OwnerType  string `json:"ownerType"`
		NextAction string `json:"nextAction"`
		Cause      string `json:"cause"`
	} `json:"activeRecoveryAction"`
}

type pcCommentRaw struct {
	AuthorType    string    `json:"authorType"`
	AuthorAgentID string    `json:"authorAgentId"`
	Body          string    `json:"body"`
	CreatedAt     time.Time `json:"createdAt"`
}

type pcInteraction struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Status    string    `json:"status"`
	Title     string    `json:"title"`
	CreatedAt time.Time `json:"createdAt"`
	Payload   struct {
		Prompt          string `json:"prompt"`
		DetailsMarkdown string `json:"detailsMarkdown"`
		Title           string `json:"title"`
		Questions       []struct {
			ID            string `json:"id"`
			Prompt        string `json:"prompt"`
			SelectionMode string `json:"selectionMode"`
			Options       []struct {
				ID    string `json:"id"`
				Label string `json:"label"`
			} `json:"options"`
		} `json:"questions"`
	} `json:"payload"`
}

// pcMaxComments: how much of the thread the panel keeps (the newest).
const pcMaxComments = 40

// loadPCDetail reads one issue's panel. names maps agent ids to names.
func loadPCDetail(id string, names map[string]string) PCDetail {
	d := PCDetail{ID: id, At: time.Now()}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	esc := url.PathEscape(id)
	var (
		is    pcIssueFull
		cms   []pcCommentRaw
		inter []pcInteraction
		errs  [3]error
		wg    sync.WaitGroup
	)
	wg.Add(3)
	go func() { defer wg.Done(); errs[0] = pcGet(ctx, "/api/issues/"+esc, &is) }()
	go func() { defer wg.Done(); errs[1] = pcGet(ctx, "/api/issues/"+esc+"/comments", &cms) }()
	go func() { defer wg.Done(); errs[2] = pcGet(ctx, "/api/issues/"+esc+"/interactions", &inter) }()
	wg.Wait()
	if errs[0] != nil {
		d.Err = pcErr(errs[0])
		return d
	}
	d.Ref, d.Title, d.Status, d.Description = is.Identifier, is.Title, is.Status, strings.TrimSpace(is.Description)
	sort.SliceStable(cms, func(i, j int) bool { return cms[i].CreatedAt.Before(cms[j].CreatedAt) })
	if len(cms) > pcMaxComments {
		cms = cms[len(cms)-pcMaxComments:]
	}
	for _, c := range cms {
		pc := PCComment{Body: strings.TrimSpace(c.Body), At: c.CreatedAt}
		switch {
		case c.AuthorType == "agent":
			pc.Author = names[c.AuthorAgentID]
			if pc.Author == "" {
				pc.Author = "agent"
			}
		case c.AuthorType == "user" || c.AuthorType == "board":
			pc.Author, pc.Board = "you", true
		default:
			pc.Author = c.AuthorType
		}
		d.Comments = append(d.Comments, pc)
	}
	d.Ask = pcAskOf(is, inter)
	return d
}

// pcAskOf: the newest open interaction, else a recovery action that waits for the board.
func pcAskOf(is pcIssueFull, inter []pcInteraction) *PCAsk {
	var open *pcInteraction
	for i := range inter {
		if inter[i].Status == "pending" && (open == nil || inter[i].CreatedAt.After(open.CreatedAt)) {
			open = &inter[i]
		}
	}
	if open != nil {
		a := &PCAsk{Kind: open.Kind, ID: open.ID, Title: open.Title, Prompt: open.Payload.Prompt,
			Details: strings.TrimSpace(open.Payload.DetailsMarkdown)}
		if a.Title == "" {
			a.Title = open.Payload.Title
		}
		switch open.Kind {
		case "request_confirmation":
			a.Options = []PCOption{{"approve", "accept", ""}, {"decline", "reject", ""}, {"decline with a reason", "reason", ""}}
		case "ask_user_questions":
			// one single-choice question: a number answers it; more questions are for the browser
			if qs := open.Payload.Questions; len(qs) == 1 && qs[0].SelectionMode == "single" {
				a.Prompt = qs[0].Prompt
				for _, o := range qs[0].Options {
					a.Options = append(a.Options, PCOption{o.Label, "answer", qs[0].ID + "/" + o.ID})
				}
			}
		}
		return a
	}
	if r := is.Recovery; r != nil && r.Status == "active" && r.OwnerType == "board" {
		return &PCAsk{Kind: "recovery", ID: r.ID, Title: "Recovery: " + strings.ReplaceAll(r.Kind, "_", " "), Prompt: r.NextAction,
			Options: []PCOption{
				{"retry: hand it back to the agent", "recover", "restored/todo"},
				{"done: mark the issue done", "recover", "restored/done"},
				{"blocked: keep it blocked", "recover", "blocked/blocked"},
			}}
	}
	return nil
}

// pcAct posts the owner's answer n (1-based) to the issue's open request; reason goes with a decline.
func pcAct(issueID string, a *PCAsk, n int, reason string) error {
	if a == nil || n < 1 || n > len(a.Options) {
		return errors.New("no such answer")
	}
	o := a.Options[n-1]
	base := "/api/issues/" + url.PathEscape(issueID)
	switch o.Action {
	case "accept":
		return pcPost(base+"/interactions/"+url.PathEscape(a.ID)+"/accept", map[string]any{})
	case "reject", "reason":
		body := map[string]any{}
		if r := strings.TrimSpace(reason); r != "" {
			body["reason"] = r
		}
		return pcPost(base+"/interactions/"+url.PathEscape(a.ID)+"/reject", body)
	case "answer":
		q, opt, _ := strings.Cut(o.Arg, "/")
		return pcPost(base+"/interactions/"+url.PathEscape(a.ID)+"/respond",
			map[string]any{"answers": []map[string]any{{"questionId": q, "optionIds": []string{opt}}}})
	case "recover":
		outcome, status, _ := strings.Cut(o.Arg, "/")
		return pcPost(base+"/recovery-actions/resolve", map[string]any{"actionId": a.ID, "outcome": outcome, "sourceIssueStatus": status})
	}
	return errors.New("kaching can't send this answer")
}

// pcPost sends a JSON body as the board user; Paperclip's own error message comes back on a refusal.
func pcPost(path string, body any) error {
	b, _ := json.Marshal(body)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, pcBase+path, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return errors.New(pcErr(err))
	}
	defer res.Body.Close()
	if res.StatusCode/100 == 2 {
		return nil
	}
	return fmt.Errorf("Paperclip refused (HTTP %d): %s", res.StatusCode, pcRefusal(res.Body))
}

// pcRefusal: the error text in a refusal's body.
func pcRefusal(r io.Reader) string {
	b, _ := io.ReadAll(io.LimitReader(r, 2048))
	var e struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	msg := strings.TrimSpace(string(b))
	if json.Unmarshal(b, &e) == nil {
		if e.Error != "" {
			msg = e.Error
		} else if e.Message != "" {
			msg = e.Message
		}
	}
	return msg
}
