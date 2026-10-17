package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// histMax is how many mentioned files the FL view keeps: the newest mentions, also of agents that have gone.
const histMax = 30

// fileMention is one file an agent named in a message, and when it wrote that message.
type fileMention struct {
	Path  string    `json:"path"`
	Agent string    `json:"agent"`
	At    time.Time `json:"at"`
}

// fileHistory is the FL view's list, newest first. It is shared by every copy of the model and saved in
// ~/.agent/terminal/files.json, so the list survives a restart.
type fileHistory struct {
	items []fileMention
}

func filesPath() string { return filepath.Join(agentHome(), "terminal", "files.json") }

func loadFileHistory() *fileHistory {
	h := &fileHistory{}
	if b, err := os.ReadFile(filesPath()); err == nil {
		_ = json.Unmarshal(b, &h.items)
	}
	return h
}

// add puts a mention on the list. A file already on it moves up only when this mention is newer. true when
// the list changed.
func (h *fileHistory) add(path, agent string, at time.Time) bool {
	for i, it := range h.items {
		if it.Path != path {
			continue
		}
		if !at.After(it.At) {
			return false
		}
		h.items = append(h.items[:i], h.items[i+1:]...)
		break
	}
	h.items = append(h.items, fileMention{path, agent, at})
	sort.SliceStable(h.items, func(i, j int) bool { return h.items[i].At.After(h.items[j].At) })
	if len(h.items) > histMax {
		h.items = h.items[:histMax]
	}
	return true
}

// save writes the list (replaced in one rename).
func (h *fileHistory) save() {
	p := filesPath()
	b, err := json.MarshalIndent(h.items, "", "  ")
	if err != nil || os.MkdirAll(filepath.Dir(p), 0o700) != nil {
		return
	}
	if os.WriteFile(p+".tmp", b, 0o600) == nil {
		_ = os.Rename(p+".tmp", p)
	}
}

// noteFiles adds the files that each agent's recent messages name, dated by those messages. readOnly runs
// (--render) read the list but don't write it.
func (m *model) noteFiles() {
	if m.files == nil {
		return
	}
	changed := false
	for i := range m.agents {
		a := &m.agents[i]
		for _, f := range m.last(a).Mentions {
			if m.files.add(f.Path, a.Name, f.At) {
				changed = true
			}
		}
	}
	if changed && !readOnly {
		m.files.save()
	}
}
