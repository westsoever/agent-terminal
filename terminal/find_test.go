package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/mattn/go-runewidth"
)

// ---- fixtures: small fake transcripts under a scratch HOME

func jsonLine(t *testing.T, v any) string {
	b, err := json.Marshal(v) // like Claude Code's own lines: "<" comes out as an escape
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

type tm = map[string]any

func userLine(t *testing.T, text string, at time.Time, cwd string) string {
	return jsonLine(t, tm{"parentUuid": nil, "isSidechain": false, "type": "user", "cwd": cwd, "timestamp": at.UTC().Format(time.RFC3339),
		"message": tm{"role": "user", "content": text}})
}

func userBlocks(t *testing.T, at time.Time, cwd string, blocks ...tm) string {
	return jsonLine(t, tm{"parentUuid": nil, "isSidechain": false, "type": "user", "cwd": cwd, "timestamp": at.UTC().Format(time.RFC3339),
		"message": tm{"role": "user", "content": blocks}})
}

func asstLine(t *testing.T, at time.Time, cwd string, blocks ...tm) string {
	return jsonLine(t, tm{"parentUuid": nil, "isSidechain": false, "type": "assistant", "cwd": cwd, "timestamp": at.UTC().Format(time.RFC3339),
		"message": tm{"role": "assistant", "model": "claude-opus-5-5", "content": blocks}})
}

func textBlock(s string) tm { return tm{"type": "text", "text": s} }

func asstText(t *testing.T, text string, at time.Time, cwd string) string {
	return asstLine(t, at, cwd, textBlock(text))
}

// titleLines are the title entries as Claude Code writes them: the type first.
func titleLines(t *testing.T, sid, custom, ai string) []string {
	var out []string
	q := func(s string) string { return jsonLine(t, s) }
	if custom != "" {
		out = append(out, `{"type":"custom-title","customTitle":`+q(custom)+`,"sessionId":"`+sid+`"}`,
			`{"type":"agent-name","agentName":`+q(custom)+`,"sessionId":"`+sid+`"}`)
	}
	if ai != "" {
		out = append(out, `{"type":"ai-title","aiTitle":`+q(ai)+`,"sessionId":"`+sid+`"}`)
	}
	return out
}

// writeSession writes ~/.claude/projects/<folder>/<id>.jsonl with that modification time.
func writeSession(t *testing.T, folder, id string, mtime time.Time, lines ...string) string {
	dir := filepath.Join(os.Getenv("HOME"), ".claude", "projects", folder)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, id+".jsonl")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	return p
}

const observerFolder = "-Users-clyde--claude-mem-observer-sessions"

func sid(n int) string { return fmt.Sprintf("%08d-aaaa-bbbb-cccc-%012d", n, n) }

func ids(hits []findHit) string {
	var out []string
	for _, h := range hits {
		out = append(out, h.ID[:8])
	}
	return strings.Join(out, " ")
}

// runCmd runs a command (and the commands of a batch) and returns the messages, for a test to feed back in.
func runCmd(cmd tea.Cmd) []tea.Msg {
	if cmd == nil {
		return nil
	}
	msg := cmd()
	if b, ok := msg.(tea.BatchMsg); ok {
		var out []tea.Msg
		for _, c := range b {
			out = append(out, runCmd(c)...)
		}
		return out
	}
	return []tea.Msg{msg}
}

// feed gives the messages of a command to the model, one after the other, and runs what each one asks for.
func feed(m model, cmd tea.Cmd) model {
	queue := runCmd(cmd)
	for len(queue) > 0 {
		mm, c := m.Update(queue[0])
		m, queue = mm.(model), append(queue[1:], runCmd(c)...)
	}
	return m
}

// searchFixture: a scratch HOME with the sessions that the tier tests search.
func searchFixture(t *testing.T) (now time.Time) {
	t.Setenv("HOME", t.TempDir())
	now = time.Now().Truncate(time.Second)
	h := func(d time.Duration) time.Time { return now.Add(-d) }
	// s1: two matching messages, an untitled session
	writeSession(t, "-tmp-proj-a", sid(1), h(time.Hour),
		userLine(t, "How do I deploy the Zebra service?", h(90*time.Minute), "/tmp/proj-a"),
		asstText(t, "Run the deploy script for zebra first. Then check the logs.", h(time.Hour), "/tmp/proj-a/sub"))
	// s2: the words are in two different messages: no match; a tool result with both words does not count
	writeSession(t, "-tmp-proj-a", sid(2), h(2*time.Hour),
		userLine(t, "start", h(3*time.Hour), "/tmp/proj-a"),
		asstText(t, "The ZEBRA is ready.", h(150*time.Minute), "/tmp/proj-a"),
		asstText(t, "Now we deploy it.", h(140*time.Minute), "/tmp/proj-a"),
		userBlocks(t, h(130*time.Minute), "/tmp/proj-a", tm{"type": "tool_result", "tool_use_id": "x", "content": "zebra deploy output"}))
	// s3: only machinery has the words
	writeSession(t, "-tmp-proj-b", sid(3), h(3*time.Hour),
		asstLine(t, h(4*time.Hour), "/tmp/proj-b", tm{"type": "tool_use", "id": "x", "name": "Bash", "input": tm{"command": "zebra deploy"}}),
		asstLine(t, h(4*time.Hour), "/tmp/proj-b", tm{"type": "thinking", "thinking": "zebra deploy"}),
		jsonLine(t, tm{"type": "user", "isMeta": true, "timestamp": h(4 * time.Hour).UTC().Format(time.RFC3339), "message": tm{"role": "user", "content": "zebra deploy meta"}}),
		userLine(t, "<local-command-stdout>zebra deploy</local-command-stdout>", h(4*time.Hour), "/tmp/proj-b"),
		userLine(t, "<system-reminder>zebra deploy</system-reminder>", h(4*time.Hour), "/tmp/proj-b"),
		jsonLine(t, tm{"type": "api-request-blob", "sessionId": sid(3), "blob": "zebra deploy in every message again"}),
		jsonLine(t, tm{"type": "attachment", "cwd": "/tmp/proj-b", "attachment": tm{"text": "zebra deploy"}}),
		jsonLine(t, tm{"type": "queue-operation", "operation": "enqueue", "content": "zebra deploy"}))
	// the observer folder and a sub-agent transcript are not searched
	writeSession(t, observerFolder, sid(4), h(time.Minute), userLine(t, "zebra deploy observer", h(time.Minute), "/x"))
	writeSession(t, filepath.Join("-tmp-proj-a", sid(1), "subagents"), "agent-x", h(time.Minute), userLine(t, "zebra deploy subagent", h(time.Minute), "/x"))
	// s6: older, renamed, a plain-string prompt, other case
	lines := append(titleLines(t, sid(6), "old-name", ""), titleLines(t, sid(6), "my-rename", "Auto title")...)
	writeSession(t, "-tmp-proj-c", sid(6), h(5*time.Hour), append(lines,
		userLine(t, "ZEBRA DEPLOY checklist please", h(6*time.Hour), "/tmp/proj-c"))...)
	return now
}

