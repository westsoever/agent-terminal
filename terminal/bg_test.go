package main

import (
	"strings"
	"testing"
)

// The attach window quotes the job like any other shell word, so a strange id can't run something else.
func TestBgAttachWindowQuotes(t *testing.T) {
	var script string
	old := osascriptRun
	t.Cleanup(func() { osascriptRun = old })
	osascriptRun = func(s string) ([]byte, error) { script = s; return nil, nil }
	if r := bgAttachWindow("j'1; rm"); r != "ok" {
		t.Fatalf("r = %q", r)
	}
	if want := ` attach 'j'\\''1; rm'"`; !strings.Contains(script, want) || !strings.Contains(script, `do script "'`) {
		t.Errorf("script:\n%s\nwant to contain %s", script, want)
	}
}
