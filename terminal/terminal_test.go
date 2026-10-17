package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-runewidth"
)

func TestNumbered(t *testing.T) {
	cases := []struct {
		text string
		want int
	}{
		{"Which one?\n1. merge and push\n2. merge only\n3. not yet", 3},
		{"Pick:\n1) **Yes**\n2) No", 2},
		{"1. only one", 0},
		{"1. a\n3. skipped two", 0},
		// a numbered list in the middle of a long message is not a set of options
		{"1. first point\n2. second point\n" + strings.Repeat("more text\n", 15), 0},
		// paragraphs are not options
		{"1. " + strings.Repeat("long ", 30) + "\n2. " + strings.Repeat("long ", 30), 0},
	}
	for _, c := range cases {
		if got := numbered(c.text); len(got) != c.want {
			t.Errorf("numbered(%q) = %v, want %d options", c.text[:20], got, c.want)
		}
	}
}

func TestMentionedFiles(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.go"), nil, 0o644)
	os.MkdirAll(filepath.Join(dir, "docs"), 0o755)
	os.WriteFile(filepath.Join(dir, "docs", "x.md"), nil, 0o644)
	got := mentionedFiles("Changed `a.go:12` and docs/x.md, not missing/y.go.", dir)
	if len(got) != 2 || got[0] != filepath.Join(dir, "a.go") || got[1] != filepath.Join(dir, "docs", "x.md") {
		t.Fatalf("got %v", got)
	}
}

func writeTranscript(t *testing.T, lines ...string) string {
	p := filepath.Join(t.TempDir(), "t.jsonl")
	os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
	return p
}

const askLine = `{"type":"assistant","message":{"content":[{"type":"text","text":"Let me ask."},{"type":"tool_use","id":"tu1","name":"AskUserQuestion","input":{"questions":[{"question":"Pick a colour.","options":[{"label":"Red"},{"label":"Blue"}]}]}}]}}`

func TestReadLastOpenQuestion(t *testing.T) {
	l := readLast(writeTranscript(t, askLine), "/")
	if !l.Menu || l.Question != "Pick a colour." || len(l.Options) != 2 || l.Options[1] != "Blue" {
		t.Fatalf("got %+v", l)
	}
}

