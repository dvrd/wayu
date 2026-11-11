// test_markdown.odin - build/markdown, the renderer behind the static docs
// pages (./build_it docs): the constructs docs/*.md use, and heading ids that
// match GitHub's (and the old client-side viewer's) so deep links keep working.

package test_wayu

import md "../../build/markdown"
import "core:strings"
import "core:testing"

@(private = "file")
render :: proc(src: string, opts := md.Options{}) -> md.Document {
	return md.render(src, opts, context.temp_allocator)
}

@(private = "file")
expect_html :: proc(t: ^testing.T, src, want: string, loc := #caller_location) {
	doc := render(src)
	testing.expectf(
		t,
		doc.html == want,
		"render(%q)\n got: %q\nwant: %q",
		src,
		doc.html,
		want,
		loc = loc,
	)
	free_all(context.temp_allocator)
}

@(private = "file")
expect_contains :: proc(t: ^testing.T, src: string, wants: ..string, loc := #caller_location) {
	doc := render(src)
	for want in wants {
		testing.expectf(
			t,
			strings.contains(doc.html, want),
			"render(%q) lacks %q\n got: %q",
			src,
			want,
			doc.html,
			loc = loc,
		)
	}
	free_all(context.temp_allocator)
}

@(private = "file")
ANCHOR :: `" aria-label="Link to this section">#</a>`

@(test)
test_markdown_headings_get_github_slugs :: proc(t: ^testing.T) {
	expect_html(t, "# Title", "<h1 id=\"title\">Title</h1>\n")
	expect_html(
		t,
		"## `wayu path` (PATH)",
		`<h2 id="wayu-path-path"><code class="nw">wayu path</code> (PATH)<a class="anchor" href="#wayu-path-path` +
		ANCHOR +
		"</h2>\n",
	)
	// Punctuation dropped, each space a '-', escapes are their character.
	expect_contains(t, "### extra.\\<ext\\> and tools.\\<ext\\>", `id="extraext-and-toolsext"`)
	expect_contains(t, "## hooks.conf", `id="hooksconf"`)
	expect_contains(t, "## wayu ≤ 3.9 — notes", `id="wayu--39--notes"`)
	expect_contains(t, "## Ünïcode Straße", `id="ünïcode-straße"`)
	// Closing #s are not part of the text; h5 has no id.
	expect_contains(t, "## Closed ##", `id="closed"`, ">Closed<a")
	expect_html(t, "##### Small", "<h5>Small</h5>\n")
}

@(test)
test_markdown_duplicate_slugs_are_numbered :: proc(t: ^testing.T) {
	doc := render("## Fixed\n\n## Fixed\n\n**Fixed**\n")
	testing.expect_value(t, len(doc.headings), 3)
	if len(doc.headings) == 3 {
		testing.expect_value(t, doc.headings[0].id, "fixed")
		testing.expect_value(t, doc.headings[1].id, "fixed-1")
		testing.expect_value(t, doc.headings[2].id, "fixed-2")
		testing.expect_value(t, doc.headings[2].level, 0)
	}
	free_all(context.temp_allocator)
}

@(test)
test_markdown_title_and_bold_subheading :: proc(t: ^testing.T) {
	doc := render("# wayu `docs`\n\ntext\n\n**init.zsh**\n\n**not** a heading\n")
	testing.expect_value(t, doc.title, "wayu docs")
	testing.expect(
		t,
		strings.contains(
			doc.html,
			`<p class="pseudo-h" id="initzsh"><strong>init.zsh<a class="anchor" href="#initzsh` +
			ANCHOR +
			"</strong></p>",
		),
		doc.html,
	)
	testing.expect(
		t,
		strings.contains(doc.html, "<p><strong>not</strong> a heading</p>"),
		doc.html,
	)
	free_all(context.temp_allocator)
}

@(test)
test_markdown_paragraphs_and_breaks :: proc(t: ^testing.T) {
	expect_html(t, "one\ntwo\n\nthree", "<p>one\ntwo</p>\n<p>three</p>\n")
	expect_html(t, "hard  \nbreak", "<p>hard<br>\nbreak</p>\n")
	expect_html(t, "a < b & \"c\" 'd'", "<p>a &lt; b &amp; &quot;c&quot; &#39;d&#39;</p>\n")
	// Raw HTML is not passed through.
	expect_html(t, "core.<ext> <b>x</b>", "<p>core.&lt;ext&gt; &lt;b&gt;x&lt;/b&gt;</p>\n")
	expect_html(t, "\\*not em\\* \\`x\\`", "<p>*not em* `x`</p>\n")
	expect_html(t, "---", "<hr>\n")
}

@(test)
test_markdown_inline :: proc(t: ^testing.T) {
	expect_html(
		t,
		"**bold** and *em* and _em_",
		"<p><strong>bold</strong> and <em>em</em> and <em>em</em></p>\n",
	)
	expect_html(t, "snake_case_name stays", "<p>snake_case_name stays</p>\n")
	expect_html(t, "a * b * c", "<p>a * b * c</p>\n")
	expect_html(t, "*(none)*", "<p><em>(none)</em></p>\n")
	// Short code never wraps, long code may; <, & escaped; one space stripped.
	expect_html(t, "`--json`", "<p><code class=\"nw\">--json</code></p>\n")
	expect_html(t, "`` a `<b>` & c ``", "<p><code class=\"nw\">a `&lt;b&gt;` &amp; c</code></p>\n")
	expect_html(
		t,
		"`${WAYU_DATA_DIR:-${XDG_DATA_HOME}}/wayu`",
		"<p><code>${WAYU_DATA_DIR:-${XDG_DATA_HOME}}/wayu</code></p>\n",
	)
	expect_html(t, "`**not bold**`", "<p><code class=\"nw\">**not bold**</code></p>\n")
}

