package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// What the owner sent shows in the conversation however Claude Code wrapped it: a paste, a slash command with
// its arguments, a ! command. Machinery around it (reminders, command output, notifications) does not.
func TestPromptText(t *testing.T) {
	cases := []struct{ in, want string }{
		{"plain words", "plain words"},
		{"\n\n<pasted_content id=\"bf5d\">\n1. first\n2. second\n</pasted_content id=\"bf5d\">", "1. first\n2. second"},
		{"look at this\n<pasted_content id=\"x1\">some log</pasted_content id=\"x1\">", "look at this\nsome log"},
		{"<command-message>rename</command-message>\n<command-name>/rename</command-name>\n<command-args>KachingUpdates</command-args>", "/rename KachingUpdates"},
		{"<command-name>/merge</command-name>\n<command-args></command-args>", "/merge"},
		{"<bash-input>git status</bash-input>", "! git status"},
		{"<local-command-stdout>Session renamed</local-command-stdout>", ""},
		{"<task-notification><task-id>x</task-id></task-notification>", ""},
		{"<system-reminder>hook said hi</system-reminder>\nthe real prompt", "the real prompt"},
		{"Caveat: the messages below were generated", ""},
	}
	for _, c := range cases {
		if got := promptText(c.in); got != c.want {
			t.Errorf("promptText(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The first prompt of a session, sent as a paste, is in the conversation (it used to be dropped).
func TestReadLastFirstPastedPrompt(t *testing.T) {
	l := readLast(writeTranscript(t,
		`{"type":"user","isMeta":true,"message":{"content":"<system-reminder>named</system-reminder>"}}`,
		`{"type":"user","message":{"content":"\n\n<pasted_content id=\"a\">\nfix the files view\n</pasted_content id=\"a\">"}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"On it."}]}}`,
	), "/")
	if len(l.Chat) != 2 || !l.Chat[0].User || l.Chat[0].Text != "fix the files view" {
		t.Fatalf("chat = %+v", l.Chat)
	}
}

// The owner's prompts sit on a band of their own colour, so they stand out from the agent's replies.
func TestPromptBand(t *testing.T) {
	lipgloss.SetColorProfile(termenv.ANSI256)
	rows := chatLines(Last{Chat: []Turn{{User: true, Text: "my prompt"}, {Text: "the reply"}}}, 40, "auto")
	if len(rows) < 3 {
		t.Fatalf("rows = %q", rows)
	}
	if !strings.Contains(rows[0], "48;5;236") {
		t.Errorf("prompt row has no band: %q", rows[0])
	}
	if strings.Contains(rows[len(rows)-1], "48;5;236") {
		t.Errorf("reply row has the band: %q", rows[len(rows)-1])
	}
}

// The FL list keeps the newest histMax mentions, newest first, and survives a restart; a file mentioned again
// later moves up, an older mention of it doesn't.
func TestFileHistory(t *testing.T) {
	h := &fileHistory{}
	t0 := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	for i := 0; i < histMax+5; i++ {
		h.add("/f/"+string(rune('a'+i%26))+string(rune('a'+i/26)), "ag", t0.Add(time.Duration(i)*time.Minute))
	}
	if len(h.items) != histMax || h.items[0].At != t0.Add(time.Duration(histMax+4)*time.Minute) {
		t.Fatalf("len %d, first %v", len(h.items), h.items[0])
	}
	last := h.items[histMax-1].Path
	if h.add(last, "other", t0) { // an older mention: no change
		t.Fatal("older mention moved the file")
	}
	if !h.add(last, "other", t0.Add(time.Hour)) || h.items[0].Path != last || h.items[0].Agent != "other" {
		t.Fatalf("newer mention did not move it up: %v", h.items[0])
	}
	h.save()
	if g := loadFileHistory(); len(g.items) != histMax || g.items[0].Path != last {
		t.Fatalf("reloaded %d items, first %v", len(g.items), g.items)
	}
}

// Mentions of agents that are gone stay in the FL view; files that no longer exist are left out.
func TestFilesViewKeepsGoneAgents(t *testing.T) {
	dir := t.TempDir()
	keep := filepath.Join(dir, "keep.md")
	os.WriteFile(keep, nil, 0o644)
	m := newModel()
	m.agents = nil
	m.files = &fileHistory{}
	m.files.add(keep, "gone-agent", time.Now().Add(-time.Hour))
	m.files.add(filepath.Join(dir, "deleted.md"), "gone-agent", time.Now())
	fs := m.allFiles()
	if len(fs) != 1 || fs[0].path != keep || fs[0].agent != "gone-agent" {
		t.Fatalf("files = %+v", fs)
	}
}

// The PO and PC tabs fill orange while something waits for the owner there, and show how many.
func TestTabAlerts(t *testing.T) {
	lipgloss.SetColorProfile(termenv.ANSI256)
	m := newModel()
	m.w, m.h = 160, 40
	plain := m.tabBar()[1]
	if strings.Contains(plain, "48;5;202") {
		t.Fatalf("no alerts, but an orange tab: %q", plain)
	}
	m.props = []string{"skill x: a", "rule y: b"}
	m.pc = PCState{Items: []PCItem{{Ref: "COS-1", Needs: true}, {Ref: "COS-2"}}}
	bar := escRe.ReplaceAllString(m.tabBar()[1], "")
	if !strings.Contains(bar, "proposals  2") || !strings.Contains(bar, "paperclip  1") {
		t.Fatalf("counts missing: %q", bar)
	}
	if n := strings.Count(m.tabBar()[1], "48;5;202"); n < 2 {
		t.Fatalf("want two orange tabs, got %d styled runs: %q", n, m.tabBar()[1])
	}
}

// Background sessions (claude --bg) are agents kaching can write to; unclaimed spares are not listed.
func TestLoadAgentsBackground(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	sess := filepath.Join(home, ".claude", "sessions")
	os.MkdirAll(sess, 0o755)
	pid := os.Getpid()
	os.WriteFile(filepath.Join(sess, "1.json"), []byte(`{"pid":`+strconv.Itoa(pid)+`,"sessionId":"c6bd5097-ec6c","cwd":"/tmp","kind":"bg","jobId":"c6bd5097","name":"nw-probe","status":"idle"}`), 0o644)
	os.WriteFile(filepath.Join(sess, "2.json"), []byte(`{"pid":`+strconv.Itoa(pid)+`,"cwd":"/tmp","kind":"bg"}`), 0o644)
	ags := loadAgents(map[string]tabPos{}, nil)
	if len(ags) != 1 || !ags[0].Bg || ags[0].Job != "c6bd5097" || ags[0].InTerminal || !ags[0].canSend() {
		t.Fatalf("agents = %+v", ags)
	}
}

// /NW finds its folder: a path, a folder in ~/bbq, an agent's name, or the selected agent's folder.
func TestResolveDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, "bbq", "soii"), 0o755)
	work := t.TempDir()
	m := newModel()
	m.agents = []Agent{{SID: "s1", Name: "miso-MASTER", Cwd: work}}
	m.selSID = "s1"
	cases := map[string]string{
		"":         work,
		"soii":     filepath.Join(home, "bbq", "soii"),
		"~/bbq":    filepath.Join(home, "bbq"),
		"miso":     work,
		work:       work,
		"nowhere":  "",
		"/no/such": "",
	}
	for arg, want := range cases {
		if got := m.resolveDir(arg); got != want {
			t.Errorf("resolveDir(%q) = %q, want %q", arg, got, want)
		}
	}
}

// Live: starts a real background session, writes to it through claude attach, stops it. Runs only with
// KACHING_LIVE_BG=1 (it uses the owner's Claude account).
func TestBackgroundLive(t *testing.T) {
	if os.Getenv("KACHING_LIVE_BG") == "" {
		t.Skip("KACHING_LIVE_BG=1 runs it")
	}
	home := os.Getenv("HOME")
	job, err := bgStart(nwOpts{Dir: home}, "Reply with just: pong")
	if err != nil {
		t.Fatal(err)
	}
	defer exec.Command(claudeBin(), "rm", job).Run()
	defer bgStop(job)
	var a *Agent
	for i := 0; i < 60 && a == nil; i++ {
		time.Sleep(500 * time.Millisecond)
		for _, x := range loadAgents(map[string]tabPos{}, nil) {
			if x.Bg && x.Job == job && !x.Busy && readLast(x.Transcript, x.Cwd).Text != "" { // idle, and it has replied
				a = &x
			}
		}
	}
	if a == nil {
		t.Fatalf("background agent %s never showed idle in the list", job)
	}
	if res := bgSend(job, "Reply with just: ping2", nil); res != "ok" {
		t.Fatal(res)
	}
	for i := 0; i < 60; i++ {
		time.Sleep(500 * time.Millisecond)
		l := readLast(a.Transcript, a.Cwd)
		if n := len(l.Chat); n >= 2 && l.Chat[n-2].User && l.Chat[n-2].Text == "Reply with just: ping2" && strings.Contains(l.Text, "ping2") {
			return
		}
	}
	t.Fatalf("the follow-up never reached %s: %+v", job, readLast(a.Transcript, a.Cwd).Chat)
}

// /NW opens the message box for a new background agent on the desk; an unknown folder is an error.
func TestNWCommand(t *testing.T) {
	work := t.TempDir()
	m := newModel()
	m.w, m.h = 140, 40
	m.agents = []Agent{{SID: "s1", Name: "miso", Cwd: work, InTerminal: true}}
	m.selSID = "s1"
	mm, _ := m.command("NW")
	m = mm.(model)
	if m.mode != mTyping || m.ed.target != "nw:"+work || m.view != vDesk {
		t.Fatalf("mode %v target %q view %v", m.mode, m.ed.target, m.view)
	}
	v := escRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "new background agent in "+tildify(work)) {
		t.Fatalf("no NW box in view:\n%s", v)
	}
	m.mode = mKeys
	mm, _ = m.command("NW no-such-folder-xyz")
	if m = mm.(model); m.mode == mTyping || !m.statusErr {
		t.Fatalf("unknown folder: mode %v status %q", m.mode, m.status)
	}
}

