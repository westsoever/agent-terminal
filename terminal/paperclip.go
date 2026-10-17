package main

// The PC view's data: the local Paperclip instance's HTTP API (local_trusted mode, so requests act as the board
// user without a login). Endpoints, read from the server source (@paperclipai/server dist/routes):
//   GET  /api/companies                                   every company
//   GET  /api/companies/:id/attention                     what needs the owner (the app's own inbox feed)
//   GET  /api/companies/:id/issues?status=a,b             open issues
//   GET  /api/companies/:id/agents                        agent names
//   GET  /api/companies/:id/heartbeat-runs?limit=N        recent runs: status, usageJson.costUsd, contextSnapshot.issueId
//   POST /api/issues/:id/comments {body, clientRequestId} a comment as the board user (what the UI sends)
// The web UI route for an issue is the attention item's href, /<PREFIX>/issues/<REF>.

import (
	"bytes"
	"context"
	"crypto/rand"
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

// PCItem is one row of the PC view: an issue that needs the owner, or an agent run.
type PCItem struct {
	ID     string // API id, used for comments
	Ref    string // human reference, e.g. COS-7
	Title  string
	Status string // blocked, in_review, ...
	Agent  string // assigned agent name
	Detail string // one line: why it waits, or the run's progress
	Cost   string // e.g. "$0.38"
	URL    string // the issue in Paperclip's web UI
	Needs  bool   // true: waits for the owner
}

type PCState struct {
	Err   string
	Items []PCItem
}

// pcBase is Paperclip's address; a variable so tests can point it at an httptest server.
var pcBase = "http://localhost:3100"

const (
	pcTimeout  = 1500 * time.Millisecond
	pcMaxItems = 30
	pcRuns     = 50
)

var pcOpenStatuses = "todo,in_progress,in_review,blocked"

type pcCompany struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	IssuePrefix string `json:"issuePrefix"`
	Status      string `json:"status"`
}

type pcSubject struct {
	Kind       string `json:"kind"`
	ID         string `json:"id"`
	Title      string `json:"title"`
	Identifier string `json:"identifier"`
	Status     string `json:"status"`
	Href       string `json:"href"`
	Metadata   struct {
		AssigneeAgentID string `json:"assigneeAgentId"`
		SourceIssueID   string `json:"sourceIssueId"`
	} `json:"metadata"`
}

type pcAttention struct {
	Items []struct {
		SourceKind   string     `json:"sourceKind"`
		Subject      pcSubject  `json:"subject"`
		RelatedIssue *pcSubject `json:"relatedIssue"`
		WhyNow       string     `json:"whyNow"`
		Severity     string     `json:"severity"`
		ActivityAt   string     `json:"activityAt"`
	} `json:"items"`
}

type pcIssue struct {
	ID                string `json:"id"`
	Identifier        string `json:"identifier"`
	Title             string `json:"title"`
	Status            string `json:"status"`
	AssigneeAgentID   string `json:"assigneeAgentId"`
	UpdatedAt         string `json:"updatedAt"`
	UnblockDescriptor *struct {
		Action string `json:"action"`
	} `json:"unblockDescriptor"`
	ActiveRun *struct {
		Status string `json:"status"`
	} `json:"activeRun"`
}

type pcAgent struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type pcRun struct {
	Status          string `json:"status"`
	StartedAt       string `json:"startedAt"`
	CreatedAt       string `json:"createdAt"`
	ContextSnapshot struct {
		IssueID string `json:"issueId"`
	} `json:"contextSnapshot"`
	UsageJSON struct {
		CostUSD float64 `json:"costUsd"`
	} `json:"usageJson"`
}

func pcGet(ctx context.Context, path string, into any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pcBase+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("%s: HTTP %d", path, res.StatusCode)
	}
	return json.NewDecoder(res.Body).Decode(into)
}

