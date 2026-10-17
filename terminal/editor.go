package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// editor is the reply box: a multi-line text area with the keys of a normal editor, the owner's Option
// characters, @file and /command suggestions, image paste and an external editor. One draft is kept per target.
type editor struct {
	ta     textarea.Model
	opt    map[rune]rune     // Option chords back to the layout's characters (layout_darwin.go)
	drafts map[string]string // target (session id or Paperclip issue id) -> unsent text
	target string
	cwd    string // the agent's folder: @ suggestions are its files

	comp     []string // suggestions shown now ('' kind when none)
	compKind byte     // '@' or '/'
	compSel  int
	compTok  string // the token being completed, as typed

	files   map[string][]string // cwd -> its files, for @
	filesAt map[string]time.Time
	height  int
}

func newEditor() *editor {
	ta := textarea.New()
	ta.ShowLineNumbers = false
	ta.CharLimit = 0
	ta.MaxHeight = 0
	ta.SetPromptFunc(2, func(i int) string {
		if i == 0 {
			return "> "
		}
		return "  "
	})
	st := textarea.Style{
		Base:        lipgloss.NewStyle(),
		CursorLine:  lipgloss.NewStyle().Foreground(lipgloss.Color("231")),
		Text:        lipgloss.NewStyle().Foreground(lipgloss.Color("231")),
		Prompt:      lipgloss.NewStyle().Foreground(lipgloss.Color("202")),
		Placeholder: cDark,
		EndOfBuffer: cDark,
	}
	ta.FocusedStyle, ta.BlurredStyle = st, st
	ta.Placeholder = "write your reply"
	ta.Cursor.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("202"))
	km := textarea.DefaultKeyMap
	km.InsertNewline = key.NewBinding(key.WithKeys("alt+enter", "ctrl+j"))
	off := key.NewBinding(key.WithDisabled())
	km.UppercaseWordForward, km.LowercaseWordForward, km.CapitalizeWordForward = off, off, off
	km.TransposeCharacterBackward = off
	km.InputBegin = key.NewBinding(key.WithKeys("alt+<", "ctrl+home", "alt+up"))
	km.InputEnd = key.NewBinding(key.WithKeys("alt+>", "ctrl+end", "alt+down"))
	ta.KeyMap = km
	return &editor{ta: ta, opt: optionLayer(), drafts: map[string]string{}, files: map[string][]string{}, filesAt: map[string]time.Time{}}
}

// open starts editing for target, with its draft.
func (e *editor) open(target, cwd string, width int) tea.Cmd {
	e.target, e.cwd = target, cwd
	e.ta.SetValue(e.drafts[target])
	e.height = 0
	e.resize(width)
	e.comp = nil
	return e.ta.Focus()
}

// close keeps the text as the target's draft.
func (e *editor) close() {
	e.drafts[e.target] = e.ta.Value()
	e.ta.Blur()
	e.comp = nil
}

// sent forgets the draft.
func (e *editor) sent() {
	delete(e.drafts, e.target)
	e.ta.SetValue("")
	e.ta.Blur()
	e.comp = nil
}

func (e *editor) resize(w int) {
	if w < 10 {
		w = 10
	}
	e.ta.SetWidth(w)
	rows := 0
	for _, l := range strings.Split(e.ta.Value(), "\n") {
		n := (width(l) + w - 3) / (w - 2)
		if n < 1 {
			n = 1
		}
		rows += n
	}
	if rows > 10 {
		rows = 10
	}
	if rows == e.height {
		return
	}
	grew := rows > e.height
	e.height = rows
	e.ta.SetHeight(rows)
	if grew && rows < 10 {
		e.toTop()
	}
}

// toTop: the box just grew and all the text fits, but the text area keeps its old scroll offset (its first
// line would stay hidden). Re-setting the value scrolls to the top; the cursor is put back where it was.
func (e *editor) toTop() {
	row := e.ta.Line()
	li := e.ta.LineInfo()
	col := li.StartColumn + li.ColumnOffset
	e.ta.SetValue(e.ta.Value()) // cursor at the end, view at the top
	for i := 0; e.ta.Line() > row && i < 1000; i++ {
		e.ta.CursorUp()
	}
	e.ta.SetCursor(col)
}

type editorAction int

const (
	edNone editorAction = iota
	edSend
	edClose
	edExternal
	edImage
)

