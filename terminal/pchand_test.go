package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func TestPcIssueRepo(t *testing.T) {
	for in, want := range map[string]string{
		"lane: triage\nrepo: cos\nnote: 04-Resources/x.md\n\nPropose a lane": "cos",
		"repo: soii\n":                "soii",
		"No head here.\nrepo: cos":    "", // not a "key: value" head
		"lane: triage\n\nrepo: cos":   "", // after the blank line
		"":                            "",
		"repo:   miso  \nlane: build": "miso",
	} {
		if got := pcIssueRepo(in); got != want {
			t.Errorf("pcIssueRepo(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPcIssueDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, "bbq", "soii"), 0o755)
	os.MkdirAll(filepath.Join(home, "cos"), 0o755)
	for repo, want := range map[string]string{
		"soii": filepath.Join(home, "bbq", "soii"), "cos": filepath.Join(home, "cos"),
		"nowhere": home, "../etc": home, "a/b": home, "": home,
	} {
		d := PCDetail{Description: "repo: " + repo + "\n\nbody"}
		if repo == "" {
			d.Description = "just text"
		}
		if got := pcIssueDir(d); got != want {
			t.Errorf("repo %q: dir %q, want %q", repo, got, want)
		}
	}
}

func TestPcBriefing(t *testing.T) {
	at := time.Date(2026, 10, 17, 19, 30, 0, 0, time.UTC)
	d := PCDetail{ID: "uuid-1", Description: "repo: cos\n\nTriage the notes.",
		Comments: []PCComment{{Author: "Researcher", Body: "I can't set the status: my tools are restricted.", At: at},
			{Author: "you", Board: true, Body: "ok", At: at.Add(time.Hour)}},
		Ask: &PCAsk{Title: "Review COS-13", Prompt: "Review the PR", Details: "https://github.com/o/r/pull/12"}}
	it := PCItem{Ref: "COS-13", Title: "Triage notes", Status: "in_review", Agent: "Researcher", Cost: "$0.41", URL: "http://localhost:3100/COS/issues/COS-13", Detail: "Needs a status"}
	b := pcBriefing(it, d, "/Users/x/cos")
	for _, want := range []string{"# Paperclip issue COS-13: Triage notes", "in review · assigned to Researcher · spent $0.41", "Triage the notes.",
		"**Researcher**", "**me**", "restricted", "https://github.com/o/r/pull/12", "This is my decision. Do not answer it.",
		"curl -s http://localhost:3100/api/issues/uuid-1/comments", `"status":"in_review","comment":"From an external Claude session`,
		"Never set it to `done`", "Do not accept, reject or answer any request or approval"} {
		if !strings.Contains(b, want) {
			t.Errorf("briefing lacks %q:\n%s", want, b)
		}
	}
	d2 := d
	d2.Comments = append([]PCComment{{Author: "Researcher", Body: "PR: https://github.com/o/r/pull/12 and more", At: at}}, d.Comments...)
	if b2 := pcBriefing(it, d2, "/x"); strings.Count(b2, "https://github.com/o/r/pull/12") != 1 {
		t.Error("a request's details already in the thread are repeated")
	}
	if strings.Index(b, "**Researcher**") > strings.Index(b, "**me**") {
		t.Error("the thread is not oldest first")
	}
	// a long thread keeps the newest comments
	var many []PCComment
	for i := 0; i < 40; i++ {
		many = append(many, PCComment{Author: "A", Body: "comment number " + string(rune('A'+i%26)) + strings.Repeat("x", i), At: at.Add(time.Duration(i) * time.Minute)})
	}
	b = pcBriefing(it, PCDetail{ID: "u", Comments: many}, "/x")
	if !strings.Contains(b, "the last 15 of 40 comments") || strings.Count(b, "**A**") != 15 {
		t.Errorf("thread cut wrong: %d comments", strings.Count(b, "**A**"))
	}
}

func TestPcHandPrompt(t *testing.T) {
	it := PCItem{Ref: "COS-13", Title: "Triage notes"}
	p := pcHandPrompt(it, "/x/b.md", "")
	if !strings.Contains(p, "Take over Paperclip issue COS-13: Triage notes") || !strings.Contains(p, "/x/b.md") || !strings.Contains(p, pcHandDefault) {
		t.Errorf("default prompt: %q", p)
	}
	if p = pcHandPrompt(it, "/x/b.md", "  just check the PR  "); !strings.Contains(p, "just check the PR") || strings.Contains(p, pcHandDefault) {
		t.Errorf("own task: %q", p)
	}
}

func handModel(t *testing.T) (model, *[]string, *[]string) {
	t.Helper()
	srv, _ := fakeIssue(t, confirmation, nil)
	withBase(t, srv.URL)
	home := t.TempDir()
	t.Setenv("HOME", home)
	os.MkdirAll(filepath.Join(home, "cos"), 0o755)
	var texts, terms []string
	oldT, oldTerm := transmitFn, termStartFn
	transmitFn = func(a Agent, text string, keys []string) string { texts = append(texts, a.Name+"<-"+text); return "ok" }
	termStartFn = func(o nwOpts, dir, prompt string) error { terms = append(terms, o.Name+"|"+dir+"|"+prompt); return nil }
	t.Cleanup(func() { transmitFn, termStartFn = oldT, oldTerm })
	m := newModel()
	m.w, m.h = 160, 44
	m.view = vPaperclip
	m.agents = []Agent{{SID: "a1", Name: "miso", Cwd: "/tmp", InTerminal: true}, {SID: "a2", Name: "looker", Cwd: "/tmp"}}
	m.pc = PCState{Items: []PCItem{{ID: "i14", Ref: "COS-14", Status: "in_review", Title: "Clip with Defuddle", Needs: true}}}
	m.pcDet["i14"] = loadPCDetail("i14", nil)
	return m, &texts, &terms
}

// b opens the box for a new background agent, t for a Terminal session; the title says what enter does.
func TestPCHandKeys(t *testing.T) {
	m, _, _ := handModel(t)
	mm, _ := m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'b'}})
	m = mm.(model)
	if m.mode != mTyping || m.ed.target != "pcgo:i14@b" {
		t.Fatalf("b: mode %v target %q", m.mode, m.ed.target)
	}
	v := escRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "hand COS-14 to a new background agent") || !strings.Contains(v, "empty sends the default task") {
		t.Errorf("box title missing:\n%s", v)
	}
	m.mode = mKeys
	mm, _ = m.key(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'t'}})
	if m = mm.(model); m.ed.target != "pcgo:i14@t" {
		t.Fatalf("t: target %q", m.ed.target)
	}
	if v = escRe.ReplaceAllString(m.View(), ""); !strings.Contains(v, "to a new Terminal session") {
		t.Error("the Terminal title is missing")
	}
	// the footer and the panel say the keys
	m.mode = mKeys
	v = escRe.ReplaceAllString(m.View(), "")
	if !strings.Contains(v, "b agent") || !strings.Contains(v, "t Terminal") {
		t.Errorf("hints missing:\n%s", v)
	}
}

