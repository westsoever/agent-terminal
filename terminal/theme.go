package main

// The accent color and /THEME, the picker for it. The accent is the one color kaching adds to its greys: cOrange
// (text) and cSel (the selected row) in render.go. They are variables, so a theme is a reassignment of those two:
// no drawing code names a color. The choice is the "theme" line of keys.toml.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// vTheme is the /THEME picker. It has no tab, like FIND.
const vTheme view = 1001

// theme is one accent. Color is what is drawn: the terminal's 256-color number for the first (the orange kaching
// always had), a hex value for the rest. Hex is the same color written out, for the picker.
type theme struct {
	ID, Name, Hex, Color string
}

// themes, the first one is the default. Each stays readable as text on a dark and on a light background (at least
// 4.3:1 against #1c1c1c and 2.2:1 against white; amber is the brightest hue and the lowest on light) and carries
// the black text of a selected row (at least 5.4:1).
var themes = []theme{
	{"orange", "Orange", "#ff5f00", "202"},
	{"amber", "Amber", "#d9930d", "#d9930d"},
	{"green", "Green", "#2ea043", "#2ea043"},
	{"cyan", "Cyan", "#12a8b8", "#12a8b8"},
	{"blue", "Blue", "#3b82f6", "#3b82f6"},
	{"violet", "Violet", "#8b6cf0", "#8b6cf0"},
	{"magenta", "Magenta", "#d946b4", "#d946b4"},
	{"red", "Red", "#e5484d", "#e5484d"},
}

// themeIndex is the place of id in themes; an empty or unknown id is the default, orange.
func themeIndex(id string) int {
	id = strings.ToLower(strings.TrimSpace(id))
	for i, t := range themes {
		if t.ID == id {
			return i
		}
	}
	return 0
}

// themeID is id as a known theme's id, "orange" when it is not one.
func themeID(id string) string { return themes[themeIndex(id)].ID }

// curTheme is the id of the theme drawn now.
var curTheme = themes[0].ID

// accentColor is the color of the theme on the screen.
func accentColor() lipgloss.Color { return lipgloss.Color(themes[themeIndex(curTheme)].Color) }

// applyTheme draws everything in the theme id (orange for an unknown one).
func applyTheme(id string) {
	curTheme = themeID(id)
	c := accentColor()
	cOrange = lipgloss.NewStyle().Foreground(c)
	cSel = lipgloss.NewStyle().Background(c).Foreground(lipgloss.Color("16")).Bold(true)
}

// restyle gives the reply box the accent of the theme: its "> " and its cursor.
func (e *editor) restyle() {
	st := e.ta.FocusedStyle
	st.Prompt = lipgloss.NewStyle().Foreground(accentColor())
	e.ta.FocusedStyle, e.ta.BlurredStyle = st, st
	e.ta.Cursor.Style = lipgloss.NewStyle().Foreground(accentColor())
}

var themeLine = regexp.MustCompile(`(?m)^[ \t]*theme[ \t]*=.*$`)
var tableHead = regexp.MustCompile(`(?m)^[ \t]*\[`)

// withTheme is the text of keys.toml with its theme line set to id: the line replaced where there is one,
// otherwise written above the first [table] (a top-level key can't come after one). Everything else, comments
// included, stays as it was.
func withTheme(text, id string) string {
	line := fmt.Sprintf("theme = %q", id)
	head := tableHead.FindStringIndex(text)
	top := text
	if head != nil {
		top = text[:head[0]]
	}
	if loc := themeLine.FindStringIndex(top); loc != nil {
		return text[:loc[0]] + line + text[loc[1]:]
	}
	add := "# The accent color: " + themeNames() + ". /THEME picks it and writes this line.\n" + line + "\n\n"
	if head == nil {
		if text != "" && !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		return text + "\n" + add
	}
	return text[:head[0]] + add + text[head[0]:]
}

func themeNames() string {
	var n []string
	for _, t := range themes[:len(themes)-1] {
		n = append(n, t.ID)
	}
	return strings.Join(n, ", ") + " or " + themes[len(themes)-1].ID
}

// saveTheme writes the theme into keys.toml (the file is made when it isn't there).
func saveTheme(id string) error {
	p := configPath()
	b, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		b, err = []byte(defaultConfig), nil
	}
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(withTheme(string(b), themeID(id))), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// themeState is the picker: the row the cursor is on, and the theme to go back to on esc.
type themeState struct {
	sel  int
	back string
}

