package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

// Reply is a key that sends text to the selected agent as if the owner typed it there.
type Reply struct {
	Key   string `toml:"key"`   // one key ("f"), or "space " + key ("space m")
	Label string `toml:"label"` // shown in the key bar
	Text  string `toml:"text"`  // what gets typed into the session
}

// Keys are the fixed actions. Values are single keys as Bubble Tea names them ("j", "enter", "esc", " ").
type Keys struct {
	Next    string `toml:"next"`
	Prev    string `toml:"prev"`
	Waiting string `toml:"next_waiting"`
	Reply   string `toml:"type_reply"`
	Open    string `toml:"open_file"`
	Goto    string `toml:"go_to_window"`
	Here    string `toml:"bring_here"`
	Command string `toml:"command"`
	Wall    string `toml:"wall"`
	Zoom    string `toml:"zoom"`
	Dismiss string `toml:"dismiss"`
	Refresh string `toml:"refresh"`
	Older   string `toml:"scroll_up"`
	Newer   string `toml:"scroll_down"`
	Quick   string `toml:"quick_approve"`
	PCAgent string `toml:"pc_agent"`    // PC view: hand the issue to a new background agent
	PCTerm  string `toml:"pc_terminal"` // PC view: hand the issue to a new Terminal session
}

type Config struct {
	OpenCmd  string  `toml:"open_cmd"`      // run with the file path as its only argument
	Tables   string  `toml:"tables"`        // how agents' markdown tables are drawn: auto, grid, rule or records
	NWModel  string  `toml:"nw_model"`      // the model /NW starts an agent with, "" for Claude Code's default
	NWEffort string  `toml:"nw_effort"`     // its effort level
	NWPerm   string  `toml:"nw_permission"` // its permission mode: plan, auto, bypass, accept, manual or dontask
	Theme    string  `toml:"theme"`         // the accent color, see theme.go; /THEME writes it
	Bg       string  `toml:"background"`    // auto (ask the terminal), dark or light, see theme.go
	Keys     Keys    `toml:"keys"`
	Replies  []Reply `toml:"reply"`
}

const defaultConfig = `# Agent Terminal: keys and pre-written replies.
# Edit freely. The terminal reloads this file when you save it.
# Keys use Bubble Tea names: a letter, "enter", "esc", "tab", "up", "down", " " (space).

# How a file an agent mentioned is opened (gets the path as its only argument).
open_cmd = "open"

# How tables in an agent's messages are drawn: "auto" (columns under a rule; each row as a small block when the
# columns would get too narrow), "rule", "grid" (every cell framed) or "records" (always blocks).
tables = "auto"

# /NW starts a background agent. These are its defaults; words after /NW override them, e.g. /NW soii sonnet high.
# Model: opus, sonnet, haiku, fable or a full name. Effort: low, medium, high, xhigh, max. Permission: plan, auto,
# bypass, accept, manual, dontask. Empty: Claude Code's own default (the "model" and "effortLevel" of
# ~/.claude/settings.json). The same options start the agents that b and t hand a Paperclip issue to.
nw_model = "claude-sonnet-5-5"
nw_effort = "high"
nw_permission = ""

# The accent color: orange, amber, green, cyan, blue, violet, magenta or red. /THEME picks it and writes this line.
theme = "orange"

# The terminal's background: auto (agterm asks the terminal at start), dark or light. Set it when auto guesses wrong.
background = "auto"

[keys]
next = "l"            # next agent (down the list)
prev = "j"            # previous agent (up the list)
next_waiting = " "    # the INPUT agent that has waited the longest; " " means space twice (space waits for a second key, esc cancels)
type_reply = "k"      # write a reply (enter sends, esc keeps a draft)
open_file = "o"       # then a letter: open that mentioned file
go_to_window = "g"    # bring the agent's own Terminal window forward, where it is
bring_here = "h"      # bring the agent's window to the main display and into focus, to type in it
command = "/"         # command line: IN FL RP RC PR PO PC FIND <words> THEME A<n> HELP QUIT
wall = "W"            # every agent as tiles
zoom = "z"            # in the wall: one tile full screen
dismiss = "x"         # take a waiting agent out of the queue without answering
refresh = "R"         # re-read everything now
quick_approve = "a"   # an agent that asks questions: take every recommended answer and submit
pc_agent = "b"        # PC view: hand the selected issue to a new background agent (it has your permissions)
pc_terminal = "t"     # PC view: hand it to a new session in a Terminal window
scroll_up = "up"      # the agent's conversation: 3 lines back (pgup a page, home the start)
scroll_down = "down"  # 3 lines on (pgdown a page, end the newest)

# Pre-written replies. key is one key, or "space " + a key (press space, then the key).
# text is typed into the selected agent's session exactly as written, then Enter.
[[reply]]
key = "f"
label = "fix it"
text = "fix it"

[[reply]]
key = "d"
label = "review the code"
text = "review the code"

[[reply]]
key = "s"
label = "check other agents"
text = "check in on the other agents"

[[reply]]
key = "space m"
label = "merge"
text = "/merge"

[[reply]]
key = "space c"
label = "commit"
text = "commit your work"

[[reply]]
key = "space w"
label = "new worktree"
text = "make a new worktree for this and continue there"
`