// Enter on an empty box sends the default task to a new Terminal session in the issue's folder, with a briefing file.
func TestPCHandTerminal(t *testing.T) {
	m, _, terms := handModel(t)
	m.pcDet["i14"] = PCDetail{ID: "i14", Ref: "COS-14", Title: "Clip", Description: "repo: cos\n\nMake /unbox clip pages.", At: time.Now()}
	m.mode = mTyping
	m.ed.open("pcgo:i14@t", "", 80)
	mm, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(model)
	if cmd == nil || m.mode != mKeys {
		t.Fatalf("an empty box did not send: mode %v", m.mode)
	}
	msg := cmd()
	if sm, ok := msg.(statusMsg); !ok || !strings.Contains(string(sm), "COS-14 is in a new Terminal session") {
		t.Fatalf("msg %#v", msg)
	}
	home := os.Getenv("HOME")
	if len(*terms) != 1 || !strings.HasPrefix((*terms)[0], "paperclip COS-14|"+filepath.Join(home, "cos")+"|Take over Paperclip issue COS-14") ||
		!strings.Contains((*terms)[0], pcHandDefault) {
		t.Fatalf("terminal start: %v", *terms)
	}
	files, _ := filepath.Glob(filepath.Join(handDir(), "COS-14-*.md"))
	if len(files) != 1 {
		t.Fatalf("briefing files: %v", files)
	}
	b, _ := os.ReadFile(files[0])
	if !strings.Contains(string(b), "Make /unbox clip pages.") || !strings.Contains((*terms)[0], files[0]) {
		t.Error("the briefing is not what the prompt points to")
	}
}

// @Name hands the issue to a running session, with the rest as the task; a bad name keeps the box and the text.
func TestPCHandRunningSession(t *testing.T) {
	m, texts, _ := handModel(t)
	m.mode = mTyping
	m.ed.open("pcgo:i14@b", "", 80)
	m.ed.ta.SetValue("@miso check the PR and merge it")
	mm, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(model)
	if cmd == nil {
		t.Fatalf("not sent: %q", m.status)
	}
	msg := cmd().(sentMsg)
	if msg.res != "ok" || msg.name != "miso" || len(*texts) != 1 || !strings.HasPrefix((*texts)[0], "miso<-Take over Paperclip issue COS-14") ||
		!strings.Contains((*texts)[0], "check the PR and merge it") || strings.Contains((*texts)[0], "@miso") {
		t.Fatalf("msg %+v texts %v", msg, *texts)
	}
	for _, c := range []struct{ text, err string }{{"@nobody hello", "no live session is named nobody"}, {"@looker hello", "look only"}} {
		m.mode = mTyping
		m.ed.open("pcgo:i14@b", "", 80)
		m.ed.ta.SetValue(c.text)
		mm, cmd = m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
		m = mm.(model)
		if cmd != nil || m.mode != mTyping || m.ed.ta.Value() != c.text || !m.statusErr || !strings.Contains(m.status, c.err) {
			t.Errorf("%q: cmd %v mode %v value %q status %q", c.text, cmd != nil, m.mode, m.ed.ta.Value(), m.status)
		}
	}
}

