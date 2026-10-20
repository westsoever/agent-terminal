package main

import (
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
	"github.com/muesli/termenv"
)

// The links on screen come out top to bottom, each once, the lowest 9; numbering them keeps every line's width.
func TestScreenLinks(t *testing.T) {
	var rows []string
	for _, u := range []string{"https://a.dk/1", "https://a.dk/2", "https://a.dk/1"} {
		rows = append(rows, row(30, s("see "+u, cText)))
	}
	screen := strings.Join(rows, "\n")
	got := screenLinks(screen)
	if strings.Join(got, " ") != "https://a.dk/1 https://a.dk/2" {
		t.Fatalf("links: %q", got)
	}
	out := strings.Split(numberLinks(screen, got), "\n")
	plain := func(l string) string { return ansiRe.ReplaceAllString(oscRe.ReplaceAllString(l, ""), "") }
	for i, want := range []string{"see 1ttps://a.dk/1", "see 2ttps://a.dk/2", "see 1ttps://a.dk/1"} {
		if p := plain(out[i]); strings.TrimRight(p, " ") != want || runewidth.StringWidth(p) != 30 {
			t.Fatalf("line %d: %q", i, p)
		}
		if m := oscRe.FindAllStringSubmatch(out[i], -1); len(m) != 2 || m[0][1] != got[i%2] {
			t.Fatalf("line %d lost its link: %q", i, out[i])
		}
	}
	// in colour the number goes after the link's style codes, and the rest of the URL keeps its colour
	defer lipgloss.SetColorProfile(lipgloss.ColorProfile())
	lipgloss.SetColorProfile(termenv.ANSI256)
	c := numberLinks(row(30, s("see https://a.dk/1", cText)), got)
	if p := plain(c); !strings.HasPrefix(p, "see 1ttps://a.dk/1") || runewidth.StringWidth(p) != 30 || !regexp.MustCompile(`\x1b\[[0-9;]+mttps`).MatchString(c) {
		t.Fatalf("in colour: %q", c)
	}
	var many []string
	for i := range 12 {
		many = append(many, osc8("https://a.dk/"+itoa(i), "x"))
	}
	if got := screenLinks(strings.Join(many, " ")); len(got) != 9 || got[0] != "https://a.dk/3" {
		t.Fatalf("more than 9: %q", got)
	}
}

// o numbers the links in the agent's conversation, 1 opens the first; esc or a number with no link opens nothing.
func TestOpenLink(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	var opened []string
	defer func(f func(string) error) { linkOpen = f }(linkOpen)
	linkOpen = func(u string) error { opened = append(opened, u); return nil }
	cfg, _, _ := loadConfig()
	const url = "https://github.com/westsoever/agent-terminal/pull/18"
	tr := writeTranscript(t, `{"type":"user","message":{"content":"open a PR"}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Opened `+url+`."}]}}`)
	m := model{cfg: cfg, expect: map[string]time.Time{}, lastCache: map[string]cachedLast{}, ed: newEditor(),
		prompts: map[string]Prompt{}, scroll: &chatScroll{}, w: 140, h: 40}
	m.agents = []Agent{{SID: "a", Name: "one", Cwd: "/tmp", State: "done", Transcript: tr}}
	m.selSID = "a"
	m, _ = press(m, "o")
	if m.mode != mOpen || len(m.openLinks) != 1 || m.openLinks[0] != url {
		t.Fatalf("o: mode %v links %q", m.mode, m.openLinks)
	}
	if out := ansiRe.ReplaceAllString(oscRe.ReplaceAllString(m.View(), ""), ""); !strings.Contains(out, "1ttps://github.com") {
		t.Fatalf("no number on the link:\n%s", out)
	}
	m, _ = press(m, "1")
	if m.mode != mKeys || len(opened) != 1 || opened[0] != url || m.status != "opened "+url {
		t.Fatalf("1: opened %q status %q", opened, m.status)
	}
	if strings.Contains(m.View(), "1ttps") {
		t.Fatal("the number stays after the pick")
	}
	m, _ = press(m, "o", "esc")
	m, _ = press(m, "o", "2")
	if len(opened) != 1 || !m.statusErr {
		t.Fatalf("esc or 2 opened %q", opened)
	}
}

var oscRe = regexp.MustCompile("\x1b\\]8;;([^\x1b]*)\x1b\\\\")

func TestURLSpans(t *testing.T) {
	for in, want := range map[string]string{
		"see https://a.dk/x.":                      "https://a.dk/x",
		"(https://a.dk/x)":                         "https://a.dk/x",
		"https://en.wikipedia.org/wiki/Go_(game),": "https://en.wikipedia.org/wiki/Go_(game)",
		"no link, http:// alone":                   "",
		"**https://a.dk/?q=1&r=2**":                "https://a.dk/?q=1&r=2",
	} {
		got := ""
		if sp := urlSpans(in); len(sp) > 0 {
			got = in[sp[0][0]:sp[0][1]]
		}
		if got != want {
			t.Errorf("%q: got %q want %q", in, got, want)
		}
	}
}

// A URL in a row is a link to the whole URL, the row keeps its width, and a URL cut with … still links to all of it.
func TestRowLinks(t *testing.T) {
	const url = "https://github.com/westsoever/ching/pull/1"
	r := row(60, s("PR: "+url+" done", cText))
	if m := oscRe.FindAllStringSubmatch(r, -1); len(m) != 2 || m[0][1] != url || m[1][1] != "" {
		t.Fatalf("links in %q: %q", r, m)
	}
	if lipgloss.Width(r) != 60 {
		t.Fatalf("width %d", lipgloss.Width(r))
	}
	r = row(30, s("PR: "+url+" done", cText))
	if m := oscRe.FindAllStringSubmatch(r, -1); len(m) != 2 || m[0][1] != url {
		t.Fatalf("cut link in %q: %q", r, m)
	}
	if lipgloss.Width(r) != 30 || !strings.Contains(ansiRe.ReplaceAllString(oscRe.ReplaceAllString(r, ""), ""), "…") {
		t.Fatalf("cut row width %d: %q", lipgloss.Width(r), r)
	}
	if r = row(20, s("no links here", cText)); strings.Contains(r, "\x1b]8") {
		t.Fatal("a row without a URL has no link")
	}
	// wrap keeps a long URL on one line instead of cutting it in the middle
	if lines := wrap("see "+url+" ok", 20); len(lines) != 3 || lines[1] != url {
		t.Fatalf("wrap: %q", lines)
	}
}
