package main

// The AI tier of FIND: Claude picks the sessions that fit the words by meaning. It runs by itself when the names
// and the text have nothing, and on the s key.
//
// It must leave nothing behind. The call is `claude -p` in an empty folder of its own, with
//   - --safe-mode: no hooks (the owner's hooks register a session in ~/.agent/sessions, send a notification and
//     check the Stop), no CLAUDE.md, plugins, skills or MCP servers;
//   - --no-session-persistence: no transcript, so the call can't show up in a search or be resumed;
//   - --tools "": it can read and write nothing.
//
// Claude Code still lists the call as an interactive session while it runs (entrypoint sdk-cli, a file in
// ~/.claude/sessions and a row in `claude agents`); loadAgents leaves it out (hidden in snapshot.go), so it
// never shows on the desk. It is gone when the call ends.
//
// It also sets KACHING_LEARNER=1, the marker Kaching's own hooks read as "a model call, no session" (so they stay
// out even if --safe-mode did not exist), and CLAUDE_MEM_INTERNAL=1 (claude-mem does not observe it). --bare is
// no choice: it wants an API key. The prompt is an index of the latest sessions, at most aiPromptCap bytes.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

const (
	aiSessions  = 120      // the latest sessions in the index
	aiPromptCap = 60 << 10 // bytes of the prompt
	aiField     = 200      // characters of a first prompt and of a last agent message in the index
	aiMax       = 10       // sessions kept from the answer
	aiHead      = 1 << 20  // the start of a transcript can be long hook output before the first prompt
	aiTail      = 512 << 10
	aiTailMax   = 4 << 20
)

// aiModel: Haiku is small, and the owner's Claude usage pays for every search.
var aiModel = "haiku"

// aiTimeout is how long Claude has to answer; a variable so a test can shorten it.
var aiTimeout = 120 * time.Second

// aiBin: the claude to run. KACHING_CLAUDE_BIN overrides it (the learner's variable; the tests use a fake).
func aiBin() string {
	if p := os.Getenv("KACHING_CLAUDE_BIN"); p != "" {
		return p
	}
	return claudeBin()
}

// aiEntry is one session of the index.
type aiEntry struct {
	ref                    sessionRef
	name, cwd, first, last string
}

// buildAIIndex: the latest aiSessions sessions (newest first) with what tells them apart: name, folder, date,
// the first prompt and the last agent message. The folder and name of a live agent come from the desk.
func buildAIIndex(sessions []sessionRef, agents []Agent) []aiEntry {
	n := min(len(sessions), aiSessions)
	out := make([]aiEntry, n)
	byID := map[string]Agent{}
	for _, a := range agents {
		byID[a.SID] = a
	}
	var next atomic.Int64
	var wg sync.WaitGroup
	for w := 0; w < workerCount(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1) - 1)
				if i >= n {
					return
				}
				ref := sessions[i]
				e := aiEntry{ref: ref}
				head, _ := readHeadN(ref.Path, aiHead)
				e.cwd, e.first = cwdIn(head), firstPrompt(head)
				tail := readEnd(ref.Path, aiTail, nil)
				if e.last = lastAgentText(tail); e.last == "" { // a long run of tool calls: look further back
					e.last = lastAgentText(readEnd(ref.Path, aiTailMax, nil))
				}
				e.name = withSidecar(titlesIn(tail), ref.Path).display()
				if a, ok := byID[ref.ID]; ok {
					e.name, e.cwd = a.Name, a.Cwd
				}
				out[i] = e
			}
		}()
	}
	wg.Wait()
	return out
}

// clip: the text on one line, at most n characters.
func clip(t string, n int) string {
	t = strings.Join(strings.Fields(t), " ")
	if utf8.RuneCountInString(t) <= n {
		return t
	}
	return string([]rune(t)[:n-1]) + "…"
}

// aiID is how the index names a session: "s" and the first 8 characters of its id. The letter keeps an id that is
// all digits from being a number in the answer.
func aiID(id string) string { return "s" + id[:min(8, len(id))] }

func (e aiEntry) line() string {
	name := e.name
	if name == "" {
		name = "(no name)"
	}
	q := func(t string) string { return `"` + strings.ReplaceAll(clip(t, aiField), `"`, "'") + `"` }
	return fmt.Sprintf("[%s] %s | %s | %s | first: %s | last: %s\n", aiID(e.ref.ID), clip(name, 60), tildify(e.cwd),
		e.ref.Mtime.Format("2006-01-02"), q(e.first), q(e.last))
}

// aiPrompt: the question, with as many index lines as fit in aiPromptCap bytes (the oldest sessions give way).
// It returns the entries it used.
func aiPrompt(query string, idx []aiEntry) (string, []aiEntry) {
	head := "Below are the Claude Code sessions of one person, newest first. Each line is: [id] name | folder | date | " +
		"first: their first message | last: the agent's last message.\n\n"
	tail := "\nFind the sessions that best match this search, by meaning and not only by the words: " + query +
		"\n\nAnswer with JSON only: no other text and no code fence. It is an array of at most 8 objects, best match " +
		`first, like [{"id":"<an id from the list>","why":"<one short sentence>"}]. Use the ids exactly as in the list. ` +
		"Answer [] when no session fits.\n"
	room := aiPromptCap - len(head) - len(tail)
	var b strings.Builder
	b.WriteString(head)
	used := 0
	for _, e := range idx {
		l := e.line()
		if len(l) > room {
			break
		}
		b.WriteString(l)
		room -= len(l)
		used++
	}
	b.WriteString(tail)
	return b.String(), idx[:used]
}