func configPath() string {
	return filepath.Join(agentHome(), "terminal", "keys.toml")
}

func agentHome() string {
	if h := os.Getenv("AGENT_HOME"); h != "" {
		return h
	}
	return filepath.Join(os.Getenv("HOME"), ".agent")
}

// loadConfig reads keys.toml, writing the default first when it doesn't exist. Missing keys fall back to the
// defaults, so an old file keeps working after new actions are added.
func loadConfig() (Config, time.Time, error) {
	var def Config
	if _, err := toml.Decode(defaultConfig, &def); err != nil {
		panic(err) // the built-in default must parse
	}
	p := configPath()
	st, err := os.Stat(p)
	if os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err == nil {
			_ = os.WriteFile(p, []byte(defaultConfig), 0o644)
		}
		return def, time.Now(), nil
	}
	if err != nil {
		return def, time.Time{}, err
	}
	var c Config
	if _, err := toml.DecodeFile(p, &c); err != nil {
		return def, st.ModTime(), err
	}
	if c.OpenCmd == "" {
		c.OpenCmd = def.OpenCmd
	}
	if !slices.Contains(tableStyles, c.Tables) {
		c.Tables = "auto"
	}
	c.Theme = themeID(c.Theme) // empty or unknown: orange
	c.Bg = bgModeOf(c.Bg)      // empty or unknown: auto
	fill := func(v *string, d string) {
		if *v == "" {
			*v = d
		}
	}
	fill(&c.Keys.Next, def.Keys.Next)
	fill(&c.Keys.Prev, def.Keys.Prev)
	fill(&c.Keys.Waiting, def.Keys.Waiting)
	fill(&c.Keys.Reply, def.Keys.Reply)
	fill(&c.Keys.Open, def.Keys.Open)
	fill(&c.Keys.Goto, def.Keys.Goto)
	fill(&c.Keys.Here, def.Keys.Here)
	fill(&c.Keys.Command, def.Keys.Command)
	fill(&c.Keys.Wall, def.Keys.Wall)
	fill(&c.Keys.Zoom, def.Keys.Zoom)
	fill(&c.Keys.Older, def.Keys.Older)
	fill(&c.Keys.Newer, def.Keys.Newer)
	fill(&c.Keys.Dismiss, def.Keys.Dismiss)
	fill(&c.Keys.Refresh, def.Keys.Refresh)
	fill(&c.Keys.Quick, def.Keys.Quick)
	fill(&c.Keys.PCAgent, def.Keys.PCAgent)
	fill(&c.Keys.PCTerm, def.Keys.PCTerm)
	for i := range c.Replies {
		c.Replies[i].Key = strings.TrimSpace(c.Replies[i].Key)
		if c.Replies[i].Label == "" {
			c.Replies[i].Label = c.Replies[i].Text
		}
	}
	return c, st.ModTime(), nil
}

// leaderReply returns the reply bound to "space <k>", if any.
func (c Config) leaderReply(k string) (Reply, bool) {
	for _, r := range c.Replies {
		if r.Key == "space "+k {
			return r, true
		}
	}
	return Reply{}, false
}

// directReply returns the reply bound to the single key k, if any.
func (c Config) directReply(k string) (Reply, bool) {
	for _, r := range c.Replies {
		if r.Key == k {
			return r, true
		}
	}
	return Reply{}, false
}
