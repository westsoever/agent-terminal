package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Last is what the desk shows for the selected agent, read from the tail of its transcript.
type Last struct {
	Text     string        // the agent's last message
	Question string        // an open AskUserQuestion, '' when none
	Options  []string      // numbered options: from the open question, else "1. ..." lines in the last message
	Menu     bool          // true: the options are a menu in Claude Code (answer with a key press, no Enter)
	Ask      []AskQuestion // every question of the open AskUserQuestion, with its recommendations; nil when none
	AskID    string        // the tool call of that question set
	Files    []string      // paths the last message mentions that exist, absolute
	Recap    string        // Claude Code's latest recap (the "while you were away" summary), '' when none
	RecapAt  time.Time     // when Claude Code wrote it
	Chat     []Turn        // the conversation in the transcript tail, oldest first, at most maxTurns
	Model    string        // the model of its latest reply, as Claude Code names it ("claude-opus-5-5"), '' when none
	Effort   string        // the effort that reply ran at ("high"), '' when the transcript doesn't say
	Ctx      int           // tokens in the context window after its latest reply, 0 when the transcript doesn't say
	Mentions []fileMention // the files its recent messages name (newest message last), for the FL view
}

// Turn is one message of the conversation: the owner's prompt (User) or a text the agent wrote.
type Turn struct {
	User bool
	Text string
	At   time.Time
}

const maxTurns = 300

// tailBytes is how much of the transcript's end is read: enough for some prompts of conversation to scroll
// back through (tool output fills most of it). 4 MB of the largest transcript reads in about 12 ms, only when
// the file changed.
const tailBytes = 4 << 20