// The words after /NW: model, effort and permission words are picked out wherever they stand; the rest is the
// folder; keys.toml fills what they leave open.
func TestParseNW(t *testing.T) {
	cfg := Config{NWModel: "haiku", NWPerm: "bypass"}
	for _, c := range []struct {
		in   string
		want nwOpts
	}{
		{"", nwOpts{Model: "haiku", Perm: "bypassPermissions"}},
		{"soii", nwOpts{Dir: "soii", Model: "haiku", Perm: "bypassPermissions"}},
		{"soii sonnet", nwOpts{Dir: "soii", Model: "sonnet", Perm: "bypassPermissions"}},
		{"Opus xhigh ~/bbq/soii", nwOpts{Dir: "~/bbq/soii", Model: "opus", Effort: "xhigh", Perm: "bypassPermissions"}},
		{"plan miso data", nwOpts{Dir: "miso data", Model: "haiku", Perm: "plan"}},
		{"claude-opus-5-5", nwOpts{Model: "claude-opus-5-5", Perm: "bypassPermissions"}},
	} {
		if got := parseNW(c.in, cfg); got != c.want {
			t.Errorf("parseNW(%q) = %+v, want %+v", c.in, got, c.want)
		}
	}
	o := nwOpts{Dir: "/x", Model: "sonnet", Effort: "high", Perm: "plan"}
	if got := strings.Join(o.args("/model opus"), " "); got != "--bg --model sonnet --effort high --permission-mode plan -- /model opus" {
		t.Errorf("args = %q", got)
	}
	if got := strings.Join((nwOpts{Dir: "/x"}).args("hi"), " "); got != "--bg -- hi" {
		t.Errorf("plain args = %q", got)
	}
	if o.summary() != "sonnet · high · plan" {
		t.Errorf("summary = %q", o.summary())
	}
}

