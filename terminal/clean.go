package main

// CLEAN: map the disk (bin/disk-map.sh), show the map in the browser, and start a background agent in the home
// folder that has the map and helps free space. The agent removes nothing without the owner's yes.

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

const cleanPrompt = `Help me free disk space on this Mac. bin/disk-map.sh just mapped my home folder: the data is ~/.agent/disk-map/report.json and I have report.html open in the browser.
1. Read report.json. "items" are the candidates (safe: caches and build output; review: costs a download or may hold work); "tree" is every folder of 50 MB or more, 3 levels deep. "Not scanned" (disk used minus the home folder) is system, apps and snapshots: check it too if it is large (tmutil listlocalsnapshots /, /Applications, /Library).
2. Give me a short ranked list: what to remove, how much it frees, how it comes back, and what is risky. Point out big folders that are not candidates yet (an app's caches or old data, for example).
3. Remove only what I approve. Prefer each tool's own clean command (npm cache clean, brew cleanup, uv cache clean, ollama rm) over rm -rf. Before a worktree or a project folder goes, check it for uncommitted or unpushed work and a live session. Never touch Documents, Desktop, Pictures or a repo's tracked files without asking.
4. When done, run ~/.claude/agent-terminal/bin/disk-map.sh again and tell me how much space was freed.`

// cleanCmd runs the scan (a few minutes on a full home folder), then starts the agent with its screen open.
func cleanCmd(o nwOpts) tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command(filepath.Join(kitDir(), "bin", "disk-map.sh"), "--open").CombinedOutput()
		if err != nil {
			return sentMsg{"", "CLEAN", "map the disk", "error: " + firstLine(strings.TrimSpace(string(out)))}
		}
		o.Dir, o.Name = os.Getenv("HOME"), "clean"
		return bgStartCmd(o, cleanPrompt, true)()
	}
}
