# FFF

[**AI agents (MCP)**](https://raw.githubusercontent.com/dmtrKovalenko/fff.nvim/main/README.md#mcp)   \|   [**Neovim users**](https://raw.githubusercontent.com/dmtrKovalenko/fff.nvim/main/README.md#neovim-guide)

_A fast file search for your AI and neovim, with memory built-in_

[![Stars](https://img.shields.io/github/stars/dmtrKovalenko/fff.nvim?style=for-the-badge&logo=starship&color=C9CBFF&logoColor=D9E0EE&labelColor=302D41)](https://github.com/dmtrKovalenko/fff.nvim/stargazers)[![Issues](https://img.shields.io/github/issues/dmtrKovalenko/fff.nvim?style=for-the-badge&logo=bilibili&color=F5E0DC&logoColor=D9E0EE&labelColor=302D41)](https://github.com/dmtrKovalenko/fff.nvim/issues)[![Contributors](https://img.shields.io/github/contributors/dmtrKovalenko/fff.nvim?color=%23DDB6F2&label=CONTRIBUTORS&logo=git&style=for-the-badge&logoColor=D9E0EE&labelColor=302D41)](https://github.com/dmtrKovalenko/fff.nvim/contributors)

\-\-\-

\*\*FFF\*\* stands for ~~freakin fast fuzzy file finder~~ (pick 3) and it is an opinionated fuzzy file picker for your AI agent and Neovim. Just for file search, but we do the file search really fff well.

FFF is a tool for grepping, fuzzy file matching, globbing, and multigrepping with a strong focus on performance and useful search results. For humans - provides an unbelievable typo-resistant experience, for AI agents - implements the fastest file search with additional free memory suggesting the best search results based on various factors like frecency, git status, file size, definition matches, and more.

\## MCP

FFF is an amazing way to reduce the time and tokens by giving your AI agent a bit of memory built-in to their file search tools. It makes your AI harness to find the code faster and spend less tokens by doing less roundtrips and reading less useless files.

!\[Chart showing the superiority of fff.nvim over builtin claude code tools\](./chart.png)

You can install FFF as a dependency for your AI agent using a simple bash script:

\`\`\`bash
curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh \| bash
\`\`\`

\> The installation script is here \[./install-mcp.sh\](./install-mcp.sh) if you want to review it before running.

It will print out the instructions on how to connect it to your \`Claude Code\`, \`Codex\`, \`OpenCode\`, etc. Once you have it connected just ask your agent to "use fff".
Here is an example addition to \`CLAUDE.md\` that works perfectly:

\`\`\`sh
\# CLAUDE.md
For any file search or grep in the current git indexed directory use fff tools
\`\`\`

\## Neovim guide

Here is some demo on the linux repository (100k files, 8GB) but you better fill it yourself and see the magic

https://github.com/user-attachments/assets/5d0e1ce9-642c-4c44-aa88-01b05bb86abb

\### Installation

FFF.nvim requires neovim 0.10.0 or higher

\#### lazy.nvim

\`\`\`lua
{
 'dmtrKovalenko/fff.nvim',
 build = function()
 \-\- this will download prebuild binary or try to use existing rustup toolchain to build from source
 \-\- (if you are using lazy you can use gb for rebuilding a plugin if needed)
 require("fff.download").download\_or\_build\_binary()
 end,
 \-\- if you are using nixos
 \-\- build = "nix run .#release",
 opts = { -- (optional)
 debug = {
 enabled = true, -- we expect your collaboration at least during the beta
 show\_scores = true, -- to help us optimize the scoring system, feel free to share your scores!
 },
 },
 \-\- No need to lazy-load with lazy.nvim.
 \-\- This plugin initializes itself lazily.
 lazy = false,
 keys = {
 {
 "ff", -- try it if you didn't it is a banger keybinding for a picker
 function() require('fff').find\_files() end,
 desc = 'FFFind files',
 },
 {
 "fg",
 function() require('fff').live\_grep() end,
 desc = 'LiFFFe grep',
 },
 {
 "fz",
 function() require('fff').live\_grep({
 grep = {
 modes = { 'fuzzy', 'plain' }
 }
 }) end,
 desc = 'Live fffuzy grep',
 },
 {
 "fc",
 function() require('fff').live\_grep({ query = vim.fn.expand("") }) end,
 desc = 'Search current word',
 },
 }
}
\`\`\`

\#### vim.pack

\`\`\`lua
vim.pack.add({ 'https://github.com/dmtrKovalenko/fff.nvim' })

vim.api.nvim\_create\_autocmd('PackChanged', {
 callback = function(ev)
 local name, kind = ev.data.spec.name, ev.data.kind
 if name == 'fff.nvim' and (kind == 'install' or kind == 'update') then
 if not ev.data.active then
 vim.cmd.packadd('fff.nvim')
 end
 require('fff.download').download\_or\_build\_binary()
 end
 end,
})

\-\- the plugin will automatically lazy load
vim.g.fff = {
 lazy\_sync = true, -- start syncing only when the picker is open
 debug = {
 enabled = true,
 show\_scores = true,
 },
}

vim.keymap.set(
 'n',
 'ff',
 function() require('fff').find\_files() end,
 { desc = 'FFFind files' }
)
\`\`\`

\### Configuration

FFF.nvim comes with sensible defaults. Here's the complete configuration with all available options:

\`\`\`lua
require('fff').setup({
 base\_path = vim.fn.getcwd(),
 prompt = '🪿 ',
 title = 'FFFiles',
 max\_results = 100,
 max\_threads = 4,
 lazy\_sync = true, -- set to false if you want file indexing to start on open
 layout = {
 height = 0.8,
 width = 0.8,
 prompt\_position = 'bottom', -- or 'top'
 preview\_position = 'right', -- or 'left', 'right', 'top', 'bottom'
 preview\_size = 0.5,
 flex = { -- set to false to disable flex layout
 size = 130, -- column threshold: if screen width >= size, use preview\_position; otherwise use wrap
 wrap = 'top', -- position to use when screen is narrower than size
 },
 show\_scrollbar = true, -- Show scrollbar for pagination
 \-\- How to shorten long directory paths in the file list:
 \-\- 'middle\_number' (default): uses dots for 1-3 hidden (a/./b, a/../b, a/.../b)
 \-\- and numbers for 4+ (a/.4./b, a/.5./b)
 \-\- 'middle': always uses dots (a/./b, a/../b, a/.../b)
 \-\- 'end': truncates from the end (home/user/projects)
 path\_shorten\_strategy = 'middle\_number',
 },
 preview = {
 enabled = true,
 max\_size = 10 \* 1024 \* 1024, -- Do not try to read files larger than 10MB
 chunk\_size = 8192, -- Bytes per chunk for dynamic loading (8kb - fits ~100-200 lines)
 binary\_file\_threshold = 1024, -- amount of bytes to scan for binary content (set 0 to disable)
 imagemagick\_info\_format\_str = '%m: %wx%h, %\[colorspace\], %q-bit',
 line\_numbers = false,
 cursorlineopt = 'both', -- the cursorlineopt used for lines in grep file previews, see :h cursorlineopt
 wrap\_lines = false,
 filetypes = {
 svg = { wrap\_lines = true },
 markdown = { wrap\_lines = true },
 text = { wrap\_lines = true },
 },
 },
 keymaps = {
 close = '',
 select = '',
 select\_split = '',
 select\_vsplit = '',
 select\_tab = '',
 \-\- you can assign multiple keys to any action
 move\_up = { '', '' },
 move\_down = { '', '' },
 preview\_scroll\_up = '',
 preview\_scroll\_down = '',
 toggle\_debug = '',
 \-\- grep mode: cycle between plain text, regex, and fuzzy search
 cycle\_grep\_modes = '',
 \-\- goes to the previous query in history
 cycle\_previous\_query = '',
 \-\- multi-select keymaps for quickfix
 toggle\_select = '',
 send\_to\_quickfix = '',
 \-\- this are specific for the normal mode (you can exit it using any other keybind like jj)
 focus\_list = 'l',
 focus\_preview = 'p',
 },
 hl = {
 border = 'FloatBorder',
 normal = 'Normal',
 cursor = 'CursorLine', -- Falls back to 'Visual' if CursorLine is not defined
 matched = 'IncSearch',
 title = 'Title',
 prompt = 'Question',
 frecency = 'Number',
 debug = 'Comment',
 combo\_header = 'Number',
 scrollbar = 'Comment',
 directory\_path = 'Comment',
 \-\- Multi-select highlights
 selected = 'FFFSelected',
 selected\_active = 'FFFSelectedActive',
 \-\- Git text highlights for file names
 git\_staged = 'FFFGitStaged',
 git\_modified = 'FFFGitModified',
 git\_deleted = 'FFFGitDeleted',
 git\_renamed = 'FFFGitRenamed',
 git\_untracked = 'FFFGitUntracked',
 git\_ignored = 'FFFGitIgnored',
 \-\- Git sign/border highlights
 git\_sign\_staged = 'FFFGitSignStaged',
 git\_sign\_modified = 'FFFGitSignModified',
 git\_sign\_deleted = 'FFFGitSignDeleted',
 git\_sign\_renamed = 'FFFGitSignRenamed',
 git\_sign\_untracked = 'FFFGitSignUntracked',
 git\_sign\_ignored = 'FFFGitSignIgnored',
 \-\- Git sign selected highlights
 git\_sign\_staged\_selected = 'FFFGitSignStagedSelected',
 git\_sign\_modified\_selected = 'FFFGitSignModifiedSelected',
 git\_sign\_deleted\_selected = 'FFFGitSignDeletedSelected',
 git\_sign\_renamed\_selected = 'FFFGitSignRenamedSelected',
 git\_sign\_untracked\_selected = 'FFFGitSignUntrackedSelected',
 git\_sign\_ignored\_selected = 'FFFGitSignIgnoredSelected',
 \-\- Grep highlights
 grep\_match = 'IncSearch', -- Highlight for matched text in grep results
 grep\_line\_number = 'LineNr', -- Highlight for :line:col location
 grep\_regex\_active = 'DiagnosticInfo', -- Highlight for keybind + label when regex is on
 grep\_plain\_active = 'Comment', -- Highlight for keybind + label when regex is off
 grep\_fuzzy\_active = 'DiagnosticHint', -- Highlight for keybind + label when fuzzy is on
 \-\- Cross-mode suggestion highlights
 suggestion\_header = 'WarningMsg', -- Highlight for the "No results found. Suggested..." banner
 },
 \-\- Store file open frecency
 frecency = {
 enabled = true,
 db\_path = vim.fn.stdpath('cache') .. '/fff\_nvim',
 },
 \-\- Store successfully opened queries with respective matches
 history = {
 enabled = true,
 db\_path = vim.fn.stdpath('data') .. '/fff\_queries',
 min\_combo\_count = 3, -- Minimum selections before combo boost applies (3 = boost starts on 3rd selection)
 combo\_boost\_score\_multiplier = 100, -- Score multiplier for combo matches (files repeatedly opened with same query)
 },
 \-\- Git integration
 git = {
 status\_text\_color = false, -- Apply git status colors to filename text (default: false, only sign column)
 },
 debug = {
 enabled = false, -- Show file info panel in preview
 show\_scores = false, -- Show scores inline in the UI
 },
 logging = {
 enabled = true,
 log\_file = vim.fn.stdpath('log') .. '/fff.log',
 log\_level = 'info',
 },
 \-\- find\_files settings
 file\_picker = {
 current\_file\_label = '(current)',
 },
 \-\- grep settings
 grep = {
 max\_file\_size = 10 \* 1024 \* 1024, -- Skip files larger than 10MB
 max\_matches\_per\_file = 100, -- Maximum matches per file (set 0 to unlimited)
 smart\_case = true, -- Case-insensitive unless query has uppercase
 time\_budget\_ms = 150, -- Max search time in ms per call (prevents UI freeze, 0 = no limit)
 modes = { 'plain', 'regex', 'fuzzy' }, -- Available grep modes and their cycling order
 trim\_whitespace = false, -- Strip leading whitespace from matched lines
 },
 })
\`\`\`

\### Key Features

\#### Available Methods

\`\`\`lua
require('fff').find\_files() -- Find files in current repository
require('fff').scan\_files() -- Trigger rescan of files in the current directory
require('fff').refresh\_git\_status() -- Refresh git status for the active file list
require('fff').find\_files\_in\_dir(path) -- Find files in a specific directory
require('fff').change\_indexing\_directory(new\_path) -- Change the base directory for the file picker
\`\`\`

just jump to the definition and see what other APIs are exposed we have a plenty

\#### Commands

FFF.nvim provides several commands for interacting with the file picker:

\- \`:FFFScan\` - Manually trigger a rescan of files in the current directory
\- \`:FFFRefreshGit\` - Manually refresh git status for all files
\- \`:FFFClearCache \[all\|frecency\|files\]\` - Clear various caches
\- \`:FFFHealth\` - Check FFF health status and dependencies
\- \`:FFFDebug \[on\|off\|toggle\]\` - Toggle debug scores display
\- \`:FFFOpenLog\` - Open the FFF log file in a new tab

\#### Debug Mode

Toggle scoring information display:

\- Press \`F2\` while in the picker
\- Use \`:FFFDebug\` command
\- Enable by default with \`debug.show\_scores = true\`

\#### Multi-Select and Quickfix Integration

Select multiple files and send them to Neovim's quickfix list (keymaps are configurable):

\- \`\` \- Toggle selection for the current file (shows thick border \`▊\` in signcolumn)
\- \`\` \- Send selected files to quickfix list and close picker

\#### Live Grep Search Modes

Live grep supports three search modes, cycled with \`\`:

\- \*\*Plain text\*\* (default) - The query is matched literally. Special regex characters like \`.\`, \`\*\`, \`(\`, \`)\`, \`$\` have no special meaning. This is the safest mode for searching code containing regex metacharacters.
\- \*\*Regex\*\* - The query is interpreted as a regular expression. Supports character classes (\`\[a-z\]\`), quantifiers (\`+\`, \`\*\`, \`{n}\`), alternation (\`foo\|bar\`), anchors (\`^\`, \`$\`), word boundaries (\`\\b\`), and more.
\- \*\*Fuzzy\*\* - The query is fuzzy matched using Smith-Waterman scoring. Accommodates typos and scattered characters (e.g., "mtxlk" matches "mutex\_lock"). Results are filtered by a quality threshold to avoid overly fuzzy matches.

The current mode is shown on the right side of the input field (e.g., \`plain\`, \`regex\`, \`fuzzy\`) with color-coded highlighting.

You can customize which modes are available and their cycling order globally in your configuration, or per-call when invoking \`live\_grep()\`.

\*\*Global configuration:\*\*

\`\`\`lua
require('fff').setup({
 grep = {
 modes = { 'plain', 'regex' }, -- Only plain and regex, no fuzzy
 }
})
\`\`\`

\*\*Per-call configuration:\*\*

\`\`\`lua
\-\- Only fuzzy and plain modes for this specific grep
require('fff').live\_grep({
 grep = {
 modes = { 'fuzzy', 'plain' },
 }
})

\-\- Single mode (hides mode indicator completely)
require('fff').live\_grep({
 grep = {
 modes = { 'fuzzy' },
 }
})

\-\- Pre-fill the search with an initial query
require('fff').live\_grep({ query = 'search term' })
\`\`\`

When only one mode is configured, the mode indicator is hidden completely and the cycle keybind does nothing.

\#### Constraints

There are a number of constraints you can use to refine your search in both grep and file search mode:

\- \`git:modified\` - show only modified files (one of \`modified\`, \`staged\`, \`deleted\`, \`renamed\`, \`untracked\`, \`ignored\`)
\- \`test/\` - any deeply nested children of any test/ dir
\- \`!something\` - exclude results matching something
\- \`!test/\`, \`!git:modified\` - combining with any other constraint works as negation
\- \`./\*\*/\*.{rs,lua}\` - any valid glob expression via \[the fastest globbing library\](https://github.com/dmtrKovalenko/zlob)

For grep only:

\- \`\*.md\`, \`\*.{c,h}\` - extension filtering
\- \`src/main.rs\` - grep in a single file

In addition to that, all constraints can be combined together like:

\`\`\`
git:modified src/\*\*/\*.rs !src/\*\*/mod.rs user controller
\`\`\`

This will find all the files that qualify the constraints and:

\- match \*\*both\*\* user and controller (for file mode)
\- match "user controller" (for grep mode)

\#### Cross-Mode Suggestions

When a search returns no results, FFF automatically queries the opposite search mode and displays the results as suggestions:

\- \*\*File search with no matches\*\* → shows suggested \*\*content matches\*\* (grep results) for the same query
\- \*\*Grep search with no matches\*\* → shows suggested \*\*file name matches\*\* for the same query

Suggestions are clearly labeled with a "No results found. Suggested ..." banner (highlighted with \`hl.suggestion\_header\`). You can navigate and select suggestion items just like normal results — selecting a grep suggestion will open the file at the matching line.

\#### Git Status Highlighting

FFF integrates with git to show file status through sign column indicators (enabled by default) and optional filename text coloring.

\*\*Sign Column Indicators\*\* (enabled by default) - Border characters shown in the sign column:

\`\`\`lua
hl = {
 git\_sign\_staged = 'FFFGitSignStaged',
 git\_sign\_modified = 'FFFGitSignModified',
 git\_sign\_deleted = 'FFFGitSignDeleted',
 git\_sign\_renamed = 'FFFGitSignRenamed',
 git\_sign\_untracked = 'FFFGitSignUntracked',
 git\_sign\_ignored = 'FFFGitSignIgnored',
}
\`\`\`

\*\*Text Highlights\*\* (opt-in) - Apply colors to filenames based on git status:

To enable git status text coloring, set \`git.status\_text\_color = true\`:

\`\`\`lua
require('fff').setup({
 git = {
 status\_text\_color = true, -- Enable git status colors on filename text
 },
 hl = {
 git\_staged = 'FFFGitStaged', -- Files staged for commit
 git\_modified = 'FFFGitModified', -- Modified unstaged files
 git\_deleted = 'FFFGitDeleted', -- Deleted files
 git\_renamed = 'FFFGitRenamed', -- Renamed files
 git\_untracked = 'FFFGitUntracked', -- New untracked files
 git\_ignored = 'FFFGitIgnored', -- Git-ignored files
 }
})
\`\`\`

The plugin provides sensible default highlight groups that link to common git highlight groups (e.g., GitSignsAdd, GitSignsChange). You can override these with your own custom highlight groups to match your colorscheme.

\*\*Example - Custom Bright Colors for Text:\*\*

\`\`\`lua
vim.api.nvim\_set\_hl(0, 'CustomGitModified', { fg = '#FFA500' })
vim.api.nvim\_set\_hl(0, 'CustomGitUntracked', { fg = '#00FF00' })

require('fff').setup({
 git = {
 status\_text\_color = true,
 },
 hl = {
 git\_modified = 'CustomGitModified',
 git\_untracked = 'CustomGitUntracked',
 }
})
\`\`\`

\#### File Filtering

FFF.nvim respects \`.gitignore\` patterns automatically. To filter files from the picker without modifying \`.gitignore\`, create a \`.ignore\` file in your project root:

\`\`\`gitignore
\# Exclude all markdown files
\*.md

\# Exclude specific subdirectory
docs/archive/\*\*/\*.md
\`\`\`

Run \`:FFFScan\` to force a rescan if needed.

\### Troubleshooting

\#### Health Check

Run \`:FFFHealth\` to check the status of FFF.nvim and its dependencies. This will verify:

\- File picker initialization status
\- Optional dependencies (git, image preview tools)
\- Database connectivity

\#### Viewing Logs

If you encounter issues, check the log file:

\`\`\`
:FFFOpenLog
\`\`\`

Or manually open the log file at \`~/.local/state/nvim/log/fff.log\` (default location).