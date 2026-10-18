package main

// The PR view's side panel: one pull request read with gh pr view, the hand-off of a comment on it to a new
// background agent that works on it in the repo's local clone, and the merge that kaching does itself.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// PRDetail is the side panel of one pull request.
type PRDetail struct {
	URL       string
	Err       string
	At        time.Time
	Head      string // its branch
	HeadSHA   string // its branch's last commit: a merge takes exactly this one
	Base      string // the branch it merges into
	Body      string
	Add, Del  int
	Files     []PRFile
	Mergeable string // MERGEABLE, CONFLICTING, UNKNOWN
	Review    string // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or ""
	Checks    string // e.g. "3 passed, 1 failed"; "" when it has none
	Thread    []PRComment
}

type PRFile struct {
	Path     string
	Add, Del int
}

// PRComment is a comment or a review on the pull request, oldest first.
type PRComment struct {
	Author, Body, State string // State: a review's verdict (APPROVED, ...); "" for a comment
	At                  time.Time
}

type prDetailMsg PRDetail

// ghPRView reads one pull request; a variable so tests can hand back their own JSON.
var ghPRView = func(ctx context.Context, url string) ([]byte, error) {
	return exec.CommandContext(ctx, "gh", "pr", "view", url, "--json",
		"body,headRefName,headRefOid,baseRefName,additions,deletions,files,mergeable,reviewDecision,statusCheckRollup,comments,reviews").Output()
}

