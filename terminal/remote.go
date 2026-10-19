package main

// The REMOTE section of the desk: Claude Code sessions that run on another machine (Remote Control) and are
// connected to the owner's account now, read from the same list claude.ai/code shows, with the owner's own Claude
// login. Only active sessions on other machines are listed: connected, not archived, and not a window of this Mac. Reading a session's messages needs a
// trusted device and is refused for this login, so agterm shows its state and sends a message with the CLI's
// own path (claude -p ... --cloud <id>); the reply is read on claude.ai/code (enter).

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// RemoteSession is one row of the REMOTE section.
type RemoteSession struct {
	ID      string // session_01…
	Title   string
	Model   string
	Status  string // the API's session_status: idle, running, requires_action
	Unread  bool   // the session answered and the owner has not looked at it yet
	CtxPct  string // context used, "" when unknown
	Updated time.Time
	Summary string // what it last said it did (post_turn_summary), "" when none
}

type RemoteState struct {
	Err   string // the last read failed; Items are still the last good list
	Items []RemoteSession
	At    time.Time // when Items were read
}

type remoteMsg RemoteState

const (
	remoteTimeout = 15 * time.Second
	remoteEvery   = 30 * time.Second
	remoteSendMax = 120 * time.Second
	remoteAPI     = "https://api.anthropic.com/v1/sessions?beta=true&limit=100"
)