func TestParseQuery(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"zebra deploy", "zebra|deploy"},
		{"  Zebra   DEPLOY  ", "zebra|deploy"},
		{`"kaching resume" bug`, "kaching resume|bug"},
		{`say "hello   world"`, "say|hello world"},
		{`"unclosed phrase`, "unclosed|phrase"},
		{"dup Dup dup", "dup"},
		{"", ""},
		{`""`, ""},
	}
	for _, c := range cases {
		if got := strings.Join(parseQuery(c.in), "|"); got != c.want {
			t.Errorf("parseQuery(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSnippet(t *testing.T) {
	long := strings.Repeat("filler words go here. ", 40) + "The Zebra deploy broke on Friday. " + strings.Repeat("more filler text. ", 40)
	sn := makeSnippet(long, []string{"zebra", "deploy"}, 120)
	if !strings.Contains(sn, "Zebra deploy") || !strings.HasPrefix(sn, "…") || !strings.HasSuffix(sn, "…") {
		t.Errorf("snippet = %q", sn)
	}
	if n := len([]rune(sn)); n > 122 {
		t.Errorf("snippet is %d characters", n)
	}
	if got := makeSnippet("short\n\ntext   with  space", []string{"text"}, 120); got != "short text with space" {
		t.Errorf("short snippet = %q", got)
	}
	// the window shows the place where most words are, not only the first word
	far := "alpha " + strings.Repeat("x ", 150) + "alpha beta " + strings.Repeat("y ", 50)
	if sn := makeSnippet(far, []string{"alpha", "beta"}, 100); !strings.Contains(sn, "alpha beta") {
		t.Errorf("window misses both words: %q", sn)
	}
	// non-ASCII text keeps its characters
	uni := strings.Repeat("ä", 150) + " CAFÉ au lait " + strings.Repeat("ö", 150)
	if sn := makeSnippet(uni, []string{"café"}, 80); !strings.Contains(sn, "CAFÉ au lait") {
		t.Errorf("unicode snippet = %q", sn)
	}
}

func TestTitlesIn(t *testing.T) {
	tail := []byte(strings.Join([]string{
		`{"type":"custom-title","customTitle":"first","sessionId":"x"}`,
		`{"type":"agent-name","agentName":"first","sessionId":"x"}`,
		`{"type":"ai-title","aiTitle":"Auto one","sessionId":"x"}`,
		`{"type":"custom-title","customTitle":"second","sessionId":"x"}`,
		`{"type":"ai-title","aiTitle":"Auto two","sessionId":"x"}`,
	}, "\n"))
	got := titlesIn(tail)
	if got.Custom != "second" || got.Agent != "first" || got.AI != "Auto two" || got.display() != "second" {
		t.Errorf("titles = %+v", got)
	}
	if got := titlesIn([]byte(`{"type":"ai-title","aiTitle":"Only auto"}`)); got.display() != "Only auto" {
		t.Errorf("auto-title only: %+v", got)
	}
	if got := titlesIn([]byte(`{"type":"user","message":{"content":"{\"type\":\"custom-title\",\"customTitle\":\"x\"}"}}`)); got.display() != "" {
		t.Errorf("a title inside a message: %+v", got)
	}
	// the order of the keys does not matter
	if got := titlesIn([]byte(`{"customTitle":"reordered","sessionId":"x","type":"custom-title"}`)); got.Custom != "reordered" {
		t.Errorf("keys in another order: %+v", got)
	}
}

// ---- tier 1: names

func TestFindNamesTier(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now()
	writeSession(t, "-tmp-a", sid(1), now.Add(-time.Hour), append(titleLines(t, sid(1), "Kaching Find", ""),
		userLine(t, "hello", now, "/tmp/a"))...)
	writeSession(t, "-tmp-a", sid(2), now.Add(-2*time.Hour), append(titleLines(t, sid(2), "", "Fix the billing export"),
		userLine(t, "hello", now, "/tmp/a"))...)
	// no title in the file; the name is in the session's custom-title.json
	p := writeSession(t, "-tmp-b", sid(3), now.Add(-3*time.Hour), userLine(t, "hello", now, "/tmp/b"))
	side := strings.TrimSuffix(p, ".jsonl")
	os.MkdirAll(side, 0o755)
	os.WriteFile(filepath.Join(side, "custom-title.json"), []byte(`{"customTitle":"billing sidecar"}`), 0o644)
	writeSession(t, "-tmp-b", sid(4), now.Add(-4*time.Hour), userLine(t, "billing but untitled", now, "/tmp/b"))
	writeSession(t, observerFolder, sid(5), now, append(titleLines(t, sid(5), "", "Billing observer"), userLine(t, "x", now, "/x"))...)
	live := []Agent{
		{SID: "live-1", Name: "deploy-bot", Cwd: "/work/zebra", Branch: "feature/Billing", Since: now},
		{SID: sid(1), Name: "Kaching Find", Cwd: "/tmp/a", Since: now.Add(-time.Hour)}, // its transcript is a session too: listed once
	}
	sessions := listSessions()
	cases := []struct{ q, want string }{
		{"kaching", sid(1)},                            // the live agent's name, once, though its transcript is a session too
		{"find kaching", sid(1)},                       // both words, in one name
		{"zebra bot", "live-1"},                        // the name and the folder together
		{"billing", "live-1 " + sid(2) + " " + sid(3)}, // the live branch (any case), two past titles: not the untitled, not the observer
		{"BILLING export", sid(2)},                     // all words
		{"feature/billing", "live-1"},
		{"nothing-like-this", ""},
	}
	for _, c := range cases {
		var got []string
		for _, h := range searchNames(context.Background(), parseQuery(c.q), live, sessions) {
			got = append(got, h.ID)
			if h.Tier != tierName {
				t.Errorf("%q: tier %d", c.q, h.Tier)
			}
		}
		if g := strings.Join(got, " "); g != c.want {
			t.Errorf("%q: got %q want %q", c.q, g, c.want)
		}
	}
	// a past session: its display name, the folder from its first entry, the transcript
	hits := searchNames(context.Background(), parseQuery("billing export"), nil, sessions)
	if len(hits) != 1 || hits[0].Name != "Fix the billing export" || hits[0].Cwd != "/tmp/a" || hits[0].Path == "" {
		t.Errorf("past session hit: %+v", hits)
	}
	hits = searchNames(context.Background(), parseQuery("sidecar"), nil, sessions)
	if len(hits) != 1 || hits[0].Name != "billing sidecar" {
		t.Errorf("sidecar name: %+v", hits)
	}
}

func TestRawKeys(t *testing.T) {
	cases := []struct{ term, want string }{
		{"zebra", "zebra"},
		{"café", "caf"},
		{"<div>", "div"},
		{"a&b", ""},
		{"é", ""},
		{"file.go", "file.go"},
		{"it's fine", "s fine"},
		{"日本語", ""},
	}
	for _, c := range cases {
		var got []string
		for _, k := range rawKeys(c.term) {
			got = append(got, string(k))
		}
		if g := strings.Join(got, "|"); g != c.want {
			t.Errorf("rawKeys(%q) = %q, want %q", c.term, g, c.want)
		}
	}
}

// ---- tier 2: text

func TestFindTextTier(t *testing.T) {
	now := searchFixture(t)
	hits, st := searchText(context.Background(), parseQuery("zebra deploy"), listSessions())
	if st.Partial || st.Files != 4 { // s1 s2 s3 s6: not the observer folder, not the sub-agent
		t.Errorf("stats = %+v", st)
	}
	if got, want := ids(hits), sid(1)[:8]+" "+sid(6)[:8]; got != want {
		t.Fatalf("hits = %q, want %q", got, want)
	}
	h := hits[0]
	if h.Count != 2 || h.Who != "agent" || h.Cwd != "/tmp/proj-a" || h.Tier != tierText || h.Name != "" || h.label() != sid(1)[:7] {
		t.Errorf("s1 hit = %+v", h)
	}
	if !h.At.Equal(now.Add(-time.Hour)) || !strings.Contains(h.Snippet, "deploy script for zebra") {
		t.Errorf("s1 newest match: at %v snippet %q", h.At, h.Snippet)
	}
	h = hits[1]
	if h.Name != "my-rename" || h.Who != "you" || h.Count != 1 || h.Cwd != "/tmp/proj-c" || !strings.Contains(h.Snippet, "ZEBRA DEPLOY checklist") {
		t.Errorf("s6 hit = %+v", h)
	}
	// one word is a looser search: s2 has "zebra" in a message of its own
	hits, _ = searchText(context.Background(), parseQuery("zebra"), listSessions())
	if got, want := ids(hits), sid(1)[:8]+" "+sid(2)[:8]+" "+sid(6)[:8]; got != want {
		t.Errorf("one word: %q, want %q", got, want)
	}
	if hits, _ = searchText(context.Background(), parseQuery("zebra unicorn"), listSessions()); len(hits) != 0 {
		t.Errorf("a word that nobody said: %+v", hits)
	}
	// a quoted phrase is one term
	if hits, _ = searchText(context.Background(), parseQuery(`"deploy the zebra"`), listSessions()); ids(hits) != sid(1)[:8] {
		t.Errorf("phrase: %q", ids(hits))
	}
}

// Words the transcript writes in another form (a "<" as an escape, a capital non-ASCII letter) are still found.
func TestFindTextEscapesAndUnicode(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now()
	writeSession(t, "-tmp-a", sid(1), now, userLine(t, "Please use <div> and CAFÉ, not A&B", now, "/tmp/a"))
	raw, _ := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".claude", "projects", "-tmp-a", sid(1)+".jsonl"))
	if !strings.Contains(string(raw), "u003c") { // the fixture really has the escape
		t.Fatalf("fixture has no escape: %s", raw)
	}
	for _, q := range []string{"<div>", "café", "a&b", "use <DIV> café", "é", "É"} {
		if hits, _ := searchText(context.Background(), parseQuery(q), listSessions()); len(hits) != 1 {
			t.Errorf("%q: %d hits", q, len(hits))
		}
	}
}

