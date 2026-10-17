package main

// FIND: /FIND <words> looks for a session by its name and by what was said in it, in every session on this Mac
// (live and ended). Three tiers, one after the other:
//
//	names  live agents (name, folder, branch) and the titles of past sessions: the owner's /rename (a
//	       custom-title entry in the transcript, with the same name in <session>/custom-title.json and in an
//	       agent-name entry) or Claude Code's own title (ai-title).
//	text   every word, in one message of the owner's prompts or the agents' text replies, in every transcript
//	       under ~/.claude/projects (this file).
//	AI     a Claude call that reads a short index of the latest sessions (findai.go).
//
// The search code here has no UI in it; findui.go draws it and handles the keys.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"
)

// The tiers a hit was found in (a session found by more than one has more than one bit).
const (
	tierName uint8 = 1 << iota
	tierText
	tierAI
)

const (
	findMax      = 50  // results per tier
	snippetWidth = 220 // characters of a result's snippet (the view cuts it to the screen)
	snippetLead  = 40  // characters of it before the match
	titleTail    = 256 << 10
	headBytes    = 256 << 10
)

// findBudget is how long the text tier may run; what it found by then is shown, marked partial.
var findBudget = 3 * time.Second

// findWorkers: how many transcripts the text tier reads at once (0: one for each CPU, at most 8).
var findWorkers = 0

// readTranscript reads a whole transcript into buf (grown when too small); a variable so a test can slow it.
var readTranscript = readInto

// findHit is one session that matched.
type findHit struct {
	ID, Name, Cwd, Branch string
	Path                  string    // its transcript, '' when unknown
	At                    time.Time // the newest matching message; else its last activity
	Tier                  uint8
	Who                   string // text tier: who said the newest match, "you" or "agent"
	Snippet               string // text tier: a line around that match
	Count                 int    // text tier: how many messages match
	Why                   string // AI tier: why Claude picked it
}

// label is the session's name, else its short id.
func (h findHit) label() string {
	if h.Name != "" {
		return h.Name
	}
	return short(h.ID)
}

// sessionRef is a past or live session's transcript.
type sessionRef struct {
	ID, Path string
	Mtime    time.Time
}

func projectsDir() string { return filepath.Join(os.Getenv("HOME"), ".claude", "projects") }

// observerSuffix ends the folder of claude-mem's observer sessions: machinery, no conversation of the owner's.
const observerSuffix = "--claude-mem-observer-sessions"

// listSessions: every session transcript, newest first. The observer folder and sub-agent transcripts (in a
// <session>/subagents folder: the prompts there are the parent agent's, not the owner's) are left out.
func listSessions() []sessionRef {
	var out []sessionRef
	dirs, _ := os.ReadDir(projectsDir())
	for _, d := range dirs {
		if !d.IsDir() || strings.HasSuffix(d.Name(), observerSuffix) {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(projectsDir(), d.Name()))
		for _, f := range files {
			id, ok := strings.CutSuffix(f.Name(), ".jsonl")
			if !ok || f.IsDir() {
				continue
			}
			if info, err := f.Info(); err == nil && info.Mode().IsRegular() {
				out = append(out, sessionRef{id, filepath.Join(projectsDir(), d.Name(), f.Name()), info.ModTime()})
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Mtime.After(out[j].Mtime) })
	return out
}

// ---- query and matching

// fold lowers case rune by rune, so the folded text keeps its length in runes (snippets rely on that).
func fold(s string) string { return strings.Map(unicode.ToLower, s) }

// parseQuery: the words of the query, folded. "a quoted phrase" is one term. A term that repeats counts once.
func parseQuery(q string) []string {
	var terms []string
	add := func(t string) {
		t = fold(strings.Join(strings.Fields(t), " "))
		for _, x := range terms {
			if x == t {
				return
			}
		}
		if t != "" {
			terms = append(terms, t)
		}
	}
	for q = strings.TrimSpace(q); q != ""; q = strings.TrimSpace(q) {
		if q[0] == '"' {
			if j := strings.IndexByte(q[1:], '"'); j >= 0 {
				add(q[1 : 1+j])
				q = q[j+2:]
			} else {
				q = q[1:] // a quote that never closes is dropped
			}
			continue
		}
		w := q
		if i := strings.IndexAny(q, " \t"); i >= 0 {
			w, q = q[:i], q[i:]
		} else {
			q = ""
		}
		add(w)
	}
	return terms
}

// hasAll: the folded text has every term.
func hasAll(folded string, terms []string) bool {
	for _, t := range terms {
		if !strings.Contains(folded, t) {
			return false
		}
	}
	return len(terms) > 0
}

// rawKeys: parts of a term that a transcript's raw JSON has as they are: the runs of letters, digits and a few
// plain marks (at least 3 long). Other characters can be written another way: Claude Code writes "<" as the escape
// \u003c in some entries, and a non-ASCII letter changes case. A message that has the term has these parts.
func rawKeys(term string) [][]byte {
	var keys [][]byte
	run := func(from, to int) {
		if to-from >= 3 {
			keys = append(keys, []byte(term[from:to]))
		}
	}
	start := 0
	for i, r := range term {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || strings.ContainsRune("-_./@:#~ ", r)) {
			run(start, i)
			start = i + utf8.RuneLen(r)
		}
	}
	run(start, len(term))
	return keys
}

