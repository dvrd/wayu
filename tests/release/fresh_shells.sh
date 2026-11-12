#!/bin/zsh -f
# Release check: `./build_it install` from a clean clone into an empty HOME,
# then the README rc lines for zsh/bash/fish: PATH, const, alias,
# completions in a new shell of each; doctor.
# usage: tests/release/fresh_shells.sh   (from the repo root, build_it built)
H=$(mktemp -d "${TMPDIR:-/tmp}/wayu-fresh.XXXXXX"); H=${H:A}; fails=0
git clone -q . $H/src && cp build_it $H/src/ &&
  (cd $H/src && env -i HOME=$H PATH=${$(command -v odin):h}:/usr/bin:/bin SHELL=/bin/zsh TERM=xterm NO_COLOR=1 ./build_it install >$H/install.log 2>&1) ||
  { print "install failed: $H/install.log"; exit 1 }
ok() { if [[ $1 == 0 ]]; then print "  ok    $2"; else print "  FAIL  $2"; fails=$((fails+1)); fi }
FISH=$(command -v fish)
P="$H/.local/bin:${FISH:h}:/usr/bin:/bin"
E=(env -i HOME=$H PATH=$P TERM=xterm-256color NO_COLOR=1)
mkdir -p $H/fresh-tools $H/.config/fish
print 'export PATH="$HOME/.local/bin:$PATH"' > $H/.zshrc
print 'source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"' >> $H/.zshrc
print 'export PATH="$HOME/.local/bin:$PATH"' > $H/.bashrc
print 'source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.bash"' >> $H/.bashrc
print 'if test -n "$WAYU_DATA_DIR"; source $WAYU_DATA_DIR/init.fish; else if test -n "$XDG_DATA_HOME"; source $XDG_DATA_HOME/wayu/init.fish; else; source ~/.local/share/wayu/init.fish; end' > $H/.config/fish/config.fish
$E SHELL=/bin/bash wayu init --shell bash </dev/null >/dev/null 2>&1; ok $? "init bash"
if [[ -n $FISH ]]; then $E SHELL=$FISH wayu init --shell fish </dev/null >/dev/null 2>&1; ok $? "init fish"; fi
$E SHELL=/bin/zsh wayu completions generate >/dev/null 2>&1;           ok $? "completions generate"
$E SHELL=/bin/zsh wayu path add $H/fresh-tools >/dev/null 2>&1;         ok $? "path add"
$E SHELL=/bin/zsh wayu alias add fz 'ls -1' >/dev/null 2>&1;            ok $? "alias add"
$E SHELL=/bin/zsh wayu const add FRESH_C fresh >/dev/null 2>&1;         ok $? "const add"
probe='case ":$PATH:" in *":'$H/fresh-tools':"*) echo PATHOK;; esac; [ "$FRESH_C" = fresh ] && echo CONSTOK; alias fz >/dev/null 2>&1 && echo ALIASOK'
for sh in zsh bash; do
  out=$($E SHELL=/bin/$sh /bin/$sh -i -c "$probe; $( [[ $sh == zsh ]] && print '(( $+_comps[wayu] )) && echo COMPOK' || print 'complete -p wayu >/dev/null 2>&1 && echo COMPOK')" 2>$H/err.$sh)
  for t in PATH CONST ALIAS COMP; do [[ $out == *${t}OK* ]]; ok $? "$sh new shell: $t"; done
  grep -v 'no job control' $H/err.$sh | sed "s/^/    $sh stderr: /" | head -5
done
if [[ -n $FISH ]]; then
  out=$($E SHELL=$FISH $FISH -i -c 'contains -- '$H/fresh-tools' $PATH; and echo PATHOK; test "$FRESH_C" = fresh; and echo CONSTOK; functions -q fz; and echo ALIASOK; complete -C"wayu pa" | string match -q "path*"; and echo COMPOK' 2>$H/err.fish)
  for t in PATH CONST ALIAS COMP; do [[ $out == *${t}OK* ]]; ok $? "fish new shell: $t"; done
  grep -v -E 'TERM|fallback|set up terminal' $H/err.fish | sed 's/^/    fish stderr: /' | head -5
fi
$E SHELL=/bin/zsh wayu doctor >$H/doc 2>&1;                              ok $? "doctor"
grep -E '✗|⚠' $H/doc | sed 's/^/    doctor: /' | head -8
if [[ $fails == 0 ]]; then
  print ALL OK
else
  print "$fails FAILED"
  exit 1
fi
