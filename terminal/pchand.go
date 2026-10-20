package main

// Hand a Paperclip issue to an agent that has the owner's permissions. Paperclip's own agents run with restricted
// permissions and sometimes can't finish a job (set a status, merge, write outside their folder). From the PC view
// the owner hands the issue to
//   - a new background agent (b),
//   - a new session in a Terminal window (t), or
//   - a session that is already running, by starting the box's text with @Name.
// The agent gets a short first message and a briefing file with the issue's context: description, thread, the
// request that waits, and how to report back through Paperclip's local API.

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// pcHandDefault is the task when the owner writes nothing in the box.
const pcHandDefault = "Look over this issue and finish what the Paperclip agents could not: their permissions are " +
	"restricted, yours are not."

const (
	pcHandDesc     = 6000 // characters of the description in the briefing
	pcHandComments = 15   // comments of the thread (the newest)
	pcHandComment  = 1500 // characters of one comment
)

// pcHandTarget splits the box target "pcgo:<issue id>@<kind>" (kind b: background agent, t: the same with its screen open, D75).
func pcHandTarget(target string) (id, kind string, ok bool) {
	rest, ok := strings.CutPrefix(target, "pcgo:")
	if !ok {
		return "", "", false
	}
	if i := strings.LastIndex(rest, "@"); i >= 0 {
		return rest[:i], rest[i+1:], true
	}
	return rest, "b", true
}

// pcHandFor: the box is open to hand the issue id over.
func pcHandFor(target, id string) bool {
	got, _, ok := pcHandTarget(target)
	return ok && got == id
}

func handDir() string { return filepath.Join(agentHome(), "terminal", "handoff") }

var headLineRe = regexp.MustCompile(`^([a-z][a-z_-]*):\s*(.*)$`)

// pcIssueRepo is the "repo:" line in the head of an issue's description ("lane: triage\nrepo: cos\n..."), the
// head being the "key: value" lines before the first blank line.
func pcIssueRepo(desc string) string {
	for _, l := range strings.Split(desc, "\n") {
		l = strings.TrimSpace(l)
		if l == "" {
			return ""
		}
		m := headLineRe.FindStringSubmatch(l)
		if m == nil { // the head is over
			return ""
		}
		if m[1] == "repo" {
			return strings.TrimSpace(m[2])
		}
	}
	return ""
}

// pcIssueDir is the folder the agent works in: the issue's repo as a folder of ~/bbq or of home, else home.
func pcIssueDir(d PCDetail) string {
	home := os.Getenv("HOME")
	if repo := pcIssueRepo(d.Description); repo != "" && !strings.ContainsAny(repo, " /\\") && repo != ".." {
		for _, p := range []string{filepath.Join(home, "bbq", repo), filepath.Join(home, repo)} {
			if dirExists(p) {
				return p
			}
		}
	}
	return home
}

func cut(t string, n int) string {
	t = strings.TrimSpace(t)
	if r := []rune(t); len(r) > n {
		return string(r[:n]) + "…"
	}
	return t
}

// inThread: the text (a request's details) is already in a comment of the thread, so the briefing need not repeat it.
func inThread(cs []PCComment, text string) bool {
	probe := strings.TrimSpace(text)
	if r := []rune(probe); len(r) > 200 {
		probe = string(r[:200])
	}
	for _, c := range cs {
		if probe != "" && strings.Contains(c.Body, probe) {
			return true
		}
	}
	return false
}

// pcBriefing is the file the agent reads first: everything it needs about the issue, and the rules.
func pcBriefing(it PCItem, d PCDetail, dir string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Paperclip issue %s: %s\n\n", it.Ref, it.Title)
	fmt.Fprintf(&b, "- Status: %s", strings.ReplaceAll(it.Status, "_", " "))
	if it.Agent != "" {
		fmt.Fprintf(&b, " · assigned to %s", it.Agent)
	}
	if it.Cost != "" {
		fmt.Fprintf(&b, " · spent %s", it.Cost)
	}
	b.WriteString("\n")
	if it.URL != "" {
		fmt.Fprintf(&b, "- In Paperclip: %s\n", it.URL)
	}
	if it.Detail != "" {
		fmt.Fprintf(&b, "- Why it waits for me: %s\n", it.Detail)
	}
	fmt.Fprintf(&b, "- Folder of the work: %s\n\n", tildify(dir))
	b.WriteString("## Why you have it\n\nThe Paperclip agents run with restricted permissions and could not finish this. " +
		"You work with my permissions, on my Mac. Look over what they did and finish it.\n\n")
	if d.Description != "" {
		fmt.Fprintf(&b, "## Description\n\n%s\n\n", cut(d.Description, pcHandDesc))
	}
	if n := len(d.Comments); n > 0 {
		cs := d.Comments
		if n > pcHandComments {
			cs = cs[n-pcHandComments:]
			fmt.Fprintf(&b, "## Thread (the last %d of %d comments, oldest first)\n\n", pcHandComments, n)
		} else {
			b.WriteString("## Thread (oldest first)\n\n")
		}
		for _, c := range cs {
			who := c.Author
			if c.Board {
				who = "me"
			}
			fmt.Fprintf(&b, "**%s** · %s\n\n%s\n\n", who, c.At.Local().Format("Jan 2 15:04"), cut(c.Body, pcHandComment))
		}
	}
	if a := d.Ask; a != nil {
		b.WriteString("## What waits for my answer\n\n")
		if a.Title != "" {
			fmt.Fprintf(&b, "%s\n\n", a.Title)
		}
		if a.Prompt != "" {
			fmt.Fprintf(&b, "%s\n\n", cut(a.Prompt, 1500))
		}
		if a.Details != "" && !inThread(d.Comments, a.Details) {
			fmt.Fprintf(&b, "%s\n\n", cut(a.Details, 3000))
		}
		b.WriteString("This is my decision. Do not answer it.\n\n")
	}
	api := "http://localhost:3100/api/issues/" + d.ID
	fmt.Fprintf(&b, "## Paperclip's API (this Mac, no login)\n\n"+
		"- Read the issue: `curl -s %s`\n"+
		"- Read its thread: `curl -s %s/comments`\n"+
		"- Report and set the status in one call: `curl -s -X PATCH %s -H 'content-type: application/json' "+
		"-d '{\"status\":\"in_review\",\"comment\":\"From an external Claude session: ...\"}'`\n\n", api, api, api)
	b.WriteString("## Rules\n\n" +
		"- Do the work, or review what is there. If you change code in a repo, work in your own git worktree, not in the main checkout.\n" +
		"- When you are done, report once on the issue (the PATCH call above): start the comment with \"From an external Claude session:\", say what you did and what is left, and set the status to `in_review`. Never set it to `done`: I close issues.\n" +
		"- If you cannot finish, comment why and leave the status as it is.\n" +
		"- Do not accept, reject or answer any request or approval in Paperclip: those are mine.\n" +
		"- Do not push to a remote or merge unless the task says so.\n")
	return b.String()
}

