#!/bin/zsh
# Release check: upgrade from the previous release's binary to this build
# in a throwaway HOME with a fake `security` (never the real keychain):
# entries, secrets (keychain key move), a new shell, build, doctor. macOS.
# The new side is this checkout built with -define:WAYU_TEST_KEYSTORE=true,
# the only kind of build that takes its keychain program from
# WAYU_TEST_SECURITY_BIN (a release build always runs /usr/bin/security).
# usage: tests/release/upgrade_from_release.sh [tag (default v7.0.0; v6.0.0 also tests the keychain key move)]   (repo root)
TAG=${1:-v7.0.0}
DL=$(mktemp -d "${TMPDIR:-/tmp}/wayu-rel.XXXXXX")
gh release download $TAG -R dvrd/wayu -p 'wayu-macos-arm64.tar.gz' -D $DL || exit 1
tar xzf $DL/wayu-macos-arm64.tar.gz -C $DL && V6=$DL/wayu
H=$(mktemp -d "${TMPDIR:-/tmp}/wayu-up.XXXXXX"); H=${H:A}
KC=$H/fake-keychain; mkdir -p $KC/bin $H/bin6 $H/binN $H/tools
cat > $KC/bin/security <<EOF
#!/bin/sh
if [ "\$1" = -i ]; then IFS= read -r line; eval "set -- \$line"; fi
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
NEW=$H/wayu-test-keystore
odin build src -define:WAYU_TEST_KEYSTORE=true -out:$NEW || exit 1
ln -s $V6 $H/bin6/wayu; ln -s $NEW $H/binN/wayu
fails=0
ok() { if [[ $1 == 0 ]]; then print "  ok    $2"; else print "  FAIL  $2"; fails=$((fails+1)); fi }
E=(env -i HOME=$H SHELL=/bin/zsh TERM=xterm-256color NO_COLOR=1 TMPDIR=$H/tmp/)
mkdir -p $H/tmp
v6() { $E PATH=$H/bin6:$KC/bin:/usr/bin:/bin "$@"; }
vn() { $E PATH=$H/binN:$KC/bin:/usr/bin:/bin WAYU_TEST_SECURITY_BIN=$KC/bin/security "$@"; }

# A release from 7.0 on runs only /usr/bin/security (never a PATH lookup),
# so the fake keychain can't stand in for it: use the file backend there,
# or the run would reach the real keychain. 6.x finds `security` in PATH.
LEGACY_KC=0
if [[ ${${TAG#v}%%.*} -lt 7 ]]; then
  LEGACY_KC=1
else
  mkdir -p $H/.config/wayu
  printf '[secrets]\nbackend = "file"\n' > $H/.config/wayu/wayu.toml
fi

print "$TAG setup"
v6 wayu init --shell zsh >/dev/null 2>&1;                 ok $? "v6 init"
v6 wayu path add $H/tools >/dev/null 2>&1;                ok $? "v6 path add"
v6 wayu alias add upll 'ls -1' >/dev/null 2>&1;           ok $? "v6 alias add"
v6 wayu const add UP_PLAIN plainval >/dev/null 2>&1;      ok $? "v6 const add"
print fake-up-secret | v6 wayu const add UP_SECRET --secret >/dev/null 2>&1; ok $? "v6 const add --secret"
if (( LEGACY_KC )); then
[[ -f $KC/wayu ]];                                        ok $? "v6 key in fake keychain account 'wayu'"
fi
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
if (( LEGACY_KC )); then
ls $KC | grep -qE '^wayu-[0-9a-f]{16}$';                  ok $? "key moved to wayu-<id>"
[[ -f $KC/wayu ]];                                        ok $? "old item kept"
grep -q "moved the master key" $H/err1;           ok $? "one-time notice shown"
fi
vn wayu build >/dev/null 2>$H/err3;                       ok $? "build"
[[ ! -s $H/err3 ]] || sed 's/^/    build stderr: /' $H/err3 | head -5
out=$(vn zsh -ic 'print -r -- "S=$UP_SECRET"' 2>$H/err4)
[[ $out == *"S=fake-up-secret"* ]];                       ok $? "next shell: secret"
grep -q 'moved' $H/err4;                                  [[ $? != 0 ]]; ok $? "next shell: no notice again"
vn wayu doctor >$H/doc 2>&1;                              ok $? "doctor exit 0"
grep -E '✗|⚠' $H/doc | sed 's/^/    doctor: /' | head -10

print "multi-machine secrets (opt-in)"
S=$H/.local/share/wayu/secrets.json
grep -q '"version": 1' $S;                                ok $? "secrets.json still version 1 after the upgrade"
# A second machine (file backend) for its age recipient.
H2=$H/other; mkdir -p $H2/tmp
o2() { env -i HOME=$H2 SHELL=/bin/zsh NO_COLOR=1 TMPDIR=$H2/tmp/ PATH=/usr/bin:/bin $NEW "$@"; }
o2 init --shell zsh >/dev/null 2>&1 && print '\n[secrets]\nbackend = "file"' >> $H2/.config/wayu/wayu.toml
R2=$(o2 secrets identity 2>/dev/null);                    ok $? "other machine: identity"
# This machine by name first (a hostname that is an IP address gives none).
vn wayu secrets recipient add "$(vn wayu secrets identity 2>/dev/null)" --name this-mac >/dev/null 2>$H/err5; ok $? "recipient add (this machine)"
grep -q '"version": 2' $S;                                ok $? "secrets.json migrated to version 2"
grep -q 'is now version 2' $H/err5;                       ok $? "one-time upgrade notice"
vn wayu secrets recipient add $R2 --name other >$H/out5 2>&1; ok $? "recipient add (other machine)"
grep -q 'data key fingerprint' $H/out5;                   ok $? "recipient add prints the fingerprint"
grep -lq '"version": 1' $H/.local/share/wayu/backup/secrets/* 2>/dev/null; ok $? "version 1 copy in the backups"
out=$(vn zsh -ic 'print -r -- "S=$UP_SECRET"' 2>/dev/null)
[[ $out == *"S=fake-up-secret"* ]];                       ok $? "shell after the upgrade: secret"
cp $S $H/.local/share/wayu/entries.json $H2/.local/share/wayu/
o2 const get UP_SECRET >/dev/null 2>&1;                   [[ $? == 78 ]]; ok $? "other machine: 78 until it adopts"
o2 secrets adopt --yes >/dev/null 2>&1;                   ok $? "other machine: adopt --yes"
[[ $(o2 const get UP_SECRET 2>/dev/null) == fake-up-secret ]]; ok $? "other machine reads the secret"
[[ $fails == 0 ]] && print "ALL OK ($H)" || print "$fails FAILED ($H)"
