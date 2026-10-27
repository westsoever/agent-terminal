package main

import (
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Links in the text are OSC 8 hyperlinks, so cmd+click opens them in terminals that know OSC 8 (iTerm2, Ghostty).
// The click target is the whole URL even when the row shows it cut with …; wrap does not break a URL for that
// reason. Terminal.app ignores OSC 8, so o numbers the links on screen and 1-9 opens one (D72); the mouse stays
// the terminal's, so drag-to-select keeps working.

var urlRe = regexp.MustCompile(`https?://[^\s<>"'` + "`" + `]+`)

// urlSpans: the byte ranges of the URLs in t, without the punctuation that ends a sentence around them.
func urlSpans(t string) [][2]int {
	var out [][2]int
	for _, m := range urlRe.FindAllStringIndex(t, -1) {
		end := m[1]
		for end > m[0] {
			c := t[end-1]
			if strings.IndexByte(".,;:!?]}*", c) >= 0 || (c == ')' && !strings.Contains(t[m[0]:end], "(")) {
				end--
				continue
			}
			break
		}
		if end-m[0] > len("https://") {
			out = append(out, [2]int{m[0], end})
		}
	}
	return out
}

// isURL: whether the word starts with a URL, so that wrap keeps it whole.
func isURL(w string) bool {
	sp := urlSpans(w)
	return len(sp) > 0 && sp[0][0] == 0
}

func osc8(url, text string) string {
	return "\x1b]8;;" + url + "\x1b\\" + text + "\x1b]8;;\x1b\\"
}

// renderSeg renders sg for display as shown: sg.t, or its prefix cut with a closing … (cut). The URLs in sg.t
// become links; one that is cut still points at the whole URL, and carries the … with it.
func renderSeg(sg seg, shown string, cut bool) string {
	if sg.link != "" {
		return osc8(sg.link, sg.st.Render(shown))
	}
	spans := urlSpans(sg.t)
	if len(spans) == 0 {
		return sg.st.Render(shown)
	}
	body := shown
	if cut {
		body = strings.TrimSuffix(shown, "…")
	}
	var b strings.Builder
	plainPart := func(t string) {
		if t != "" {
			b.WriteString(sg.st.Render(t))
		}
	}
	pos := 0
	for _, sp := range spans {
		if sp[0] >= len(body) {
			break
		}
		plainPart(body[pos:sp[0]])
		end := min(sp[1], len(body))
		t := body[sp[0]:end]
		if cut && end == len(body) {
			t += "…"
		}
		b.WriteString(osc8(sg.t[sp[0]:sp[1]], sg.st.Render(t)))
		pos = end
	}
	if pos < len(body) {
		plainPart(body[pos:])
	}
	if cut && !(pos == len(body) && len(spans) > 0 && pos > 0 && endsInLink(spans, pos)) {
		plainPart("…")
	}
	return b.String()
}

// endsInLink: whether a link reaches pos, the end of the shown text (the … is then inside it already).
func endsInLink(spans [][2]int, pos int) bool {
	for _, sp := range spans {
		if sp[0] < pos && min(sp[1], pos) == pos {
			return true
		}
	}
	return false
}

// linkOpen opens a link in the default browser; tests replace it.
var linkOpen = func(url string) error { return openPath("open", url) }

// linkRe: one link as osc8 writes it: its URL and the text shown for it.
var linkRe = regexp.MustCompile("\x1b\\]8;;([^\x1b]+)\x1b\\\\(.*?)\x1b\\]8;;\x1b\\\\")

var sgrRe = regexp.MustCompile("^\x1b\\[[0-9;]*m")

// screenLinks: the URLs of the links on a drawn screen, top to bottom, each once; the lowest 9 when there are more.
func screenLinks(screen string) []string {
	var out []string
	for _, mm := range linkRe.FindAllStringSubmatch(screen, -1) {
		if !slices.Contains(out, mm[1]) {
			out = append(out, mm[1])
		}
	}
	return out[max(0, len(out)-9):]
}

// numberLinks writes the number of each of links on its first cell, so the screen shows what 1-9 opens. The
// number takes the place of the first character, so every line keeps its width.
func numberLinks(screen string, links []string) string {
	return linkRe.ReplaceAllStringFunc(screen, func(l string) string {
		mm := linkRe.FindStringSubmatch(l)
		i, text, j := slices.Index(links, mm[1]), mm[2], 0
		for loc := sgrRe.FindStringIndex(text); loc != nil; loc = sgrRe.FindStringIndex(text[j:]) {
			j += loc[1] // past the style codes in front of the first character
		}
		if i < 0 || j == len(text) {
			return l
		}
		_, n := utf8.DecodeRuneInString(text[j:])
		return osc8(mm[1], cSel.Render(strconv.Itoa(i+1))+text[:j]+text[j+n:])
	})
}