func TestReadLastAnsweredQuestion(t *testing.T) {
	answered := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"Blue"}]}}`
	final := `{"type":"assistant","message":{"content":[{"type":"text","text":"Blue"}]}}`
	l := readLast(writeTranscript(t, askLine, answered, final), "/")
	if l.Menu || len(l.Options) != 0 || l.Text != "Blue" {
		t.Fatalf("got %+v", l)
	}
}

func TestReadLastPlainPrompt(t *testing.T) {
	prompt := `{"type":"user","message":{"content":"a plain string prompt"}}`
	msg := `{"type":"assistant","message":{"content":[{"type":"text","text":"Merge?\n1. merge and push\n2. not yet"}]}}`
	l := readLast(writeTranscript(t, prompt, msg), "/")
	if l.Menu || len(l.Options) != 2 {
		t.Fatalf("got %+v", l)
	}
}

func TestConfigDefaultsAndPartialFile(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	c, _, err := loadConfig() // writes the default
	if err != nil || len(c.Replies) != 6 || c.Keys.Next != "l" || c.Keys.Prev != "j" || c.Keys.Reply != "k" {
		t.Fatalf("default: %v %+v", err, c)
	}
	if _, err := os.Stat(configPath()); err != nil {
		t.Fatal("default config not written")
	}
	os.WriteFile(configPath(), []byte("[[reply]]\nkey = \"x\"\ntext = \"do x\"\n"), 0o644)
	c, _, err = loadConfig()
	if err != nil || c.Keys.Next != "l" || len(c.Replies) != 1 || c.Replies[0].Label != "do x" {
		t.Fatalf("partial: %v %+v", err, c)
	}
	if r, ok := c.directReply("x"); !ok || r.Text != "do x" {
		t.Fatal("directReply")
	}
	os.WriteFile(configPath(), []byte("[[reply]]\nkey = \"space q\"\ntext = \"q\"\n"), 0o644)
	c, _, _ = loadConfig()
	if _, ok := c.leaderReply("q"); !ok {
		t.Fatal("leaderReply")
	}
}

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// Every view, at several sizes, is exactly as tall as the screen and no line is wider than it; framed lines
// fill the width exactly (the box lines stay straight).
const recapLine = `{"type":"system","subtype":"away_summary","content":"We fixed the queue. Next, merge it. (disable recaps in /config)","timestamp":"2026-10-17T15:29:15.319Z"}`

func TestReadLastRecap(t *testing.T) {
	msg := `{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}`
	l := readLast(writeTranscript(t, msg, recapLine), "/")
	if l.Recap != "We fixed the queue. Next, merge it." || l.RecapAt.IsZero() || l.Text != "done" {
		t.Fatalf("got %+v", l)
	}
	if l := readLast(writeTranscript(t, msg), "/"); l.Recap != "" {
		t.Fatalf("no recap line, got %q", l.Recap)
	}
}

func TestViewGeometry(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	now := time.Now()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}}
	for i, st := range []string{"input", "done", "working", "idle", "blocked"} {
		m.agents = append(m.agents, Agent{SID: string(rune('a' + i)), Name: "agent-" + st + "-with-a-long-name", Cwd: "/tmp",
			State: st, Busy: st == "working", Since: now.Add(-time.Duration(i) * time.Hour), InTerminal: i != 4})
	}
	m.agents[0].Ask = strings.Repeat("should the first batch be the roasters you buy from, or all of them? ", 4)
	sortAgents(m.agents)
	m.selSID = m.agents[0].SID
	long := strings.Replace(recapLine, "We fixed the queue.", strings.Repeat("A long recap line. ", 40), 1)
	m.agents[0].Transcript = writeTranscript(t, `{"type":"assistant","effort":"xhigh","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"hi\n\n| a | b |\n|---|---|\n| one | two |"}]}}`, long)
	m.usage = Usage{OK: true, Five: Limit{Pct: 54, Reset: now.Add(97 * time.Minute), OK: true}, Week: Limit{Pct: 88, Reset: now.Add(50 * time.Hour), OK: true}}
	m.pc = PCState{Items: []PCItem{{Ref: "COS-5", Status: "blocked", Title: "t", Detail: "why", Needs: true}}}
	m.props = []string{"skill x: something"}
	m.pulls = PullsState{Items: []PullReq{{Repo: "westsoever/cos", Number: 12, Title: "t", Draft: true, Updated: now.Add(-time.Hour)}}}
	m.sync = []string{"## repo", "needs: 1 stash"}
	m.find = findFixtureState()
	for _, v := range []view{vDesk, vWall, vFiles, vRepos, vRecaps, vProposals, vPulls, vPaperclip, vFind, vHelp} {
		for _, sz := range [][2]int{{80, 24}, {120, 40}, {200, 60}} {
			m.view, m.w, m.h = v, sz[0], sz[1]
			lines := strings.Split(m.View(), "\n")
			if len(lines) != m.h {
				t.Errorf("view %d %dx%d: %d lines", v, m.w, m.h, len(lines))
			}
			for i, l := range lines {
				p := ansiRe.ReplaceAllString(l, "")
				w := runewidth.StringWidth(p)
				framed := strings.ContainsAny(p, "│┌└")
				if w > m.w || (framed && v == vDesk && w != m.w) {
					t.Errorf("view %d %dx%d line %d: width %d: %q", v, m.w, m.h, i, w, p)
				}
			}
		}
	}
}