// key handles a key while writing. It returns what the model must do next.
func (e *editor) key(k tea.KeyMsg, width int) (editorAction, tea.Cmd) {
	ks := k.String()
	if len(e.comp) > 0 {
		switch ks {
		case "up", "ctrl+p":
			if e.compSel > 0 {
				e.compSel--
			}
			return edNone, nil
		case "down", "ctrl+n":
			if e.compSel < len(e.comp)-1 {
				e.compSel++
			}
			return edNone, nil
		case "tab", "enter":
			e.accept()
			e.resize(width)
			return edNone, nil
		case "esc":
			e.comp = nil
			return edNone, nil
		}
	}
	switch ks {
	case "esc", "ctrl+c":
		return edClose, nil
	case "enter":
		v := e.ta.Value()
		if strings.HasSuffix(v, "\\") { // backslash + enter: a new line, as in Claude Code
			e.ta.SetValue(strings.TrimSuffix(v, "\\") + "\n")
			e.resize(width)
			return edNone, nil
		}
		return edSend, nil
	case "ctrl+g":
		return edExternal, nil
	case "ctrl+v":
		return edImage, nil
	}
	// Option + a key: the character the owner's layout puts there (with "Use Option as Meta key" Terminal
	// sends ESC + the plain key). alt+b / alt+f / alt+d stay word moves and word delete.
	if k.Alt && k.Type == tea.KeyRunes && len(k.Runes) == 1 && !k.Paste {
		r := k.Runes[0]
		if r != 'b' && r != 'f' && r != 'd' {
			if c, ok := e.opt[r]; ok {
				e.ta.InsertRune(c)
				e.afterEdit(width)
				return edNone, nil
			}
		}
	}
	var cmd tea.Cmd
	e.ta, cmd = e.ta.Update(k)
	e.afterEdit(width)
	return edNone, cmd
}

func (e *editor) afterEdit(width int) {
	e.resize(width)
	e.suggest()
}

// suggest looks at the token at the end of the text: @path -> the agent's files, a leading /cmd -> commands.
func (e *editor) suggest() {
	v := e.ta.Value()
	e.comp = nil
	if v == "" || strings.HasSuffix(v, " ") || strings.HasSuffix(v, "\n") {
		return
	}
	tok := v
	if i := strings.LastIndexAny(v, " \n\t"); i >= 0 {
		tok = v[i+1:]
	}
	var items []string
	switch {
	case strings.HasPrefix(tok, "@"):
		items = rank(e.cwdFiles(), tok[1:], "@")
		e.compKind = '@'
	case strings.HasPrefix(tok, "/") && tok == v:
		items = rank(slashCommands(e.cwd), tok[1:], "/")
		e.compKind = '/'
	default:
		return
	}
	if len(items) == 1 && items[0] == tok {
		return // already complete
	}
	if len(items) > 6 {
		items = items[:6]
	}
	if e.compTok != tok {
		e.compSel = 0
	}
	e.comp, e.compTok = items, tok
}

func (e *editor) accept() {
	if e.compSel >= len(e.comp) {
		return
	}
	v := e.ta.Value()
	e.ta.SetValue(v[:len(v)-len(e.compTok)] + e.comp[e.compSel] + " ")
	e.comp = nil
}

// rank: candidates whose text contains every letter of q in order (case-insensitive), best first: the name
// starts with q, then q appears in one piece, then the shortest. Each gets prefix in front.
func rank(cands []string, q, prefix string) []string {
	ql := strings.ToLower(q)
	type sc struct {
		s     string
		score int
	}
	var out []sc
	for _, c := range cands {
		cl := strings.ToLower(c)
		if !subseq(cl, ql) {
			continue
		}
		score := len(c)
		base := strings.ToLower(filepath.Base(c))
		switch {
		case strings.HasPrefix(base, ql) || strings.HasPrefix(cl, ql):
			score -= 10000
		case strings.Contains(cl, ql):
			score -= 5000
		}
		out = append(out, sc{prefix + c, score})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].score < out[j].score })
	res := make([]string, 0, len(out))
	for _, o := range out {
		res = append(res, o.s)
	}
	return res
}

func subseq(s, q string) bool {
	i := 0
	for _, r := range s {
		if i < len(q) && byte(r) == q[i] {
			i++
		}
	}
	return i == len(q)
}