func TestFindTextOrderAndCap(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now().Truncate(time.Second)
	for i := 1; i <= findMax+10; i++ { // session i is i minutes old
		at := now.Add(-time.Duration(i) * time.Minute)
		writeSession(t, "-tmp-a", sid(i), at, userLine(t, fmt.Sprintf("needle number %d", i), at, "/tmp/a"))
	}
	hits, st := searchText(context.Background(), parseQuery("needle"), listSessions())
	if len(hits) != findMax || st.Partial {
		t.Fatalf("%d hits, stats %+v", len(hits), st)
	}
	for i, h := range hits {
		if h.ID != sid(i+1) {
			t.Fatalf("hit %d is %s, want %s (newest first)", i, h.ID[:8], sid(i + 1)[:8])
		}
	}
}

// A slow disk or a huge corpus: when the time is spent the tier returns what it found, newest first, and says so.
func TestFindTextBudget(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now().Truncate(time.Second)
	for i := 1; i <= 12; i++ {
		at := now.Add(-time.Duration(i) * time.Minute)
		writeSession(t, "-tmp-a", sid(i), at, userLine(t, "needle", at, "/tmp/a"))
	}
	oldRead, oldBudget, oldWorkers := readTranscript, findBudget, findWorkers
	t.Cleanup(func() { readTranscript, findBudget, findWorkers = oldRead, oldBudget, oldWorkers })
	findWorkers = 1
	newestFirst := func(hits []findHit) {
		t.Helper()
		for i, h := range hits {
			if h.ID != sid(i+1) {
				t.Fatalf("hit %d is %s, want %s (the newest first)", i, h.ID[:8], sid(i + 1)[:8])
			}
		}
	}

	// the context ends while the fourth transcript is read: four are searched, the rest are not
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	readTranscript = func(p string, buf []byte) ([]byte, error) {
		if calls++; calls == 4 {
			cancel()
		}
		return readInto(p, buf)
	}
	hits, st := searchText(ctx, parseQuery("needle"), listSessions())
	if !st.Partial || len(hits) != 4 || st.Files != 4 {
		t.Fatalf("cancelled in the fourth: %d hits, stats %+v", len(hits), st)
	}
	newestFirst(hits)

	// the budget runs out: a slow disk
	readTranscript = func(p string, buf []byte) ([]byte, error) {
		time.Sleep(100 * time.Millisecond)
		return readInto(p, buf)
	}
	findBudget = 300 * time.Millisecond
	hits, st = searchText(context.Background(), parseQuery("needle"), listSessions())
	if !st.Partial || len(hits) >= 12 || st.Files >= 12 {
		t.Fatalf("slow disk: %d hits, stats %+v", len(hits), st)
	}
	newestFirst(hits)
	// the title says so
	f := findState{Query: "needle", NamesDone: true, TextDone: true, Partial: true, Text: hits}
	if s := f.status(); !strings.Contains(s, "partial") {
		t.Errorf("status %q", s)
	}
	// a search that is cancelled before it starts returns at once
	ctx, cancel = context.WithCancel(context.Background())
	cancel()
	readTranscript, findBudget = readInto, time.Minute
	if hits, st := searchText(ctx, parseQuery("needle"), listSessions()); len(hits) != 0 || !st.Partial {
		t.Errorf("cancelled: %d hits, %+v", len(hits), st)
	}
}

func TestFindExcerpts(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now()
	var lines []string
	for i := 0; i < 30; i++ {
		at := now.Add(time.Duration(i) * time.Minute)
		text := fmt.Sprintf("message %02d about nothing", i)
		if i == 3 || i == 4 || i == 10 || i == 15 || i == 20 || i == 25 {
			text = fmt.Sprintf("message %02d has the Needle", i)
		}
		if i%2 == 0 {
			lines = append(lines, userLine(t, text, at, "/tmp/a"))
		} else {
			lines = append(lines, asstText(t, text, at, "/tmp/a"))
		}
		if i == 5 { // a tool result between: no turn
			lines = append(lines, userBlocks(t, at, "/tmp/a", tm{"type": "tool_result", "tool_use_id": "x", "content": "needle"}))
		}
	}
	p := writeSession(t, "-tmp-a", sid(1), now, lines...)
	groups, all, err := loadExcerpts(p, parseQuery("needle"))
	if err != nil || all != 6 || len(groups) != excerptMax {
		t.Fatalf("all %d groups %d err %v", all, len(groups), err)
	}
	// the newest four matches 10, 15, 20, 25, each with a message on both sides
	var got []string
	for _, g := range groups {
		var one []string
		for _, tn := range g {
			mark := ""
			if tn.Match {
				mark = "*"
			}
			one = append(one, strings.Fields(tn.Text)[1]+mark)
		}
		got = append(got, strings.Join(one, ","))
	}
	if want := "09,10*,11|14,15*,16|19,20*,21|24,25*,26"; strings.Join(got, "|") != want {
		t.Errorf("groups %q, want %q", strings.Join(got, "|"), want)
	}
	if !groups[0][1].User || groups[0][2].User { // 10 is even: a prompt; 11 is a reply
		t.Errorf("who: %+v", groups[0])
	}
	// groups that touch are one: matches 3 and 4 with their neighbours
	groups, all, _ = loadExcerpts(writeSession(t, "-tmp-a", sid(2), now, lines[:9]...), parseQuery("needle")) // messages 0 to 7
	if all != 2 || len(groups) != 1 || len(groups[0]) != 4 {                                                  // 02 03* 04* 05
		t.Errorf("merged: all %d groups %+v", all, groups)
	}
}