// A session that changed folder (EnterWorktree, cd) keeps its meta transcript path from its start, but Claude
// Code writes under the new folder's project dir: the stale path must not hide the chat.
func TestFindTranscriptAfterFolderChange(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	write := func(dir string) string {
		p := filepath.Join(home, ".claude", "projects", dir, "sid1.jsonl")
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte("{}\n"), 0o644)
		return p
	}
	stale := filepath.Join(home, ".claude", "projects", "-Users-me", "sid1.jsonl")
	moved := write("-Users-me-repo--claude-worktrees-wt")
	if got := findTranscript(stale, "/Users/me/repo/.claude/worktrees/wt", "sid1"); got != moved {
		t.Errorf("cwd's project dir: got %q want %q", got, moved)
	}
	if got := findTranscript(stale, "/somewhere/else", "sid1"); got != moved {
		t.Errorf("any project dir: got %q want %q", got, moved)
	}
	if got := findTranscript(moved, "/x", "sid1"); got != moved {
		t.Errorf("a valid recorded path is kept: got %q", got)
	}
	if got := findTranscript(stale, "/x", "none"); got != stale {
		t.Errorf("nothing found keeps the recorded path: got %q", got)
	}
}

// A finished turn is DONE only when nothing is left: no next action, no blocker, no NEXT.md. The checkpoint is
// read from the repo's .agent (with a GOAL.md) or the session's own folder, and "none" counts as empty.
func TestNothingLeft(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENT_HOME", home)
	state := func(dir, next, blocker string) {
		os.MkdirAll(dir, 0o755)
		os.WriteFile(filepath.Join(dir, "STATE.md"), []byte("# s\n<!-- ching:checkpoint -->\nresult: ok\nblocker: "+blocker+"\nnext_action: "+next+"\n<!-- /ching:checkpoint -->\nnext_action: outside the block\n"), 0o644)
	}
	sess := filepath.Join(home, "sessions", "s1")
	state(sess, "none", "(none)")
	if !nothingLeft("", "s1") {
		t.Error("none/(none) is empty, the line outside the block is not the checkpoint")
	}
	state(sess, "Merge the PR", "none")
	if nothingLeft("", "s1") {
		t.Error("a next action is left")
	}
	state(sess, "none", "waiting on the owner's key")
	if nothingLeft("", "s1") {
		t.Error("a blocker is left")
	}
	state(sess, "none", "none")
	os.WriteFile(filepath.Join(sess, "NEXT.md"), []byte(" \n"), 0o644)
	if !nothingLeft("", "s1") {
		t.Error("a blank NEXT.md is nothing")
	}
	os.WriteFile(filepath.Join(sess, "NEXT.md"), []byte("- ship it\n"), 0o644)
	if nothingLeft("", "s1") {
		t.Error("NEXT.md has an item")
	}
	// a repo with a GOAL.md keeps its state in <root>/.agent, and the session folder is ignored
	root := t.TempDir()
	state(filepath.Join(root, ".agent"), "none", "none")
	os.WriteFile(filepath.Join(root, ".agent", "GOAL.md"), []byte("# goal\n"), 0o644)
	if !nothingLeft(root, "s1") {
		t.Error("the repo's .agent says nothing is left")
	}
	state(filepath.Join(root, ".agent"), "Fix the build", "none")
	if nothingLeft(root, "s1") {
		t.Error("the repo's next action is left")
	}
}