var lowerTab = func() (t [256]byte) {
	for i := range t {
		t[i] = byte(i)
		if i >= 'A' && i <= 'Z' {
			t[i] = byte(i) + 32
		}
	}
	return
}()

// lowerInto: src with ASCII capitals lowered (a copy in dst, which is grown when too small).
func lowerInto(dst, src []byte) []byte {
	if cap(dst) < len(src) {
		dst = make([]byte, len(src), len(src)+len(src)/8)
	}
	dst = dst[:len(src)]
	for i, c := range src {
		dst[i] = lowerTab[c]
	}
	return dst
}

// makeSnippet: a window of the text (spaces collapsed) with the match near its start, "…" where it is cut. The
// window is the place where most terms are in view; the first term decides a tie.
func makeSnippet(text string, terms []string, width int) string {
	txt := []rune(strings.Join(strings.Fields(text), " "))
	if len(txt) <= width {
		return string(txt)
	}
	low := []rune(fold(string(txt)))
	best, bestN := 0, -1
	for _, t := range terms {
		c := indexRunes(low, []rune(t), 0)
		if c < 0 {
			continue
		}
		start := max(0, c-snippetLead)
		n := 0
		for _, u := range terms {
			if i := indexRunes(low, []rune(u), start); i >= 0 && i < start+width {
				n++
			}
		}
		if n > bestN {
			best, bestN = start, n
		}
	}
	end := min(len(txt), best+width)
	best = max(0, end-width)
	out := string(txt[best:end])
	if best > 0 {
		out = "…" + out
	}
	if end < len(txt) {
		out += "…"
	}
	return out
}

// indexRunes: where sub first is in s at or after from, -1 when it isn't.
func indexRunes(s, sub []rune, from int) int {
	if len(sub) == 0 {
		return -1
	}
	for i := max(0, from); i+len(sub) <= len(s); i++ {
		if s[i] != sub[0] {
			continue
		}
		j := 1
		for j < len(sub) && s[i+j] == sub[j] {
			j++
		}
		if j == len(sub) {
			return i
		}
	}
	return -1
}

// ---- transcripts