func loadPaperclip() PCState {
	ctx, cancel := context.WithTimeout(context.Background(), pcTimeout)
	defer cancel()
	var companies []pcCompany
	if err := pcGet(ctx, "/api/companies", &companies); err != nil {
		return PCState{Err: pcErr(err)}
	}
	type result struct {
		items []PCItem
		err   error
	}
	results := make([]result, len(companies))
	var wg sync.WaitGroup
	for i, c := range companies {
		if c.Status == "archived" {
			continue
		}
		wg.Add(1)
		go func(i int, c pcCompany) {
			defer wg.Done()
			items, err := loadCompany(ctx, c)
			results[i] = result{items, err}
		}(i, c)
	}
	wg.Wait()
	var needs, rest []PCItem
	var firstErr error
	for _, r := range results {
		if r.err != nil && firstErr == nil {
			firstErr = r.err
		}
		for _, it := range r.items {
			if it.Needs {
				needs = append(needs, it)
			} else {
				rest = append(rest, it)
			}
		}
	}
	items := append(needs, rest...)
	if len(items) > pcMaxItems {
		items = items[:pcMaxItems]
	}
	st := PCState{Items: items}
	if firstErr != nil && len(items) == 0 {
		st.Err = pcErr(firstErr)
	}
	return st
}

// loadCompany returns the company's rows: attention items first (in the feed's order), then open issues newest
// first. Each issue appears once.
func loadCompany(ctx context.Context, c pcCompany) ([]PCItem, error) {
	esc := url.PathEscape(c.ID)
	var (
		att    pcAttention
		issues []pcIssue
		agents []pcAgent
		runs   []pcRun
		errs   [4]error
		wg     sync.WaitGroup
	)
	wg.Add(4)
	go func() { defer wg.Done(); errs[0] = pcGet(ctx, "/api/companies/"+esc+"/attention", &att) }()
	go func() {
		defer wg.Done()
		errs[1] = pcGet(ctx, "/api/companies/"+esc+"/issues?status="+pcOpenStatuses, &issues)
	}()
	go func() { defer wg.Done(); errs[2] = pcGet(ctx, "/api/companies/"+esc+"/agents", &agents) }()
	go func() {
		defer wg.Done()
		errs[3] = pcGet(ctx, fmt.Sprintf("/api/companies/%s/heartbeat-runs?limit=%d", esc, pcRuns), &runs)
	}()
	wg.Wait()
	if errs[0] != nil && errs[1] != nil {
		return nil, errs[0]
	}
	// agents and runs are extras: without them rows just lack the name or cost.

	names := map[string]string{}
	for _, a := range agents {
		names[a.ID] = a.Name
	}
	// the latest run per issue (runs come newest first), and the issue tree's spend across those runs
	latest := map[string]pcRun{}
	spent := map[string]float64{}
	for _, r := range runs {
		id := r.ContextSnapshot.IssueID
		if id == "" {
			continue
		}
		if _, ok := latest[id]; !ok {
			latest[id] = r
		}
		spent[id] += r.UsageJSON.CostUSD
	}
	byID := map[string]pcIssue{}
	for _, is := range issues {
		byID[is.ID] = is
	}

	var out []PCItem
	index := map[string]int{} // issue id -> position in out
	for _, a := range att.Items {
		subj := a.Subject
		issue := subj
		if subj.Kind != "issue" && a.RelatedIssue != nil {
			issue = *a.RelatedIssue
		}
		id := issue.ID
		if issue.Kind != "issue" {
			id = subj.Metadata.SourceIssueID
		}
		if id == "" {
			continue
		}
		detail := a.WhyNow
		if subj.Kind != "issue" && subj.Title != "" {
			detail = subj.Title
		}
		if i, ok := index[id]; ok { // a second reason for the same issue
			if detail != "" && !strings.Contains(out[i].Detail, detail) {
				out[i].Detail += "; " + detail
			}
			continue
		}
		it := PCItem{ID: id, Ref: issue.Identifier, Title: issue.Title, Status: issue.Status, Detail: detail, Needs: true}
		href := issue.Href
		if href == "" {
			href = subj.Href
		}
		if href == "" && it.Ref != "" && c.IssuePrefix != "" {
			href = "/" + c.IssuePrefix + "/issues/" + it.Ref
		}
		if href != "" {
			it.URL = pcBase + href
		}
		if full, ok := byID[id]; ok {
			fillFromIssue(&it, full, names)
		} else if agent := issue.Metadata.AssigneeAgentID; agent != "" {
			it.Agent = names[agent]
		}
		fillRun(&it, latest, spent)
		index[id] = len(out)
		out = append(out, it)
	}

	var open []pcIssue
	for _, is := range issues {
		if _, ok := index[is.ID]; !ok {
			open = append(open, is)
		}
	}
	sort.SliceStable(open, func(i, j int) bool { return open[i].UpdatedAt > open[j].UpdatedAt })
	for _, is := range open {
		it := PCItem{ID: is.ID, Ref: is.Identifier, Title: is.Title, Status: is.Status}
		if is.Identifier != "" && c.IssuePrefix != "" {
			it.URL = pcBase + "/" + c.IssuePrefix + "/issues/" + is.Identifier
		}
		fillFromIssue(&it, is, names)
		fillRun(&it, latest, spent)
		if it.Detail == "" {
			it.Detail = strings.ReplaceAll(is.Status, "_", " ")
		}
		out = append(out, it)
	}
	return out, nil
}

