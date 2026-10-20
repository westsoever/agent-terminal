package main

// The select file (D73): cl (bin/cl) starts a background session and writes "<job> <unix time>" to
// ~/.agent/terminal/select. Each tick selects that session once it is listed and deletes the file. An entry older
// than selectMaxAge (its start failed later, or it never shows up) is deleted without selecting anything.

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const selectMaxAge = 30 * time.Second

func selectPath() string { return filepath.Join(agentHome(), "terminal", "select") }

func (m *model) selectFile() {
	b, err := os.ReadFile(selectPath())
	if err != nil {
		return
	}
	f := strings.Fields(string(b))
	var at int64
	if len(f) == 2 {
		at, err = strconv.ParseInt(f[1], 10, 64)
	}
	if len(f) != 2 || err != nil || time.Since(time.Unix(at, 0)) > selectMaxAge {
		os.Remove(selectPath())
		return
	}
	for _, a := range m.agents {
		if a.Bg && a.Job == f[0] {
			m.selSID = a.SID
			m.setStatus("✓ " + a.Name + " started with cl · g attaches a window")
			os.Remove(selectPath())
			m.writeState()
			return
		}
	}
}