// pcHandPrompt is the first message of the agent: where the briefing is, and the task.
func pcHandPrompt(it PCItem, file, instruction string) string {
	instruction = strings.TrimSpace(instruction)
	if instruction == "" {
		instruction = pcHandDefault
	}
	return fmt.Sprintf("Take over Paperclip issue %s: %s\nRead the briefing first: %s\n\n%s", it.Ref, it.Title, file, instruction)
}

// writeBriefing saves the briefing and returns its path.
func writeBriefing(it PCItem, text string) (string, error) {
	if err := os.MkdirAll(handDir(), 0o700); err != nil {
		return "", err
	}
	ref := strings.Map(func(r rune) rune {
		if r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' {
			return r
		}
		return '_'
	}, it.Ref)
	p := filepath.Join(handDir(), fmt.Sprintf("%s-%s.md", ref, time.Now().Format("20060102-150405")))
	return p, os.WriteFile(p, []byte(text), 0o600)
}

// pcHandOpen opens the box for handing the selected issue over: kind "b" a new background agent, "t" a new session
// in a Terminal window. An empty text sends the default task; @Name first sends it to that running session.
func (m *model) pcHandOpen(kind string) tea.Cmd {
	it := m.pcSelected()
	if it == nil || it.ID == "" {
		return nil
	}
	m.mode = mTyping
	return m.ed.open("pcgo:"+it.ID+"@"+kind, "", m.editorWidth())
}

// pcHandTitle is the title of the box while the hand-over box is open, else "".
func (m model) pcHandTitle() string {
	if m.mode != mTyping || m.ed == nil {
		return ""
	}
	id, kind, ok := pcHandTarget(m.ed.target)
	if !ok {
		return ""
	}
	what := "a new background agent"
	if kind == "t" {
		what = "a new background agent, its screen open"
	}
	ref := id
	for _, it := range m.pc.Items {
		if it.ID == id {
			ref = it.Ref
		}
	}
	return "─ hand " + ref + " to " + what + " · @Name: a running session "
}

// pcHandSend hands the issue over with what the owner wrote. keep is true when it could not go (the box stays open,
// the text stays); otherwise cmd does it.
func (m *model) pcHandSend(id, kind, text string) (cmd tea.Cmd, keep bool) {
	var it *PCItem
	for i := range m.pc.Items {
		if m.pc.Items[i].ID == id {
			it = &m.pc.Items[i]
		}
	}
	if it == nil {
		m.setErr("that issue is no longer in the list")
		return nil, true
	}
	item := *it
	instruction := text
	var target *Agent // a running session, when the text starts with @Name
	if name, rest, ok := mention(text); ok {
		a, n := m.agentNamed(name)
		switch {
		case n == 0:
			m.setErr("no live session is named " + name)
			return nil, true
		case n > 1:
			m.setErr(fmt.Sprintf("%d sessions are named %s: select one and write to it", n, a.Name))
			return nil, true
		case !a.canSend():
			m.setErr(a.Name + " isn't in a Terminal tab: look only (g opens it)")
			return nil, true
		case m.prompts[a.SID].Options != nil:
			m.setErr(a.Name + " shows a menu: answer it first")
			return nil, true
		}
		target, instruction = &a, rest
	}
	cached, haveCached := m.pcDet[id]
	names := m.pc.Names
	o := parseNW("", m.cfg) // the model, effort and mode that keys.toml sets for /NW
	o.Name = "paperclip " + item.Ref
	m.setStatus("handing " + item.Ref + " over…")
	return func() tea.Msg {
		d := cached
		if !haveCached || d.Err != "" || time.Since(d.At) > 30*time.Second {
			d = loadPCDetail(id, names)
		}
		if d.Err != "" {
			return sentMsg{"", item.Ref, "hand over", "error: " + d.Err}
		}
		dir := pcIssueDir(d)
		file, err := writeBriefing(item, pcBriefing(item, d, dir))
		if err != nil {
			return sentMsg{"", item.Ref, "hand over", "error: " + err.Error()}
		}
		prompt := pcHandPrompt(item, file, instruction)
		switch {
		case target != nil:
			return sentMsg{target.SID, target.Name, "hand over " + item.Ref, transmitFn(*target, prompt, nil)}
		}
		o.Dir = dir
		job, err := bgStartFn(o, prompt)
		if err != nil {
			return sentMsg{"", item.Ref, "hand over", "error: " + err.Error()}
		}
		return bgStartedMsg{job, dir, kind == "t"} // t: a background agent too, with its screen open at once (D75)
	}, false
}