// ---- tier 3: AI

// fakeClaude installs an executable that stands for claude: it records how it was called and prints a file.
func fakeClaude(t *testing.T, answer string, exit int) (rec string) {
	dir := t.TempDir()
	rec = filepath.Join(dir, "rec")
	out := filepath.Join(dir, "out")
	os.WriteFile(out, []byte(answer), 0o644)
	script := `#!/bin/sh
{ echo "pwd=$(pwd)"; echo "learner=$KACHING_LEARNER"; echo "mem=$CLAUDE_MEM_INTERNAL"; echo "claudecode=${CLAUDECODE:-unset}"; echo "session=${CLAUDE_CODE_SESSION_ID:-unset}"
  for a in "$@"; do echo "arg=$a"; done; } > "` + rec + `"
cat > "` + rec + `.stdin"
cat "` + out + `"
[ ` + fmt.Sprint(exit) + ` -eq 0 ] || { echo "boom: the fake failed" >&2; exit ` + fmt.Sprint(exit) + `; }
`
	bin := filepath.Join(dir, "claude")
	os.WriteFile(bin, []byte(script), 0o755)
	t.Setenv("KACHING_CLAUDE_BIN", bin)
	return rec
}

func envelope(result string, isErr bool) string {
	b, _ := json.Marshal(tm{"type": "result", "is_error": isErr, "result": result})
	return string(b)
}

func aiFixture(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now()
	for i := 1; i <= 3; i++ {
		at := now.Add(-time.Duration(i) * time.Hour)
		lines := append(titleLines(t, sid(i), fmt.Sprintf("session-%d", i), ""),
			userLine(t, fmt.Sprintf("the first prompt of %d about invoices", i), at, "/tmp/a"),
			asstText(t, fmt.Sprintf("the last answer of %d", i), at, "/tmp/a"))
		writeSession(t, "-tmp-a", sid(i), at, lines...)
	}
}

func TestFindAITier(t *testing.T) {
	aiFixture(t)
	good := fmt.Sprintf(`[{"id":"%s","why":"it is about invoices"},{"id":"%s","why":"second"}]`, aiID(sid(2)), aiID(sid(1)))
	cases := []struct {
		name, out string
		want      string // ids, or "error: ..." text
	}{
		{"plain envelope", envelope(good, false), sid(2)[:8] + " " + sid(1)[:8]},
		{"fenced", envelope("Here you go:\n```json\n"+good+"\n```", false), sid(2)[:8] + " " + sid(1)[:8]},
		{"raw text, no envelope", good, sid(2)[:8] + " " + sid(1)[:8]},
		{"words around it", envelope("The best are "+good+" Hope that helps [sic].", false), sid(2)[:8] + " " + sid(1)[:8]},
		{"full ids and an unknown one", envelope(fmt.Sprintf(`[{"id":"nope1234","why":"?"},{"id":"%s","why":"full"}]`, sid(3)), false), sid(3)[:8]},
		{"empty", envelope("[]", false), ""},
		{"not json", envelope("I could not find that.", false), "error: Claude's answer was not JSON"},
		{"claude reports an error", envelope("Credit balance is too low", true), "error: Credit balance is too low"},
	}
	for _, c := range cases {
		fakeClaude(t, c.out, 0)
		hits, err := searchAI(context.Background(), "invoices", nil, listSessions())
		if strings.HasPrefix(c.want, "error: ") {
			if err == nil || !strings.Contains(err.Error(), strings.TrimPrefix(c.want, "error: ")) {
				t.Errorf("%s: err %v", c.name, err)
			}
			continue
		}
		if err != nil || ids(hits) != c.want {
			t.Errorf("%s: hits %q err %v, want %q", c.name, ids(hits), err, c.want)
		}
		for _, h := range hits {
			if h.Tier != tierAI || h.Why == "" || h.Path == "" || h.Name == "" {
				t.Errorf("%s: hit %+v", c.name, h)
			}
		}
	}
	// claude fails: its own words come back
	fakeClaude(t, "", 3)
	if _, err := searchAI(context.Background(), "invoices", nil, listSessions()); err == nil || !strings.Contains(err.Error(), "boom: the fake failed") {
		t.Errorf("failure: %v", err)
	}
	// claude is slow
	old := aiTimeout
	t.Cleanup(func() { aiTimeout = old })
	aiTimeout = 100 * time.Millisecond
	slow := filepath.Join(t.TempDir(), "claude")
	os.WriteFile(slow, []byte("#!/bin/sh\nexec sleep 5\n"), 0o755)
	t.Setenv("KACHING_CLAUDE_BIN", slow)
	if _, err := searchAI(context.Background(), "invoices", nil, listSessions()); err == nil || !strings.Contains(err.Error(), "did not answer") {
		t.Errorf("timeout: %v", err)
	}
	// no sessions at all
	t.Setenv("HOME", t.TempDir())
	if _, err := searchAI(context.Background(), "x", nil, listSessions()); err == nil {
		t.Error("no sessions: no error")
	}
}

// The call is made so that it leaves nothing behind: no hooks, no transcript, no tools, an empty folder of its
// own, the markers Kaching's hooks read, and none of a running session's variables.
func TestFindAICallHasNoSideEffects(t *testing.T) {
	aiFixture(t)
	rec := fakeClaude(t, envelope("[]", false), 0)
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "some-session")
	t.Setenv("KACHING_LEARNER", "0")
	if _, err := searchAI(context.Background(), "invoices", nil, listSessions()); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(rec)
	if err != nil {
		t.Fatal(err)
	}
	args := string(b)
	for _, want := range []string{"arg=-p\n", "arg=--model\narg=haiku\n", "arg=--safe-mode\n", "arg=--no-session-persistence\n",
		"arg=--tools\narg=\n", "arg=--output-format\narg=json\n", "learner=1\n", "mem=1\n", "claudecode=unset\n", "session=unset\n"} {
		if !strings.Contains(args, want) {
			t.Errorf("the call lacks %q:\n%s", want, args)
		}
	}
	if strings.Contains(args, "arg=--bare") { // --bare wants an API key
		t.Error("--bare")
	}
	pwd := strings.TrimSpace(strings.TrimPrefix(strings.SplitN(args, "\n", 2)[0], "pwd="))
	if want, _ := filepath.EvalSymlinks(aiDir()); pwd != want || strings.HasPrefix(pwd, os.Getenv("HOME")) {
		t.Errorf("it ran in %q, want the scratch folder %q", pwd, want)
	}
	prompt, _ := os.ReadFile(rec + ".stdin")
	if !strings.Contains(string(prompt), "invoices") || !strings.Contains(string(prompt), "the first prompt of 1") || len(prompt) > aiPromptCap {
		t.Errorf("prompt (%d bytes): %s", len(prompt), prompt)
	}
	// nothing was added to the owner's folders: this HOME and AGENT_HOME only hold the fixture
	if _, err := os.Stat(filepath.Join(agentHome(), "sessions")); err == nil {
		t.Error("the call made ~/.agent/sessions")
	}
}