type findEntry struct {
	Type             string    `json:"type"`
	IsMeta           bool      `json:"isMeta"`
	IsSidechain      bool      `json:"isSidechain"`
	IsCompactSummary bool      `json:"isCompactSummary"`
	Timestamp        time.Time `json:"timestamp"`
	Message          struct {
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

// candidateLine: a line that can hold a conversation message. The api-request lines carry the whole request,
// every message again, so they are left out; so is a user line that has only a tool result.
func candidateLine(line []byte) bool {
	if rest, ok := bytes.CutPrefix(line, []byte(`{"type":"`)); ok {
		return bytes.HasPrefix(rest, []byte(`user"`)) || bytes.HasPrefix(rest, []byte(`assistant"`))
	}
	if bytes.Contains(line, []byte(`"type":"tool_result"`)) && !bytes.Contains(line, []byte(`"type":"text"`)) {
		return false
	}
	return true
}

// entryTurns: what the owner typed (promptText: no command output, reminders or notifications) and the text
// blocks the agent wrote in one transcript line. Tool calls, tool results, meta entries, sub-agent entries,
// compact summaries and Claude Code's own error replies give nothing.
func entryTurns(line []byte) []Turn {
	var e findEntry
	if json.Unmarshal(line, &e) != nil || e.IsSidechain || e.IsCompactSummary || (e.Type != "user" && e.Type != "assistant") {
		return nil
	}
	user := e.Type == "user"
	if (user && e.IsMeta) || (!user && e.Message.Model == "<synthetic>") {
		return nil
	}
	turn := func(text string) (Turn, bool) {
		if user {
			text = promptText(text)
		} else {
			text = strings.TrimSpace(text)
		}
		return Turn{User: user, Text: text, At: e.Timestamp}, text != ""
	}
	var blocks []block
	if json.Unmarshal(e.Message.Content, &blocks) != nil {
		var p string // a plain-string user prompt
		if user && json.Unmarshal(e.Message.Content, &p) == nil {
			if t, ok := turn(p); ok {
				return []Turn{t}
			}
		}
		return nil
	}
	var out []Turn
	for _, b := range blocks {
		if b.Type != "text" {
			continue
		}
		if t, ok := turn(b.Text); ok {
			out = append(out, t)
		}
	}
	return out
}

// readInto reads the whole file into buf, grown when too small.
func readInto(path string, buf []byte) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return buf[:0], err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return buf[:0], err
	}
	n := int(st.Size())
	if cap(buf) < n {
		buf = make([]byte, n, n+n/8)
	}
	buf = buf[:n]
	got, err := io.ReadFull(f, buf)
	if err == io.ErrUnexpectedEOF { // the file shrank
		err = nil
	}
	return buf[:got], err
}

// readEnd reads at most n bytes from the end of the file into buf (grown when too small). The first line of a
// partial read is cut off.
func readEnd(path string, n int64, buf []byte) []byte {
	f, err := os.Open(path)
	if err != nil {
		return buf[:0]
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return buf[:0]
	}
	off := max(0, st.Size()-n)
	size := int(st.Size() - off)
	if cap(buf) < size {
		buf = make([]byte, size)
	}
	buf = buf[:size]
	got, _ := io.ReadFull(io.NewSectionReader(f, off, int64(size)), buf)
	buf = buf[:got]
	if off > 0 {
		if i := bytes.IndexByte(buf, '\n'); i >= 0 {
			buf = buf[i+1:]
		}
	}
	return buf
}

// titles are the names of a session in its transcript.
type titles struct{ Custom, Agent, AI string }

// display is the name Claude Code shows: the owner's /rename, else the agent name, else its own title.
func (t titles) display() string {
	for _, n := range []string{t.Custom, t.Agent, t.AI} {
		if n != "" {
			return n
		}
	}
	return ""
}

// all is every name of the session, for the names tier to search.
func (t titles) all() string { return t.Custom + " " + t.Agent + " " + t.AI }

// titlesIn reads the newest title entries of the text (the end of a transcript: Claude Code writes them again
// at every turn, so the end has the current ones). The marker "type":"..." can only be a key: inside a message
// its quotes are escaped.
func titlesIn(tail []byte) titles {
	last := func(typ, key string) string {
		i := bytes.LastIndex(tail, []byte(`"type":"`+typ+`"`))
		if i < 0 {
			return ""
		}
		start := bytes.LastIndexByte(tail[:i], '\n') + 1
		line := tail[start:]
		if j := bytes.IndexByte(line, '\n'); j >= 0 {
			line = line[:j]
		}
		var m map[string]any
		if json.Unmarshal(line, &m) != nil {
			return ""
		}
		v, _ := m[key].(string)
		return strings.TrimSpace(v)
	}
	return titles{last("custom-title", "customTitle"), last("agent-name", "agentName"), last("ai-title", "aiTitle")}
}

