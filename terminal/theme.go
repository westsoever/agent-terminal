package main

// The accent color and /THEME, the picker for it. The accent is the one color agterm adds to its greys: cOrange
// (text) and cSel (the selected row) in render.go. They are variables, so a theme is a reassignment of those two:
// no drawing code names a color. The choice is the "theme" line of keys.toml. The greys are variables too: on a
// light background (the "background" line, or the terminal's answer) they and the accent take darker shades.

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

// theme is one accent. Color is what is drawn on a dark background: the terminal's 256-color number for the first
// (the orange agterm always had), a hex value for the rest. Hex is the same color written out, for the picker.
// Light is the darker shade of it drawn on a light background, a 256-color number so it looks the same in every
// terminal, and LightHex is that number written out.
type theme struct {
	ID, Name, Hex, Color, Light, LightHex string
}

// themes, the first one is the default. On a dark background each is at least 4.3:1 against #1c1c1c and carries
// the black text of a selected row (at least 5.4:1). On a light one the Light shade is at least 4.7:1 against
// white (4.1:1 against #eeeeee) and carries the white text of a selected row by the same ratio.
var themes = []theme{
	{"orange", "Orange", "#ff5f00", "202", "130", "#af5f00"},
	{"amber", "Amber", "#d9930d", "#d9930d", "94", "#875f00"},
	{"green", "Green", "#2ea043", "#2ea043", "28", "#008700"},
	{"cyan", "Cyan", "#12a8b8", "#12a8b8", "24", "#005f87"},
	{"blue", "Blue", "#3b82f6", "#3b82f6", "26", "#005fd7"},
	{"violet", "Violet", "#8b6cf0", "#8b6cf0", "92", "#8700d7"},
	{"magenta", "Magenta", "#d946b4", "#d946b4", "127", "#af00af"},
	{"red", "Red", "#e5484d", "#e5484d", "160", "#d70000"},
}

// palette is everything but the accent: the greys of render.go, the band behind the owner's prompts, the text on
// a selected row and the usage colours.
type palette struct {
	white, grey, text, dark, band, onAccent, useLow, useMid, useHigh lipgloss.Color
}

// The dark palette is the terminal.shop one agterm always had. The light one keeps the order (white is the
// strongest, dark the faintest) at 3.9:1 or more against #eeeeee for every text color.
var (
	darkPalette  = palette{"231", "248", "253", "243", "236", "16", "71", "178", "196"}
	lightPalette = palette{"16", "240", "235", "243", "253", "231", "28", "94", "160"}
)

// bgMode is the "background" line of keys.toml: "dark", "light", or "auto" (the terminal's answer at start).
var bgMode = "auto"

// termDark is the terminal's answer: main asks it before the screen starts. It stays true where nothing can be
// asked (--render, tests).
var termDark = true

// lightBg says whether agterm draws for a light background now.
func lightBg() bool { return bgMode == "light" || (bgMode != "dark" && !termDark) }

// bgModeOf is v as a background mode: dark, light, or auto for anything else.
func bgModeOf(v string) string {
	if v = strings.ToLower(strings.TrimSpace(v)); v == "dark" || v == "light" {
		return v
	}
	return "auto"
}

// themeShade is the color of t on the background agterm draws for.
func themeShade(t theme) string {
	if lightBg() {
		return t.Light
	}
	return t.Color
}

// themeHex is t's color written out, for the picker.
func themeHex(t theme) string {
	if lightBg() {
		return t.LightHex
	}
	return t.Hex
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
func accentColor() lipgloss.Color { return lipgloss.Color(themeShade(themes[themeIndex(curTheme)])) }

// curPalette is the palette of the background agterm draws for.
func curPalette() palette {
	if lightBg() {
		return lightPalette
	}
	return darkPalette
}

// applyTheme draws everything in the theme id (orange for an unknown one), on the background of bgMode.
func applyTheme(id string) {
	curTheme = themeID(id)
	c, p := accentColor(), curPalette()
	cOrange = lipgloss.NewStyle().Foreground(c)
	cSel = lipgloss.NewStyle().Background(c).Foreground(p.onAccent).Bold(true)
	cWhite = lipgloss.NewStyle().Foreground(p.white).Bold(true)
	cGrey = lipgloss.NewStyle().Foreground(p.grey)
	cText = lipgloss.NewStyle().Foreground(p.text)
	cDark = lipgloss.NewStyle().Foreground(p.dark)
	promptBg = p.band
	cUseLow = lipgloss.NewStyle().Foreground(p.useLow)
	cUseMid = lipgloss.NewStyle().Foreground(p.useMid)
	cUseHigh = lipgloss.NewStyle().Foreground(p.useHigh)
}

// restyle gives the reply box the theme: the accent for its "> " and its cursor, the palette's white for the text.
func (e *editor) restyle() {
	st := e.ta.FocusedStyle
	txt := lipgloss.NewStyle().Foreground(curPalette().white)
	st.Text, st.CursorLine, st.Placeholder, st.EndOfBuffer = txt, txt, cDark, cDark
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
		m.setErr("keys.toml: " + err.Error() + " (the theme holds until agterm stops)")
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
	bg := "dark"
	if lightBg() {
		bg = "light"
	}
	from := "the terminal says so"
	if bgMode != "auto" {
		from = "background = \"" + bgMode + "\" in keys.toml"
	}
	body := []string{line(s("The accent color: the selected row, what needs you, the cursor. It follows the cursor here.", cGrey)),
		line(s("Drawn for a "+bg+" background ("+from+"). The background line of keys.toml sets dark, light or auto.", cDark)), line()}
	for i, t := range themes {
		name := padTo(t.Name, 10)
		hex := themeHex(t)
		if i == 0 {
			hex += "  default"
		}
		swatch := lipgloss.NewStyle().Foreground(lipgloss.Color(themeShade(t)))
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
