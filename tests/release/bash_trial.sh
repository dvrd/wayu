#!/bin/sh
# OKAMI-193 bash trial: every bash found (macOS /bin/bash 3.2, Homebrew bash 5),
# each in a throwaway HOME (your real config and keychain are never touched).
# usage: sh tests/release/bash_trial.sh [path/to/wayu (default bin/wayu)]
W=${1:-$PWD/bin/wayu}
fails=0
for B in /bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
  [ -x "$B" ] || continue
  V=$("$B" -c 'echo $BASH_VERSION')
  H=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wayu-bash-trial.XXXXXX")" && pwd)
  mkdir -p "$H/bin-a" "$H/.config/wayu"
  printf '[secrets]\nbackend = "file"\n' > "$H/.config/wayu/wayu.toml"
  run() { env -i HOME="$H" PATH="$(dirname "$W"):/usr/bin:/bin" SHELL="$B" TERM=xterm-256color NO_COLOR=1 "$@"; }
  ok() { if [ "$1" = 0 ]; then echo "  ok    $2"; else echo "  FAIL  $2"; fails=$((fails + 1)); fi; }
  echo "bash $V ($B)"
  run "$W" init --shell bash >/dev/null 2>&1;                   ok $? "init"
  run "$W" completions generate >/dev/null 2>&1;                ok $? "completions generate"
  run "$W" --shell bash path add "$H/bin-a" >/dev/null 2>&1;    ok $? "path add"
  run "$W" --shell bash alias add trialls 'ls -1' >/dev/null 2>&1; ok $? "alias add"
  run "$W" --shell bash const add TRIAL_CONST hello >/dev/null 2>&1; ok $? "const add"
  printf 'fake-trial-secret\n' | run "$W" --shell bash const add TRIAL_SECRET --secret >/dev/null 2>&1
  ok $? "const add --secret"
  out=$(run "$B" -i -c '
    source ~/.local/share/wayu/init.bash
    case ":$PATH:" in *":$HOME/bin-a:"*) echo PATH_OK ;; esac
    alias trialls >/dev/null 2>&1 && echo ALIAS_OK
    [ "$TRIAL_CONST" = hello ] && echo CONST_OK
    [ "$TRIAL_SECRET" = fake-trial-secret ] && echo SECRET_OK
    complete -p wayu >/dev/null 2>&1 && echo COMPL_OK
    mkdir -p "$HOME/bin-b"; wayu --shell bash path add "$HOME/bin-b" >/dev/null 2>&1; _wayu_paths_sync
    case ":$PATH:" in *":$HOME/bin-b:"*) echo SYNC_OK ;; esac
  ' 2>"$H/stderr")
  for t in PATH ALIAS CONST SECRET COMPL SYNC; do
    case $out in *${t}_OK*) ok 0 "new shell: $t" ;; *) ok 1 "new shell: $t" ;; esac
  done
  [ -s "$H/stderr" ] && { echo "  shell stderr:"; sed 's/^/    /' "$H/stderr" | head -5; }
  run "$W" --shell bash doctor >/dev/null 2>&1;                 ok $? "doctor"
  rm -rf "$H"
done
[ "$fails" = 0 ] && echo "ALL OK" || echo "$fails FAILED"