// themeCommand is /THEME: the picker, or with a name (THEME green) that theme at once.
func (m model) themeCommand(arg string) (tea.Model, tea.Cmd) {
	if arg = strings.TrimSpace(arg); arg != "" {
		i := themeIndex(arg)
		if themes[i].ID != strings.ToLower(arg) {
			m.setErr("no theme " + arg + ": " + themeNames())
			return m, nil
		}
		return m.themeSave(themes[i].ID)
	}
	m.theme = &themeState{sel: themeIndex(curTheme), back: curTheme}
	m.view, m.zoom = vTheme, false
	return m, nil
}

func (m model) themeSave(id string) (tea.Model, tea.Cmd) {
	applyTheme(id)
	m.ed.restyle()
	m.cfg.Theme = curTheme
	if err := saveTheme(curTheme); err != nil {
		m.setErr("keys.toml: " + err.Error() + " (the theme holds until kaching stops)")
		return m, nil
	}
	if st, err := os.Stat(configPath()); err == nil { // our own write isn't a reload to announce
		m.cfgTime = st.ModTime()
	}
	m.setStatus("theme " + curTheme + " saved to keys.toml")
	return m, nil
}

// themeKey is the picker's keys. It takes all of them, so no other view is reached with the preview unsaved.
func (m model) themeKey(ks string) (tea.Model, tea.Cmd) {
	K := m.cfg.Keys
	p := m.theme
	if p == nil {
		m.view = vDesk
		return m, nil
	}
	n := len(themes)
	switch {
	case ks == K.Next || ks == "down" || ks == "tab":
		p.sel = (p.sel + 1) % n
	case ks == K.Prev || ks == "up" || ks == "shift+tab":
		p.sel = (p.sel + n - 1) % n
	case ks == "home":
		p.sel = 0
	case ks == "end":
		p.sel = n - 1
	case len(ks) == 1 && ks[0] >= '1' && ks[0] <= '0'+byte(n):
		p.sel = int(ks[0] - '1')
	case ks == "enter":
		m.view, m.theme = vDesk, nil
		return m.themeSave(themes[p.sel].ID)
	case ks == "esc":
		applyTheme(p.back)
		m.ed.restyle()
		m.view, m.theme = vDesk, nil
		return m, nil
	}
	applyTheme(themes[p.sel].ID) // the screen shows the color under the cursor
	m.ed.restyle()
	return m, nil
}

// themeView: the eight colors with their swatch, and below them a few lines drawn the way the real screens are.
func (m model) themeView(h int) []string {
	in := m.w - 6
	sel := 0
	if m.theme != nil {
		sel = m.theme.sel
	}
	line := func(segs ...seg) string { return " " + row(in, segs...) + " " }
	body := []string{line(s("The accent color: the selected row, what needs you, the cursor. It follows the cursor here.", cGrey)), line()}
	for i, t := range themes {
		name := padTo(t.Name, 10)
		hex := t.Hex
		if i == 0 {
			hex += "  default"
		}
		swatch := lipgloss.NewStyle().Foreground(lipgloss.Color(t.Color))
		if i == sel {
			body = append(body, line(s(padTo(fmt.Sprintf(" > %s ██ %s%s", padTo(fmt.Sprint(i+1), 2), name, hex), in), cSel)))
		} else {
			body = append(body, line(s("   ", cPlain), s(padTo(fmt.Sprint(i+1), 2), cDark), s("██", swatch), s(" "+name, cWhite), s(hex, cDark)))
		}
	}
	body = append(body, line(), line(s("preview", cDark)),
		line(s("   ", cPlain), s("needs: answer the question above", cOrange)),
		line(s(padTo(" > selected row", 24), cSel), s("  ", cPlain), s("★ ", cOrange), s("recommended", cGrey)),
		line(s("   > ", cOrange), s("a reply being written", cWhite)),
	)
	if n := h - 2; len(body) > n {
		body = body[:max(n, 0)]
	}
	return indent(box(m.w-2, h, []seg{s("THEME", cWhite), s("   "+m.themeHint(), cGrey)}, cDark, body))
}

func (m model) themeHint() string {
	K := m.cfg.Keys
	return K.Prev + "/" + K.Next + " or 1-8 choose · enter saves · esc keeps the old one"
}
