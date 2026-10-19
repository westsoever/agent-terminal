package main

import (
	"regexp"
	"strings"
)

// Links in the text are OSC 8 hyperlinks, so cmd+click in the terminal opens them in the default browser. The
// click target is the whole URL even when the row shows it cut with …; wrap does not break a URL for that reason.

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