func loadPRDetail(url string) PRDetail {
	ctx, cancel := context.WithTimeout(context.Background(), pullsTimeout)
	defer cancel()
	d := PRDetail{URL: url, At: time.Now()}
	out, err := ghPRView(ctx, url)
	if err != nil {
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			msg = string(ee.Stderr)
		}
		d.Err = "gh pr view: " + strings.Join(strings.Fields(msg), " ")
		return d
	}
	type author struct {
		Login string `json:"login"`
	}
	var raw struct {
		Body      string `json:"body"`
		Head      string `json:"headRefName"`
		HeadSHA   string `json:"headRefOid"`
		Base      string `json:"baseRefName"`
		Additions int    `json:"additions"`
		Deletions int    `json:"deletions"`
		Mergeable string `json:"mergeable"`
		Review    string `json:"reviewDecision"`
		Files     []struct {
			Path      string `json:"path"`
			Additions int    `json:"additions"`
			Deletions int    `json:"deletions"`
		} `json:"files"`
		Checks []struct {
			Status     string `json:"status"`     // check run: COMPLETED, IN_PROGRESS, ...
			Conclusion string `json:"conclusion"` // check run: SUCCESS, FAILURE, ...
			State      string `json:"state"`      // status context: SUCCESS, FAILURE, PENDING, ERROR
		} `json:"statusCheckRollup"`
		Comments []struct {
			Author    author `json:"author"`
			Body      string `json:"body"`
			CreatedAt string `json:"createdAt"`
		} `json:"comments"`
		Reviews []struct {
			Author      author `json:"author"`
			Body        string `json:"body"`
			State       string `json:"state"`
			SubmittedAt string `json:"submittedAt"`
		} `json:"reviews"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		d.Err = "gh pr view: " + err.Error()
		return d
	}
	d.Head, d.HeadSHA, d.Base, d.Body, d.Add, d.Del = raw.Head, raw.HeadSHA, raw.Base, raw.Body, raw.Additions, raw.Deletions
	d.Mergeable, d.Review = raw.Mergeable, raw.Review
	for _, f := range raw.Files {
		d.Files = append(d.Files, PRFile{f.Path, f.Additions, f.Deletions})
	}
	var pass, fail, wait int
	for _, c := range raw.Checks {
		r := c.Conclusion
		if r == "" {
			r = c.State
		}
		switch {
		case r == "SUCCESS" || r == "NEUTRAL" || r == "SKIPPED":
			pass++
		case r == "PENDING" || r == "EXPECTED" || (c.Status != "" && c.Status != "COMPLETED"):
			wait++
		default:
			fail++
		}
	}
	var parts []string
	for _, p := range []struct {
		n    int
		what string
	}{{pass, "passed"}, {fail, "failed"}, {wait, "running"}} {
		if p.n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", p.n, p.what))
		}
	}
	d.Checks = strings.Join(parts, ", ")
	for _, c := range raw.Comments {
		at, _ := time.Parse(time.RFC3339, c.CreatedAt)
		d.Thread = append(d.Thread, PRComment{c.Author.Login, c.Body, "", at})
	}
	for _, r := range raw.Reviews {
		if r.Body == "" && r.State == "COMMENTED" { // the shell of inline comments: nothing to read here
			continue
		}
		at, _ := time.Parse(time.RFC3339, r.SubmittedAt)
		d.Thread = append(d.Thread, PRComment{r.Author.Login, r.Body, r.State, at})
	}
	sort.SliceStable(d.Thread, func(i, j int) bool { return d.Thread[i].At.Before(d.Thread[j].At) })
	return d
}

// prQuick: the panel's number keys. One with a text starts an agent on the pull request with it as the comment;
// merge it is done by kaching itself at once with gh pr merge, no agent (D55).
var prQuick = []struct{ label, text string }{
	{"review it", "Review this pull request: does it do what it says, and is the code right? Tell me what you find."},
	{"merge it", ""},
}

const prMergeTimeout = 30 * time.Second

type prMergedMsg struct{ url, ref, how, err string }

// prMergeBlock: why kaching does not merge pr as its panel d shows it, "" when it does. The rule the merge agent had:
// checks pass and no conflicts.
func prMergeBlock(pr PullReq, d PRDetail) string {
	switch {
	case d.At.IsZero() || d.Err != "" || d.HeadSHA == "":
		return "its panel has not loaded"
	case pr.Draft:
		return "it is a draft"
	case d.Mergeable == "CONFLICTING":
		return "it has conflicts"
	case strings.Contains(d.Checks, "failed") || strings.Contains(d.Checks, "running"):
		return "checks: " + d.Checks
	}
	return ""
}

// ghMergeRun runs gh outside any local clone (a merge never touches a checkout here); a variable so tests can
// record the calls.
var ghMergeRun = func(ctx context.Context, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, "gh", args...)
	c.Dir = os.TempDir()
	return c.CombinedOutput()
}

// prMerge merges pr with gh pr merge, pinned to the commit its panel showed: a merge commit when the repo allows
// one, else squash, else rebase. The branch is kept (the repo's own setting may still delete it).
func prMerge(pr PullReq, sha string) (how string, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), prMergeTimeout)
	defer cancel()
	how = "merge"
	if out, err := ghMergeRun(ctx, "repo", "view", pr.Repo, "--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed"); err == nil {
		var r struct{ MergeCommitAllowed, SquashMergeAllowed, RebaseMergeAllowed bool }
		if json.Unmarshal(out, &r) == nil {
			switch {
			case r.MergeCommitAllowed:
			case r.SquashMergeAllowed:
				how = "squash"
			case r.RebaseMergeAllowed:
				how = "rebase"
			}
		}
	}
	out, err := ghMergeRun(ctx, "pr", "merge", pr.URL, "--"+how, "--match-head-commit", sha)
	if err != nil {
		msg := strings.Join(strings.Fields(string(out)), " ")
		if msg == "" {
			msg = err.Error()
		}
		return how, fmt.Errorf("gh pr merge: %s", msg)
	}
	return how, nil
}

// prPrompt: the first message of the agent that works on pr, with the owner's comment as its task.
func prPrompt(pr PullReq, d PRDetail, comment string, cloned bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Pull request %s#%d: %s\n%s\n", pr.Repo, pr.Number, pr.Title, pr.URL)
	if d.Head != "" {
		fmt.Fprintf(&b, "Branch %s into %s.\n", d.Head, d.Base)
	}
	fmt.Fprintf(&b, "\nMy comment on it:\n%s\n\n", comment)
	if !cloned {
		b.WriteString("This Mac has no clone of the repo; if you need its code, clone it into a folder under /private/tmp.\n")
	}
	b.WriteString("Read it with gh pr view and gh pr diff. If you change or test code, do it in your own git worktree of " +
		"the pull request's branch, not in the main checkout. Report back here; comment on the pull request on GitHub " +
		"only if I ask for it.")
	return b.String()
}

var (
	cloneMu    sync.Mutex
	cloneCache map[string]string // owner/name (lower case) -> local folder
)

// cloneRoots: where local clones are looked for, one level deep; a variable so tests can use their own.
var cloneRoots = func() []string {
	home := os.Getenv("HOME")
	return []string{filepath.Join(home, "bbq"), home}
}

// prCloneDir: the local clone of repo (owner/name), or "" when there is none. A folder named like the repo wins
// over another clone of it.
func prCloneDir(repo string) string {
	key := strings.ToLower(repo)
	cloneMu.Lock()
	defer cloneMu.Unlock()
	if d, ok := cloneCache[key]; ok && dirExists(d) {
		return d
	}
	found := ""
	for _, root := range cloneRoots() {
		ents, _ := os.ReadDir(root)
		for _, e := range ents {
			dir := filepath.Join(root, e.Name())
			if !e.IsDir() || !dirExists(filepath.Join(dir, ".git")) {
				continue
			}
			out, _ := exec.Command("git", "-C", dir, "remote", "get-url", "origin").Output()
			if remoteRepo(string(out)) != key {
				continue
			}
			if found == "" || strings.EqualFold(e.Name(), filepath.Base(repo)) {
				found = dir
			}
			if strings.EqualFold(e.Name(), filepath.Base(repo)) {
				break
			}
		}
		if found != "" {
			break
		}
	}
	if found != "" {
		if cloneCache == nil {
			cloneCache = map[string]string{}
		}
		cloneCache[key] = found
	}
	return found
}

// remoteRepo: "owner/name" in lower case from a GitHub remote URL (https, www, ssh, with or without .git).
func remoteRepo(url string) string {
	u := strings.ToLower(strings.TrimSpace(url))
	for _, p := range []string{"https://www.github.com/", "https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:"} {
		if strings.HasPrefix(u, p) {
			return strings.TrimSuffix(strings.TrimSuffix(u[len(p):], "/"), ".git")
		}
	}
	return ""
}
