// site.odin — the generated parts of the website (docs/, served as
// wayu.dvrd.io), written by `./build_it docs` and checked by `--check`:
//
//   docs/docs/index.html          docs overview
//   docs/docs/<id>/index.html     one static page per DOC_PAGES entry, rendered
//                                 from docs/<file> (build/markdown) into
//                                 build/docs_shell.html
//   docs/sitemap.xml              landing page, overview, every docs page
//   docs/index.html               the unit test count in the trust strip
//
// docs/docs/docs.css and docs.js are hand-written and shared by every page.

package main

import bld "../bld"
import "core:fmt"
import "core:os"
import "core:strings"
import md "markdown"

SITE_URL :: "https://wayu.dvrd.io"
REPO_BLOB :: "https://github.com/dvrd/wayu/blob/main/"
DOCS_SHELL :: "build/docs_shell.html"

Doc_Page :: struct {
	id:    string, // URL: /docs/<id>/
	file:  string, // under docs/
	title: string,
	desc:  string,
}

// Sidebar, pager and sitemap order.
DOC_PAGES :: [?]Doc_Page {
	{
		"quickstart",
		"quickstart.md",
		"Quickstart",
		"Install, the one rc line, your first entries and secrets, and bringing over an existing rc file.",
	},
	{
		"cli",
		"cli.md",
		"CLI reference",
		"Every command, action and flag, the --json shapes and the exit codes.",
	},
	{
		"config",
		"config-reference.md",
		"Configuration",
		"wayu.toml, entries.json, hooks, plugins and the files wayu generates.",
	},
	{
		"stability",
		"STABILITY.md",
		"Stability",
		"What a release promises from 7.0 on: stable surfaces, migrations, deprecation, platforms.",
	},
	{
		"upgrading",
		"UPGRADING.md",
		"Upgrading",
		"User-visible behavior changes per release, with the steps to follow.",
	},
	{
		"compatibility",
		"compatibility.md",
		"Compatibility",
		"Coexistence recipes and pinned tests for shell tools and dotfiles managers.",
	},
	{
		"benchmarks",
		"benchmarks.md",
		"Benchmarks",
		"Reproduce startup budgets and comparative measurements with raw evidence.",
	},
	{
		"security-review",
		"security-review.md",
		"Security review",
		"Scope and evidence for the pending independent review of multi-machine secrets.",
	},
}

OVERVIEW_DESC :: "wayu documentation: quickstart, CLI reference, configuration reference, stability guarantees and upgrade guide."

// A generated file and the content it should have.
Site_File :: struct {
	path:    string,
	content: string,
}

// Render every generated site file; with check, write nothing and return
// false when one on disk differs.
sync_site :: proc(check: bool) -> bool {
	files := make([dynamic]Site_File, context.temp_allocator)
	shell := read_text(DOCS_SHELL)
	append(&files, Site_File{"docs/docs/index.html", render_overview(shell)})
	pages := DOC_PAGES
	for _, i in pages {
		append(
			&files,
			Site_File {
				fmt.tprintf("docs/docs/%s/index.html", pages[i].id),
				render_doc_page(shell, i),
			},
		)
	}
	append(&files, Site_File{"docs/sitemap.xml", render_sitemap()})
	append(&files, Site_File{"docs/index.html", with_test_count(read_text("docs/index.html"))})

	ok := true
	for f in files {
		old, err := os.read_entire_file_from_path(f.path, context.temp_allocator)
		if err == nil && string(old) == f.content {
			continue
		}
		if check {
			bld.log_error("%s is out of date — run ./build_it docs", f.path)
			ok = false
			continue
		}
		dir := f.path[:strings.last_index_byte(f.path, '/')]
		if !os.exists(dir) && os.make_directory_all(dir) != nil {
			bld.log_error("Failed to create the directory for %s", f.path)
			os.exit(1)
		}
		if os.write_entire_file(f.path, transmute([]byte)f.content) != nil {
			bld.log_error("Failed to write %s", f.path)
			os.exit(1)
		}
		bld.log_info("%s regenerated", f.path)
	}
	if ok && check {
		bld.log_info("Site pages, sitemap and test count are current")
	}
	return ok
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		bld.log_error("Failed to read %s", path)
		os.exit(1)
	}
	return string(data)
}