// The queue lists INPUT (asked the owner, or blocked) above WAITING (done, something open), then WORKING, IDLE
// and DONE (done, nothing left); an INPUT row shows what it asks under it.
func TestQueueSections(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	now := time.Now()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}}
	m.agents = []Agent{
		{SID: "d", Name: "old-done", State: "done", Since: now.Add(-3 * time.Hour)},
		{SID: "w", Name: "busy", State: "working", Busy: true, Since: now},
		{SID: "i", Name: "asks", State: "input", Ask: "Want me to merge?", Since: now.Add(-time.Minute)},
		{SID: "z", Name: "fresh", State: "idle", Since: now},
		{SID: "b", Name: "stuck", State: "blocked", Since: now.Add(-2 * time.Hour)},
		{SID: "m", Name: "menu", State: "working", Busy: true, Asking: true, Ask: "stale", Since: now.Add(-30 * time.Minute)},
		{SID: "c", Name: "closed", State: "done", Closed: true, Since: now.Add(-5 * time.Hour)},
	}
	sortAgents(m.agents)
	var order []string
	for _, a := range m.agents {
		order = append(order, a.Name)
	}
	if got, want := strings.Join(order, " "), "stuck menu asks old-done busy fresh closed"; got != want {
		t.Errorf("order: got %q want %q", got, want)
	}
	m.selSID = "z"
	out := ansiRe.ReplaceAllString(strings.Join(m.queuePanel(60, 30), "\n"), "")
	last := -1
	for _, h := range []string{" INPUT", "stuck", "menu", "asks", "↳ Want me to merge?", " WAITING", "old-done", " WORKING", "busy", " IDLE", "fresh", " DONE", "closed"} {
		at := strings.Index(out, h)
		if at < 0 || at < last {
			t.Fatalf("%q missing or out of order in:\n%s", h, out)
		}
		last = at
	}
	if strings.Contains(out, "stale") {
		t.Errorf("an ask from an earlier turn is shown:\n%s", out)
	}
}

// The conversation keeps the owner's prompts (a slash command as "/name args") and the agent's texts in order;
// tool calls, tool results, meta entries and tagged machinery (command output, reminders) are left out.
func TestReadLastChat(t *testing.T) {
	l := readLast(writeTranscript(t,
		`{"type":"user","message":{"content":"first prompt"}}`,
		`{"type":"user","isMeta":true,"message":{"content":"Caveat: meta"}}`,
		`{"type":"user","message":{"content":"<command-name>/rename</command-name>"}}`,
		`{"type":"user","message":{"content":"<local-command-stdout>Session renamed</local-command-stdout>"}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}`,
		`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"out"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}`,
		`{"type":"user","message":{"content":[{"type":"text","text":"second prompt"},{"type":"image"}]}}`,
	), "/")
	var got []string
	for _, c := range l.Chat {
		who := "agent"
		if c.User {
			who = "you"
		}
		got = append(got, who+":"+c.Text)
	}
	if want := "you:first prompt|you:/rename|agent:Looking.|agent:Done.|you:second prompt"; strings.Join(got, "|") != want {
		t.Fatalf("chat: got %q want %q", strings.Join(got, "|"), want)
	}
}

// The panel shows the newest part of the conversation; the scroll keys go back and forth, the panel says how
// much is above and below, and another agent starts at its newest line. A recap gets a divider under it.
func TestChatScroll(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	var lines []string
	for i := 1; i <= 40; i++ {
		lines = append(lines, `{"type":"user","message":{"content":"prompt `+itoa(i)+`"}}`,
			`{"type":"assistant","message":{"content":[{"type":"text","text":"answer `+itoa(i)+`"}]}}`)
	}
	lines = append(lines, `{"type":"system","subtype":"away_summary","content":"the recap","timestamp":"2026-10-17T10:00:00Z"}`)
	tr := writeTranscript(t, lines...)
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, ed: newEditor(),
		prompts: map[string]Prompt{}, scroll: &chatScroll{}, w: 140, h: 40}
	m.agents = []Agent{{SID: "a", Name: "one", Cwd: "/tmp", State: "done", Transcript: tr},
		{SID: "b", Name: "two", Cwd: "/tmp", State: "done", Transcript: tr}}
	m.selSID = "a"
	screen := func() string {
		out := ansiRe.ReplaceAllString(m.View(), "")
		for i, l := range strings.Split(out, "\n") {
			if w := runewidth.StringWidth(l); w != m.w && strings.ContainsAny(l, "│") {
				t.Fatalf("line %d is %d wide: %q", i, w, l)
			}
		}
		return out
	}
	out := screen()
	if !strings.Contains(out, "answer 40") || strings.Contains(out, "answer 1 ") || !strings.Contains(out, "earlier lines") {
		t.Fatalf("not at the newest line:\n%s", out)
	}
	if r, d := strings.Index(out, "the recap"), strings.Index(out, "─ session ─"); r < 0 || d < r {
		t.Fatalf("no divider under the recap:\n%s", out)
	}
	m.scrollChat("up")
	if out = screen(); !strings.Contains(out, "↓ 3 newer lines") {
		t.Fatalf("up did not scroll back:\n%s", out)
	}
	m.scrollChat("home")
	if out = screen(); !regexp.MustCompile(`› prompt 1\s`).MatchString(out) {
		t.Fatalf("home did not reach the start:\n%s", out)
	}
	if strings.Contains(out, "earlier lines") {
		t.Fatalf("at the start but says there is more above:\n%s", out)
	}
	m.scrollChat("down")
	m.scrollChat("end")
	if out = screen(); strings.Contains(out, "newer lines") || !strings.Contains(out, "answer 40") {
		t.Fatalf("end did not come back to the newest line:\n%s", out)
	}
	m.scrollChat("home")
	screen()
	m.selSID = "b"
	if out = screen(); !strings.Contains(out, "answer 40") || strings.Contains(out, "newer lines") {
		t.Fatalf("another agent did not start at its newest line:\n%s", out)
	}
	if m.scrollChat("x") {
		t.Fatal("x is no scroll key")
	}
}

