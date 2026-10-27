package main

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// An agent's text keeps its inline marks as two zero-width control characters through wrap and the table
// layout: mdCode opens and closes a `code` span (or a link's text), mdBold a bold span (or a heading). mdSegs
// turns them into colors when a row is drawn. wrap and width see them as nothing, so the columns stay straight.
const (
	mdCode = "\x01"
	mdBold = "\x02"
)

var mdLinkRe = regexp.MustCompile(`\[([^\]\n]+)\]\((https?://[^)\s]+)\)`)

// mdPlain is plain for text that is drawn in colors: bold, `code`, [links](url) and headings turn into marks
// instead of being stripped.
func mdPlain(t string) string {
	t = strings.NewReplacer(mdCode, "", mdBold, "").Replace(t)
	t = mdLinkRe.ReplaceAllString(t, "`$1` ($2)")
	var b strings.Builder
	code := false
	for i := 0; i < len(t); i++ {
		switch {
		case t[i] == '`':
			code = !code
			b.WriteString(mdCode)
		case !code && strings.HasPrefix(t[i:], "**"):
			b.WriteString(mdBold)
			i++
		default:
			b.WriteByte(t[i])
		}
	}
	lines := strings.Split(b.String(), "\n")
	for i, l := range lines {
		if trim := strings.TrimLeft(l, "#"); trim != l {
			lines[i] = mdBold + strings.TrimSpace(trim) + mdBold
		}
	}
	return strings.Join(lines, "\n")
}

// unMd is t without its marks.
func unMd(t string) string { return strings.NewReplacer(mdCode, "", mdBold, "").Replace(t) }

// balanceMd makes every wrapped line carry its own marks: a span still open at the end of a line is closed
// there and opened again at the start of the next.
func balanceMd(lines []string) []string {
	var code, bold bool
	out := make([]string, len(lines))
	for i, l := range lines {
		pre := ""
		if code {
			pre += mdCode
		}
		if bold {
			pre += mdBold
		}
		code = code != (strings.Count(l, mdCode)%2 == 1)
		bold = bold != (strings.Count(l, mdBold)%2 == 1)
		post := ""
		if code {
			post += mdCode
		}
		if bold {
			post += mdBold
		}
		out[i] = pre + l + post
	}
	return out
}

// wrapMd is wrap for marked text.
func wrapMd(text string, w int) []string { return balanceMd(wrap(mdPlain(text), w)) }

// proseLinkRe: a file path in prose: one that starts with / ~/ ./ ../, or a relative one that ends in a file name
// with an extension. Group 1 is what comes before it, group 2 the path.
var proseLinkRe = regexp.MustCompile(`(^|[\s(\[])((?:(?:~|\.\.?)?/[\w.@+-]+(?:/[\w.@+-]+)*/?)|(?:[\w.@+-]+(?:/[\w.@+-]+)*/[\w@+-]+\.[A-Za-z]\w{0,5}))`)

// linkSpans: the byte ranges in t of the URLs (true) and the file paths (false), in order.
func linkSpans(t string) (spans [][2]int, urls []bool) {
	us := urlSpans(t)
	inURL := func(i int) bool {
		for _, u := range us {
			if i >= u[0] && i < u[1] {
				return true
			}
		}
		return false
	}
	type span struct {
		a, b int
		url  bool
	}
	var all []span
	for _, u := range us {
		all = append(all, span{u[0], u[1], true})
	}
	for _, m := range proseLinkRe.FindAllStringSubmatchIndex(t, -1) {
		a, b := m[4], m[5]
		for b > a && strings.IndexByte(".,;:)]", t[b-1]) >= 0 {
			b--
		}
		if b > a+1 && !inURL(a) {
			all = append(all, span{a, b, false})
		}
	}
	for i := 1; i < len(all); i++ { // few spans: insertion sort by start
		for j := i; j > 0 && all[j].a < all[j-1].a; j-- {
			all[j], all[j-1] = all[j-1], all[j]
		}
	}
	for _, sp := range all {
		spans = append(spans, [2]int{sp.a, sp.b})
		urls = append(urls, sp.url)
	}
	return spans, urls
}

// mdSegs draws one line of marked text: `code`, paths and links in the link color (URLs underlined), bold in
// white, the rest in base.
func mdSegs(l string, base lipgloss.Style) []seg {
	var out []seg
	add := func(t string, st lipgloss.Style, links bool) {
		if t == "" {
			return
		}
		if !links {
			out = append(out, s(t, st))
			return
		}
		spans, urls := linkSpans(t)
		pos := 0
		for i, sp := range spans {
			if sp[0] < pos {
				continue
			}
			out = append(out, s(t[pos:sp[0]], st))
			ls := cLink
			if urls[i] {
				ls = ls.Underline(true)
			}
			out = append(out, s(t[sp[0]:sp[1]], ls))
			pos = sp[1]
		}
		out = append(out, s(t[pos:], st))
	}
	code, bold := false, false
	for _, part := range splitMarks(l) {
		switch part {
		case mdCode:
			code = !code
		case mdBold:
			bold = !bold
		default:
			switch {
			case code:
				add(part, cLink, false)
			case bold:
				add(part, cWhite, false)
			default:
				add(part, base, true)
			}
		}
	}
	return out
}

// splitMarks cuts t into its text runs and its marks, in order.
func splitMarks(t string) []string {
	var out []string
	for {
		i := strings.IndexAny(t, mdCode+mdBold)
		if i < 0 {
			return append(out, t)
		}
		out = append(out, t[:i], t[i:i+1])
		t = t[i+1:]
	}
}