// readTitles: the names of the session whose transcript is path. Claude Code keeps the /rename name in a
// <session>/custom-title.json too; it is the answer when the end of the transcript has none.
func readTitles(path string, buf []byte) (titles, []byte) {
	buf = readEnd(path, titleTail, buf)
	return withSidecar(titlesIn(buf), path), buf
}

func withSidecar(t titles, path string) titles {
	if t.Custom == "" {
		if b, err := os.ReadFile(filepath.Join(strings.TrimSuffix(path, ".jsonl"), "custom-title.json")); err == nil {
			var c struct {
				CustomTitle string `json:"customTitle"`
			}
			if json.Unmarshal(b, &c) == nil {
				t.Custom = strings.TrimSpace(c.CustomTitle)
			}
		}
	}
	return t
}

// cwdIn: the folder the session started in: the first entry that has one (it is the folder claude --resume
// has to run in; a later cd changes the cwd of the entries after it).
func cwdIn(head []byte) string {
	for len(head) > 0 {
		line := head
		if i := bytes.IndexByte(head, '\n'); i >= 0 {
			line, head = head[:i], head[i+1:]
		} else {
			head = nil
		}
		if !bytes.Contains(line, []byte(`"cwd":"`)) {
			continue
		}
		var e struct {
			Cwd string `json:"cwd"`
		}
		if json.Unmarshal(line, &e) == nil && e.Cwd != "" {
			return e.Cwd
		}
	}
	return ""
}

// fillMeta completes a hit from Kaching's record of the session (~/.agent/sessions/<id>/meta): its folder and
// branch when the transcript gave none. (The meta name is the folder's name, not the session's.)
func fillMeta(h *findHit) {
	meta := readMeta(filepath.Join(agentHome(), "sessions", h.ID, "meta"))
	if h.Cwd == "" {
		h.Cwd = meta["cwd"]
	}
	if h.Branch == "" {
		h.Branch = meta["branch"]
	}
}

// ---- tier 1: names

// searchNames: the live agents whose name, folder or branch has every term, and the past sessions whose
// title has. Live agents come from the desk, so a live session is not listed twice.
func searchNames(ctx context.Context, terms []string, agents []Agent, sessions []sessionRef) []findHit {
	var out []findHit
	live := map[string]bool{}
	for _, a := range agents {
		live[a.SID] = true
		if hasAll(fold(a.Name+" "+a.Cwd+" "+a.Branch), terms) {
			out = append(out, findHit{ID: a.SID, Name: a.Name, Cwd: a.Cwd, Branch: a.Branch, Path: a.Transcript, At: a.Since, Tier: tierName})
		}
	}
	var mu sync.Mutex
	var next atomic.Int64
	var wg sync.WaitGroup
	for w := 0; w < workerCount(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var buf []byte
			for ctx.Err() == nil {
				i := int(next.Add(1) - 1)
				if i >= len(sessions) {
					return
				}
				ref := sessions[i]
				if live[ref.ID] {
					continue
				}
				var t titles
				t, buf = readTitles(ref.Path, buf)
				if !hasAll(fold(t.all()), terms) {
					continue
				}
				h := findHit{ID: ref.ID, Name: t.display(), Path: ref.Path, At: ref.Mtime, Tier: tierName}
				head, _ := readHead(ref.Path)
				h.Cwd = cwdIn(head)
				fillMeta(&h)
				mu.Lock()
				out = append(out, h)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	sortHits(out)
	if len(out) > findMax {
		out = out[:findMax]
	}
	return out
}

func readHead(path string) ([]byte, error) { return readHeadN(path, headBytes) }

// readHeadN reads at most n bytes from the start of the file.
func readHeadN(path string, n int) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if st, err := f.Stat(); err == nil {
		n = int(min(int64(n), st.Size()))
	}
	b := make([]byte, n)
	got, err := io.ReadFull(f, b)
	if err == io.ErrUnexpectedEOF || err == io.EOF {
		err = nil
	}
	return b[:got], err
}

func workerCount() int {
	if findWorkers > 0 {
		return findWorkers
	}
	return min(runtime.NumCPU(), 8)
}

// sortHits: newest first.
func sortHits(h []findHit) {
	sort.SliceStable(h, func(i, j int) bool { return h[i].At.After(h[j].At) })
}

// ---- tier 2: text

// textStats says how the text tier went.
type textStats struct {
	Files   int           // transcripts looked at
	Partial bool          // the time ran out before all were
	Took    time.Duration // how long it ran
}

// searchText looks for a message with every term in the transcripts, newest transcript first, in parallel. One hit
// for each session: its newest matching message. It stops at findMax sessions or when the budget is spent.
func searchText(ctx context.Context, terms []string, sessions []sessionRef) ([]findHit, textStats) {
	start := time.Now()
	ctx, cancel := context.WithTimeout(ctx, findBudget)
	defer cancel()
	st := scanTerms{terms: terms}
	for _, t := range terms {
		for _, k := range rawKeys(t) {
			st.keys = append(st.keys, k)
			if len(k) > len(st.key0) {
				st.key0 = k
			}
		}
	}
	res := make([]*findHit, len(sessions))
	var next, matched, looked atomic.Int64
	var aborted atomic.Bool
	var wg sync.WaitGroup
	for w := 0; w < workerCount(); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var sc scanner
			for matched.Load() < findMax {
				i := int(next.Add(1) - 1)
				if i >= len(sessions) {
					return
				}
				if ctx.Err() != nil {
					aborted.Store(true)
					return
				}
				h, cut := sc.scan(ctx, sessions[i], &st)
				looked.Add(1)
				if cut {
					aborted.Store(true)
				}
				if h != nil {
					res[i] = h
					matched.Add(1)
				}
			}
		}()
	}
	wg.Wait()
	var out []findHit
	for _, h := range res {
		if h != nil && len(out) < findMax {
			fillMeta(h)
			out = append(out, *h)
		}
	}
	sortHits(out)
	return out, textStats{Files: int(looked.Load()), Partial: aborted.Load(), Took: time.Since(start)}
}

