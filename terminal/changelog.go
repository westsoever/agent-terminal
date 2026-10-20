package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// vChangelog is the CL view: what changed, newest first, one line per decision in DECISIONS.md. It has no tab,
// like FIND, and scrolls like the help page (it shares helpOff).
const vChangelog view = 1002

var decisionRe = regexp.MustCompile(`^## (D\d+) \((\d{4}-\d{2}-\d{2})\): (.+)$`)

// changelogLines is the changelog as lines for textBody: a "## date" heading per day, then row2(D-number, title) for
// each decision of that day. DECISIONS.md is read when CL opens, so it is current without a rebuild.
func changelogLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return []string{"No changelog: " + path + " can't be read."}
	}
	var lines []string
	day := ""
	for _, l := range strings.Split(string(data), "\n") {
		g := decisionRe.FindStringSubmatch(l)
		if g == nil {
			continue
		}
		if g[2] != day {
			if day != "" {
				lines = append(lines, "")
			}
			day = g[2]
			lines = append(lines, "## "+day)
		}
		lines = append(lines, g[1]+"\t"+strings.ReplaceAll(g[3], "`", ""))
	}
	if len(lines) == 0 {
		return []string{"No changelog: " + path + " has no decisions."}
	}
	return lines
}

func (m model) changelogLines() []string {
	return changelogLines(filepath.Join(kitDir(), "DECISIONS.md"))
}

// pageLines: the lines of the scrolling text page on screen, the help page or the changelog.
func (m model) pageLines() []string {
	if m.view == vChangelog {
		return m.changelogLines()
	}
	return m.helpLines()
}