func fillFromIssue(it *PCItem, is pcIssue, names map[string]string) {
	if it.Ref == "" {
		it.Ref = is.Identifier
	}
	if it.Title == "" {
		it.Title = is.Title
	}
	if is.Status != "" {
		it.Status = is.Status
	}
	if is.AssigneeAgentID != "" {
		it.Agent = names[is.AssigneeAgentID]
	}
	if is.UnblockDescriptor != nil && is.UnblockDescriptor.Action != "" {
		if it.Detail == "" {
			it.Detail = is.UnblockDescriptor.Action
		} else {
			it.Detail = is.UnblockDescriptor.Action + "; " + it.Detail
		}
	}
	if is.ActiveRun != nil && is.ActiveRun.Status != "" && !it.Needs {
		it.Detail = "run " + is.ActiveRun.Status
	}
}

func fillRun(it *PCItem, latest map[string]pcRun, spent map[string]float64) {
	if usd := spent[it.ID]; usd > 0 {
		it.Cost = fmt.Sprintf("$%.2f", usd)
	}
	if r, ok := latest[it.ID]; ok && !it.Needs && it.Detail == "" {
		it.Detail = "last run " + r.Status
	}
}

func pcErr(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) && (strings.Contains(ue.Err.Error(), "connection refused") ||
		errors.Is(ue.Err, context.DeadlineExceeded) || ue.Timeout()) {
		u, _ := url.Parse(pcBase)
		host := pcBase
		if u != nil {
			host = u.Host
		}
		if ue.Timeout() || errors.Is(ue.Err, context.DeadlineExceeded) {
			return "Paperclip didn't answer in time (" + host + ")"
		}
		return "Paperclip isn't running (" + host + ")"
	}
	return "Paperclip: " + err.Error()
}

// pcComment posts text on the issue as the board user, the way the issue page's comment box does.
func pcComment(id, text string) error {
	text = strings.TrimSpace(text)
	if id == "" || text == "" {
		return errors.New("nothing to post")
	}
	body, _ := json.Marshal(map[string]string{"body": text, "clientRequestId": newUUID()})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, pcBase+"/api/issues/"+url.PathEscape(id)+"/comments", bytes.NewReader(body))
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
	b, _ := io.ReadAll(io.LimitReader(res.Body, 2048))
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
	return fmt.Errorf("Paperclip refused the comment (HTTP %d): %s", res.StatusCode, msg)
}

// newUUID returns a random version 4 UUID (Paperclip wants one per comment for safe retries).
func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