// Replace each {{name}} in tmpl with values[name], in one pass (so a value
// containing "{{" is never expanded). An unknown name is a bug: exit.
fill :: proc(tmpl: string, values: map[string]string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := tmpl
	for {
		open := strings.index(rest, "{{")
		if open == -1 {
			break
		}
		close := strings.index(rest[open:], "}}")
		if close == -1 {
			break
		}
		name := rest[open + 2:open + close]
		value, known := values[name]
		if !known {
			bld.log_error("%s: unknown placeholder {{%s}}", DOCS_SHELL, name)
			os.exit(1)
		}
		strings.write_string(&b, rest[:open])
		strings.write_string(&b, value)
		rest = rest[open + close + 2:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

html_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	md.escape(&b, s)
	return strings.to_string(b)
}

page_url :: proc(id: string) -> string {
	return fmt.tprintf("/docs/%s/", id)
}

// Old ?p= ids → page ids, for the redirect in the shell's <head>.
redirects_js :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	for p, i in DOC_PAGES {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "'%s': '%s'", p.id, p.id)
		stem := strings.to_lower(strings.trim_suffix(p.file, ".md"), context.temp_allocator)
		if stem != p.id {
			fmt.sbprintf(&b, ", '%s': '%s'", stem, p.id)
		}
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// Sidebar links; the current page's entry carries its table of contents.
sidebar :: proc(current: int, toc: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for p, i in DOC_PAGES {
		fmt.sbprintf(&b, `          <li><a href="%s" data-page="%s"`, page_url(p.id), p.id)
		if i == current {
			strings.write_string(&b, ` aria-current="page"`)
		}
		fmt.sbprintf(&b, ">%s</a>", html_escape(p.title))
		if i == current && toc != "" {
			fmt.sbprintf(&b, `<ul class="toc-list side-toc">%s</ul>`, toc)
		}
		strings.write_string(&b, "</li>\n")
	}
	return strings.to_string(b)
}

page_cards :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for p in DOC_PAGES {
		fmt.sbprintf(
			&b,
			`<a href="%s"><strong>%s</strong>%s</a>`,
			page_url(p.id),
			html_escape(p.title),
			html_escape(p.desc),
		)
	}
	return strings.to_string(b)
}

render_overview :: proc(shell: string) -> string {
	article := fmt.tprintf(
		`        <div class="state">
          <p class="doc-meta"><span class="crumb">Docs</span></p>
          <h1>wayu documentation</h1>
          <p>The reference for every command and config file, rendered from the Markdown in the repository, so it always matches the release on <code>main</code>. New here? Start with the <a href="%s">Quickstart</a>, then keep the CLI reference open.</p>
          <div class="cards">%s</div>
          <p class="foot">Press <kbd>/</kbd> to search every page.</p>
        </div>
`,
		page_url("quickstart"),
		page_cards(),
	)
	values := make(map[string]string, context.temp_allocator)
	values["source"] = "*.md"
	values["title"] = "wayu docs"
	values["description"] = OVERVIEW_DESC
	values["url"] = SITE_URL + "/docs/"
	values["og_type"] = "website"
	values["redirects"] = redirects_js()
	values["pages"] = sidebar(-1, "")
	values["article"] = article
	values["toc"] = ""
	values["rail_hidden"] = " hidden"
	return fill(shell, values)
}

// Links between the docs' Markdown files go to their pages; any other
// relative link goes to the file on GitHub.
rewrite_doc_link :: proc(href: string, _: rawptr) -> string {
	path, hash := href, ""
	if h := strings.index_byte(href, '#'); h != -1 {
		path, hash = href[:h], href[h:]
	}
	if strings.contains_rune(path, '?') || path == "" {
		return href
	}
	path = strings.trim_prefix(path, "./")
	for p in DOC_PAGES {
		if strings.equal_fold(p.file, path) {
			return fmt.tprintf("%s%s", page_url(p.id), hash)
		}
	}
	return fmt.tprintf("%sdocs/%s%s", REPO_BLOB, path, hash)
}

render_doc_page :: proc(shell: string, index: int) -> string {
	pages := DOC_PAGES
	page := pages[index]
	doc := md.render(
		read_text(fmt.tprintf("docs/%s", page.file)),
		{rewrite_link = rewrite_doc_link},
		context.temp_allocator,
	)

	// On this page: h2 and h3, plus the bold-only sub-headings of the
	// upgrade notes (one per change).
	toc := strings.builder_make(context.temp_allocator)
	for h in doc.headings {
		level := h.level
		if level == 0 {
			if page.id != "upgrading" {
				continue
			}
			level = 3
		}
		if level < 2 || level > 3 {
			continue
		}
		fmt.sbprintf(
			&toc,
			`<li><a class="%s" href="#%s" data-id="%s">%s</a></li>`,
			"l2" if level == 2 else "l3",
			html_escape(h.id),
			html_escape(h.id),
			html_escape(h.text),
		)
	}
	toc_html := strings.to_string(toc)

	pager := strings.builder_make(context.temp_allocator)
	if index > 0 {
		prev := pages[index - 1]
		fmt.sbprintf(
			&pager,
			`<a class="prev" href="%s"><span>Previous</span>%s</a>`,
			page_url(prev.id),
			html_escape(prev.title),
		)
	}
	if index + 1 < len(pages) {
		next := pages[index + 1]
		fmt.sbprintf(
			&pager,
			`<a class="next" href="%s"><span>Next</span>%s</a>`,
			page_url(next.id),
			html_escape(next.title),
		)
	}

	article := fmt.tprintf(
		`        <p class="doc-meta"><span class="crumb">Docs / %s</span><a href="%sdocs/%s">Source: docs/%s</a></p>
        <div class="md">
%s        </div>
        <nav class="pager" aria-label="Previous and next page">%s</nav>
`,
		html_escape(page.title),
		REPO_BLOB,
		page.file,
		page.file,
		doc.html,
		strings.to_string(pager),
	)

	values := make(map[string]string, context.temp_allocator)
	values["source"] = page.file
	values["title"] = html_escape(fmt.tprintf("%s · wayu docs", page.title))
	values["description"] = html_escape(page.desc)
	values["url"] = fmt.tprintf("%s%s", SITE_URL, page_url(page.id))
	values["og_type"] = "article"
	values["redirects"] = redirects_js()
	values["pages"] = sidebar(index, toc_html)
	values["article"] = article
	values["toc"] = toc_html if toc_html == "" else fmt.tprintf("        %s\n", toc_html)
	values["rail_hidden"] = " hidden" if toc_html == "" else ""
	return fill(shell, values)
}

render_sitemap :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		`<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by ./build_it docs (build/site.odin). -->
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
`,
	)
	fmt.sbprintf(&b, "  <url><loc>%s/</loc></url>\n", SITE_URL)
	fmt.sbprintf(&b, "  <url><loc>%s/docs/</loc></url>\n", SITE_URL)
	for p in DOC_PAGES {
		fmt.sbprintf(&b, "  <url><loc>%s%s</loc></url>\n", SITE_URL, page_url(p.id))
	}
	strings.write_string(&b, "</urlset>\n")
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Unit test count in the landing page's trust strip
// ---------------------------------------------------------------------------

