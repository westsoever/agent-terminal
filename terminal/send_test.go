package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// A Ghostty terminal in the tabs list is marked ghostty, with no window or tab.
func TestParseTabs(t *testing.T) {
	m := parseTabs("ttys001 395 2\nttys010 0 0 ghostty\nerror: x\n")
	if m["ttys001"] != (tabPos{395, 2, false}) || m["ttys010"] != (tabPos{0, 0, true}) || len(m) != 2 {
		t.Errorf("tabs = %v", m)
	}
}

// A hung command ends at its limit, also when a child it left behind keeps the output pipe open.
func TestRunForTimeout(t *testing.T) {
	start := time.Now()
	_, err := runFor(100*time.Millisecond, false, "sh", "-c", "sleep 10 & wait")
	if err == nil || !strings.HasPrefix(err.Error(), "timeout") {
		t.Errorf("err = %v", err)
	}
	if d := time.Since(start); d > 4*time.Second {
		t.Errorf("took %s", d)
	}
	if out, err := runFor(5*time.Second, true, "sh", "-c", "echo hi >&2"); err != nil || strings.TrimSpace(string(out)) != "hi" {
		t.Errorf("combined = %q %v", out, err)
	}
}

// An old send.js is replaced whole, through a temp file that does not stay behind.
func TestSendScript(t *testing.T) {
	t.Setenv("AGENT_HOME", t.TempDir())
	sendOnce = sync.Once{}
	t.Cleanup(func() { sendOnce = sync.Once{} })
	p := filepath.Join(agentHome(), "terminal", "send.js")
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, []byte("old"), 0o644)
	if got := sendScript(); got != p {
		t.Fatalf("path = %q", got)
	}
	if b, _ := os.ReadFile(p); string(b) != string(sendJS) {
		t.Error("send.js not replaced")
	}
	if _, err := os.Stat(p + ".tmp"); err == nil {
		t.Error("temp file left")
	}
}
