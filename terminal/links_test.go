package main

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

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