// A new background agent: claude --bg with the name, the options of /NW and the prompt after --.
func TestPCHandBackground(t *testing.T) {
	m, _, _ := handModel(t)
	bin := t.TempDir()
	log := filepath.Join(bin, "args.txt")
	os.WriteFile(filepath.Join(bin, "claude"), []byte("#!/bin/sh\nprintf '%s\\n' \"$@\" > "+log+"\necho 'backgrounded · cafe1234 · x'\n"), 0o755)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	m.cfg.NWModel, m.cfg.NWEffort, m.cfg.NWPerm = "sonnet", "", "plan"
	m.mode = mTyping
	m.ed.open("pcgo:i14@b", "", 80)
	m.ed.ta.SetValue("review only, change nothing")
	_, cmd := m.typingKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("not sent")
	}
	if msg, ok := cmd().(bgStartedMsg); !ok || msg.job != "cafe1234" {
		t.Fatalf("msg %#v", cmd())
	}
	b, _ := os.ReadFile(log)
	got := strings.Split(strings.TrimSpace(string(b)), "\n")
	if strings.Join(got[:8], " ") != "--bg -n paperclip COS-14 --model sonnet --permission-mode plan --" || !strings.Contains(strings.Join(got[8:], "\n"), "review only, change nothing") {
		t.Errorf("claude args: %q", got)
	}
}

// The shell line that opens a Terminal session: quoted so an apostrophe or a newline in the task can't break it, and the
// AppleScript that runs it compiles.
func TestTermCommand(t *testing.T) {
	o := nwOpts{Name: "paperclip COS-14", Model: "sonnet", Perm: "plan"}
	cmd := termCommand(o, "/Users/x/my dir", "Take over: it's \"hard\"\nline 2 $HOME `x`")
	for _, want := range []string{"cd '/Users/x/my dir' && ", "-n 'paperclip COS-14'", "--model 'sonnet'", "--permission-mode 'plan'",
		" -- 'Take over: it'\\''s \"hard\"\nline 2 $HOME `x`'"} {
		if !strings.Contains(cmd, want) {
			t.Errorf("command lacks %q:\n%s", want, cmd)
		}
	}
	if out, err := exec.Command("osacompile", "-e", termScript, "-o", filepath.Join(t.TempDir(), "t.scpt")).CombinedOutput(); err != nil {
		t.Errorf("the AppleScript does not compile: %v %s", err, out)
	}
}

// Live: a real background agent gets an issue handed over, reads the briefing file and answers from it. The issue is
// made up and the task forbids any API call. KACHING_LIVE_BG=1 runs it (haiku, the owner's Claude account).
func TestPCHandLive(t *testing.T) {
	if os.Getenv("KACHING_LIVE_BG") == "" {
		t.Skip("KACHING_LIVE_BG=1 runs it")
	}
	m := newModel()
	m.cfg.NWModel, m.cfg.NWPerm, m.cfg.NWEffort = "haiku", "", ""
	m.pc = PCState{Items: []PCItem{{ID: "fake-1", Ref: "COS-999", Status: "blocked", Title: "Handover probe", Agent: "Researcher"}}}
	m.pcDet["fake-1"] = PCDetail{ID: "fake-1", Ref: "COS-999", Title: "Handover probe", At: time.Now(),
		Description: "The secret word of this briefing is PINEAPPLE.", Comments: []PCComment{{Author: "Researcher", Body: "I am stuck: my permissions are restricted.", At: time.Now()}}}
	cmd, keep := m.pcHandSend("fake-1", "b", "Reply with just the secret word from the briefing. Do not call any API and do not change anything.")
	if keep || cmd == nil {
		t.Fatalf("not sent: %s", m.status)
	}
	msg, ok := cmd().(bgStartedMsg)
	if !ok {
		t.Fatalf("msg %#v", cmd())
	}
	defer exec.Command(claudeBin(), "rm", msg.job).Run()
	defer bgStop(msg.job)
	var tr string
	for i := 0; i < 90; i++ {
		time.Sleep(500 * time.Millisecond)
		for _, a := range loadAgents(map[string]tabPos{}, nil) {
			if a.Bg && a.Job == msg.job {
				tr = a.Transcript
			}
		}
		if tr != "" && strings.Contains(strings.ToUpper(readLast(tr, "/").Text), "PINEAPPLE") {
			return
		}
	}
	t.Fatalf("the agent never answered from the briefing: %q", readLast(tr, "/").Text)
}