// scanTerms is the query as the text tier searches it: the folded terms and, for those that can be searched in
// the raw JSON, their bytes. A transcript that lacks one of them has no matching message; a line is looked at
// (parsed) only when it has all of them.
type scanTerms struct {
	terms []string
	keys  [][]byte
	key0  []byte // the longest key: the search jumps from one line that has it to the next
}

// scanner is one worker's buffers: the transcript and its lowered copy.
type scanner struct{ data, lower []byte }

// scan reads one transcript and returns its newest matching message as a hit (nil when none). cut: the
// context ended before the transcript was read to its end.
func (sc *scanner) scan(ctx context.Context, ref sessionRef, st *scanTerms) (hit *findHit, cut bool) {
	data, err := readTranscript(ref.Path, sc.data)
	sc.data = data
	if err != nil {
		return nil, false
	}
	lower := lowerInto(sc.lower, data)
	sc.lower = lower
	for _, k := range st.keys {
		if !bytes.Contains(lower, k) {
			return nil, false
		}
	}
	h := findHit{ID: ref.ID, Path: ref.Path, At: ref.Mtime, Tier: tierText}
	visit := func(line []byte) {
		if !candidateLine(line) {
			return
		}
		for _, t := range entryTurns(line) {
			if !hasAll(fold(t.Text), st.terms) {
				continue
			}
			h.Count++
			h.Who, h.Snippet = "agent", makeSnippet(t.Text, st.terms, snippetWidth)
			if t.User {
				h.Who = "you"
			}
			if !t.At.IsZero() {
				h.At = t.At
			}
		}
	}
	lines := 0
	if st.key0 == nil { // no term to search for in the raw bytes: every line is a candidate
		for pos := 0; pos < len(data); {
			end := len(data)
			if j := bytes.IndexByte(data[pos:], '\n'); j >= 0 {
				end = pos + j
			}
			visit(data[pos:end])
			pos = end + 1
			if lines++; lines%256 == 0 && ctx.Err() != nil {
				cut = true
				break
			}
		}
	} else {
		for pos := 0; pos < len(data); {
			i := bytes.Index(lower[pos:], st.key0)
			if i < 0 {
				break
			}
			at := pos + i
			ls := bytes.LastIndexByte(lower[:at], '\n') + 1
			le := len(data)
			if j := bytes.IndexByte(lower[at:], '\n'); j >= 0 {
				le = at + j
			}
			pos = le + 1
			hasKeys := true
			for _, k := range st.keys {
				if !bytes.Contains(lower[ls:le], k) {
					hasKeys = false
					break
				}
			}
			if hasKeys {
				visit(data[ls:le])
			}
			if lines++; lines%64 == 0 && ctx.Err() != nil {
				cut = true
				break
			}
		}
	}
	if h.Count == 0 {
		return nil, cut
	}
	t := withSidecar(titlesIn(data[max(0, len(data)-titleTail):]), ref.Path)
	h.Name = t.display()
	h.Cwd = cwdIn(data[:min(len(data), headBytes)])
	return &h, cut
}

