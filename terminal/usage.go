package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// Limit is one of the account's Claude usage limits: how much of it is used and when it starts over.
type Limit struct {
	Pct   float64
	Reset time.Time
	OK    bool
}

// Usage is the 5-hour window and the 7-day limit as a session's statusline last saw them. The statusline
// writes ~/.agent/usage/<session id>.json (Claude Code's rate_limits) only when they change, so the newest
// file is the newest reading.
type Usage struct {
	Five, Week Limit
	OK         bool
}

func usageDir() string { return filepath.Join(agentHome(), "usage") }

func loadUsage() Usage {
	files, _ := filepath.Glob(filepath.Join(usageDir(), "*.json"))
	var newest string
	var at time.Time
	for _, f := range files {
		if st, err := os.Stat(f); err == nil && st.ModTime().After(at) {
			newest, at = f, st.ModTime()
		}
	}
	if newest == "" {
		return Usage{}
	}
	b, err := os.ReadFile(newest)
	if err != nil {
		return Usage{}
	}
	var raw struct {
		Five limitJSON `json:"five_hour"`
		Week limitJSON `json:"seven_day"`
	}
	if json.Unmarshal(b, &raw) != nil {
		return Usage{}
	}
	u := Usage{Five: raw.Five.limit(), Week: raw.Week.limit()}
	u.OK = u.Five.OK || u.Week.OK
	return u
}

type limitJSON struct {
	Pct     *float64        `json:"used_percentage"`
	ResetAt json.RawMessage `json:"resets_at"`
}

func (l limitJSON) limit() Limit {
	if l.Pct == nil {
		return Limit{}
	}
	return Limit{Pct: *l.Pct, Reset: resetTime(l.ResetAt), OK: true}
}

// resetTime reads resets_at: epoch seconds, as a number or a string, or an RFC 3339 time.
func resetTime(r json.RawMessage) time.Time {
	t := strings.Trim(string(r), `"`)
	if n, err := strconv.ParseFloat(t, 64); err == nil && n > 0 {
		return time.Unix(int64(n), 0)
	}
	if p, err := time.Parse(time.RFC3339, t); err == nil {
		return p
	}
	return time.Time{}
}

// now: what the limit stands at. A window whose reset has passed has started over.
func (l Limit) now(at time.Time) (pct float64, left time.Duration) {
	if l.Reset.IsZero() {
		return l.Pct, 0
	}
	if left = l.Reset.Sub(at); left <= 0 {
		return 0, 0
	}
	return l.Pct, left
}

// The usage colours: green while there's plenty, amber from half, red from 80%, as the statusline does.
var (
	cUseLow  = lipgloss.NewStyle().Foreground(lipgloss.Color("71"))
	cUseMid  = lipgloss.NewStyle().Foreground(lipgloss.Color("178"))
	cUseHigh = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
)

func useStyle(pct float64) lipgloss.Style {
	switch {
	case pct >= 80:
		return cUseHigh
	case pct >= 50:
		return cUseMid
	}
	return cUseLow
}

const (
	usageBarW = 20
	usageW    = 2 + 1 + 4 + 1 + usageBarW + 1 + 8 // label, percentage, bar, reset
)

// usageRows are the two footer rows on the right: the 5-hour window over the 7-day limit, each its exact
// percentage, a bar and the time left until it starts over. Both rows are equally wide.
func usageRows(u Usage, at time.Time) [2][]seg {
	if !u.OK {
		return [2][]seg{{s("claude usage: no statusline reading yet", cDark)}, {}}
	}
	line := func(label string, l Limit) []seg {
		if !l.OK {
			return []seg{s(padTo(label+"    —", usageW), cDark)}
		}
		pct, left := l.now(at)
		st := useStyle(pct)
		full, part := barCells(pct, usageBarW)
		reset := ""
		if left > 0 {
			reset = "↻ " + dur(left)
		}
		return []seg{
			s(label+" ", cGrey), s(fmt.Sprintf("%3.0f%%", math.Min(pct, 999)), st), s(" ", cPlain),
			s(full, st), s(part, cDark), s(" "+padTo(reset, 8), cGrey),
		}
	}
	return [2][]seg{line("5h", u.Five), line("7d", u.Week)}
}

// barCells: the filled part of a w-cell bar for pct (eighth blocks for the last cell) and the empty rest.
func barCells(pct float64, w int) (full, empty string) {
	eighths := int(math.Round(math.Max(0, math.Min(pct, 100)) / 100 * float64(w*8)))
	n := eighths / 8
	full = strings.Repeat("█", n)
	if r := eighths % 8; r > 0 {
		full += string([]rune(" ▏▎▍▌▋▊▉")[r])
		n++
	}
	return full, strings.Repeat("░", w-n)
}

// dur is a time left in its two biggest units: 2h13m, 3d04h, 12m.
func dur(d time.Duration) string {
	m := int(math.Ceil(d.Minutes()))
	switch {
	case m >= 24*60:
		return fmt.Sprintf("%dd%02dh", m/(24*60), m%(24*60)/60)
	case m >= 60:
		return fmt.Sprintf("%dh%02dm", m/60, m%60)
	}
	return fmt.Sprintf("%dm", m)
}

// ctxPct is the share of the context window in use, the way agent-terminal-watch.sh counts it: the window is
// 200k tokens unless the context already exceeds it (then 1M). -1 when the transcript gave no usage.
func ctxPct(tokens int) int {
	if tokens <= 0 {
		return -1
	}
	win := 200000
	if tokens > win {
		win = 1000000
	}
	return tokens * 100 / win
}

// modelTag is the top right of an agent's frame: "[Opus 5.5] high ctx: 42%". nil when its transcript names no model.
func modelTag(l Last) []seg {
	if l.Model == "" {
		return nil
	}
	tag := []seg{s("["+modelName(l.Model)+"]", cWhite)}
	if l.Effort != "" {
		tag = append(tag, s(" "+l.Effort, cGrey))
	}
	if pct := ctxPct(l.Ctx); pct >= 0 {
		c := cGrey
		if pct >= 80 {
			c = cOrange
		}
		tag = append(tag, s(fmt.Sprintf(" ctx: %d%%", pct), c))
	}
	return tag
}

// modelName turns a model id into its name: claude-opus-5-5 → Opus 5.5, claude-haiku-4-5-20251001 → Haiku 4.5,
// claude-sonnet-5-5[1m] → Sonnet 5.5 1M. An id of another shape stays as it is.
func modelName(id string) string {
	name := strings.TrimPrefix(id, "claude-")
	suffix := ""
	if i := strings.Index(name, "["); i > 0 {
		suffix = " " + strings.ToUpper(strings.Trim(name[i:], "[]"))
		name = name[:i]
	}
	parts := strings.Split(name, "-")
	if len(parts) < 2 || parts[0] == "" || parts[0][0] < 'a' || parts[0][0] > 'z' {
		return id
	}
	var ver []string
	for _, p := range parts[1:] {
		if _, err := strconv.Atoi(p); err != nil || len(p) >= 8 { // not a version number, or a date
			break
		}
		ver = append(ver, p)
	}
	if len(ver) == 0 {
		return id
	}
	return strings.ToUpper(parts[0][:1]) + parts[0][1:] + " " + strings.Join(ver, ".") + suffix
}