// remoteCreds: the owner's Claude login (the keychain item Claude Code keeps) and organisation. The token goes to
// api.anthropic.com only. A variable so tests need no keychain.
var remoteCreds = func() (token, org string, err error) {
	out, err := runFor(5*time.Second, false, "security", "find-generic-password", "-s", "Claude Code-credentials", "-w")
	if err != nil {
		return "", "", fmt.Errorf("no Claude login in the keychain")
	}
	var c struct {
		O struct {
			Token string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(out, &c) != nil || c.O.Token == "" {
		return "", "", fmt.Errorf("no Claude login in the keychain")
	}
	home, _ := os.UserHomeDir()
	b, err := os.ReadFile(filepath.Join(home, ".claude.json"))
	if err != nil {
		return "", "", err
	}
	var cfg struct {
		A struct {
			Org string `json:"organizationUuid"`
		} `json:"oauthAccount"`
	}
	if json.Unmarshal(b, &cfg) != nil || cfg.A.Org == "" {
		return "", "", fmt.Errorf("no organisation in ~/.claude.json")
	}
	return c.O.Token, cfg.A.Org, nil
}

// remoteGet reads the session list; a variable so tests can hand back their own JSON.
var remoteGet = func(ctx context.Context) ([]byte, error) {
	token, org, err := remoteCreds()
	if err != nil {
		return nil, err
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, remoteAPI, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", "2023-06-01")
	req.Header.Set("anthropic-beta", "ccr-byoc-2025-07-29")
	req.Header.Set("x-organization-uuid", org)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return b, nil
}

// loadRemote: the active remote sessions, the last updated first.
func loadRemote() RemoteState {
	ctx, cancel := context.WithTimeout(context.Background(), remoteTimeout)
	defer cancel()
	b, err := remoteGet(ctx)
	if err != nil {
		return RemoteState{Err: "remote sessions: " + strings.Join(strings.Fields(err.Error()), " ")}
	}
	st := parseRemote(b)
	st.Items = dropLocal(st.Items, remoteLocal())
	return st
}

// remoteLocal: the remote ids of the sessions running on this Mac. Claude Code writes bridgeSessionId into
// ~/.claude/sessions/<pid>.json when a terminal gets a Remote Control connection, so a live process with one is a
// window here, already an agent row, and not a REMOTE one. A variable so tests need no session files.
var remoteLocal = func() map[string]bool {
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".claude", "sessions", "*.json"))
	ids := map[string]bool{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var c struct {
			PID    int    `json:"pid"`
			Bridge string `json:"bridgeSessionId"`
		}
		if json.Unmarshal(b, &c) != nil || c.Bridge == "" || c.PID <= 0 {
			continue
		}
		if err := syscall.Kill(c.PID, 0); err == nil || err == syscall.EPERM { // the process is still there
			ids[c.Bridge] = true
		}
	}
	return ids
}

// dropLocal leaves out the sessions that run on this Mac: only other machines' sessions belong in REMOTE.
func dropLocal(items []RemoteSession, local map[string]bool) []RemoteSession {
	var out []RemoteSession
	for _, r := range items {
		if !local[r.ID] {
			out = append(out, r)
		}
	}
	return out
}

func parseRemote(b []byte) RemoteState {
	var raw struct {
		Data []struct {
			ID         string `json:"id"`
			Title      string `json:"title"`
			Status     string `json:"session_status"`
			Connection string `json:"connection_status"`
			Unread     bool   `json:"unread"`
			UpdatedAt  string `json:"updated_at"`
			Meta       struct {
				Model   string `json:"model"`
				Context struct {
					Max  float64 `json:"max_tokens"`
					Used float64 `json:"used_tokens"`
				} `json:"context_usage"`
				Summary struct {
					Recent string `json:"recent_action"`
					Detail string `json:"status_detail"`
				} `json:"post_turn_summary"`
			} `json:"external_metadata"`
		} `json:"data"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return RemoteState{Err: "remote sessions: " + err.Error()}
	}
	st := RemoteState{At: time.Now()}
	for _, r := range raw.Data {
		if r.Status == "archived" || r.Connection != "connected" { // only what is active
			continue
		}
		at, _ := time.Parse(time.RFC3339, r.UpdatedAt)
		s := RemoteSession{ID: r.ID, Title: r.Title, Model: r.Meta.Model, Status: r.Status, Unread: r.Unread, Updated: at, Summary: r.Meta.Summary.Detail}
		if s.Summary == "" {
			s.Summary = r.Meta.Summary.Recent
		}
		if s.Title == "" {
			s.Title = r.ID
		}
		if r.Meta.Context.Max > 0 {
			s.CtxPct = fmt.Sprintf("%.0f%%", 100*r.Meta.Context.Used/r.Meta.Context.Max)
		}
		st.Items = append(st.Items, s)
	}
	sort.SliceStable(st.Items, func(i, j int) bool { return st.Items[i].Updated.After(st.Items[j].Updated) })
	return st
}

// merge takes a new read: a failed one keeps the last good list and shows its error with it.
func (r RemoteState) merge(n RemoteState) RemoteState {
	if n.Err != "" {
		r.Err = n.Err
		return r
	}
	return n
}

func (r RemoteState) index(id string) int {
	for i, s := range r.Items {
		if s.ID == id {
			return i
		}
	}
	return -1
}

// Label is the state as the section shows it.
func (s RemoteSession) Label() string {
	switch {
	case s.Status == "requires_action":
		return "asks"
	case s.Status != "idle" && s.Status != "":
		return "working"
	case s.Unread:
		return "reply"
	}
	return "idle"
}

// needsYou: it asks something, or answered and waits for the owner to read it.
func (s RemoteSession) needsYou() bool { l := s.Label(); return l == "asks" || l == "reply" }

func remoteURL(id string) string { return "https://claude.ai/code/" + id }

type remoteSentMsg struct{ id, title, err string }

// remoteSendRun runs the claude CLI outside any project; a variable so tests can record the calls.
var remoteSendRun = func(ctx context.Context, args ...string) ([]byte, error) {
	c := cmdCtx(ctx, "claude", args...)
	c.Dir = os.TempDir()
	return c.CombinedOutput()
}

// remoteSend sends text to the session the way the CLI does for a cloud session: claude -p text --cloud id.
func remoteSend(id, text string) error {
	ctx, cancel := context.WithTimeout(context.Background(), remoteSendMax)
	defer cancel()
	if strings.HasPrefix(text, "-") { // never an option of the CLI
		text = " " + text
	}
	out, err := remoteSendRun(ctx, "-p", text, "--cloud", id)
	if err != nil {
		msg := strings.Join(strings.Fields(string(out)), " ")
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("%s", msg)
	}
	return nil
}

// remoteOpen opens the session on claude.ai/code in the default browser; a variable so tests do not open one.
var remoteOpen = func(url string) error { return exec.Command("open", url).Start() }
