package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Last is what the desk shows for the selected agent, read from the tail of its transcript.
type Last struct {
	Text     string    // the agent's last message
	Question string    // an open AskUserQuestion, '' when none
	Options  []string  // numbered options: from the open question, else "1. ..." lines in the last message
	Menu     bool      // true: the options are a menu in Claude Code (answer with a key press, no Enter)
	Files    []string  // paths the last message mentions that exist, absolute
	Recap    string    // Claude Code's latest recap (the "while you were away" summary), '' when none
	RecapAt  time.Time // when Claude Code wrote it
	Chat     []Turn    // the conversation in the transcript tail, oldest first, at most maxTurns
}

// Turn is one message of the conversation: the owner's prompt (User) or a text the agent wrote.
type Turn struct {
	User bool
	Text string
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
	Message   struct {
		Content json.RawMessage `json:"content"`
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
		Question string `json:"question"`
		Options  []struct {
			Label string `json:"label"`
		} `json:"options"`
	} `json:"questions"`
}

func readLast(path, cwd string) Last {
	var l Last
	f, err := os.Open(path)
	if err != nil {
		return l
	}
	defer f.Close()
	st, _ := f.Stat()
	off := int64(0)
	if st != nil && st.Size() > tailBytes {
		off = st.Size() - tailBytes
	}
	_, _ = f.Seek(off, io.SeekStart)
	data, _ := io.ReadAll(f)
	if off > 0 { // drop the partial first line
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			data = data[i+1:]
		}
	}
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
		var blocks []block
		if json.Unmarshal(e.Message.Content, &blocks) != nil {
			var p string // a plain-string user prompt
			if e.Type == "user" && !e.IsMeta && json.Unmarshal(e.Message.Content, &p) == nil {
				if t := promptText(p); t != "" {
					chat = append(chat, Turn{User: true, Text: t})
				}
			}
			continue
		}
		for _, b := range blocks {
			switch {
			case e.Type == "assistant" && b.Type == "text" && strings.TrimSpace(b.Text) != "":
				lastText = b.Text
				chat = append(chat, Turn{Text: strings.TrimSpace(b.Text)})
			case e.Type == "user" && !e.IsMeta && b.Type == "text":
				if t := promptText(b.Text); t != "" {
					chat = append(chat, Turn{User: true, Text: t})
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
	} else {
		l.Options = numbered(l.Text)
	}
	l.Files = mentionedFiles(l.Text, cwd)
	return l
}

// promptText is what the owner typed, ” for user entries that are machinery: slash-command records, command
// output, system reminders and task notifications all start with a tag, and Claude Code's "Caveat:" note.
func promptText(t string) string {
	t = strings.TrimSpace(t)
	if strings.HasPrefix(t, "<") || strings.HasPrefix(t, "Caveat:") {
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