@(private = "file")
rewrite :: proc(href: string, _: rawptr) -> string {
	return strings.concatenate({"/docs/", href}, context.temp_allocator)
}

@(test)
test_markdown_links :: proc(t: ^testing.T) {
	doc := render(
		"[CLI](cli.md#json-output), [ext](https://example.com \"T\"), [here](#top), <https://a.dev/x>, see https://b.dev/y.",
		{rewrite_link = rewrite},
	)
	for want in ([]string {
			`<a href="/docs/cli.md#json-output">CLI</a>`,
			`<a href="https://example.com" title="T" rel="noopener">ext</a>`,
			`<a href="#top">here</a>`,
			`<a href="https://a.dev/x" rel="noopener">https://a.dev/x</a>`,
			`<a href="https://b.dev/y" rel="noopener">https://b.dev/y</a>.`,
		}) {
		testing.expectf(t, strings.contains(doc.html, want), "lacks %q in %q", want, doc.html)
	}
	free_all(context.temp_allocator)
	// Link text keeps inline markup; "https://," is no link.
	expect_html(
		t,
		"[`wayu` **x**](a.md)",
		"<p><a href=\"a.md\"><code class=\"nw\">wayu</code> <strong>x</strong></a></p>\n",
	)
	expect_html(t, "not https://, ssh://", "<p>not https://, ssh://</p>\n")
}

@(test)
test_markdown_lists :: proc(t: ^testing.T) {
	// Tight, nested two levels.
	expect_html(
		t,
		"- one\n  - nested\n    - deeper\n- two\n  continued",
		"<ul>\n<li>one\n<ul>\n<li>nested\n<ul>\n<li>deeper\n</li>\n</ul>\n</li>\n</ul>\n</li>\n<li>two\ncontinued\n</li>\n</ul>\n",
	)
	// Lazy continuation line.
	expect_html(t, "- one\nlazy", "<ul>\n<li>one\nlazy\n</li>\n</ul>\n")
	// Ordered with a start number.
	expect_html(t, "3. c\n4. d", "<ol start=\"3\">\n<li>c\n</li>\n<li>d\n</li>\n</ol>\n")
	// A blank line between items makes every item a paragraph.
	expect_html(t, "- a\n\n- b", "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>\n")
	// So does one between an item's own blocks.
	expect_contains(t, "- a\n\n  b\n- c", "<li><p>a</p>\n<p>b</p>\n</li>", "<li><p>c</p>")
	// A different bullet starts a new list; the list ends at a paragraph.
	expect_html(t, "- a\n* b", "<ul>\n<li>a\n</li>\n</ul>\n<ul>\n<li>b\n</li>\n</ul>\n")
	expect_html(t, "- a\n\npara", "<ul>\n<li>a\n</li>\n</ul>\n<p>para</p>\n")
}

@(test)
test_markdown_code_blocks :: proc(t: ^testing.T) {
	doc := render("```sh\necho \"<x>\" && ls\n\n  indented\n```\n")
	testing.expect(
		t,
		strings.has_prefix(
			doc.html,
			"<div class=\"code\"><pre><code class=\"language-sh\">echo &quot;&lt;x&gt;&quot; &amp;&amp; ls\n\n  indented\n</code></pre><button type=\"button\" class=\"icon-btn copy-btn\" aria-label=\"Copy sh code\">",
		),
		doc.html,
	)
	free_all(context.temp_allocator)
	// Inside a list item, the item's indent is removed; no language: no class.
	expect_contains(
		t,
		"- run:\n\n  ```\n  wayu init\n  ```\n",
		"<li><p>run:</p>\n<div class=\"code\"><pre><code>wayu init\n</code></pre>",
		`aria-label="Copy code"`,
	)
	// Markdown inside a fence is literal; ~~~ fences and 4-space indents work.
	expect_contains(t, "~~~\n# not a heading\n~~~", "<code># not a heading\n</code>")
	expect_contains(t, "    indented code", "<pre><code>indented code\n</code></pre>")
}

@(test)
test_markdown_tables :: proc(t: ^testing.T) {
	expect_html(
		t,
		"| Flag | Meaning |\n|:--|--:|\n| `--shell <zsh\\|bash>` | *pick* |\n| a",
		"<div class=\"table-wrap\"><table>\n<thead>\n<tr>\n<th align=\"left\">Flag</th>\n<th align=\"right\">Meaning</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"left\"><code class=\"nw\">--shell &lt;zsh|bash&gt;</code></td>\n<td align=\"right\"><em>pick</em></td>\n</tr>\n<tr>\n<td align=\"left\">a</td>\n<td align=\"right\"></td>\n</tr>\n</tbody>\n</table></div>\n",
	)
	// A pipe without a delimiter row is a paragraph.
	expect_html(t, "a | b\nc", "<p>a | b\nc</p>\n")
}

@(test)
test_markdown_blockquote :: proc(t: ^testing.T) {
	expect_html(
		t,
		"> quoted **text**\nlazy\n>\n> - item",
		"<blockquote>\n<p>quoted <strong>text</strong>\nlazy</p>\n<ul>\n<li>item\n</li>\n</ul>\n</blockquote>\n",
	)
}