func TestAIPromptCap(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	now := time.Now()
	big := strings.Repeat("日本語 ", 400) // 3 bytes a character
	for i := 1; i <= aiSessions+30; i++ {
		at := now.Add(-time.Duration(i) * time.Minute)
		writeSession(t, "-tmp-a", sid(i), at, userLine(t, big, at, "/tmp/a"), asstText(t, big, at, "/tmp/a"))
	}
	idx := buildAIIndex(listSessions(), nil)
	if len(idx) != aiSessions {
		t.Fatalf("index has %d sessions, want %d", len(idx), aiSessions)
	}
	if idx[0].ref.ID != sid(1) || idx[0].first == "" || idx[0].last == "" || idx[0].cwd != "/tmp/a" {
		t.Errorf("first entry %+v", idx[0])
	}
	prompt, used := aiPrompt("find invoices", idx)
	if len(prompt) > aiPromptCap || len(prompt) < aiPromptCap-2000 {
		t.Errorf("prompt is %d bytes, cap %d", len(prompt), aiPromptCap)
	}
	if len(used) >= len(idx) || len(used) < 30 || used[0].ref.ID != sid(1) { // the oldest give way
		t.Errorf("used %d of %d", len(used), len(idx))
	}
	for _, l := range strings.Split(prompt, "\n") {
		if strings.HasPrefix(l, "[s") && utf8Len(l) > 600 {
			t.Errorf("an index line has %d characters", utf8Len(l))
		}
	}
}

func utf8Len(s string) int { return len([]rune(s)) }

// ---- the screen and the keys

func findModel(t *testing.T, w, h int) model {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, w: w, h: h}
	return m
}

func TestFindCommand(t *testing.T) {
	now := searchFixture(t)
	m := findModel(t, 120, 34)
	m.agents = []Agent{{SID: sid(1), Name: "zebra-live", Cwd: "/tmp/proj-a", State: "idle", Since: now, InTerminal: true}}
	m.selSID = sid(1)

	// no words: a hint, no search
	mm, cmd := m.command("FIND")
	m2 := mm.(model)
	if cmd != nil || m2.view != vFind || !strings.Contains(escRe.ReplaceAllString(m2.View(), ""), "Write /FIND and some words") {
		t.Fatalf("no words: view %d cmd %v", m2.view, cmd)
	}
	// any case, any amount of space
	mm, cmd = m.command("  find   zebra  deploy ")
	m2 = mm.(model)
	if m2.view != vFind || cmd == nil || m2.find.Query != "zebra  deploy" || strings.Join(m2.find.Terms, "|") != "zebra|deploy" {
		t.Fatalf("with words: view %d query %q terms %v", m2.view, m2.find.Query, m2.find.Terms)
	}
	if v := escRe.ReplaceAllString(m2.View(), ""); !strings.Contains(v, "searching…") {
		t.Errorf("before the results the title says searching:\n%s", v)
	}
	// the tiers answer: names (the live agent by name) and text (s1 and s6)
	m2 = feed(m2, cmd)
	v := escRe.ReplaceAllString(m2.View(), "")
	for _, want := range []string{`FIND "zebra  deploy"`, "0 in names, 2 in text", "text ×2", "zebra-live", "my-rename", "agent  ", "you  ", "deploy script for zebra", "ZEBRA DEPLOY checklist"} {
		if !strings.Contains(v, want) {
			t.Errorf("view lacks %q:\n%s", want, v)
		}
	}
	if !strings.Contains(v, "● ") { // s1 is a live agent
		t.Errorf("no live mark:\n%s", v)
	}
	// an answer of an older search is dropped
	mm, _ = m2.Update(findTextMsg{seq: m2.find.Seq - 1, hits: []findHit{{ID: "stale"}}})
	if got := len(mm.(model).find.Text); got != 2 {
		t.Errorf("a stale answer was taken: %d hits", got)
	}
}

// Nothing in the names or the text: Claude is asked by itself, and its answer shows with the tier AI.
func TestFindAutoAI(t *testing.T) {
	aiFixture(t)
	good := fmt.Sprintf(`[{"id":"%s","why":"it is about invoices"}]`, aiID(sid(2)))
	rec := fakeClaude(t, envelope(good, false), 0)
	m := findModel(t, 120, 34)
	mm, cmd := m.command("FIND payment receipts")
	m = mm.(model)
	// names and text first: the AI call has not run
	msgs := runCmd(cmd)
	for i, msg := range msgs {
		var c tea.Cmd
		mm, c = m.Update(msg)
		m = mm.(model)
		if c != nil && i == len(msgs)-1 {
			if m.find.AIState != 1 || !strings.Contains(m.status, "asking Claude") {
				t.Errorf("AI state %d status %q", m.find.AIState, m.status)
			}
			if v := escRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "asking Claude…") {
				t.Errorf("view while asking:\n%s", v)
			}
			if _, err := os.Stat(rec); err == nil {
				t.Error("the AI call ran before the other tiers were done")
			}
			m = feed(m, c)
		}
	}
	v := escRe.ReplaceAllString(m.View(), "")
	for _, want := range []string{"0 in names, 0 in text, 1 from AI", "AI  ", "session-2", "it is about invoices"} {
		if !strings.Contains(v, want) {
			t.Errorf("view lacks %q:\n%s", want, v)
		}
	}
	// a failure shows, and s asks again
	fakeClaude(t, "", 2)
	m.find.AIState, m.find.AI = 0, nil
	mm, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})
	m = feed(mm.(model), cmd)
	if v := escRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "Claude failed") || !strings.Contains(v, "boom") || !m.statusErr {
		t.Errorf("failure view:\n%s\nstatus %q", v, m.status)
	}
}

// With hits in the names or text, Claude is asked only on the s key. Its answer goes on top.
func TestFindAIOnKey(t *testing.T) {
	now := searchFixture(t)
	good := fmt.Sprintf(`[{"id":"%s","why":"asked for it"}]`, aiID(sid(3)))
	fakeClaude(t, envelope(good, false), 0)
	m := findModel(t, 120, 34)
	m.agents = nil
	mm, cmd := m.command("FIND zebra deploy")
	m = feed(mm.(model), cmd)
	if m.find.AIState != 0 || len(m.find.Text) != 2 {
		t.Fatalf("AI state %d, %d text hits", m.find.AIState, len(m.find.Text))
	}
	m.listSel = 1
	mm, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")})
	m = mm.(model)
	if m.find.AIState != 1 || cmd == nil {
		t.Fatalf("s did not start the AI: state %d", m.find.AIState)
	}
	if _, c2 := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("s")}); c2 != nil { // already asking
		t.Error("a second s started a second call")
	}
	m = feed(m, cmd)
	hits := m.find.merged()
	if len(hits) != 3 || hits[0].ID != sid(3) || hits[0].Tier != tierAI || m.listSel != 0 {
		t.Fatalf("merged: %+v (sel %d)", hits, m.listSel)
	}
	if got := ids(hits[1:]); got != sid(1)[:8]+" "+sid(6)[:8] {
		t.Errorf("order of the rest: %q (now %v)", got, now)
	}
	if s := m.find.status(); s != "0 in names, 2 in text, 1 from AI" {
		t.Errorf("status %q", s)
	}
	// a session found by two tiers is one row with both tags
	m.find.AI = []findHit{{ID: sid(1), Tier: tierAI, Why: "again"}}
	if hits := m.find.merged(); len(hits) != 2 || hits[0].ID != sid(1) || tagOf(hits[0]) != "AI+text" || hits[0].Snippet == "" || hits[0].Why != "again" {
		t.Errorf("merged twice: %+v", hits)
	}
}

