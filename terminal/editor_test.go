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
