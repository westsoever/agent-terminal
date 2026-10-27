package main

import (
	"os"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// A path in an agent's text is a link to its folder (a file's folder), relative paths from the agent's folder;
// one that doesn't exist, or text drawn without an agent, is not.
func TestPathLinks(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(dir+"/sub dir", 0o755)
	os.WriteFile(dir+"/sub dir/a.go", nil, 0o644)
	linkBase = dir
	defer func() { linkBase = "" }()
	want := "file://" + dir + "/sub%20dir"
	for _, p := range []string{"sub dir/a.go", dir + "/sub dir/a.go:42", dir + "/sub dir"} {
		if got := pathLink(p); got != want {
			t.Errorf("%q: %q, want %q", p, got, want)
		}
	}
	if got := pathLink("nope/x.go"); got != "" {
		t.Errorf("missing file linked: %q", got)
	}
	segs := mdSegs("see "+mdCode+"sub dir/a.go"+mdCode+" and "+dir+"/sub dir", cText)
	if segs[1].link != want || !segs[1].st.GetUnderline() {
		t.Errorf("code span not linked and underlined: %+v", segs)
	}
	if nope := mdSegs(mdCode+"nope/x.go"+mdCode, cText); nope[0].link != "" || nope[0].st.GetUnderline() {
		t.Errorf("a missing file looks like a link: %+v", nope)
	}
	if row(60, segs[1]) == "" || !strings.Contains(row(60, segs[1]), "\x1b]8;;"+want) {
		t.Errorf("row has no OSC 8 link: %q", row(60, segs[1]))
	}
	linkBase = ""
	if got := pathLink(dir); got != "" {
		t.Errorf("linked with no agent folder: %q", got)
	}
}

// Links, paths, `code` and bold get their own colors; the marks and the markdown around them never show.
func TestMdSegs(t *testing.T) {
	text := "See **bold** and `code`, [docs](https://a.io/x) at https://b.io/y or ~/aiw/x.go and terminal/table.go."
	fg := func(st lipgloss.Style) string { return string(st.GetForeground().(lipgloss.Color)) }
	got := map[string]string{}
	shown := ""
	for _, l := range wrapMd(text, 200) {
		for _, sg := range mdSegs(l, cText) {
			shown += sg.t
			got[sg.t] = fg(sg.st)
		}
	}
	if strings.ContainsAny(shown, mdCode+mdBold+"`*") || strings.Contains(shown, "](") {
		t.Errorf("marks show: %q", shown)
	}
	for _, w := range []string{"bold", "code", "docs", "https://b.io/y", "~/aiw/x.go", "terminal/table.go"} {
		if got[w] == "" || got[w] == fg(cText) {
			t.Errorf("%q is not colored: %v", w, got)
		}
	}
	if got[" and "] != fg(cText) {
		t.Errorf("plain text colored: %v", got)
	}
	// a span that wraps keeps its color on every line, and the marks take no room
	for _, l := range wrapMd("`one two three four five`", 10) {
		if segs := mdSegs(l, cText); len(segs) != 1 || fg(segs[0].st) != fg(cLink) {
			t.Errorf("wrapped code line %q: %v", l, segs)
		}
	}
	if width(mdBold+"ab"+mdCode) != 2 {
		t.Error("marks take room")
	}
}

const tblMsg = "Before.\n\n| Name | Note | N |\n|---|---|--:|\n| **a** | a long note that has to wrap when the panel is narrow | 1 |\n| b \\| c | `x` | 22 |\n\nAfter."

func plainRows(rows []string) []string {
	var out []string
	for _, r := range rows {
		out = append(out, strings.TrimRight(ansiRe.ReplaceAllString(r, ""), " "))
	}
	return out
}

func TestParseTable(t *testing.T) {
	lines := strings.Split(tblMsg, "\n")[2:6]
	tb, ok := parseTable(lines)
	if !ok || len(tb.head) != 3 || len(tb.rows) != 2 {
		t.Fatalf("got %+v %v", tb, ok)
	}
	if unMd(tb.rows[0][0]) != "a" || tb.rows[1][0] != "b | c" || unMd(tb.rows[1][1]) != "x" || !tb.right[2] || tb.right[0] {
		t.Fatalf("cells %+v", tb)
	}
	if _, ok := parseTable([]string{"| a | b |", "| not | a separator |"}); ok {
		t.Fatal("no separator, no table")
	}
}

// Every row of every style is exactly w wide, and the text around a table stays text.
func TestTextRowsWidths(t *testing.T) {
	for _, st := range tableStyles {
		for _, w := range []int{20, 44, 80, 200} {
			rows := textRows(tblMsg, w, st)
			for i, r := range rows {
				if g := width(ansiRe.ReplaceAllString(r, "")); g != w {
					t.Errorf("%s w%d row %d: width %d", st, w, i, g)
				}
			}
			p := plainRows(rows)
			if p[0] != "Before." || p[len(p)-1] != "After." {
				t.Errorf("%s w%d: text around the table: %q … %q", st, w, p[0], p[len(p)-1])
			}
			if p[1] != "" || p[len(p)-2] != "" {
				t.Errorf("%s w%d: no blank row around the table: %q", st, w, p)
			}
			if strings.Contains(strings.Join(p, "\n"), "|---") {
				t.Errorf("%s w%d: the separator row shows", st, w)
			}
		}
	}
}

func TestTableStyles(t *testing.T) {
	tb, _ := parseTable(strings.Split(tblMsg, "\n")[2:6])
	rule := plainRows(renderTable(tb, 80, "rule"))
	if !strings.HasPrefix(rule[0], "Name") || !strings.HasPrefix(rule[1], "─") || !strings.HasSuffix(rule[2], " 1") {
		t.Errorf("rule:\n%s", strings.Join(rule, "\n"))
	}
	grid := plainRows(renderTable(tb, 80, "grid"))
	if !strings.HasPrefix(grid[0], "┌") || !strings.HasPrefix(grid[len(grid)-1], "└") {
		t.Errorf("grid:\n%s", strings.Join(grid, "\n"))
	}
	rec := plainRows(renderTable(tb, 80, "records"))
	if rec[0] != "▸ a" || !strings.HasPrefix(rec[1], "  Note  a long note") {
		t.Errorf("records:\n%s", strings.Join(rec, "\n"))
	}
	// grid: a line between every row, the header centered
	if g := strings.Join(grid, "\n"); strings.Count(g, "├") != 2 || !strings.Contains(grid[1], " Name ") {
		t.Errorf("grid lines:\n%s", g)
	}
	// auto: grid while the columns fit, records once one would be squeezed below minColW
	if a := plainRows(renderTable(tb, 80, "auto")); a[0] != grid[0] {
		t.Errorf("auto at 80 is not grid: %q", a[0])
	}
	if a := plainRows(renderTable(tb, 20, "auto")); a[0] != "▸ a" {
		t.Errorf("auto at 20 is not records: %q", a[0])
	}
	// a column that is narrow by itself (N) doesn't make auto switch
	if squeezed(tb, colWidths(tb, 80-1-3*3)) {
		t.Error("narrow N column counted as squeezed")
	}
}

func TestConfigTables(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	if c, _, _ := loadConfig(); c.Tables != "auto" {
		t.Fatalf("default %q", c.Tables)
	}
	os.WriteFile(configPath(), []byte("tables = \"grid\"\n"), 0o644)
	if c, _, _ := loadConfig(); c.Tables != "grid" {
		t.Fatalf("grid: %q", c.Tables)
	}
	os.WriteFile(configPath(), []byte("tables = \"fancy\"\n"), 0o644)
	if c, _, _ := loadConfig(); c.Tables != "auto" {
		t.Fatalf("unknown style: %q", c.Tables)
	}
}
