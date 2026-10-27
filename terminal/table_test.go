package main

import (
	"os"
	"strings"
	"testing"
)

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
	if tb.rows[0][0] != "a" || tb.rows[1][0] != "b | c" || tb.rows[1][1] != "x" || !tb.right[2] || tb.right[0] {
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