const aiSystem = "You are a search function inside a terminal tool. You answer with JSON only."

// sessionVars are what a Claude Code session puts in the environment of its children: a model call that
// inherited them could take itself for part of that session.
var sessionVars = []string{"CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_EXECPATH",
	"CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID", "AI_AGENT"}

// aiEnv: env without the session variables, with the markers that say "a model call, no session".
func aiEnv(env []string) []string {
	var out []string
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		drop := k == "KACHING_LEARNER" || k == "CLAUDE_MEM_INTERNAL"
		for _, v := range sessionVars {
			drop = drop || k == v
		}
		if !drop {
			out = append(out, kv)
		}
	}
	return append(out, "KACHING_LEARNER=1", "CLAUDE_MEM_INTERNAL=1")
}

// aiDir is the folder the call runs in: empty, so no project config is found there.
func aiDir() string {
	d := filepath.Join(os.TempDir(), "kaching-find")
	_ = os.MkdirAll(d, 0o700)
	return d
}

// runClaude gives the prompt to claude on its standard input and returns what it prints.
func runClaude(ctx context.Context, prompt string) (string, error) {
	cmd := exec.CommandContext(ctx, aiBin(), "-p", "--model", aiModel, "--safe-mode", "--no-session-persistence",
		"--tools", "", "--output-format", "json", "--disable-slash-commands", "--strict-mcp-config", "--system-prompt", aiSystem)
	cmd.Dir = aiDir()
	cmd.Env = aiEnv(os.Environ())
	cmd.Stdin = strings.NewReader(prompt)
	cmd.WaitDelay = 2 * time.Second // a child that outlives the kill must not keep the call waiting
	out, err := cmd.Output()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return "", fmt.Errorf("Claude did not answer in %d s", int(aiTimeout.Seconds()))
		}
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok {
			if e := strings.TrimSpace(string(ee.Stderr)); e != "" {
				msg = firstLine(e)
			} else if o := strings.TrimSpace(string(out)); o != "" {
				msg = firstLine(o)
			}
		}
		return "", errors.New(clip(msg, 160))
	}
	return string(out), nil
}

// searchAI asks Claude which of the latest sessions fit the query.
func searchAI(ctx context.Context, query string, agents []Agent, sessions []sessionRef) ([]findHit, error) {
	idx := buildAIIndex(sessions, agents)
	if len(idx) == 0 {
		return nil, errors.New("no sessions to search")
	}
	prompt, idx := aiPrompt(query, idx)
	ctx, cancel := context.WithTimeout(ctx, aiTimeout)
	defer cancel()
	out, err := runClaude(ctx, prompt)
	if err != nil {
		return nil, err
	}
	return parseAIAnswer(out, idx)
}

type aiItem struct {
	ID  flexString `json:"id"`
	Why string     `json:"why"`
}

// flexString reads a JSON string or number as text.
type flexString string

func (f *flexString) UnmarshalJSON(b []byte) error {
	var s string
	if json.Unmarshal(b, &s) == nil {
		*f = flexString(s)
	} else {
		*f = flexString(strings.TrimSpace(string(b)))
	}
	return nil
}

// parseAIAnswer reads Claude's answer: the --output-format json envelope (or plain text), in it a JSON array
// that may sit in a code fence or have words around it. Ids are matched to the index by their first characters.
func parseAIAnswer(out string, idx []aiEntry) ([]findHit, error) {
	text := strings.TrimSpace(out)
	var env struct {
		Result  *string `json:"result"`
		IsError bool    `json:"is_error"`
	}
	if json.Unmarshal([]byte(text), &env) == nil && env.Result != nil {
		if env.IsError {
			return nil, errors.New(clip(*env.Result, 160))
		}
		text = *env.Result
	}
	items, ok := aiItems(text)
	if !ok {
		return nil, errors.New("Claude's answer was not JSON: " + clip(text, 80))
	}
	var hits []findHit
	seen := map[string]bool{}
	for _, it := range items {
		id := strings.ToLower(strings.Trim(string(it.ID), " []\"'"))
		id = strings.TrimPrefix(id, "s")
		if len(id) < 6 {
			continue
		}
		for _, e := range idx {
			if strings.HasPrefix(e.ref.ID, id) && !seen[e.ref.ID] {
				seen[e.ref.ID] = true
				hits = append(hits, findHit{ID: e.ref.ID, Name: e.name, Cwd: e.cwd, Path: e.ref.Path, At: e.ref.Mtime,
					Tier: tierAI, Why: clip(clean(it.Why), 240)})
				break
			}
		}
		if len(hits) >= aiMax {
			break
		}
	}
	return hits, nil
}

// aiItems finds the answer's objects: the whole text as an array, else what is between its first [ and last ] (a code
// fence or a sentence around it), else every object {...} in it.
func aiItems(text string) ([]aiItem, bool) {
	var items []aiItem
	if json.Unmarshal([]byte(text), &items) == nil {
		return items, true
	}
	if i, j := strings.Index(text, "["), strings.LastIndex(text, "]"); i >= 0 && j > i {
		if json.Unmarshal([]byte(text[i:j+1]), &items) == nil {
			return items, true
		}
	}
	items = nil
	for i := 0; i < len(text); i++ {
		if text[i] != '{' {
			continue
		}
		dec := json.NewDecoder(strings.NewReader(text[i:]))
		var it aiItem
		if dec.Decode(&it) == nil && it.ID != "" {
			items = append(items, it)
			i += int(dec.InputOffset()) - 1
		}
	}
	return items, len(items) > 0 || strings.Contains(text, "[]")
}
