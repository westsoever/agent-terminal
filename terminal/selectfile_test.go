package main

import (
	"fmt"
	"os"
	"testing"
	"time"
)

// cl writes "<job> <unix time>" to the select file: the tick selects that background session once it is listed and
// deletes the file; an entry older than 30 s, or one it can't read, is deleted without selecting anything (D73).
func TestSelectFile(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	if err := os.MkdirAll(agentHome()+"/terminal", 0o700); err != nil {
		t.Fatal(err)
	}
	write := func(s string) {
		if err := os.WriteFile(selectPath(), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	m := newModel()
	m.agents = append(fleet(), Agent{SID: "full-sid", Name: "hlp", Cwd: "/tmp", Bg: true, Job: "1a2b3c4d", State: "idle"})
	m.selSID = "a"

	// not listed yet: nothing changes and the file waits for the next tick
	write(fmt.Sprintf("9f9f9f9f %d\n", time.Now().Unix()))
	m.selectFile()
	if _, err := os.Stat(selectPath()); err != nil || m.selSID != "a" {
		t.Fatalf("unlisted job: file %v, selected %q", err, m.selSID)
	}

	write(fmt.Sprintf("1a2b3c4d %d\n", time.Now().Unix()))
	m.selectFile()
	if m.selSID != "full-sid" {
		t.Errorf("selected %q, want full-sid", m.selSID)
	}
	if _, err := os.Stat(selectPath()); !os.IsNotExist(err) {
		t.Errorf("the file is still there: %v", err)
	}

	for _, s := range []string{fmt.Sprintf("1a2b3c4d %d\n", time.Now().Add(-31*time.Second).Unix()), "garbage\n"} {
		m.selSID = "a"
		write(s)
		m.selectFile()
		if m.selSID != "a" {
			t.Errorf("%q selected %q", s, m.selSID)
		}
		if _, err := os.Stat(selectPath()); !os.IsNotExist(err) {
			t.Errorf("%q: the file is still there: %v", s, err)
		}
	}

	m.selectFile() // no file: nothing happens
	if m.selSID != "a" {
		t.Errorf("no file selected %q", m.selSID)
	}
}