// ---- excerpts

// excerptTurn is one message of an excerpt; Match: it has every term.
type excerptTurn struct {
	User, Match bool
	Text        string
	At          time.Time
}

// excerptMax is how many matching messages the panel shows (the newest ones), each with the message before and after.
const excerptMax = 4

// loadExcerpts: the newest matching messages of a transcript, each with a message of context on both sides;
// groups that touch are one. all is how many messages match.
func loadExcerpts(path string, terms []string) (groups [][]excerptTurn, all int, err error) {
	data, err := readInto(path, nil)
	if err != nil {
		return nil, 0, err
	}
	var turns []Turn
	for pos := 0; pos < len(data); {
		end := len(data)
		if j := bytes.IndexByte(data[pos:], '\n'); j >= 0 {
			end = pos + j
		}
		if line := data[pos:end]; candidateLine(line) && bytes.Contains(line, []byte(`"role":"`)) {
			turns = append(turns, entryTurns(line)...)
		}
		pos = end + 1
	}
	matched := make([]bool, len(turns))
	var hits []int
	for i, t := range turns {
		if matched[i] = hasAll(fold(t.Text), terms); matched[i] {
			hits = append(hits, i)
		}
	}
	all = len(hits)
	if len(hits) > excerptMax {
		hits = hits[len(hits)-excerptMax:]
	}
	type span struct{ from, to int }
	var spans []span
	for _, i := range hits {
		sp := span{max(0, i-1), min(len(turns)-1, i+1)}
		if n := len(spans); n > 0 && sp.from <= spans[n-1].to+1 {
			spans[n-1].to = sp.to
		} else {
			spans = append(spans, sp)
		}
	}
	for _, sp := range spans {
		var g []excerptTurn
		for k := sp.from; k <= sp.to; k++ {
			g = append(g, excerptTurn{turns[k].User, matched[k], turns[k].Text, turns[k].At})
		}
		groups = append(groups, g)
	}
	return groups, all, nil
}

// ---- the start and the end of a session, for the panel and the AI index

// firstPrompt: the first thing the owner typed, in the start of a transcript. A slash command ("/clear", "/model")
// says little, so the first prompt that is none is preferred.
func firstPrompt(head []byte) (first string) {
	for len(head) > 0 {
		line := head
		if i := bytes.IndexByte(head, '\n'); i >= 0 {
			line, head = head[:i], head[i+1:]
		} else {
			head = nil
		}
		if !bytes.Contains(line, []byte(`"role":"user"`)) || !candidateLine(line) {
			continue
		}
		for _, t := range entryTurns(line) {
			if !t.User {
				continue
			}
			if !strings.HasPrefix(t.Text, "/") {
				return t.Text
			}
			if first == "" {
				first = t.Text
			}
		}
	}
	return first
}

// lastAgentText: the last text the agent wrote, in the end of a transcript.
func lastAgentText(tail []byte) string {
	for end := len(tail); end > 0; {
		start := bytes.LastIndexByte(tail[:end], '\n') + 1
		line := tail[start:end]
		end = start - 1
		if !bytes.Contains(line, []byte(`"role":"assistant"`)) || !candidateLine(line) {
			continue
		}
		turns := entryTurns(line)
		for i := len(turns) - 1; i >= 0; i-- {
			if !turns[i].User {
				return turns[i].Text
			}
		}
	}
	return ""
}
