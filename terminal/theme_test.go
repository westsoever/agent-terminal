package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// resetTheme puts the accent back to orange when a test is done: the styles are package variables.
func resetTheme(t *testing.T) {
	t.Helper()
	applyTheme("")
	t.Cleanup(func() { applyTheme("") })
}

func TestThemeSet(t *testing.T) {
	if len(themes) != 8 || themes[0].ID != "orange" {
		t.Fatalf("want 8 themes with orange first, got %d, first %q", len(themes), themes[0].ID)
	}
	seen := map[string]bool{}
	for _, th := range themes {
		if seen[th.ID] || seen[th.Hex] {
			t.Errorf("%s repeats an id or a color", th.ID)
		}
		seen[th.ID], seen[th.Hex] = true, true
	}
}

// A missing, empty or unknown theme is orange, whatever its case or spaces.
func TestThemeFallback(t *testing.T) {
	for in, want := range map[string]string{"": "orange", "chartreuse": "orange", "GREEN": "green", " blue ": "blue", "#fff": "orange"} {
		if got := themeID(in); got != want {
			t.Errorf("themeID(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestApplyThemeChangesAccent(t *testing.T) {
	resetTheme(t)
	if string(accentColor()) != "202" {
		t.Fatalf("the default accent is %q, want the 256-color orange 202", accentColor())
	}
	applyTheme("green")
	if string(accentColor()) != "#2ea043" || curTheme != "green" {
		t.Fatalf("accent %q theme %q", accentColor(), curTheme)
	}
	if got := cOrange.GetForeground(); got != accentColor() {
		t.Fatalf("cOrange is %v, want the accent", got)
	}
	if got := cSel.GetBackground(); got != accentColor() {
		t.Fatalf("cSel is %v, want the accent", got)
	}
	applyTheme("nonsense")
	if curTheme != "orange" || string(accentColor()) != "202" {
		t.Fatalf("unknown theme gave %q (%q), want the original orange", curTheme, accentColor())
	}
}

func TestWithTheme(t *testing.T) {
	const body = "# keep me\nopen_cmd = \"open\"\n\n[keys]\nnext = \"l\"\ntheme = \"nested\"\n"
	// no theme line: it goes above the first table, and the rest is untouched
	got := withTheme(body, "cyan")
	if !strings.Contains(got, "\ntheme = \"cyan\"\n\n[keys]") || !strings.HasPrefix(got, "# keep me\nopen_cmd") || !strings.HasSuffix(got, "theme = \"nested\"\n") {
		t.Fatalf("inserted wrongly:\n%s", got)
	}
	// a theme line is replaced in place, once
	again := withTheme(got, "red")
	if strings.Count(again, "theme = ") != 2 || !strings.Contains(again, `theme = "red"`) || strings.Contains(again, `theme = "cyan"`) {
		t.Fatalf("not replaced:\n%s", again)
	}
	// a file without a table
	if got := withTheme("open_cmd = \"x\"", "blue"); !strings.HasSuffix(got, "theme = \"blue\"\n\n") || !strings.HasPrefix(got, "open_cmd = \"x\"\n") {
		t.Fatalf("no-table file:\n%q", got)
	}
	if got := withTheme("", "blue"); !strings.Contains(got, `theme = "blue"`) {
		t.Fatalf("empty file:\n%q", got)
	}
}

// The choice is in keys.toml after a save, read back by the next start, and the rest of the file is as it was.
func TestThemePersists(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, _, err := loadConfig() // writes the default keys.toml
	if err != nil || cfg.Theme != "orange" {
		t.Fatalf("a new file: theme %q, err %v", cfg.Theme, err)
	}
	before, _ := os.ReadFile(configPath())
	if !strings.Contains(string(before), `theme = "orange"`) {
		t.Fatal("the default file has no theme line")
	}
	if err := saveTheme("violet"); err != nil {
		t.Fatal(err)
	}
	cfg, _, err = loadConfig()
	if err != nil || cfg.Theme != "violet" {
		t.Fatalf("after save: theme %q, err %v", cfg.Theme, err)
	}
	after, _ := os.ReadFile(configPath())
	if strings.ReplaceAll(string(before), `theme = "orange"`, `theme = "violet"`) != string(after) {
		t.Fatalf("saving changed more than the theme line:\n%s", after)
	}
	if cfg.Keys.Next != "l" || len(cfg.Replies) == 0 {
		t.Fatal("the other settings were lost")
	}
}

func writeKeys(t *testing.T, text string) {
	t.Helper()
	t.Setenv("AGENT_HOME", t.TempDir())
	if err := os.MkdirAll(filepath.Dir(configPath()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath(), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// An old keys.toml without the line, an empty one and an unknown name all load as orange.
func TestThemeFallbackFromFile(t *testing.T) {
	for name, line := range map[string]string{"missing": "", "empty": `theme = ""`, "unknown": `theme = "chartreuse"`, "uppercase": `theme = "ORANGE"`} {
		t.Run(name, func(t *testing.T) {
			writeKeys(t, line+"\n[keys]\nnext = \"n\"\n")
			cfg, _, err := loadConfig()
			if err != nil {
				t.Fatal(err)
			}
			if cfg.Theme != "orange" {
				t.Fatalf("theme %q, want orange", cfg.Theme)
			}
			if cfg.Keys.Next != "n" {
				t.Fatalf("the other keys were not read: next %q", cfg.Keys.Next)
			}
		})
	}
	// a value of the wrong type is a bad file, which loads as the defaults (orange) and reports the error
	writeKeys(t, "theme = 7\n")
	if cfg, _, err := loadConfig(); err == nil || cfg.Theme != "orange" {
		t.Fatalf("theme %q err %v, want orange and an error", cfg.Theme, err)
	}
}

// Saving into an old file that has no theme line adds the line and keeps the rest.
func TestThemeSaveIntoOldFile(t *testing.T) {
	writeKeys(t, "open_cmd = \"x\"\n[keys]\nnext = \"n\"\n")
	if err := saveTheme("amber"); err != nil {
		t.Fatal(err)
	}
	cfg, _, err := loadConfig()
	if err != nil || cfg.Theme != "amber" || cfg.Keys.Next != "n" || cfg.OpenCmd != "x" {
		t.Fatalf("theme %q next %q open %q err %v", cfg.Theme, cfg.Keys.Next, cfg.OpenCmd, err)
	}
}

func pickerModel(t *testing.T) model {
	t.Helper()
	t.Setenv("AGENT_HOME", t.TempDir())
	cfg, ct, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	return model{cfg: cfg, cfgTime: ct, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, ed: newEditor(), w: 100, h: 30}
}

// pressTheme sends the keys through key(), esc as the real esc key.
func pressTheme(m model, keys ...string) model {
	for _, k := range keys {
		msg := keyMsg(k)
		if k == "esc" {
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		}
		next, _ := m.key(msg)
		m = next.(model)
	}
	return m
}

// The picker previews the color under the cursor, esc puts the old one back, enter saves.
func TestThemePicker(t *testing.T) {
	resetTheme(t)
	m := pickerModel(t)
	next, _ := m.command("THEME")
	m = next.(model)
	if m.view != vTheme || m.theme == nil || m.theme.sel != 0 {
		t.Fatalf("view %v theme %+v", m.view, m.theme)
	}
	m = pressTheme(m, "l", "l") // next, next: green
	if curTheme != "green" {
		t.Fatalf("preview is %q, want green", curTheme)
	}
	if v := m.View(); !strings.Contains(v, "THEME") || !strings.Contains(v, "Green") || !strings.Contains(v, "#2ea043") {
		t.Fatalf("the picker does not show its rows:\n%s", v)
	}
	if saved, _ := os.ReadFile(configPath()); strings.Contains(string(saved), `"green"`) {
		t.Fatal("a preview was saved")
	}
	m = pressTheme(m, "esc")
	if curTheme != "orange" || m.view != vDesk || m.theme != nil {
		t.Fatalf("esc left %q on view %v", curTheme, m.view)
	}
	next, _ = m.command("theme")
	m = pressTheme(next.(model), "5", "enter") // blue
	if curTheme != "blue" || m.view != vDesk || m.cfg.Theme != "blue" {
		t.Fatalf("enter left %q on view %v", curTheme, m.view)
	}
	cfg, _, err := loadConfig()
	if err != nil || cfg.Theme != "blue" {
		t.Fatalf("saved theme %q, err %v", cfg.Theme, err)
	}
	// the picker opens on the current theme and wraps around
	next, _ = m.command("THEME")
	m = next.(model)
	if m.theme.sel != 4 {
		t.Fatalf("opened on %d, want 4", m.theme.sel)
	}
	m = pressTheme(m, "8", "l")
	if curTheme != "orange" {
		t.Fatalf("wrapped to %q, want orange", curTheme)
	}
}

func TestThemeCommandWithName(t *testing.T) {
	resetTheme(t)
	m := pickerModel(t)
	next, _ := m.command("THEME magenta")
	m = next.(model)
	if curTheme != "magenta" || m.view == vTheme {
		t.Fatalf("theme %q view %v", curTheme, m.view)
	}
	if cfg, _, _ := loadConfig(); cfg.Theme != "magenta" {
		t.Fatalf("saved %q", cfg.Theme)
	}
	next, _ = m.command("THEME chartreuse")
	if curTheme != "magenta" || !strings.Contains(next.(model).status, "no theme chartreuse") {
		t.Fatalf("theme %q status %q", curTheme, next.(model).status)
	}
}
