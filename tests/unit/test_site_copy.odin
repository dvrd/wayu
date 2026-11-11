// test_site_copy.odin - the website (docs/index.html, the docs viewer and
// docs/quickstart.md) doesn't describe layouts and commands wayu no longer has.
//
// These pages are written by hand and served from main as wayu.dvrd.io: a
// stale line there sends new users to files that don't exist.

package test_wayu

import "core:strings"
import "core:testing"

@(private = "file")
Site_Page :: struct {
	path: string,
	text: string,
}

@(private = "file")
SITE_PAGES := [?]Site_Page {
	{"docs/index.html", #load("../../docs/index.html", string)},
	{"docs/docs/index.html", #load("../../docs/docs/index.html", string)},
	{"docs/quickstart.md", #load("../../docs/quickstart.md", string)},
}

// Text that describes wayu before 6.0: init.<ext> lived in the config dir,
// PATH entries in wayu.toml's [paths] table, and `wayu migrate` existed.
@(private = "file")
STALE_SITE_TEXT := [?]struct {
	text: string,
	why:  string,
} {
	{".config/wayu/init", "init.<ext> lives in the data dir (~/.local/share/wayu)"},
	{"[paths]", "PATH entries live in entries.json (wayu path add), not wayu.toml"},
	{"wayu migrate", "there is no `wayu migrate` command"},
}

@(test)
test_site_has_no_stale_layout :: proc(t: ^testing.T) {
	for page in SITE_PAGES {
		for stale in STALE_SITE_TEXT {
			testing.expectf(
				t,
				!strings.contains(page.text, stale.text),
				"%s mentions %q: %s",
				page.path,
				stale.text,
				stale.why,
			)
		}
	}
}
