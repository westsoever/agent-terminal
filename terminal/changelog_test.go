package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestChangelogLines(t *testing.T) {
	p := filepath.Join(t.TempDir(), "DECISIONS.md")
	md := "# log\n\n## D2 (2026-10-20): second thing\n\nbody\n\n## D1 (2026-10-20): `first` thing\n\n## D0 (2026-10-19): older\n\n## Not a decision\n"
	if err := os.WriteFile(p, []byte(md), 0o644); err != nil {
		t.Fatal(err)
	}
	want := "## 2026-10-20|D2\tsecond thing|D1\tfirst thing||## 2026-10-19|D0\tolder"
	if got := strings.Join(changelogLines(p), "|"); got != want {
		t.Fatalf("changelog lines:\n got %q\nwant %q", got, want)
	}
	if got := changelogLines(filepath.Join(t.TempDir(), "none.md")); !strings.HasPrefix(got[0], "No changelog") {
		t.Fatalf("a missing file must say so: %q", got)
	}
}

func TestChangelogCommand(t *testing.T) {
	cfg, _, _ := loadConfig()
	m := model{cfg: cfg, w: 120, h: 40, view: vHelp, helpOff: 5}
	for _, c := range []string{"CL", "cl", "CHANGELOG"} {
		m.view = vHelp
		m2, _ := m.command(c)
		got := m2.(model)
		if got.view != vChangelog || got.helpOff != 0 {
			t.Fatalf("%s: view %d offset %d", c, got.view, got.helpOff)
		}
	}
}

func TestChangelogFooter(t *testing.T) {
	cfg, _, _ := loadConfig()
	for _, v := range []view{vChangelog, vHelp} {
		m := model{cfg: cfg, w: 120, h: 40, view: v}
		f := escRe.ReplaceAllString(strings.Join(m.footer(), "\n"), "")
		if !strings.Contains(f, "pgup pgdown") || !strings.Contains(f, "esc desk") || strings.Contains(f, "answer") {
			t.Fatalf("view %d: the footer must show the scroll keys, not the desk's:\n%s", v, f)
		}
	}
}
