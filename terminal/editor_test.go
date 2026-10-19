package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func runes(s string) tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)} }

func typeText(e *editor, s string) {
	for _, r := range s {
		if r == ' ' {
			e.key(tea.KeyMsg{Type: tea.KeySpace, Runes: []rune{' '}}, 60)
			continue
		}
		e.key(runes(string(r)), 60)
	}
}

func testEditor(t *testing.T, cwd string) *editor {
	e := newEditor()
	e.opt = map[rune]rune{'l': '@', '5': '[', '7': '|', '/': '\\'} // an ABC-QWERTZ-like Option layer
	e.open("s1", cwd, 60)
	return e
}

func TestEditorOptionCharacters(t *testing.T) {
	e := testEditor(t, t.TempDir())
	typeText(e, "mail ")
	e.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'l'}, Alt: true}, 60) // option+l
	typeText(e, "x ")
	e.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'5'}, Alt: true}, 60) // option+5
	if got := e.ta.Value(); got != "mail @x [" {
		t.Fatalf("got %q", got)
	}
}

func TestEditorNewLines(t *testing.T) {
	e := testEditor(t, t.TempDir())
	typeText(e, "one")
	e.key(tea.KeyMsg{Type: tea.KeyEnter, Alt: true}, 60) // option+enter
	typeText(e, "two\\")
	if act, _ := e.key(tea.KeyMsg{Type: tea.KeyEnter}, 60); act != edNone { // backslash + enter
		t.Fatal("backslash+enter must not send")
	}
	typeText(e, "three")
	if got := e.ta.Value(); got != "one\ntwo\nthree" {
		t.Fatalf("got %q", got)
	}
	if act, _ := e.key(tea.KeyMsg{Type: tea.KeyEnter}, 60); act != edSend {
		t.Fatal("enter must send")
	}
}

func TestEditorFileSuggestions(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "docs"), 0o755)
	os.WriteFile(filepath.Join(dir, "docs", "manual.md"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "main.go"), nil, 0o644)
	e := testEditor(t, dir)
	typeText(e, "look at @man")
	if len(e.comp) == 0 || e.comp[0] != "@docs/manual.md" {
		t.Fatalf("suggestions %v", e.comp)
	}
	e.key(tea.KeyMsg{Type: tea.KeyTab}, 60)
	if got := e.ta.Value(); got != "look at @docs/manual.md " {
		t.Fatalf("got %q", got)
	}
}

func TestEditorSlashSuggestions(t *testing.T) {
	e := testEditor(t, t.TempDir())
	typeText(e, "/comp")
	if len(e.comp) == 0 || e.comp[0] != "/compact" {
		t.Fatalf("suggestions %v", e.comp)
	}
	e.key(tea.KeyMsg{Type: tea.KeyEnter}, 60) // enter takes the suggestion, it doesn't send
	if got := e.ta.Value(); got != "/compact " {
		t.Fatalf("got %q", got)
	}
	typeText(e, "now /x") // a slash later in the text is no command
	if len(e.comp) != 0 {
		t.Fatalf("no suggestions expected, got %v", e.comp)
	}
}

func TestEditorDraftsPerTarget(t *testing.T) {
	e := testEditor(t, t.TempDir())
	typeText(e, "half a thought")
	e.close()
	e.open("s2", "", 60)
	if e.ta.Value() != "" {
		t.Fatal("other target must start empty")
	}
	e.close()
	e.open("s1", "", 60)
	if e.ta.Value() != "half a thought" {
		t.Fatalf("draft lost: %q", e.ta.Value())
	}
	e.sent()
	e.open("s1", "", 60)
	if e.ta.Value() != "" {
		t.Fatal("a sent draft must be gone")
	}
}

// Writing a reply never shows the text in the top line, so a long reply can't spill over it.
func TestTypingNotInCommandLine(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, _ := loadConfig()
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, ed: newEditor(), w: 120, h: 40}
	m.agents = []Agent{{SID: "s1", Name: "agent", Cwd: "/tmp", InTerminal: true, State: "input"}}
	m.selSID = "s1"
	mm, _ := m.key(runes("k"))
	m = mm.(model)
	long := strings.Repeat("word ", 60)
	for _, r := range long {
		mm, _ = m.key(runes(string(r)))
		m = mm.(model)
	}
	top := ansiRe.ReplaceAllString(m.commandLine(), "")
	if strings.Contains(top, "word") || !strings.Contains(top, "writing to agent") {
		t.Fatalf("top line: %q", top)
	}
	for i, l := range strings.Split(m.View(), "\n") {
		if w := len([]rune(ansiRe.ReplaceAllString(l, ""))); w > m.w {
			t.Fatalf("line %d is %d wide", i, w)
		}
	}
}

func TestSlashProjectCommands(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	repo := filepath.Join(home, "code", "repo")
	sub := filepath.Join(repo, "pkg")
	os.MkdirAll(filepath.Join(repo, ".claude", "commands"), 0o755)
	os.MkdirAll(filepath.Join(sub, ".claude", "skills", "deploy"), 0o755)
	os.MkdirAll(filepath.Join(home, ".claude", "commands"), 0o755)
	os.WriteFile(filepath.Join(repo, ".claude", "commands", "ship.md"), []byte("---\ndescription: Ship the repo\n---\nbody"), 0o644)
	os.WriteFile(filepath.Join(sub, ".claude", "skills", "deploy", "SKILL.md"), []byte("---\nname: deploy\ndescription: Deploy this package\n---\n"), 0o644)
	os.WriteFile(filepath.Join(home, ".claude", "commands", "mine.md"), []byte("# My command\nDo my thing"), 0o644)
	got := map[string]string{}
	for _, c := range slashCommands(sub) {
		got[c.name] = c.desc
	}
	if got["ship"] != "Ship the repo" || got["deploy"] != "Deploy this package" || got["mine"] != "Do my thing" {
		t.Fatalf("got %v", got)
	}
}

// A draft survives a restart: typing saves it (even with the box still open), a new agterm loads it, Esc keeps
// it, sending forgets it, and an emptied draft is no draft.
func TestDraftsSurviveRestart(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	e := newEditor()
	e.drafts = loadDrafts()
	e.open("s1", "/tmp", 40)
	for _, r := range "half a reply" {
		e.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}, 40)
	}
	if got := loadDrafts()["s1"]; got != "half a reply" {
		t.Fatalf("box still open, restart: draft %q", got)
	}
	e.close()
	e2 := newEditor()
	e2.drafts = loadDrafts()
	e2.open("s1", "/tmp", 40)
	if got := e2.ta.Value(); got != "half a reply" {
		t.Fatalf("after a restart the box opens with %q", got)
	}
	e2.sent()
	if _, ok := loadDrafts()["s1"]; ok {
		t.Fatal("a sent draft is still saved")
	}
	if _, err := os.Stat(draftsPath()); !os.IsNotExist(err) {
		t.Fatalf("no drafts left but the file stays: %v", err)
	}
	e2.open("s2", "/tmp", 40)
	e2.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}}, 40)
	e2.key(tea.KeyMsg{Type: tea.KeyBackspace}, 40)
	if _, ok := loadDrafts()["s2"]; ok {
		t.Fatal("an emptied draft is still saved")
	}
}