// cwdFiles: the agent folder's files, relative: git's list in a repo, else a shallow walk. Cached for a minute.
func (e *editor) cwdFiles() []string {
	if e.cwd == "" {
		return nil
	}
	if at, ok := e.filesAt[e.cwd]; ok && time.Since(at) < time.Minute {
		return e.files[e.cwd]
	}
	var files []string
	if out, err := exec.Command("git", "-C", e.cwd, "ls-files", "--cached", "--others", "--exclude-standard").Output(); err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if l != "" {
				files = append(files, l)
			}
			if len(files) >= 20000 {
				break
			}
		}
	} else {
		root := e.cwd
		_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(root, p)
			if d.IsDir() {
				if rel != "." && (strings.HasPrefix(d.Name(), ".") || d.Name() == "node_modules" || d.Name() == "Library" || strings.Count(rel, "/") >= 2) {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasPrefix(d.Name(), ".") {
				files = append(files, rel)
			}
			if len(files) >= 5000 {
				return filepath.SkipAll
			}
			return nil
		})
	}
	e.files[e.cwd], e.filesAt[e.cwd] = files, time.Now()
	return files
}

var builtinSlash = []string{"add-dir", "agents", "clear", "compact", "config", "context", "cost", "doctor", "exit",
	"export", "help", "hooks", "init", "mcp", "memory", "model", "permissions", "plugin", "pr-comments", "release-notes",
	"rename", "resume", "review", "rewind", "security-review", "skills", "status", "statusline", "todos", "usage"}

// slashCommands: Claude Code's built-ins, the owner's commands and skills, and the agent folder's own.
func slashCommands(cwd string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(n string) {
		if n != "" && !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	for _, b := range builtinSlash {
		add(b)
	}
	home := os.Getenv("HOME")
	for _, base := range []string{filepath.Join(home, ".claude"), filepath.Join(cwd, ".claude")} {
		cmds, _ := filepath.Glob(filepath.Join(base, "commands", "*.md"))
		for _, c := range cmds {
			add(strings.TrimSuffix(filepath.Base(c), ".md"))
		}
		skills, _ := os.ReadDir(filepath.Join(base, "skills"))
		for _, s := range skills {
			if !strings.HasPrefix(s.Name(), ".") {
				add(s.Name())
			}
		}
	}
	return out
}

// pasteImage saves an image on the clipboard as a PNG and returns its path; ” when the clipboard holds none.
func pasteImage() string {
	dir := filepath.Join(agentHome(), "terminal", "images")
	_ = os.MkdirAll(dir, 0o755)
	p := filepath.Join(dir, time.Now().Format("20060102-150405")+".png")
	script := `set f to open for access (POSIX file "` + p + `") with write permission
try
	write (the clipboard as «class PNGf») to f
	close access f
on error
	close access f
	error "no image"
end try`
	if err := exec.Command("osascript", "-e", script).Run(); err != nil {
		_ = os.Remove(p)
		return ""
	}
	if st, err := os.Stat(p); err != nil || st.Size() == 0 {
		_ = os.Remove(p)
		return ""
	}
	return p
}

func clipboardText() string {
	out, _ := exec.Command("pbpaste").Output()
	return string(out)
}

func (e *editor) insert(s string, width int) {
	e.ta.InsertString(s)
	e.afterEdit(width)
}

// externalEditor: the text in $VISUAL / $EDITOR (nano when neither is set), back into the box when it closes.
func (e *editor) externalEditor() (*exec.Cmd, string) {
	f, err := os.CreateTemp("", "kaching-reply-*.md")
	if err != nil {
		return nil, ""
	}
	_, _ = f.WriteString(e.ta.Value())
	f.Close()
	ed := os.Getenv("VISUAL")
	if ed == "" {
		ed = os.Getenv("EDITOR")
	}
	if ed == "" {
		ed = "nano"
	}
	parts := strings.Fields(ed)
	return exec.Command(parts[0], append(parts[1:], f.Name())...), f.Name()
}

// lines renders the box for the agent panel: suggestions, the text area, and one line of keys.
func (e *editor) lines(width int) []string {
	var out []string
	for i, c := range e.comp {
		if i == e.compSel {
			out = append(out, row(width, s(padTo(" "+c, width), cSel)))
		} else {
			out = append(out, row(width, s(" "+c, cGrey)))
		}
	}
	for _, l := range strings.Split(e.ta.View(), "\n") {
		lw := lipgloss.Width(l)
		if lw < width {
			l += strings.Repeat(" ", width-lw)
		}
		out = append(out, l)
	}
	hint := "⏎ send · ⌥⏎ new line · @ file · / command · ctrl+v image · ctrl+g editor · esc keeps draft"
	if len(e.comp) > 0 {
		hint = "tab or ⏎ takes it · ↑↓ choose · esc closes the list"
	}
	out = append(out, row(width, s(hint, cDark)))
	return out
}
