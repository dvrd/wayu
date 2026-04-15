\# antidote

\[!\[MIT License\](https://img.shields.io/badge/license-MIT-007EC7.svg)\](/LICENSE)
!\[version\](https://img.shields.io/badge/version-v2.1.0-df5e88)

[![GetAntidote Logo](https://avatars.githubusercontent.com/u/101279220?s=80&v=4)](https://antidote.sh/ "GetAntidote")

\> \[Get the cure\]\[antidote\]

\[Antidote\]\[antidote\] is a feature-complete Zsh implementation of the legacy
\[Antibody\]\[antibody\] plugin manager, which in turn was derived from \[Antigen\]\[antigen\].
Antidote not only aims to provide continuity for those legacy plugin managers, but also
to delight new users with high-performance, easy-to-use Zsh plugin management.

\## Usage

Basic usage should look really familiar to you if you have used Antibody or Antigen.
Bundles (aka: Zsh plugins) are stored in a file typically called \`.zsh\_plugins.txt\`.

\`\`\`zsh
\# .zsh\_plugins.txt
rupa/z # some bash plugins work too
sindresorhus/pure # enhance your prompt

\# you can even use Oh My Zsh plugins
getantidote/use-omz
ohmyzsh/ohmyzsh path:lib
ohmyzsh/ohmyzsh path:plugins/extract

\# add fish-like features
zsh-users/zsh-syntax-highlighting
zsh-users/zsh-autosuggestions
zsh-users/zsh-history-substring-search
\`\`\`

A typical \`.zshrc\` might then look like:

\`\`\`zsh
\# .zshrc
source /path-to-antidote/antidote.zsh
antidote load ${ZDOTDIR:-$HOME}/.zsh\_plugins.txt
\`\`\`

The full documentation can be found at \[https://antidote.sh\]\[antidote\].

\## Help getting started

If you want to see a full-featured example Zsh configuration using antidote, you can
have a look at this \[example zdotdir\](https://github.com/getantidote/zdotdir) project.
Feel free to incorporate code or plugins from it into your own dotfiles, or you can fork
it to get started building your own Zsh config from scratch driven by antidote.

\## Installation

\### Install with git

You can install the latest release of antidote by cloning it with \`git\`:

\`\`\`zsh
\# first, run this from an interactive zsh terminal session:
git clone --depth=1 https://github.com/mattmc3/antidote.git ${ZDOTDIR:-$HOME}/.antidote
\`\`\`

\### Install with a package manager

antidote may also be available in your system's package manager:

\- \[macOS homebrew\](https://formulae.brew.sh/formula/antidote): \`brew install antidote\`
\- \[Arch AUR\](https://aur.archlinux.org/packages/zsh-antidote): \`yay -S zsh-antidote\`
\- \[Nix Home-Manager\](https://mipmip.github.io/home-manager-option-search/?query=antidote) : \`programs.zsh.antidote.enable = true;\`

\## Performance

antidote supports ultra-high performance plugin loads using a static plugin file.
It also allows deferred loading for \[plugins that support it\](https://github.com/romkatv/zsh-defer#caveats).

\`\`\`zsh
\# .zsh\_plugins.txt
\# some plugins support deferred loading
zdharma-continuum/fast-syntax-highlighting kind:defer
zsh-users/zsh-autosuggestions kind:defer
zsh-users/zsh-history-substring-search kind:defer
\`\`\`

\`\`\`zsh
\# .zshrc
\# Lazy-load antidote and generate the static load file only when needed
zsh\_plugins=${ZDOTDIR:-$HOME}/.zsh\_plugins
if \[\[ ! ${zsh\_plugins}.zsh -nt ${zsh\_plugins}.txt \]\]; then
 (
 source /path-to-antidote/antidote.zsh
 antidote bundle <${zsh\_plugins}.txt >${zsh\_plugins}.zsh
 )
fi
source ${zsh\_plugins}.zsh
\`\`\`

\## bat syntax highlighting

If you use \[bat\](https://github.com/sharkdp/bat), antidote includes a syntax definition
for \`.zsh\_plugins.txt\` files. To install it:

\`\`\`zsh
bat\_syntax\_dir="$(bat --config-dir)/syntaxes"
mkdir -p "$bat\_syntax\_dir"
curl -fsSL https://raw.githubusercontent.com/mattmc3/antidote/main/misc/zsh\_plugins.sublime-syntax \
 -o "$bat\_syntax\_dir/zsh\_plugins.sublime-syntax"
bat cache --build
\`\`\`

\## Benchmarks

You can see how antidote compares with other setups \[here\]\[benchmarks\].

\## Plugin authors

If you authored a Zsh plugin, the recommended snippet for antidote is:

\`\`\`zsh
antidote install gh\_user/gh\_repo
\`\`\`

If your plugin is hosted somewhere other than GitHub, you can use this:

\`\`\`zsh
antidote install https://bitbucket.org/bb\_user/bb\_repo
\`\`\`

\## Credits

A big thank you to \[Carlos\](https://github.com/caarlos0) for all his work on
\[antibody\] over the years.

\[antigen\]: https://github.com/zsh-users/antigen
\[antibody\]: https://github.com/getantibody/antibody
\[antidote\]: https://antidote.sh
\[benchmarks\]: https://github.com/romkatv/zsh-bench/blob/master/doc/linux-desktop.md
\[zsh\]: https://www.zsh.org