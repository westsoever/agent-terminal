package main

// The PR view's data: open GitHub pull requests that involve the owner (theirs, assigned, review asked, mentioned),
// read with the gh CLI and its own login: gh search prs --state open --involves @me.

import (
	"context"
	"encoding/json"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

// PullReq is one row of the PR view.
type PullReq struct {
	Repo    string // owner/name
	Number  int
	Title   string
	Author  string
	URL     string
	Draft   bool
	Updated time.Time
}

type PullsState struct {
	Err   string // the last read failed; Items are still the last good list
	Items []PullReq
	At    time.Time // when Items were read
}

type pullsMsg PullsState

const (
	pullsTimeout = 10 * time.Second
	pullsMax     = 50
	pullsEvery   = 2 * time.Minute // outside the PR view; it uses GitHub's search quota (30 a minute)
)

// ghPulls runs the search; a variable so tests can hand back their own JSON.
var ghPulls = func(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "gh", "search", "prs", "--state", "open", "--involves", "@me",
		"--sort", "updated", "--order", "desc", "--json", "number,title,repository,url,author,isDraft,updatedAt",
		"--limit", strconv.Itoa(pullsMax)).Output()
}

// loadPulls: the open pull requests, the last updated first.
func loadPulls() PullsState {
	ctx, cancel := context.WithTimeout(context.Background(), pullsTimeout)
	defer cancel()
	out, err := ghPulls(ctx)
	if err != nil {
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			msg = string(ee.Stderr)
		}
		return PullsState{Err: "gh search prs: " + strings.Join(strings.Fields(msg), " ")} // one line: it shows in a row
	}
	var raw []struct {
		Number     int    `json:"number"`
		Title      string `json:"title"`
		URL        string `json:"url"`
		IsDraft    bool   `json:"isDraft"`
		UpdatedAt  string `json:"updatedAt"`
		Repository struct {
			NameWithOwner string `json:"nameWithOwner"`
		} `json:"repository"`
		Author struct {
			Login string `json:"login"`
		} `json:"author"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return PullsState{Err: "gh search prs: " + err.Error()}
	}
	st := PullsState{At: time.Now()}
	for _, r := range raw {
		at, _ := time.Parse(time.RFC3339, r.UpdatedAt)
		st.Items = append(st.Items, PullReq{r.Repository.NameWithOwner, r.Number, r.Title, r.Author.Login, r.URL, r.IsDraft, at})
	}
	sort.SliceStable(st.Items, func(i, j int) bool { return st.Items[i].Updated.After(st.Items[j].Updated) })
	return st
}

// merge takes a new read: a failed one keeps the last good list and shows its error with it.
func (p PullsState) merge(n PullsState) PullsState {
	if n.Err != "" {
		p.Err = n.Err
		return p
	}
	return n
}

// index: the row of the pull request at url, or -1.
func (p PullsState) index(url string) int {
	for i, pr := range p.Items {
		if pr.URL == url {
			return i
		}
	}
	return -1
}
