zmodload zsh/zpty zsh/zselect
zpty -b z zsh -f -i
zpty -w z "source ${(q)TAB_DIR}/init.zsh"
zpty -r z junk '*READY*'
for c in "${(@f)$(<$1)}"; do
    rm -f $TAB_OUT
    zpty -w -n z "$c"$'\t'
    integer k=0
    while ! { [[ -f $TAB_OUT ]] && grep -q '<<DONE>>' $TAB_OUT }; do
        zpty -rt z junk 2>/dev/null
        zselect -t 2
        (( ++k > 1500 )) && break
    done
    print -r -- "@@ $c"
    [[ -f $TAB_OUT ]] && grep -v '<<DONE>>' $TAB_OUT
done
zpty -d z
