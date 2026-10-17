package main

import (
	"os"
	"testing"
)

// TestMain points AGENT_HOME at a scratch folder for every test, so no test reads or writes the owner's real
// ~/.agent (drafts, keys.toml, the open file). A test that sets its own with t.Setenv still wins.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "kaching-test-home")
	if err != nil {
		panic(err)
	}
	os.Setenv("AGENT_HOME", dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