func press(m model, ks string) (model, tea.Cmd) {
	var k tea.KeyMsg
	switch ks {
	case "enter":
		k = tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		k = tea.KeyMsg{Type: tea.KeyEsc}
	case "down":
		k = tea.KeyMsg{Type: tea.KeyDown}
	default:
		k = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(ks)}
	}
	mm, c := m.Update(k)
	return mm.(model), c
}

func TestFindKeys(t *testing.T) {
	searchFixture(t)
	cwdA := filepath.Join(os.Getenv("HOME"), "folder a's \"quoted\"")
	os.MkdirAll(cwdA, 0o755)
	m := findModel(t, 120, 34)
	m.agents = []Agent{{SID: sid(1), Name: "zebra-live", Cwd: "/tmp/proj-a", InTerminal: true}, {SID: "other", Name: "other", InTerminal: true}}
	m.selSID = "other"
	m.view = vDesk
	mm, cmd := m.command("FIND zebra deploy")
	m = feed(mm.(model), cmd)
	if len(m.find.merged()) != 2 {
		t.Fatalf("hits: %+v", m.find.merged())
	}

	// digits and other desk keys do nothing here: no answer goes to an agent
	for _, k := range []string{"1", "k", "g", "x", "f"} {
		if m2, c := press(m, k); c != nil || m2.status != m.status || m2.view != vFind {
			t.Errorf("key %q: cmd %v status %q view %d", k, c, m2.status, m2.view)
		}
	}
	// j and l move; they stop at the ends
	m, _ = press(m, "l")
	m, _ = press(m, "l")
	if m.listSel != 1 {
		t.Errorf("sel after l l = %d", m.listSel)
	}
	m, _ = press(m, "j")
	m, _ = press(m, "j")
	if m.listSel != 0 {
		t.Errorf("sel after j j = %d", m.listSel)
	}

	// enter on a live session selects it on the desk
	m1, _ := press(m, "enter")
	if m1.view != vDesk || m1.selSID != sid(1) {
		t.Errorf("enter on a live hit: view %d sel %q", m1.view, m1.selSID)
	}
	// r on a live session does not resume it
	m1, c := press(m, "r")
	if c != nil || !m1.statusErr || !strings.Contains(m1.status, "is live") {
		t.Errorf("r on a live hit: cmd %v status %q", c, m1.status)
	}

	// the second hit is an ended session: enter opens the excerpts, esc closes them, then the view
	m, _ = press(m, "l")
	m, cmd = press(m, "enter")
	if m.find.Panel == nil || !m.find.Panel.Loading || cmd == nil {
		t.Fatalf("panel not opened: %+v", m.find.Panel)
	}
	if v := escRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "reading the transcript") {
		t.Errorf("loading panel:\n%s", v)
	}
	m = feed(m, cmd)
	v := escRe.ReplaceAllString(m.View(), "")
	for _, want := range []string{"my-rename", "/tmp/proj-c", "1 message has all the words", "› ZEBRA DEPLOY checklist please"} {
		if !strings.Contains(v, want) {
			t.Errorf("panel lacks %q:\n%s", want, v)
		}
	}
	if strings.Contains(v, "FIND hits") || strings.Contains(v, "text ×") {
		t.Errorf("the list shows through:\n%s", v)
	}
	if hints := m.findHints(); hints[1][1] != "resume" {
		t.Errorf("hints %v", hints)
	}
	m, _ = press(m, "esc")
	if m.find.Panel != nil || m.view != vFind {
		t.Errorf("first esc: panel %v view %d", m.find.Panel, m.view)
	}
	m, _ = press(m, "esc")
	if m.view != vDesk {
		t.Errorf("second esc: view %d", m.view)
	}

	// r on the ended session opens a Terminal window; the folder is where the session started
	var script string
	old := osascriptRun
	t.Cleanup(func() { osascriptRun = old })
	osascriptRun = func(s string) ([]byte, error) { script = s; return nil, nil }
	m.view = vFind
	m.listSel = 1
	m.find.Text[len(m.find.Text)-1].Cwd = cwdA // the folder exists
	if hits := m.find.merged(); hits[1].ID != sid(6) || hits[1].Cwd != cwdA {
		t.Fatalf("hits %+v", hits)
	}
	m, cmd = press(m, "r")
	if cmd == nil {
		t.Fatalf("r: no command, status %q", m.status)
	}
	m = feed(m, cmd)
	if !strings.Contains(script, "--resume") || !strings.Contains(script, sid(6)) || !strings.Contains(script, "tell application \"Terminal\"") {
		t.Errorf("script: %s", script)
	}
	if !strings.Contains(m.status, "sent resume in a new window") {
		t.Errorf("status %q", m.status)
	}
	// its folder is gone: an error, no window
	script = ""
	m.find.Text[len(m.find.Text)-1].Cwd = "/no/such/folder"
	m, cmd = press(m, "r")
	if cmd != nil || !m.statusErr || !strings.Contains(m.status, "is gone") || script != "" {
		t.Errorf("gone folder: cmd %v status %q", cmd, m.status)
	}
}

func TestResumeScript(t *testing.T) {
	cases := []struct{ cwd, bin, id, wantDo string }{
		{"/Users/clyde/bbq", "/Users/clyde/.local/bin/claude", "abc-123",
			`do script "cd '/Users/clyde/bbq' && '/Users/clyde/.local/bin/claude' --resume 'abc-123'"`},
		{"/tmp/a b/c", "claude", "id", `do script "cd '/tmp/a b/c' && 'claude' --resume 'id'"`},
		// a single quote closes, escapes and opens the shell quoting; AppleScript then doubles the backslash
		{"/tmp/it's", "claude", "id", `do script "cd '/tmp/it'\\''s' && 'claude' --resume 'id'"`},
		// double quotes and backslashes are escaped for AppleScript
		{`/tmp/say "hi"\now`, "claude", "id", `do script "cd '/tmp/say \"hi\"\\now' && 'claude' --resume 'id'"`},
		{"/tmp/$HOME `x` ; rm -rf", "claude", "id", `do script "cd '/tmp/$HOME ` + "`x`" + ` ; rm -rf' && 'claude' --resume 'id'"`},
	}
	for _, c := range cases {
		got := resumeScript(c.bin, c.cwd, c.id)
		if !strings.Contains(got, c.wantDo) || !strings.HasPrefix(got, "tell application \"Terminal\"\n\tactivate\n") || !strings.HasSuffix(got, "\nend tell") {
			t.Errorf("resumeScript(%q):\n%s\nwant to contain %s", c.cwd, got, c.wantDo)
		}
	}
	if got := shQuote("it's"); got != `'it'\''s'` {
		t.Errorf("shQuote = %s", got)
	}
}

// What AppleScript does with the script is checked for real where osascript runs: the shell command that
// Terminal would run is read back and evaluated by sh.
func TestResumeScriptRoundTrip(t *testing.T) {
	if _, err := os.Stat("/usr/bin/osascript"); err != nil {
		t.Skip("no osascript")
	}
	dir := filepath.Join(t.TempDir(), `we ird 'dir" \x`)
	os.MkdirAll(dir, 0o755)
	script := `set s to ` + asString("cd "+shQuote(dir)+" && pwd") + "\nreturn s"
	out, err := execOsascript(script)
	if err != nil {
		t.Skip("osascript does not run here: " + err.Error())
	}
	got, err := execSh(strings.TrimSpace(out))
	if err != nil || strings.TrimSpace(got) != dir {
		t.Errorf("round trip: %q %v, want %q", got, err, dir)
	}
}