type entry struct {
	Type      string          `json:"type"`
	Subtype   string          `json:"subtype"`
	Content   json.RawMessage `json:"content"` // system entries: plain text
	Timestamp time.Time       `json:"timestamp"`
	IsMeta    bool            `json:"isMeta"`
	Effort    string          `json:"effort"`
	Message   struct {
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   struct {
			Input         int `json:"input_tokens"`
			CacheRead     int `json:"cache_read_input_tokens"`
			CacheCreation int `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

type block struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
}

type askInput struct {
	Questions []struct {
		Question    string `json:"question"`
		Header      string `json:"header"`
		MultiSelect bool   `json:"multiSelect"`
		Options     []struct {
			Label       string `json:"label"`
			Description string `json:"description"`
		} `json:"options"`
	} `json:"questions"`
}

func readLast(path, cwd string) Last {
	var l Last
	data := readEnd(path, tailBytes, nil)
	var lastText string
	var chat []Turn
	var openAsk *askInput
	openID := ""
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		if len(line) == 0 || (!bytes.Contains(line, []byte(`"assistant"`)) && !bytes.Contains(line, []byte(`"user"`)) &&
			!bytes.Contains(line, []byte(`"away_summary"`))) {
			continue
		}
		var e entry
		if json.Unmarshal(line, &e) != nil {
			continue
		}
		if e.Type == "system" && e.Subtype == "away_summary" {
			var c string
			if json.Unmarshal(e.Content, &c) == nil && strings.TrimSpace(c) != "" {
				l.Recap, l.RecapAt = recapText(c), e.Timestamp
			}
			continue
		}
		if e.Type != "assistant" && e.Type != "user" {
			continue
		}
		if e.Type == "assistant" && e.Message.Model != "" && e.Message.Model != "<synthetic>" {
			l.Model, l.Effort = e.Message.Model, e.Effort
			if u := e.Message.Usage; u.Input+u.CacheRead+u.CacheCreation > 0 {
				l.Ctx = u.Input + u.CacheRead + u.CacheCreation
			}
		}
		var blocks []block
		if json.Unmarshal(e.Message.Content, &blocks) != nil {
			var p string // a plain-string user prompt
			if e.Type == "user" && !e.IsMeta && json.Unmarshal(e.Message.Content, &p) == nil {
				if t := promptText(p); t != "" {
					chat = append(chat, Turn{User: true, Text: t, At: e.Timestamp})
				}
			}
			continue
		}
		for _, b := range blocks {
			switch {
			case e.Type == "assistant" && b.Type == "text" && strings.TrimSpace(b.Text) != "":
				lastText = b.Text
				chat = append(chat, Turn{Text: strings.TrimSpace(b.Text), At: e.Timestamp})
			case e.Type == "user" && !e.IsMeta && b.Type == "text":
				if t := promptText(b.Text); t != "" {
					chat = append(chat, Turn{User: true, Text: t, At: e.Timestamp})
				}
			case e.Type == "assistant" && b.Type == "tool_use" && b.Name == "AskUserQuestion":
				var in askInput
				if json.Unmarshal(b.Input, &in) == nil {
					openAsk, openID = &in, b.ID
				}
			case e.Type == "user" && b.Type == "tool_result" && b.ToolUseID == openID:
				openAsk, openID = nil, ""
			}
		}
	}
	l.Text = strings.TrimSpace(lastText)
	if len(chat) > maxTurns {
		chat = chat[len(chat)-maxTurns:]
	}
	l.Chat = chat
	if openAsk != nil && len(openAsk.Questions) > 0 {
		q := openAsk.Questions[0]
		l.Question = q.Question
		for _, o := range q.Options {
			l.Options = append(l.Options, o.Label)
		}
		l.Menu = true
		l.AskID = openID
		for _, q := range openAsk.Questions {
			aq := AskQuestion{Header: strings.TrimSpace(q.Header), Text: strings.TrimSpace(q.Question), Multi: q.MultiSelect}
			for _, o := range q.Options {
				aq.Options = append(aq.Options, newAskOption(o.Label, o.Description))
			}
			l.Ask = append(l.Ask, aq)
		}
	} else {
		l.Options = numbered(l.Text)
	}
	l.Files = mentionedFiles(l.Text, cwd)
	l.Mentions = recentMentions(chat, cwd)
	return l
}

// mentionTurns: how many of the agent's latest messages the FL view takes its files from.
const mentionTurns = 40

// recentMentions: the files the agent's latest messages name, each dated by its message (a message's later
// files a millisecond later, so they keep their order).
func recentMentions(chat []Turn, cwd string) []fileMention {
	var out []fileMention
	n := 0
	for i := len(chat) - 1; i >= 0 && n < mentionTurns; i-- {
		t := chat[i]
		if t.User || t.At.IsZero() {
			continue
		}
		n++
		for j, f := range mentionedFiles(t.Text, cwd) {
			out = append(out, fileMention{Path: f, At: t.At.Add(time.Duration(j) * time.Millisecond)})
		}
	}
	return out
}

var (
	machineRe = regexp.MustCompile(`(?s)<(system-reminder|local-command-stdout|local-command-stderr|bash-stdout|bash-stderr|task-notification|command-message)>.*?</(?:system-reminder|local-command-stdout|local-command-stderr|bash-stdout|bash-stderr|task-notification|command-message)>`)
	pastedRe  = regexp.MustCompile(`</?pasted_content[^>]*>`)
	cmdNameRe = regexp.MustCompile(`(?s)<command-name>(.*?)</command-name>`)
	cmdArgsRe = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
	bashInRe  = regexp.MustCompile(`(?s)<bash-input>(.*?)</bash-input>`)
)

// promptText is what the owner typed, ” for user entries that are machinery (command output, system reminders,
// task notifications, Claude Code's "Caveat:" note). A paste shows as its text, a slash command as "/name args"
// and a ! command as "! cmd".
func promptText(t string) string {
	t = strings.TrimSpace(t)
	if strings.HasPrefix(t, "Caveat:") {
		return ""
	}
	if m := cmdNameRe.FindStringSubmatch(t); m != nil {
		cmd := strings.TrimSpace(m[1])
		if a := cmdArgsRe.FindStringSubmatch(t); a != nil && strings.TrimSpace(a[1]) != "" {
			cmd += " " + strings.TrimSpace(a[1])
		}
		return cmd
	}
	if m := bashInRe.FindStringSubmatch(t); m != nil {
		return "! " + strings.TrimSpace(m[1])
	}
	t = strings.TrimSpace(pastedRe.ReplaceAllString(machineRe.ReplaceAllString(t, ""), ""))
	if strings.HasPrefix(t, "<") { // any other tag-led entry is machinery too
		return ""
	}
	return t
}

// recapText drops Claude Code's "(disable recaps in /config)" hint from the end of a recap.
func recapText(c string) string {
	c = strings.TrimSpace(c)
	if i := strings.LastIndex(c, "(disable recaps"); i > 0 && strings.HasSuffix(c, ")") {
		c = strings.TrimSpace(c[:i])
	}
	return c
}

var numRe = regexp.MustCompile(`^\s*(?:[-*]\s+)?\**(\d)[.)]\**\s+(.+)$`)

// numbered returns the last "1. ... 2. ..." list in the last 30 lines of the message: items must count up
// from 1 without gaps (continuation lines and blank lines between items are fine). nil when there's none.
func numbered(text string) []string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) > 12 { // options are what the message ends with, not a numbered list in its middle
		lines = lines[len(lines)-12:]
	}
	var cur, last []string
	for _, ln := range lines {
		m := numRe.FindStringSubmatch(ln)
		if m == nil {
			continue
		}
		n := int(m[1][0] - '0')
		item := strings.TrimSpace(plain(m[2]))
		if width(item) > 90 { // a paragraph, not an option
			cur = nil
			continue
		}
		switch {
		case n == 1:
			cur = []string{item}
		case n == len(cur)+1:
			cur = append(cur, item)
		default:
			cur = nil
		}
		if len(cur) >= 2 {
			last = append([]string(nil), cur...)
		}
	}
	return last
}

var pathRe = regexp.MustCompile("(?:`([^`\\s]+)`)|((?:~|/Users|\\.{1,2})?/?[A-Za-z0-9_.@-]+(?:/[A-Za-z0-9_.@-]+)+/?)")

// mentionedFiles: paths in the text that exist, newest mention last, de-duplicated, at most 9.
func mentionedFiles(text, cwd string) []string {
	home := os.Getenv("HOME")
	seen := map[string]bool{}
	var out []string
	for _, m := range pathRe.FindAllStringSubmatch(text, -1) {
		p := m[1]
		if p == "" {
			p = m[2]
		}
		p = strings.TrimRight(p, ".,:;)")
		if i := strings.LastIndex(p, ":"); i > 0 { // file.go:42
			p = p[:i]
		}
		if (!strings.Contains(p, "/") && !strings.Contains(p, ".")) || strings.Trim(p, "/.") == "" {
			continue // a lone "/" or "." is no file
		}
		switch {
		case strings.HasPrefix(p, "~/"):
			p = filepath.Join(home, p[2:])
		case !filepath.IsAbs(p):
			p = filepath.Join(cwd, p)
		}
		p = filepath.Clean(p)
		if seen[p] || p == cwd || p == home {
			continue
		}
		if _, err := os.Stat(p); err != nil {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	if len(out) > 9 {
		out = out[len(out)-9:]
	}
	return out
}
