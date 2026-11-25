PS1='' RPS1=''
unsetopt beep autolist automenu
fpath=($TAB_DIR/fpath $fpath)
autoload -Uz compinit && compinit -u -D
compadd() {
    if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
        builtin compadd "$@"; return $?
    fi
    local -a __hits
    builtin compadd -A __hits "$@"
    (( $#__hits )) && print -rl -- $__hits >>| $TAB_OUT
    builtin compadd "$@"
}
_tab() {
    : >>| $TAB_OUT
    zle complete-word
    print -r -- '<<DONE>>' >>| $TAB_OUT
    zle kill-whole-line
}
zle -N _tab
bindkey '^I' _tab
print READY