func execOsascript(script string) (string, error) {
	b, err := osascriptRun(script)
	return string(b), err
}

func execSh(cmd string) (string, error) {
	b, err := exec.Command("sh", "-c", cmd).CombinedOutput()
	return string(b), err
}

// ---- geometry

func findFixtureState() findState {
	now := time.Now()
	long := strings.Repeat("The Zebra deploy went wrong because of a very long chain of events. ", 8)
	return findState{
		Query: "zebra deploy", Terms: []string{"zebra", "deploy"}, Seq: 1, NamesDone: true, TextDone: true, AIState: 2,
		Names: []findHit{{ID: sid(1), Name: "zebra-deployer-with-a-quite-long-name", Cwd: "/Users/clyde/bbq/some/deep/folder/for/zebra", Tier: tierName, At: now}},
		Text: []findHit{
			{ID: sid(2), Name: "", Cwd: "/tmp", Tier: tierText, At: now.Add(-time.Hour), Who: "you", Snippet: long, Count: 7},
			{ID: sid(3), Name: "ünïcode näme 日本語", Cwd: "/tmp/日本語", Tier: tierText, At: now.Add(-48 * time.Hour), Who: "agent", Snippet: "…日本語 zebra deploy…", Count: 1},
		},
		AI: []findHit{{ID: sid(4), Name: "by meaning", Cwd: "/tmp/x", Tier: tierAI, At: now.Add(-72 * time.Hour), Why: strings.Repeat("it is the one that is about the same thing. ", 6)}},
	}
}

func TestFindViewGeometry(t *testing.T) {
	now := time.Now()
	for _, sz := range [][2]int{{80, 24}, {160, 40}, {60, 16}, {200, 60}} {
		for _, st := range []string{"no query", "searching", "hits", "hits lower", "none", "ai failed", "panel", "panel loading", "panel error"} {
			m := findModel(t, sz[0], sz[1])
			m.view = vFind
			m.agents = []Agent{{SID: sid(2), Name: "live", Cwd: "/tmp", InTerminal: true}}
			switch st {
			case "searching":
				m.find = findState{Query: "zebra deploy", Terms: []string{"zebra", "deploy"}, Seq: 1}
			case "hits", "hits lower", "panel", "panel loading", "panel error":
				m.find = findFixtureState()
				if st == "hits lower" {
					m.listSel = 3
				}
				if strings.HasPrefix(st, "panel") {
					m.listSel = 2
					m.find.Panel = &findPanel{ID: sid(3), sc: &findScroll{}, Loading: st == "panel loading", Err: map[bool]string{true: "cannot read the transcript: x"}[st == "panel error"],
						Head: "6 messages have all the words. The newest 4 are here, each with the message before and after.",
						Groups: [][]excerptTurn{
							{{User: true, Text: "please check the zebra deploy " + strings.Repeat("ñ ", 300), At: now}, {Text: strings.Repeat("The deploy of zebra is done.\n\n- item one\n- item two\n", 40), Match: true, At: now}},
							{{Text: "short reply", At: now}},
						}}
				}
			case "none":
				m.find = findState{Query: "zebra deploy", Terms: []string{"zebra", "deploy"}, Seq: 1, NamesDone: true, TextDone: true}
			case "ai failed":
				m.find = findState{Query: "zebra deploy", Terms: []string{"zebra", "deploy"}, Seq: 1, NamesDone: true, TextDone: true, AIState: 2, AIErr: strings.Repeat("claude said no. ", 10)}
			}
			lines := strings.Split(m.View(), "\n")
			if len(lines) != m.h {
				t.Errorf("%s %dx%d: %d lines", st, sz[0], sz[1], len(lines))
			}
			for i, l := range lines {
				p := ansiRe.ReplaceAllString(l, "")
				w := runewidth.StringWidth(p)
				if w > m.w || (strings.ContainsAny(p, "│┌└") && i >= headerH && i < m.h-footerH && w != m.w) {
					t.Errorf("%s %dx%d line %d: width %d: %q", st, sz[0], sz[1], i, w, p)
				}
			}
			if sz[0] >= 80 && st == "hits" {
				v := ansiRe.ReplaceAllString(m.View(), "")
				for _, want := range []string{`FIND "zebra deploy"`, "1 in names, 2 in text, 1 from AI", "AI", "name", "text ×7", "●", "ünïcode näme"} {
					if !strings.Contains(v, want) {
						t.Errorf("hits %dx%d lacks %q:\n%s", sz[0], sz[1], want, v)
					}
				}
			}
		}
	}
}

// The selected hit stays on the screen however far down it is.
func TestFindListScrolls(t *testing.T) {
	m := findModel(t, 80, 24)
	m.view = vFind
	m.find = findState{Query: "x", Terms: []string{"x"}, Seq: 1, NamesDone: true, TextDone: true}
	for i := 0; i < 40; i++ {
		m.find.Text = append(m.find.Text, findHit{ID: sid(i + 1), Name: fmt.Sprintf("session number %02d", i), Tier: tierText, At: time.Now().Add(-time.Duration(i) * time.Minute),
			Who: "you", Snippet: "an x in a message", Count: 1})
	}
	for _, sel := range []int{0, 5, 20, 39} {
		m.listSel = sel
		v := ansiRe.ReplaceAllString(m.View(), "")
		if !strings.Contains(v, fmt.Sprintf("> ")) || !strings.Contains(v, fmt.Sprintf("session number %02d", sel)) {
			t.Errorf("selected %d not on screen:\n%s", sel, v)
		}
	}
}

func TestFindPanelScroll(t *testing.T) {
	m := findModel(t, 80, 24)
	m.view = vFind
	m.find = findFixtureState()
	m.listSel = 1
	var g []excerptTurn
	for i := 0; i < 60; i++ {
		g = append(g, excerptTurn{Text: fmt.Sprintf("line %02d of the excerpt", i), At: time.Now()})
	}
	m.find.Panel = &findPanel{ID: sid(2), sc: &findScroll{}, Groups: [][]excerptTurn{g}}
	v := ansiRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "line 00") || strings.Contains(v, "line 59") || !strings.Contains(v, "more lines") {
		t.Errorf("top:\n%s", v)
	}
	for i := 0; i < 200; i++ {
		m, _ = press(m, "l")
	}
	v = ansiRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "line 59") || strings.Contains(v, "line 00") || !strings.Contains(v, "earlier lines") {
		t.Errorf("bottom:\n%s", v)
	}
	m, _ = press(m, "j")
	if m.find.Panel.sc.off != m.find.Panel.sc.max-1 {
		t.Errorf("j: off %d max %d", m.find.Panel.sc.off, m.find.Panel.sc.max)
	}
}