func itoa(i int) string { return strconv.Itoa(i) }

// With the reply box open, ↑ on the first row and ↓ on the last row of the draft scroll the conversation; inside
// a draft of several lines they move the cursor; with a suggestion list open they pick in it; pgup always scrolls.
func TestTypingScroll(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	var lines []string
	for i := 1; i <= 40; i++ {
		lines = append(lines, `{"type":"user","message":{"content":"prompt `+itoa(i)+`"}}`,
			`{"type":"assistant","message":{"content":[{"type":"text","text":"answer `+itoa(i)+`"}]}}`)
	}
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, ed: newEditor(),
		prompts: map[string]Prompt{}, scroll: &chatScroll{}, w: 140, h: 40}
	m.agents = []Agent{{SID: "a", Name: "one", Cwd: "/tmp", State: "done", Transcript: writeTranscript(t, lines...), InTerminal: true}}
	m.selSID = "a"
	m.mode = mTyping
	m.ed.open("a", "/tmp", m.editorWidth())
	m.View()
	press := func(k tea.KeyType) {
		nm, _ := m.typingKey(tea.KeyMsg{Type: k})
		m = nm.(model)
		m.View()
	}
	press(tea.KeyUp)
	if m.scroll.off != 3 {
		t.Fatalf("empty draft: up did not scroll (off %d)", m.scroll.off)
	}
	press(tea.KeyDown)
	if m.scroll.off != 0 {
		t.Fatalf("empty draft: down did not scroll back (off %d)", m.scroll.off)
	}
	m.ed.ta.SetValue("line one\nline two") // the cursor ends on the second line
	press(tea.KeyUp)
	if m.scroll.off != 0 || m.ed.ta.Line() != 0 {
		t.Fatalf("two-line draft: up should move the cursor (off %d, line %d)", m.scroll.off, m.ed.ta.Line())
	}
	press(tea.KeyUp)
	if m.scroll.off != 3 {
		t.Fatalf("two-line draft, first line: up did not scroll (off %d)", m.scroll.off)
	}
	press(tea.KeyPgDown)
	if m.scroll.off != 0 {
		t.Fatalf("pgdown did not scroll (off %d)", m.scroll.off)
	}
	m.ed.comp = []string{"@a", "@b"}
	m.ed.compSel = 1
	press(tea.KeyUp)
	if m.scroll.off != 0 || m.ed.compSel != 0 {
		t.Fatalf("suggestions open: up should pick in them (off %d, sel %d)", m.scroll.off, m.ed.compSel)
	}
}