// /NW soii sonnet opens the box for that folder and shows the options.
func TestNWCommandOptions(t *testing.T) {
	work, err := os.MkdirTemp("/tmp", "nw") // a short path: the command line has little room
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(work) })
	m := newModel()
	m.w, m.h = 140, 40
	m.agents = []Agent{{SID: "s1", Name: "miso", Cwd: work, InTerminal: true}} // the panel's title shows the options
	m.selSID = "s1"
	m.cfg.NWModel, m.cfg.NWPerm = "", ""
	mm, _ := m.command("NW " + work + " sonnet high")
	m = mm.(model)
	if m.mode != mTyping || m.nw.Model != "sonnet" || m.nw.Effort != "high" || m.nw.Dir != work {
		t.Fatalf("mode %v nw %+v", m.mode, m.nw)
	}
	if v := escRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "new background agent in "+tildify(work)+" · sonnet · high") {
		t.Errorf("the box does not show the options:\n%s", v)
	}
}

// Live: /model works inside a background session. Claude Code asks "Switch model?"; kaching shows that menu from the
// session's logs, 1 confirms, and the next reply comes from the new model.
func TestBackgroundModelCommandLive(t *testing.T) {
	if os.Getenv("KACHING_LIVE_BG") == "" {
		t.Skip("KACHING_LIVE_BG=1 runs it")
	}
	job, err := bgStart(nwOpts{Dir: os.Getenv("HOME"), Model: "haiku"}, "Reply with just: pong")
	if err != nil {
		t.Fatal(err)
	}
	defer exec.Command(claudeBin(), "rm", job).Run()
	defer bgStop(job)
	var a *Agent
	for i := 0; i < 60 && a == nil; i++ {
		time.Sleep(500 * time.Millisecond)
		for _, x := range loadAgents(map[string]tabPos{}, nil) {
			if x.Bg && x.Job == job && !x.Busy && readLast(x.Transcript, x.Cwd).Text != "" { // idle, and it has replied
				a = &x
			}
		}
	}
	if a == nil {
		t.Fatal("the agent never showed idle")
	}
	if l := readLast(a.Transcript, a.Cwd); !strings.Contains(l.Model, "haiku") {
		t.Fatalf("started on %q, want haiku", l.Model)
	}
	if res := bgSend(job, "/model sonnet", nil); res != "ok" {
		t.Fatal(res)
	}
	var p Prompt
	for i := 0; i < 20 && len(p.Options) == 0; i++ {
		time.Sleep(500 * time.Millisecond)
		p = parsePrompt(bgScreen(job))
	}
	if len(p.Options) != 2 || !strings.HasPrefix(p.Options[0], "Yes, switch to Sonnet") {
		t.Fatalf("the menu kaching reads from the logs: %+v", p)
	}
	if res := bgSend(job, "", []string{"1"}); res != "ok" {
		t.Fatal(res)
	}
	time.Sleep(time.Second)
	if res := bgSend(job, "Reply with just: ok", nil); res != "ok" {
		t.Fatal(res)
	}
	for i := 0; i < 60; i++ {
		time.Sleep(500 * time.Millisecond)
		if l := readLast(a.Transcript, a.Cwd); strings.Contains(l.Model, "sonnet") && strings.Contains(l.Text, "ok") {
			return
		}
	}
	t.Fatalf("still on %q", readLast(a.Transcript, a.Cwd).Model)
}

// A new keys.toml starts the agents kaching starts (NW, b and t in PC) on Sonnet 5.5 at high effort.
func TestNWDefaultsSonnetHigh(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	o := parseNW("", cfg)
	want := []string{"--bg", "--model", "claude-sonnet-5-5", "--effort", "high", "--", "go"}
	if got := o.args("go"); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("args %q, want %q", got, want)
	}
}
