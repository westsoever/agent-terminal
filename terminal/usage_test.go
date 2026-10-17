package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestModelName(t *testing.T) {
	for id, want := range map[string]string{
		"claude-opus-5-5":           "Opus 5.5",
		"claude-fable-5-1":          "Fable 5.1",
		"claude-haiku-4-5-20251001": "Haiku 4.5",
		"claude-sonnet-5-5[1m]":     "Sonnet 5.5 1M",
		"claude-opus-4":             "Opus 4",
		"gpt-x":                     "gpt-x",
		"weird":                     "weird",
	} {
		if got := modelName(id); got != want {
			t.Errorf("modelName(%q) = %q, want %q", id, got, want)
		}
	}
}

// The model and effort are the latest real reply's; a <synthetic> entry (an interrupt, an error) doesn't count.
func TestReadLastModel(t *testing.T) {
	l := readLast(writeTranscript(t,
		`{"type":"assistant","effort":"low","message":{"model":"claude-sonnet-5-5","content":[{"type":"text","text":"a"}]}}`,
		`{"type":"assistant","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"b"}]}}`,
		`{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"c"}]}}`), "/")
	if l.Model != "claude-opus-5-5" || l.Effort != "high" {
		t.Fatalf("got %q %q", l.Model, l.Effort)
	}
	if tag := segsText(modelTag(l)); tag != "[Opus 5.5] high" {
		t.Fatalf("tag %q", tag)
	}
	if modelTag(Last{}) != nil {
		t.Fatal("no model, no tag")
	}
}

func segsText(segs []seg) string {
	var b strings.Builder
	for _, sg := range segs {
		b.WriteString(sg.t)
	}
	return b.String()
}

// The newest file wins; a window whose reset has passed shows 0% and no reset time.
func TestLoadUsage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENT_HOME", home)
	if u := loadUsage(); u.OK {
		t.Fatal("no files: no usage")
	}
	dir := filepath.Join(home, "usage")
	os.MkdirAll(dir, 0o755)
	now := time.Unix(1_800_000_000, 0)
	old := filepath.Join(dir, "a.json")
	os.WriteFile(old, []byte(`{"five_hour":{"used_percentage":90,"resets_at":1800003600}}`), 0o644)
	os.Chtimes(old, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour)) // loadUsage compares real mtimes
	os.WriteFile(filepath.Join(dir, "b.json"),
		[]byte(`{"five_hour":{"used_percentage":42.4,"resets_at":1800007980},"seven_day":{"used_percentage":64,"resets_at":"1800273600"}}`), 0o644)
	u := loadUsage()
	if !u.OK || u.Five.Pct != 42.4 || !u.Week.OK || u.Week.Reset.Unix() != 1800273600 {
		t.Fatalf("got %+v", u)
	}
	rows := usageRows(u, now)
	r0, r1 := segsText(rows[0]), segsText(rows[1])
	if want := "5h  42% ████████▌░░░░░░░░░░░ ↻ 2h13m "; r0 != want {
		t.Errorf("row 5h %q, want %q", r0, want)
	}
	if want := "7d  64% ████████████▊░░░░░░░ ↻ 3d04h "; r1 != want {
		t.Errorf("row 7d %q, want %q", r1, want)
	}
	if width(r0) != usageW || width(r1) != usageW {
		t.Errorf("widths %d %d, want %d", width(r0), width(r1), usageW)
	}
	if pct, left := u.Five.now(now.Add(3 * time.Hour)); pct != 0 || left != 0 {
		t.Errorf("after the reset: %v %v", pct, left)
	}
	if w := segsText(usageRows(Usage{OK: true, Five: u.Five}, now)[1]); width(w) != usageW || !strings.HasPrefix(w, "7d") {
		t.Errorf("missing 7d row %q", w)
	}
}

func TestBarCells(t *testing.T) {
	for _, c := range []struct {
		pct         float64
		full, empty int
	}{{0, 0, 10}, {100, 10, 0}, {150, 10, 0}, {-5, 0, 10}, {50, 5, 5}, {55, 6, 4}} {
		f, e := barCells(c.pct, 10)
		if width(f) != c.full || width(e) != c.empty {
			t.Errorf("%v%%: %q %q", c.pct, f, e)
		}
	}
}
