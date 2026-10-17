package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

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
	if err != nil || len(c.Replies) != 6 || c.Keys.Next != "k" || c.Keys.Prev != "j" {
		t.Fatalf("default: %v %+v", err, c)
	}
	if _, err := os.Stat(configPath()); err != nil {
		t.Fatal("default config not written")
	}
	os.WriteFile(configPath(), []byte("[[reply]]\nkey = \"x\"\ntext = \"do x\"\n"), 0o644)
	c, _, err = loadConfig()
	if err != nil || c.Keys.Next != "k" || len(c.Replies) != 1 || c.Replies[0].Label != "do x" {
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
func TestViewGeometry(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	now := time.Now()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}}
	for i, st := range []string{"input", "done", "working", "idle", "blocked"} {
		m.agents = append(m.agents, Agent{SID: string(rune('a' + i)), Name: "agent-" + st + "-with-a-long-name", Cwd: "/tmp",
			State: st, Busy: st == "working", Since: now.Add(-time.Duration(i) * time.Hour), InTerminal: i != 4})
	}
	sortAgents(m.agents)
	m.selSID = m.agents[0].SID
	m.pc = PCState{Items: []PCItem{{Ref: "COS-5", Status: "blocked", Title: "t", Detail: "why", Needs: true}}}
	m.props = []string{"skill x: something"}
	m.sync = []string{"## repo", "needs: 1 stash"}
	for _, v := range []view{vDesk, vWall, vFiles, vRepos, vProposals, vPaperclip, vHelp} {
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
