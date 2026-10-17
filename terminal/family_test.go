package main

import "testing"

func TestTitleName(t *testing.T) {
	cases := map[string]string{
		"/users/clyde/gitall/pico — ✳ PicoNew — chrome-devtools-mcp ◂ claude": "PicoNew",
		"pico — ⠂ PicoAgent01 — python ◂ claude":                              "PicoAgent01",
		"clyde — agent.terminal — caffeinate ◂ claude":                        "agent.terminal",
		"no separators": "",
	}
	for in, want := range cases {
		if got := titleName(in); got != want {
			t.Errorf("titleName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFamiliesFromWindowTabs(t *testing.T) {
	a := []Agent{
		{SID: "w1", Name: "worker1", State: "input"},
		{SID: "lead", Name: "PicoNew", State: "idle"},
		{SID: "w2", Name: "worker2", State: "idle"},
		{SID: "solo", Name: "solo", State: "done"},
	}
	linkFamilies(a, [][]string{{"PicoNew", "worker1", "worker2"}})
	sortAgents(a)
	order := ""
	for _, x := range a {
		order += x.SID + " "
	}
	// the waiting sub-session brings its family into WAITING, the lead comes first, then its tabs in order
	if order != "lead w1 w2 solo " {
		t.Fatalf("order %q", order)
	}
	if a[0].Subs != 2 || a[1].Lead != "lead" || FamilyGroup(a, 0) != 0 || FamilyGroup(a, 2) != 0 {
		t.Fatalf("family %+v", a)
	}
}

func TestFamiliesFromTerminalTabs(t *testing.T) {
	a := []Agent{
		{SID: "b", Name: "b", Win: 7, Tab: 2},
		{SID: "a", Name: "a", Win: 7, Tab: 1},
		{SID: "c", Name: "c", Win: 9, Tab: 1},
	}
	linkFamilies(a, nil)
	if a[0].Lead != "a" || a[1].Subs != 1 || a[2].Lead != "" {
		t.Fatalf("got %+v", a)
	}
}
