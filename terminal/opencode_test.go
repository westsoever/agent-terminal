package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestReadOpencodeLast: the conversation of an opencode session comes from its database, oldest first, the
// user's prompts and the assistant's texts (tool parts and idle markers left out).
func TestReadOpencodeLast(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	db := opencodeDB()
	if err := os.MkdirAll(filepath.Dir(db), 0o755); err != nil {
		t.Fatal(err)
	}
	sql := `create table session_message (id text, session_id text, type text, seq integer, time_created integer, data text);
insert into session_message values
 ('1','ses_A1','user',1,1000,'{"text":"hello"}'),
 ('2','ses_A1','assistant',2,2000,'{"content":[{"type":"tool","text":"x"},{"type":"text","text":"hi there"}],"model":{"id":"claude-sonnet-5-5","variant":"high"}}'),
 ('3','ses_A1','idle',3,3000,'{}'),
 ('4','ses_B','user',1,1000,'{"text":"other session"}');`
	if out, err := exec.Command("sqlite3", db, sql).CombinedOutput(); err != nil {
		t.Skip("no sqlite3:", err, string(out))
	}
	l := readOpencodeLast("ses_A1")
	if len(l.Chat) != 2 || !l.Chat[0].User || l.Chat[0].Text != "hello" || l.Chat[1].Text != "hi there" {
		t.Fatalf("chat = %+v", l.Chat)
	}
	if l.Text != "hi there" || l.Model != "claude-sonnet-5-5" || l.Effort != "high" {
		t.Fatalf("last = %q %q %q", l.Text, l.Model, l.Effort)
	}
	if l := readOpencodeLast("ses_A1' or 1=1 --"); len(l.Chat) != 0 {
		t.Fatalf("an id with a quote must not be queried: %+v", l.Chat)
	}
}
