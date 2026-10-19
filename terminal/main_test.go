package main

import (
	"os"
	"testing"
)

// TestMain points AGENT_HOME at a scratch folder for every test, so no test reads or writes the owner's real
// ~/.agent (drafts, keys.toml, the open file). A test that sets its own with t.Setenv still wins.
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "agent-terminal-test-home")
	if err != nil {
		panic(err)
	}
	os.Setenv("AGENT_HOME", dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// An older variable name (KACHING_* from before D65, CHING_* from before D35) stands for the AGENT_TERMINAL_* one
// when that is unset, and KACHING_* wins over CHING_*.
func TestLegacyEnv(t *testing.T) {
	for _, k := range []string{"AGENT_TERMINAL_T1", "AGENT_TERMINAL_T2", "AGENT_TERMINAL_T3", "AGENT_TERMINAL_T4"} {
		os.Unsetenv(k)
	}
	t.Setenv("KACHING_T1", "kaching")
	t.Setenv("CHING_T1", "ching")
	t.Setenv("CHING_T2", "ching")
	t.Setenv("KACHING_T3", "old")
	t.Setenv("AGENT_TERMINAL_T3", "new")
	t.Setenv("KACHING_T4", "")
	legacyEnv()
	for k, want := range map[string]string{"AGENT_TERMINAL_T1": "kaching", "AGENT_TERMINAL_T2": "ching", "AGENT_TERMINAL_T3": "new", "AGENT_TERMINAL_T4": ""} {
		if got, ok := os.LookupEnv(k); !ok || got != want {
			t.Errorf("%s = %q (set %v), want %q", k, got, ok, want)
		}
	}
	for _, k := range []string{"AGENT_TERMINAL_T1", "AGENT_TERMINAL_T2", "AGENT_TERMINAL_T4"} {
		os.Unsetenv(k)
	}
}