// The count is written after this marker, up to the next '<'.
TEST_COUNT_MARKER :: `data-gen="unit-tests">`

// Number of @(test) procs in tests/unit, rounded down to a multiple of 10 so
// the page only changes every tenth test ("670+ unit tests").
unit_test_count_label :: proc() -> string {
	dir, err := os.open(TEST_DIR)
	if err != nil {
		bld.log_error("Failed to open %s", TEST_DIR)
		os.exit(1)
	}
	defer os.close(dir)
	infos, read_err := os.read_all_directory(dir, context.temp_allocator)
	if read_err != nil {
		bld.log_error("Failed to list %s", TEST_DIR)
		os.exit(1)
	}
	count := 0
	for info in infos {
		if !strings.has_suffix(info.name, ".odin") {
			continue
		}
		src := read_text(fmt.tprintf("%s/%s", TEST_DIR, info.name))
		for line in strings.split_lines_iterator(&src) {
			if strings.has_prefix(strings.trim_space(line), "@(test)") {
				count += 1
			}
		}
	}
	return fmt.tprintf("%d+ unit tests", count - count % 10)
}

with_test_count :: proc(html: string) -> string {
	at := strings.index(html, TEST_COUNT_MARKER)
	if at == -1 {
		bld.log_error(
			"docs/index.html: test count marker '%s' not found (update build/site.odin)",
			TEST_COUNT_MARKER,
		)
		os.exit(1)
	}
	start := at + len(TEST_COUNT_MARKER)
	end := strings.index_byte(html[start:], '<')
	if end == -1 {
		bld.log_error("docs/index.html: unterminated test count after '%s'", TEST_COUNT_MARKER)
		os.exit(1)
	}
	return strings.concatenate(
		{html[:start], unit_test_count_label(), html[start + end:]},
		context.temp_allocator,
	)
}