// An answer sent from kaching sends the agent's window back (queue.sh return); moving inside a menu does not.
func TestReturnWindow(t *testing.T) {
	for _, w := range []string{"key left", "key right", "key tab", "key up", "key down"} {
		if returnWindow("s", w) != nil {
			t.Errorf("%s returns the window", w)
		}
	}
	for _, w := range []string{"answer", "fix it", "key 1", "key enter"} {
		if returnWindow("s", w) == nil {
			t.Errorf("%s does not return the window", w)
		}
	}
}

// Space selects the INPUT agent that has waited the longest, every time: it skips done agents (WAITING) and
// doesn't cycle on to the next one until that one is answered.
func TestNextWaitingLongestInput(t *testing.T) {
	cfg, _, _ := loadConfig()
	now := time.Now()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}}
	m.agents = []Agent{
		{SID: "done-oldest", State: "done", Since: now.Add(-3 * time.Hour)},
		{SID: "input-new", State: "input", Since: now.Add(-5 * time.Minute)},
		{SID: "blocked-old", State: "blocked", Since: now.Add(-time.Hour)},
		{SID: "working", State: "working", Busy: true, Since: now.Add(-4 * time.Hour)},
	}
	m.selSID = "working"
	for i := 0; i < 3; i++ {
		m.nextWaiting()
		if m.selSID != "blocked-old" {
			t.Fatalf("press %d: selected %s", i+1, m.selSID)
		}
	}
	m.agents[2].State = "working" // answered
	if m.nextWaiting(); m.selSID != "input-new" {
		t.Fatalf("after the answer: selected %s", m.selSID)
	}
	m.agents[1].State = "idle"
	if m.nextWaiting(); m.selSID != "input-new" || m.status == "" {
		t.Fatalf("nobody in INPUT: selected %s, status %q", m.selSID, m.status)
	}
}

// A busy agent's menu counts from when it first showed, so space doesn't jump to an agent just because its turn
// began earlier; its screen is read while not selected, so a missed read doesn't drop it out of INPUT.
func TestSpaceWithMenus(t *testing.T) {
	cfg, _, _ := loadConfig()
	now := time.Now()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, prompts: map[string]Prompt{}}
	m.agents = []Agent{
		{SID: "A", State: "input", Since: now.Add(-10 * time.Minute), InTerminal: true},
		{SID: "M", State: "working", Busy: true, Since: now.Add(-30 * time.Minute), InTerminal: true}, // turn began 30m ago
		{SID: "idle", State: "idle", Since: now.Add(-time.Hour), InTerminal: true},
	}
	m.selSID = "idle"
	// every busy agent's screen is read (every second tick), selected or not; idle ones are not
	m.ticks = 2
	m.selSID = "A"
	if !m.screenWanted(m.agents[1]) || m.screenWanted(m.agents[2]) {
		t.Fatal("busy M must be read, idle must not")
	}
	m.selSID = "idle"
	// M's menu shows now: it waits since now, so A (10 min) is still the longest
	menu := Prompt{Options: []string{"Yes", "No"}}
	mm, _ := m.Update(promptMsg{"M", menu})
	m = mm.(model)
	m.nextWaiting()
	if m.selSID != "A" {
		t.Fatalf("space chose %s, want A", m.selSID)
	}
	m.move(1) // cycle away
	// one read misses M's menu, the next one finds it again: same menu, same wait
	mm, _ = m.Update(promptMsg{"M", Prompt{}})
	m = mm.(model)
	first := m.asked["M"].first
	mm, _ = m.Update(promptMsg{"M", menu})
	m = mm.(model)
	if !m.asked["M"].first.Equal(first) {
		t.Fatal("a missed read restarted M's wait")
	}
	m.nextWaiting()
	if m.selSID != "A" {
		t.Fatalf("space after cycling away chose %s, want A", m.selSID)
	}
	// a menu back after the grace is a new wait
	m.sawAsk("M", first.Add(askGrace+time.Second))
	if !m.asked["M"].first.After(first) {
		t.Fatal("a menu after the grace kept the old wait")
	}
}
