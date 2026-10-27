package main

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Markdown tables in an agent's message are drawn as tables, not wrapped as text. Styles (keys.toml tables =):
// grid draws every cell in a frame with a line between all rows, rule lines the columns up under a rule, records
// shows each row as a small block (first cell on top, the others as "header  value" lines), auto is grid while the
// columns fit, else records.
var tableStyles = []string{"auto", "grid", "rule", "records"}

const minColW = 10

// textRows is an agent's text as rows w wide: its markdown tables drawn in the tables style, the rest wrapped as
// text (blank-line runs collapsed).
func textRows(text string, w int, style string) []string {
	var out, prose []string
	gap := func() { // one blank row between a table and the text around it
		if len(out) > 0 && strings.TrimSpace(out[len(out)-1]) != "" {
			out = append(out, row(w))
		}
	}
	afterTable := false
	flush := func() {
		lines := collapse(wrap(plain(strings.Join(prose, "\n")), w))
		if afterTable && len(lines) > 0 {
			gap()
		}
		for _, l := range lines {
			out = append(out, row(w, s(l, cText)))
		}
		prose = nil
	}
	lines := strings.Split(text, "\n")
	for i := 0; i < len(lines); i++ {
		if strings.HasPrefix(strings.TrimSpace(lines[i]), "|") && i+1 < len(lines) && isSepRow(lines[i+1]) {
			j := i + 2
			for j < len(lines) && strings.HasPrefix(strings.TrimSpace(lines[j]), "|") {
				j++
			}
			if t, ok := parseTable(lines[i:j]); ok {
				flush()
				gap()
				out = append(out, renderTable(t, w, style)...)
				afterTable = true
				i = j - 1
				continue
			}
		}
		prose = append(prose, lines[i])
	}
	flush()
	return out
} // narrower columns read badly: auto switches to records below this

type table struct {
	head  []string
	rows  [][]string
	right []bool // right-aligned columns (---: in the separator)
}

var sepCellRe = regexp.MustCompile(`^\s*:?-{2,}:?\s*$`)

// splitCells splits "| a | b |" into its trimmed cells; "\|" stays a pipe inside a cell.
func splitCells(l string) []string {
	l = strings.TrimSpace(l)
	l = strings.TrimPrefix(l, "|")
	if strings.HasSuffix(l, "|") && !strings.HasSuffix(l, `\|`) {
		l = l[:len(l)-1]
	}
	var cells []string
	var cur strings.Builder
	for i := 0; i < len(l); i++ {
		switch {
		case l[i] == '\\' && i+1 < len(l) && l[i+1] == '|':
			cur.WriteByte('|')
			i++
		case l[i] == '|':
			cells = append(cells, strings.TrimSpace(cur.String()))
			cur.Reset()
		default:
			cur.WriteByte(l[i])
		}
	}
	return append(cells, strings.TrimSpace(cur.String()))
}

func isSepRow(l string) bool {
	if !strings.HasPrefix(strings.TrimSpace(l), "|") {
		return false
	}
	for _, c := range splitCells(l) {
		if !sepCellRe.MatchString(c) {
			return false
		}
	}
	return true
}

// parseTable reads a header line, a separator line and the rows under them; ok false when lines aren't a table.
func parseTable(lines []string) (t table, ok bool) {
	if len(lines) < 2 || !isSepRow(lines[1]) {
		return t, false
	}
	t.head = cellsPlain(splitCells(lines[0]))
	for _, c := range splitCells(lines[1]) {
		c = strings.TrimSpace(c)
		t.right = append(t.right, strings.HasSuffix(c, ":") && !strings.HasPrefix(c, ":"))
	}
	n := len(t.head)
	for _, l := range lines[2:] {
		r := cellsPlain(splitCells(l))
		for len(r) < n {
			r = append(r, "")
		}
		t.rows = append(t.rows, r[:n])
	}
	for len(t.right) < n {
		t.right = append(t.right, false)
	}
	return t, true
}

func cellsPlain(c []string) []string {
	for i := range c {
		c[i] = strings.TrimSpace(plain(c[i]))
	}
	return c
}

// colWidths shares w cells out over the columns: a column that needs less than its fair share keeps its own
// width, the rest split what's left.
func colWidths(t table, w int) []int {
	n := len(t.head)
	need := make([]int, n)
	for i := 0; i < n; i++ {
		need[i] = width(t.head[i])
		for _, r := range t.rows {
			need[i] = max(need[i], width(r[i]))
		}
		need[i] = max(need[i], 1)
	}
	out := make([]int, n)
	done := make([]bool, n)
	left, cols := w, n
	for changed := true; changed && cols > 0; {
		changed = false
		share := left / cols
		for i := 0; i < n; i++ {
			if !done[i] && need[i] <= share {
				out[i], done[i] = need[i], true
				left -= need[i]
				cols--
				changed = true
			}
		}
	}
	for i := 0; i < n && cols > 0; i++ {
		if !done[i] {
			out[i] = left / cols
			left -= out[i]
			cols--
			done[i] = true
		}
	}
	return out
}

// renderTable draws t in w cells for a style; every row comes out exactly w wide.
func renderTable(t table, w int, style string) []string {
	n := len(t.head)
	switch style {
	case "grid", "rule", "records":
	default: // auto
		style = "grid"
		if squeezed(t, colWidths(t, w-1-3*n)) {
			style = "records"
		}
	}
	switch style {
	case "grid":
		return gridTable(t, w)
	case "records":
		return recordsTable(t, w)
	}
	return ruleTable(t, w)
}