func TestParseAIAnswer(t *testing.T) {
	idx := []aiEntry{{ref: sessionRef{ID: "12345678-aaaa"}, name: "n1"}, {ref: sessionRef{ID: "abcdef12-bbbb"}, name: "n2"}}
	cases := []struct {
		name, in, want string
		err            bool
	}{
		{"array", `[{"id":"sabcdef12","why":"w"}]`, "abcdef12", false},
		{"bare hex", `[{"id":"abcdef12","why":"w"}]`, "abcdef12", false},
		{"number as id", `[{"id":12345678,"why":"w"},{"id":"abcdef12","why":"v"}]`, "12345678 abcdef12", false},
		{"fence without a language", "```\n[{\"id\":\"s12345678\",\"why\":\"w\"}]\n```", "12345678", false},
		{"objects, no array", `First {"id":"sabcdef12","why":"a"} then {"id":"s12345678","why":"b"}`, "abcdef12 12345678", false},
		{"duplicates once", `[{"id":"s12345678","why":"a"},{"id":"s12345678","why":"b"}]`, "12345678", false},
		{"empty array", `[]`, "", false},
		{"prose only", `There is nothing.`, "", true},
		{"error envelope", `{"result":"rate limited","is_error":true}`, "", true},
		{"short id", `[{"id":"s12","why":"w"}]`, "", false},
	}
	for _, c := range cases {
		hits, err := parseAIAnswer(c.in, idx)
		if (err != nil) != c.err {
			t.Errorf("%s: err %v", c.name, err)
		}
		if got := ids(hits); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

// Live: asks the real Claude (Haiku) about the owner's real sessions in ~/.claude/projects. It uses the owner's
// Claude usage, so it runs only with KACHING_LIVE_FIND=<the question>. After it, ~/.agent/sessions has no new folder.
func TestFindAILive(t *testing.T) {
	q := os.Getenv("KACHING_LIVE_FIND")
	if q == "" {
		t.Skip("KACHING_LIVE_FIND=<question> runs it")
	}
	t0 := time.Now()
	sessions := listSessions()
	idx := buildAIIndex(sessions, nil)
	prompt, used := aiPrompt(q, idx)
	t.Logf("%d sessions listed, %d in the index, prompt %d bytes, built in %v", len(sessions), len(used), len(prompt), time.Since(t0))
	t1 := time.Now()
	hits, err := searchAI(context.Background(), q, nil, sessions)
	t.Logf("Claude answered in %v: err %v, %d hits", time.Since(t1), err, len(hits))
	for _, h := range hits {
		t.Logf("  %s %-24s %s %s: %s", h.ID[:8], h.Name, tildify(h.Cwd), fmtDate(h.At), h.Why)
	}
	if err != nil {
		t.Fatal(err)
	}
}

// A `claude -p` call (the AI search) writes a session file of kind interactive while it runs. It is no agent.
func TestLoadAgentsHidesPrintCalls(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	sess := filepath.Join(home, ".claude", "sessions")
	os.MkdirAll(sess, 0o755)
	pid := fmt.Sprint(os.Getpid())
	os.WriteFile(filepath.Join(sess, "1.json"), []byte(`{"pid":`+pid+`,"sessionId":"aaaa-1","cwd":"/tmp/kaching-find","kind":"interactive","entrypoint":"sdk-cli","name":"kaching-find-f4","status":"busy"}`), 0o644)
	os.WriteFile(filepath.Join(sess, "2.json"), []byte(`{"pid":`+pid+`,"sessionId":"aaaa-2","cwd":"/tmp","kind":"interactive","entrypoint":"cli","name":"real","status":"idle"}`), 0o644)
	ags := loadAgents(map[string]tabPos{}, nil)
	if len(ags) != 1 || ags[0].SID != "aaaa-2" {
		t.Fatalf("agents = %+v", ags)
	}
}

// Typed on the command line: / FIND some words, enter.
func TestFindTypedCommand(t *testing.T) {
	searchFixture(t)
	m := findModel(t, 120, 34)
	m.view = vDesk
	m, _ = press(m, "/")
	for _, r := range "find zebra deploy" {
		if r == ' ' {
			mm, _ := m.Update(tea.KeyMsg{Type: tea.KeySpace})
			m = mm.(model)
			continue
		}
		m, _ = press(m, string(r))
	}
	if m.mode != mCommand || m.buf != "find zebra deploy" {
		t.Fatalf("mode %v buf %q", m.mode, m.buf)
	}
	m, cmd := press(m, "enter")
	if m.mode != mKeys || m.view != vFind || cmd == nil || m.find.Query != "zebra deploy" {
		t.Fatalf("mode %v view %d query %q cmd %v", m.mode, m.view, m.find.Query, cmd)
	}
	m = feed(m, cmd)
	if len(m.find.Text) != 2 || !strings.Contains(escRe.ReplaceAllString(m.View(), ""), "> FIND <GO>") {
		t.Errorf("text hits %d\n%s", len(m.find.Text), escRe.ReplaceAllString(m.View(), ""))
	}
}

// Timing on the real ~/.claude/projects (read only): the names and text tiers for some queries. Runs only with
// KACHING_FIND_TIMING=1.
func TestFindTimingReal(t *testing.T) {
	if os.Getenv("KACHING_FIND_TIMING") == "" {
		t.Skip("KACHING_FIND_TIMING=1 runs it on the real transcripts")
	}
	t0 := time.Now()
	sessions := listSessions()
	t.Logf("%d sessions listed in %v", len(sessions), time.Since(t0))
	for _, q := range []string{"kaching", "kaching resume terminal", "paperclip approve", "café", "<div>", "zzzqqxx nothing", "the"} {
		terms := parseQuery(q)
		t1 := time.Now()
		names := searchNames(context.Background(), terms, nil, sessions)
		d1 := time.Since(t1)
		hits, st := searchText(context.Background(), terms, sessions)
		t.Logf("%-26q names %2d in %-8v text %2d in %-8v (%d transcripts, partial %v)", q, len(names), d1.Round(time.Millisecond), len(hits), st.Took.Round(time.Millisecond), st.Files, st.Partial)
	}
}

// An escape sequence in a transcript, or in Claude's answer, must not reach the terminal.
func TestFindTextHasNoControlCharacters(t *testing.T) {
	esc := string(rune(27))
	if sn := makeSnippet("a"+esc+"[31m zebra"+esc+"[0m deploy\x07", []string{"zebra"}, 100); strings.ContainsAny(sn, esc+"\x07") || !strings.Contains(sn, "zebra") {
		t.Errorf("snippet %q", sn)
	}
	why, _ := json.Marshal(tm{"id": "s12345678", "why": "red" + esc + "[31m and\tbell\x07"})
	hits, err := parseAIAnswer("["+string(why)+"]", []aiEntry{{ref: sessionRef{ID: "12345678-aaaa"}}})
	if err != nil || len(hits) != 1 || strings.ContainsAny(hits[0].Why, esc+"\x07\t") {
		t.Errorf("why %+v err %v", hits, err)
	}
	if got := titlesIn([]byte(`{"type":"custom-title","customTitle":"na` + "\\u001b" + `[2Jme"}`)); strings.Contains(got.Custom, esc) {
		t.Errorf("title %q", got.Custom)
	}
	m := findModel(t, 100, 30)
	m.view = vFind
	m.find = findState{Query: "zebra", Terms: []string{"zebra"}, NamesDone: true, TextDone: true,
		Text: []findHit{{ID: sid(1), Tier: tierText, Who: "you", Snippet: "zebra", Count: 1, At: time.Now(), Path: "/x"}}}
	m.find.Panel = &findPanel{ID: sid(1), sc: &findScroll{}, Groups: [][]excerptTurn{{{User: true, Text: "zebra " + esc + "[31mred", Match: true}, {Text: "reply" + esc + "[2J zebra"}}}}
	if v := ansiRe.ReplaceAllString(m.View(), ""); strings.Contains(v, esc) {
		t.Errorf("an escape reached the panel: %q", v)
	}
}
