#!/bin/zsh
# Release check: upgrade from the previous release's binary to this build
# in a throwaway HOME with a fake `security` (never the real keychain):
# entries, secrets (keychain key move), a new shell, build, doctor. macOS.
# usage: tests/release/upgrade_from_release.sh [tag (default v6.0.0)] [new wayu (default bin/wayu)]
TAG=${1:-v6.0.0} NEW=${2:-$PWD/bin/wayu}
DL=$(mktemp -d "${TMPDIR:-/tmp}/wayu-rel.XXXXXX")
gh release download $TAG -R dvrd/wayu -p 'wayu-macos-arm64.tar.gz' -D $DL || exit 1
tar xzf $DL/wayu-macos-arm64.tar.gz -C $DL && V6=$DL/wayu
H=$(mktemp -d "${TMPDIR:-/tmp}/wayu-up.XXXXXX"); H=${H:A}
KC=$H/fake-keychain; mkdir -p $KC/bin $H/bin6 $H/binN $H/tools
cat > $KC/bin/security <<EOF
#!/bin/sh
cmd=\$1; shift; acct=; pw=
while [ \$# -gt 0 ]; do
  case \$1 in -a) acct=\$2; shift ;; -w) [ \$# -gt 1 ] && { pw=\$2; shift; } ;; -s|-l) shift ;; esac
  shift
done
case \$cmd in
  find-generic-password) [ -f "$KC/\$acct" ] || exit 44; cat "$KC/\$acct" ;;
  add-generic-password) printf '%s' "\$pw" > "$KC/\$acct" ;;
  delete-generic-password) rm -f "$KC/\$acct" ;;
  *) exit 1 ;;
esac
EOF
chmod +x $KC/bin/security
ln -s $V6 $H/bin6/wayu; ln -s $NEW $H/binN/wayu
fails=0
ok() { if [[ $1 == 0 ]]; then print "  ok    $2"; else print "  FAIL  $2"; fails=$((fails+1)); fi }
E=(env -i HOME=$H SHELL=/bin/zsh TERM=xterm-256color NO_COLOR=1 TMPDIR=$H/tmp/)
mkdir -p $H/tmp
v6() { $E PATH=$H/bin6:$KC/bin:/usr/bin:/bin "$@"; }
vn() { $E PATH=$H/binN:$KC/bin:/usr/bin:/bin "$@"; }

print "$TAG setup"
v6 wayu init --shell zsh >/dev/null 2>&1;                 ok $? "v6 init"
v6 wayu path add $H/tools >/dev/null 2>&1;                ok $? "v6 path add"
v6 wayu alias add upll 'ls -1' >/dev/null 2>&1;           ok $? "v6 alias add"
v6 wayu const add UP_PLAIN plainval >/dev/null 2>&1;      ok $? "v6 const add"
print fake-up-secret | v6 wayu const add UP_SECRET --secret >/dev/null 2>&1; ok $? "v6 const add --secret"
[[ -f $KC/wayu ]];                                        ok $? "v6 key in fake keychain account 'wayu'"
print 'source "$HOME/.local/share/wayu/init.zsh"' > $H/.zshrc
out=$(v6 zsh -ic 'print -r -- "S=$UP_SECRET P=$UP_PLAIN"' 2>/dev/null)
[[ $out == *"S=fake-up-secret P=plainval"* ]];            ok $? "v6 shell sees secret + const"

print "upgrade to $($NEW --version | head -1)"
# 1st new shell after the binary swap (brew upgrade): no command run yet.
rm -rf $H/tmp/* $H/.local/share/wayu/run 2>/dev/null; # no session cache: the key must be loaded (and moved)
out=$(vn zsh -ic 'print -r -- "S=$UP_SECRET P=$UP_PLAIN A=$(alias upll)"; case ":$PATH:" in *":'$H/tools':"*) print PATHOK;; esac' 2>$H/err1)
print "  first shell: ${out//$'\n'/ | }"; [[ -s $H/err1 ]] && sed 's/^/    stderr: /' $H/err1 | head -5
[[ $out == *"P=plainval"* && $out == *PATHOK* && $out == *"A=upll="* ]]; ok $? "first shell: const, alias, PATH"
[[ $out == *"S=fake-up-secret"* ]];                       ok $? "first shell: secret"
g=$(vn wayu const get UP_SECRET 2>$H/err2);               ok $? "const get secret"
[[ $g == fake-up-secret ]];                               ok $? "secret value decrypts"
ls $KC | grep -qE '^wayu-[0-9a-f]{16}$';                  ok $? "key moved to wayu-<id>"
[[ -f $KC/wayu ]];                                        ok $? "old item kept"
grep -q "moved the master key" $H/err1;           ok $? "one-time notice shown"
vn wayu build >/dev/null 2>$H/err3;                       ok $? "build"
[[ ! -s $H/err3 ]] || sed 's/^/    build stderr: /' $H/err3 | head -5
out=$(vn zsh -ic 'print -r -- "S=$UP_SECRET"' 2>$H/err4)
[[ $out == *"S=fake-up-secret"* ]];                       ok $? "next shell: secret"
grep -q 'moved' $H/err4;                                  [[ $? != 0 ]]; ok $? "next shell: no notice again"
vn wayu doctor >$H/doc 2>&1;                              ok $? "doctor exit 0"
grep -E '✗|⚠' $H/doc | sed 's/^/    doctor: /' | head -10
[[ $fails == 0 ]] && print "ALL OK ($H)" || print "$fails FAILED ($H)"
