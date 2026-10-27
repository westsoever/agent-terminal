package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
)

// The terminal.shop palette (owner's choice): near-black, mostly grey, white for what's selected, one orange.
// These are the dark-background values; applyTheme (theme.go) sets them for the theme and the background.
var (
	cWhite  = lipgloss.NewStyle().Foreground(lipgloss.Color("231")).Bold(true)
	cGrey   = lipgloss.NewStyle().Foreground(lipgloss.Color("248"))
	cText   = lipgloss.NewStyle().Foreground(lipgloss.Color("253")) // what agents wrote: bright enough to read
	cDark   = lipgloss.NewStyle().Foreground(lipgloss.Color("243"))
	cOrange = lipgloss.NewStyle().Foreground(lipgloss.Color("202"))
	cLink   = lipgloss.NewStyle().Foreground(lipgloss.Color("111")) // links, file paths and `code` in an agent's text
	cSel    = lipgloss.NewStyle().Background(lipgloss.Color("202")).Foreground(lipgloss.Color("16")).Bold(true)
	cPlain  = lipgloss.NewStyle()
	// promptBg: the band behind the owner's prompts in a conversation, a shade lighter than the screen
	promptBg = lipgloss.Color("236")
)

// seg is a run of plain text with one style. Rows are built from segs so widths are counted on plain text
// and every line comes out exactly as wide as asked: the box lines stay straight.
type seg struct {
	t  string
	st lipgloss.Style
}

func s(t string, st lipgloss.Style) seg { return seg{t, st} }

func width(t string) int { return runewidth.StringWidth(t) }

// row renders segs into exactly w cells: cut with … when too long, padded with spaces when short.
func row(w int, segs ...seg) string {
	var b strings.Builder
	used := 0
	for i, sg := range segs {
		if used >= w {
			break
		}
		t := sg.t
		if used+width(t) > w {
			t = runewidth.Truncate(t, w-used, "…")
			// a cut segment still ends the row
			b.WriteString(renderSeg(sg, t, true))
			used += width(t)
			_ = i
			break
		}
		b.WriteString(renderSeg(sg, t, false))
		used += width(t)
	}
	if used < w {
		b.WriteString(strings.Repeat(" ", w-used))
	}
	return b.String()
}

func segsWidth(segs []seg) int {
	n := 0
	for _, sg := range segs {
		n += width(sg.t)
	}
	return n
}

// box draws a frame of outer width w and height h around body rows (each already exactly w-2 wide or shorter;
// shorter rows are padded). title goes into the top border. border is the frame's style.
func box(w, h int, title []seg, border lipgloss.Style, body []string) []string {
	return boxR(w, h, title, nil, border, body)
}

// boxR is box with a second title at the right end of the top border. It drops the right title's last parts
// while the two don't fit.
func boxR(w, h int, title, right []seg, border lipgloss.Style, body []string) []string {
	if w < 4 || h < 2 {
		return nil
	}
	in := w - 2
	top := []seg{s("┌─", border)}
	if len(title) > 0 {
		top = append(top, s(" ", border))
		top = append(top, title...)
		top = append(top, s(" ", border))
	}
	rest := w - 1 - segsWidth(top)
	if rest < 0 {
		// title too long: cut it
		top = []seg{s("┌─ ", border)}
		t := ""
		for _, sg := range title {
			t += sg.t
		}
		t = runewidth.Truncate(t, w-6, "…")
		top = append(top, s(t, cWhite), s(" ", border))
		rest = w - 1 - segsWidth(top)
	}
	for len(right) > 0 && rest-(segsWidth(right)+3) < 3 { // too wide: drop its last part
		right = right[:len(right)-1]
	}
	if rw := segsWidth(right) + 3; len(right) > 0 { // " right ─": at least 3 dashes stay between
		top = append(top, s(strings.Repeat("─", rest-rw)+" ", border))
		top = append(top, right...)
		rest = 1
		top = append(top, s(" ", border))
	}
	top = append(top, s(strings.Repeat("─", rest)+"┐", border))
	out := []string{row(w, top...)}
	for i := 0; i < h-2; i++ {
		line := ""
		if i < len(body) {
			line = body[i]
		}
		lw := lipgloss.Width(line)
		if lw < in {
			line += strings.Repeat(" ", in-lw)
		}
		out = append(out, border.Render("│")+line+border.Render("│"))
	}
	out = append(out, border.Render("└"+strings.Repeat("─", in)+"┘"))
	return out
}

// wrap breaks plain text into lines of at most w cells, on spaces where possible.
func wrap(text string, w int) []string {
	if w < 4 {
		w = 4
	}
	var out []string
	for _, para := range strings.Split(text, "\n") {
		para = strings.TrimRight(para, " ")
		if para == "" {
			out = append(out, "")
			continue
		}
		indent := len(para) - len(strings.TrimLeft(para, " "))
		if indent > w/2 {
			indent = 0
		}
		pad := strings.Repeat(" ", indent)
		line := ""
		for _, word := range strings.Fields(para) {
			for width(word) > w-indent && !isURL(word) { // a word longer than a line: hard cut (a URL stays whole: row cuts it with …, its link keeps all of it)
				if line != "" {
					out = append(out, line)
					line = ""
				}
				cut := runewidth.Truncate(word, w-indent, "")
				out = append(out, pad+cut)
				word = word[len(cut):]
			}
			switch {
			case line == "":
				line = pad + word
			case width(line)+1+width(word) <= w:
				line += " " + word
			default:
				out = append(out, line)
				line = pad + word
			}
		}
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

// plain strips the markdown that reads badly in a terminal: bold markers, backticks, heading hashes.
func plain(t string) string {
	t = strings.ReplaceAll(t, "**", "")
	t = strings.ReplaceAll(t, "`", "")
	var lines []string
	for _, l := range strings.Split(t, "\n") {
		trim := strings.TrimLeft(l, "#")
		if trim != l {
			l = strings.TrimSpace(trim)
		}
		lines = append(lines, l)
	}
	return strings.Join(lines, "\n")
}

// collapse blank-line runs to one blank line.
func collapse(lines []string) []string {
	var out []string
	for i, l := range lines {
		if strings.TrimSpace(l) == "" && (i == 0 || len(out) == 0 || strings.TrimSpace(out[len(out)-1]) == "") {
			continue
		}
		out = append(out, l)
	}
	return out
}