// squeezed: a column got narrower than minColW while its cells need more.
func squeezed(t table, ws []int) bool {
	for i, cw := range ws {
		if cw >= minColW {
			continue
		}
		if width(t.head[i]) > cw {
			return true
		}
		for _, r := range t.rows {
			if width(r[i]) > cw {
				return true
			}
		}
	}
	return false
}

// cellLines wraps every cell of a row to its column and pads the row to its tallest cell.
func cellLines(cells []string, ws []int) [][]string {
	h := 1
	out := make([][]string, len(cells))
	for i, c := range cells {
		if c == "" {
			out[i] = []string{""}
		} else {
			out[i] = wrap(c, max(ws[i], 4))
		}
		h = max(h, len(out[i]))
	}
	for i := range out {
		for len(out[i]) < h {
			out[i] = append(out[i], "")
		}
	}
	return out
}

func align(t string, w int, right bool) string {
	if right && width(t) < w {
		return strings.Repeat(" ", w-width(t)) + t
	}
	return padTo(t, w)
}

// ruleTable: columns two spaces apart, the header in white over a rule, a blank line between rows when any
// row takes more than one line.
func ruleTable(t table, w int) []string {
	n := len(t.head)
	ws := colWidths(t, w-2*(n-1))
	var out []string
	line := func(cells [][]string, k int, st func(int) seg) string {
		var segs []seg
		for i := range cells {
			if i > 0 {
				segs = append(segs, s("  ", cPlain))
			}
			sg := st(i)
			sg.t = align(cells[i][k], ws[i], t.right[i])
			segs = append(segs, sg)
		}
		return row(w, segs...)
	}
	hc := cellLines(t.head, ws)
	for k := range hc[0] {
		out = append(out, line(hc, k, func(int) seg { return s("", cWhite) }))
	}
	var rule []seg
	for i := range ws {
		if i > 0 {
			rule = append(rule, s("  ", cPlain))
		}
		rule = append(rule, s(strings.Repeat("─", ws[i]), cDark))
	}
	out = append(out, row(w, rule...))
	var body [][][]string
	tall := false
	for _, r := range t.rows {
		c := cellLines(r, ws)
		tall = tall || len(c[0]) > 1
		body = append(body, c)
	}
	for j, c := range body {
		if tall && j > 0 {
			out = append(out, row(w))
		}
		for k := range c[0] {
			out = append(out, line(c, k, func(i int) seg {
				if i == 0 {
					return s("", cGrey)
				}
				return s("", cText)
			}))
		}
	}
	return out
}

// gridTable: every cell framed in light lines, the header centered, a line between all rows.
func gridTable(t table, w int) []string {
	n := len(t.head)
	ws := colWidths(t, w-1-3*n) // "│ " + cell + " " per column, and the last "│"
	edge := func(l, mid, r string) string {
		var b strings.Builder
		b.WriteString(l)
		for i, cw := range ws {
			if i > 0 {
				b.WriteString(mid)
			}
			b.WriteString(strings.Repeat("─", cw+2))
		}
		b.WriteString(r)
		return row(w, s(b.String(), cGrey))
	}
	line := func(cells [][]string, k int, st lipgloss.Style, mid bool) string {
		var segs []seg
		for i := range cells {
			c := align(cells[i][k], ws[i], t.right[i])
			if mid {
				c = padTo(strings.Repeat(" ", max((ws[i]-width(cells[i][k]))/2, 0))+cells[i][k], ws[i])
			}
			segs = append(segs, s("│ ", cGrey), s(c, st), s(" ", cPlain))
		}
		segs = append(segs, s("│", cGrey))
		return row(w, segs...)
	}
	out := []string{edge("┌", "┬", "┐")}
	hc := cellLines(t.head, ws)
	for k := range hc[0] {
		out = append(out, line(hc, k, cWhite, true))
	}
	out = append(out, edge("├", "┼", "┤"))
	for j, r := range t.rows {
		if j > 0 {
			out = append(out, edge("├", "┼", "┤"))
		}
		c := cellLines(r, ws)
		for k := range c[0] {
			out = append(out, line(c, k, cText, false))
		}
	}
	return append(out, edge("└", "┴", "┘"))
}

// recordsTable: one block per row, its first cell in white, then "header  value" for the other cells.
func recordsTable(t table, w int) []string {
	hw := 0
	for _, h := range t.head[1:] {
		hw = max(hw, width(h))
	}
	hw = min(hw, w/3)
	var out []string
	for j, r := range t.rows {
		if j > 0 {
			out = append(out, row(w))
		}
		for k, l := range wrap(r[0], w-2) {
			lead := "▸ "
			if k > 0 {
				lead = "  "
			}
			out = append(out, row(w, s(lead, cDark), s(l, cWhite)))
		}
		for i := 1; i < len(r); i++ {
			for k, l := range wrap(r[i], max(4, w-4-hw)) {
				h := ""
				if k == 0 {
					h = t.head[i]
				}
				out = append(out, row(w, s("  "+padTo(h, hw)+"  ", cDark), s(l, cText)))
			}
		}
	}
	return out
}
