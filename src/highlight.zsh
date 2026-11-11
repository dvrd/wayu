if [[ -o interactive && -o zle ]]; then
  function _wayu_hl_redraw {
    local -i _wayu_hl_ic=0 _wayu_hl_ac=0 _wayu_hl_bh=0
    [[ -o interactivecomments ]] && _wayu_hl_ic=1
    [[ -o autocd ]] && _wayu_hl_ac=1
    [[ -o banghist && ${histchars[1]} == \! ]] && _wayu_hl_bh=1
    emulate -L zsh
    setopt extendedglob
    # The text highlighted: the lines already entered at a continuation
    # prompt (PS2) and BUFFER; offsets are shifted by _wayu_hl_pre for zle.
    local _wayu_hl_t=$PREBUFFER$BUFFER
    local -i _wayu_hl_mb=1 _wayu_hl_pre=$#PREBUFFER
    [[ $_wayu_hl_t == *[^[:ascii:]]* ]] || { _wayu_hl_mb=0; setopt nomultibyte }
    local -i _wayu_hl_c=$(( CURSOR + _wayu_hl_pre ))
    if [[ $_wayu_hl_t != "$_wayu_hl_buf" || "$HISTCMD:$PWD:$PATH:$_wayu_hl_ic$_wayu_hl_bh$_wayu_hl_mb" != "$_wayu_hl_key" ]]; then
      # What is unchanged since the last run: the first _wayu_hl_keep and
      # the last _wayu_hl_suf characters (-1: nothing reusable). Words
      # before the change are not looked at again, and words after it are
      # taken over (shifted) once the state before one matches the last run.
      local -i _wayu_hl_keep=0 _wayu_hl_suf=-1 _wayu_hl_nobr=0
      if [[ "$HISTCMD:$PWD:$PATH:$_wayu_hl_ic$_wayu_hl_bh$_wayu_hl_mb" != "$_wayu_hl_key" ]]; then
        # A command ran, the directory / PATH / an option changed, or
        # multibyte offsets switched: lookups and offsets go stale.
        _wayu_hl_key="$HISTCMD:$PWD:$PATH:$_wayu_hl_ic$_wayu_hl_bh$_wayu_hl_mb"
        _wayu_hl_cmds=() _wayu_hl_paths=() _wayu_hl_dirs=()
      elif [[ $_wayu_hl_t == "$_wayu_hl_buf"* ]]; then
        _wayu_hl_keep=$#_wayu_hl_buf
      elif [[ $_wayu_hl_buf == "$_wayu_hl_t"* ]]; then
        _wayu_hl_keep=$#_wayu_hl_t
      else
        _wayu_hl_common
      fi
      if (( $#BUFFER && $#_wayu_hl_t <= 20000 )); then
        local -i _wayu_hl_len=$#_wayu_hl_t
        local REPLY
        _wayu_hl_line "$_wayu_hl_t" 0 0 0
        _wayu_hl_pair
      else
        _wayu_hl_res=() _wayu_hl_snap=() _wayu_hl_brk=() _wayu_hl_bres=() _wayu_hl_bpair=()
      fi
      _wayu_hl_buf=$_wayu_hl_t
    fi
    if (( _wayu_hl_memo )); then
      region_highlight=( "${(@)region_highlight:#*memo=wayu-highlight}" )
    elif (( $#_wayu_hl_prev )); then
      region_highlight=( "${(@)region_highlight:|_wayu_hl_prev}" )
    fi
    local -i n=$#region_highlight
    if (( _wayu_hl_pre )); then
      _wayu_hl_shift "${(@)_wayu_hl_res}" "${(@)_wayu_hl_bres}"
    else
      region_highlight+=( "${(@)_wayu_hl_res}" "${(@)_wayu_hl_bres}" )
    fi
    # The bracket under the cursor: its pair.
    local -i p=${_wayu_hl_bpair[$_wayu_hl_c]:--1}
    (( p >= _wayu_hl_pre )) && [[ -n $_wayu_hl_style[cursor-matchingbracket] ]] &&
      region_highlight+=( "$(( p - _wayu_hl_pre )) $(( p - _wayu_hl_pre + 1 )) $_wayu_hl_style[cursor-matchingbracket]" )
    # zle draws the region / search match / pasted text under
    # region_highlight: put them back on top (zle_highlight or zsh's default).
    if (( REGION_ACTIVE || ${ISEARCHMATCH_ACTIVE:-0} || ${YANK_ACTIVE:-0} )) && [[ $zle_highlight != none ]]; then
      local -i a b
      if (( REGION_ACTIVE )); then
        (( a = MARK < CURSOR ? MARK : CURSOR, b = MARK < CURSOR ? CURSOR : MARK ))
        if (( REGION_ACTIVE == 2 )); then
          local nl=$'\n'
          a=${BUFFER[(Ib:a:)$nl]} b=${BUFFER[(ib:b+1:)$nl]}-1
        elif [[ $KEYMAP == vicmd ]] && (( b < $#BUFFER )); then
          (( b++ )) # vi visual mode includes the character under the cursor
        fi
        _wayu_hl_zle region standout $a $b
      fi
      (( ${ISEARCHMATCH_ACTIVE:-0} )) && _wayu_hl_zle isearch underline $ISEARCHMATCH_START $ISEARCHMATCH_END
      (( ${YANK_ACTIVE:-0} )) && _wayu_hl_zle paste standout $YANK_START $YANK_END
    fi
    (( _wayu_hl_memo )) || _wayu_hl_prev=( "${(@)region_highlight[n+1,-1]}" )
    _wayu_hl_cur=$_wayu_hl_c
    return 0
  }
  # Add the entries $@ to region_highlight, shifted to BUFFER (what is on
  # the continuation lines dropped).
  function _wayu_hl_shift {
    local x
    local -i a b
    for x; do
      (( a = ${x%% *} - _wayu_hl_pre ))
      x=${x#* }
      (( b = ${x%% *} - _wayu_hl_pre ))
      (( b > 0 )) && region_highlight+=( "$(( a < 0 ? 0 : a )) $b ${x#* }" )
    done
  }
  # $1: zle_highlight context, $2: its default, $3 $4: the span.
  function _wayu_hl_zle {
    local st=${${(M)zle_highlight:#$1:*}#$1:}
    [[ ${st:=$2} == none ]] && return 0
    (( _wayu_hl_memo )) && st+=", memo=wayu-highlight"
    region_highlight+=( "$3 $4 $st" )
  }
  # _wayu_hl_keep / _wayu_hl_suf: a common prefix and (not overlapping
  # it) suffix of the text (_wayu_hl_t) and the last run's _wayu_hl_buf.
  # First a guess from the cursor before and after the edit (typing,
  # deleting, pasting at the cursor), else the longest ones (binary search).
  function _wayu_hl_common {
    local o=$_wayu_hl_buf t=$_wayu_hl_t
    local -i lo hi m c=$_wayu_hl_c
    (( lo = _wayu_hl_cur < c ? _wayu_hl_cur : c,
       hi = $#t - c < $#o - _wayu_hl_cur ? $#t - c : $#o - _wayu_hl_cur ))
    if (( lo >= 0 && hi > 0 && lo + hi <= ($#o < $#t ? $#o : $#t) )) &&
       [[ $t[1,lo] == "$o[1,lo]" && $t[-hi,-1] == "$o[-hi,-1]" ]]; then
      _wayu_hl_keep=lo _wayu_hl_suf=hi
      return 0
    fi
    lo=0
    (( hi = $#o < $#t ? $#o : $#t ))
    while (( lo < hi )); do
      (( m = (lo + hi + 1) / 2 ))
      if [[ $t[1,m] == "$o[1,m]" ]]; then lo=m; else (( hi = m - 1 )); fi
    done
    _wayu_hl_keep=lo
    (( hi = ($#o < $#t ? $#o : $#t) - lo, lo = 0 ))
    while (( lo < hi )); do
      (( m = (lo + hi + 1) / 2 ))
      if [[ $t[-m,-1] == "$o[-m,-1]" ]]; then lo=m; else (( hi = m - 1 )); fi
    done
    _wayu_hl_suf=lo
  }
  # Highlight $1 (at offset $2 of BUFFER) as command lines; $3: 1 inside
  # $(...) / <(...) (stop at an unmatched ")"), $4: nesting depth. Appends
  # to _wayu_hl_res (and brackets to _wayu_hl_brk: "offset char"); REPLY:
  # where it stopped in $1. Words come from zsh's own lexer (${(z)...}),
  # which keeps each word as typed (unterminated quotes included): each is
  # found in $1 by skipping blanks. State: 1 command position, 2 arguments,
  # 3 after a precommand (options, then a command), 4 redirection target,
  # 5 inside [[ ]], 6 a name (for, case, function), 7 case patterns, 8
  # inside name=( ), 9 a precommand option's argument, 10 the words of
  # `for name (...)`, 11 typeset & co.'s arguments, 12 inside `for ((...))`,
  # 13 the target of >& / <& (a file descriptor). ng: 1 after noglob.
  #
  # For BUFFER itself (top), the state before each word is kept in
  # _wayu_hl_snap ("offset results brackets state ..."), so the next run
  # starts at the last word that ends before the changed text
  # (_wayu_hl_keep) instead of the start, and once past the change takes
  # over the last run's results for the rest (_wayu_hl_resync): a keystroke
  # anywhere in a long line costs a word or two, not the whole line.
  function _wayu_hl_line {
    local str=$1 tok c st cmd pre= nt= d line nl=$'\n'
    local -i base=$2 nested=$3 lvl=$4 pos=0 s e n ti=1 p q state=1 after=2 saved=1 depth=0 casep=0 braces=0 ng=0 k
    local -i top=$(( ! base && ! nested && ! lvl )) rsfrom=-1 delta dt
    local -a toks hd f ores osnap obrk otoks
    if (( _wayu_hl_ic )); then toks=( ${(Z+c+)str} ); else toks=( ${(z)str} ); fi
    if (( top )); then
      if (( _wayu_hl_suf > 0 )); then
        # The last run's words from the unchanged end on, to take over.
        (( rsfrom = $#str - _wayu_hl_suf, delta = $#str - $#_wayu_hl_buf, dt = $#toks - $#_wayu_hl_toks ))
        ores=( "${(@)_wayu_hl_res}" ) osnap=( "${(@)_wayu_hl_snap}" ) obrk=( "${(@)_wayu_hl_brk}" ) otoks=( "${(@)_wayu_hl_toks}" )
      fi
      # Resume at word r: words r-1 and r (r-1 looked ahead at r) end
      # before the change, so they and everything before are unchanged.
      if (( _wayu_hl_keep )); then
        for (( k = $#_wayu_hl_snap; k > 2; k-- )); do
          [[ $_wayu_hl_snap[k] != x ]] && (( ${_wayu_hl_snap[k]%% *} < _wayu_hl_keep )) && break
        done
        (( k-- ))
        if (( k >= 2 )) && [[ $_wayu_hl_snap[k] != x && $toks[k] == "$_wayu_hl_toks[k]" ]]; then
          f=( ${=_wayu_hl_snap[k]} )
          pos=f[1] state=f[4] after=f[5] saved=f[6] depth=f[7] casep=f[8] braces=f[9] ng=f[10]
          pre=${f[11]#-} nt=${f[12]#-}
          _wayu_hl_res[f[2]+1,-1]=()
          _wayu_hl_brk[f[3]+1,-1]=()
          _wayu_hl_snap[k,-1]=()
          ti=k
        fi
      fi
      if (( ti == 1 )); then
        _wayu_hl_res=() _wayu_hl_snap=() _wayu_hl_brk=()
      fi
      _wayu_hl_toks=( "${toks[@]}" )
    fi
    for (( ; ti <= $#toks; ti++ )); do
      tok=$toks[ti]
      if (( top )); then
        if (( $#hd )); then _wayu_hl_snap[ti]=x
        else
          _wayu_hl_snap[ti]="$pos $#_wayu_hl_res $#_wayu_hl_brk $state $after $saved $depth $casep $braces $ng ${pre:--} ${nt:--}"
          if (( rsfrom >= 0 && pos >= rsfrom )) && _wayu_hl_resync; then
            REPLY=$#str
            return 0
          fi
        fi
      fi
      c=$str[pos+1]
      if [[ $c == [[:blank:]] ]]; then
        (( pos++ ))
        c=$str[pos+1]
      fi
      while [[ $c == [[:blank:]\\$nl] ]]; do
        if [[ $c == [[:blank:]] ]]; then (( pos++ ))
        elif [[ $c == \\ && $str[pos+2] == $nl ]]; then (( pos += 2 ))
        elif [[ $c == $nl && $tok != \; ]]; then (( pos++ ))
        else break; fi
        c=$str[pos+1]
      done
      n=$#tok
      if [[ $str[pos+1,pos+n] != "$tok" ]]; then
        # The lexer turns a newline into ";" and "&!" into "&|". Anything
        # else: lost track.
        if [[ $tok == \; && $c == $nl ]]; then n=1
        elif [[ $tok != '&|' || $str[pos+1,pos+2] != '&!' ]]; then REPLY=$#str; return 0; fi
      fi
      (( s = base + pos, e = s + n, pos += n ))
      if (( $#hd )) && [[ $c == $nl && $tok == \; ]]; then
        # Heredoc bodies follow this newline: skip them, the rest is a new
        # command line.
        p=pos
        for d in $hd; do
          while :; do
            q=${str[(ib:p+1:)$nl]}
            line=${str[p+1,q-1]}
            [[ $d == 1* ]] && line=${line##$'\t'#}
            p=q
            [[ $line == "${d#?}" ]] && break
            (( q > $#str )) && { REPLY=$#str; return 0 }
          done
        done
        (( p >= $#str )) && { REPLY=$#str; return 0 }
        _wayu_hl_line "${str[p+1,-1]}" $(( base + p )) $nested $lvl
        (( REPLY += p ))
        return 0
      fi
      if (( state == 4 || state == 13 )); then
        [[ -n $nt ]] && hd+=( "$nt${(Q)tok}" ) nt=
        if (( state == 13 )) && [[ $tok == (<->|-|p) ]]; then
          [[ -n ${st::=$_wayu_hl_style[numeric-fd]} ]] && _wayu_hl_res+=( "$s $e $st" )
        else
          _wayu_hl_arg $tok $s $lvl
        fi
        state=$saved
        continue
      fi
      case $tok in
        (\;|\&\&|\|\||\||\|\&|\&|\&\||\&\!|\;\;|\;\&|\;\|)
          if (( state == 5 )); then
            [[ $tok == (\&\&|\|\|) && -n ${st::=$_wayu_hl_style[commandseparator]} ]] && _wayu_hl_res+=( "$s $e $st" )
            continue
          fi
          (( state == 7 || state == 8 || state == 10 || state == 12 )) && continue
          [[ -n ${st::=$_wayu_hl_style[commandseparator]} ]] && _wayu_hl_res+=( "$s $e $st" )
          state=1 pre= ng=0
          (( casep == 2 )) && [[ $tok == \;[\;\&\|] ]] && state=7
          continue ;;
        ((<->|)(\&|)[\<\>][\<\>\|\!\&-]#)
          [[ -n ${st::=$_wayu_hl_style[redirection]} ]] && _wayu_hl_res+=( "$s $e $st" )
          [[ $tok == \<\< ]] && nt=0
          [[ $tok == \<\<- ]] && nt=1
          (( state == 4 || state == 13 )) || saved=$state
          state=4
          [[ $tok == *[\<\>]\& ]] && state=13
          continue ;;
        (\))
          if (( state == 8 )); then
            # The end of name=( ... ).
            [[ -n ${st::=$_wayu_hl_style[assign]} ]] && _wayu_hl_res+=( "$s $e $st" )
            state=$saved
            continue
          fi
          if (( state == 10 )); then
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s )" )
            state=1
            continue
          fi
          if (( nested && ! depth && state != 7 )); then
            REPLY=$(( pos - 1 ))
            return 0
          fi
          (( state == 5 )) && continue
          [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
          if (( state == 7 )); then
            state=1
          else
            (( depth-- ))
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s )" )
            state=2
          fi
          continue ;;
        (\(|\(\))
          (( state == 5 )) && continue
          if (( state == 7 )); then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            continue
          fi
          if [[ $tok == \( ]] && (( state == 2 )) && [[ $toks[ti-2] == (for|foreach|select) ]]; then
            # for name (words) ...
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s (" )
            state=10
            continue
          fi
          if [[ $tok == \( ]]; then
            (( depth++ ))
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s (" )
          fi
          [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
          state=1
          continue ;;
        (\})
          if (( braces && state != 5 )); then
            (( braces-- ))
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s }" )
            state=2
            continue
          fi ;;
        (\]\])
          if (( state == 5 )); then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            state=2
            continue
          fi ;;
        (\#*)
          if (( _wayu_hl_ic )); then
            [[ -n ${st::=$_wayu_hl_style[comment]} ]] && _wayu_hl_res+=( "$s $e $st" )
            continue
          fi ;;
        (\{[[:alpha:]_][[:alnum:]_]#\})
          if [[ $toks[ti+1] == (<->|)(\&|)[\<\>]* ]]; then
            [[ -n ${st::=$_wayu_hl_style[named-fd]} ]] && _wayu_hl_res+=( "$s $e $st" )
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s {" "$(( e - 1 )) }" )
            continue
          fi ;;
      esac
      case $state in
        ([13]) ;;
        (6)
          if [[ $tok == \(\( && $toks[ti-1] == for ]]; then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            state=12
          else
            _wayu_hl_arg $tok $s $lvl
            state=$after
          fi
          continue ;;
        (9) _wayu_hl_arg $tok $s $lvl; state=3; continue ;;
        (7)
          if [[ $tok == esac ]]; then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            casep=0 state=2
          elif [[ $tok == \(?* ]]; then
            # (pattern) as one word.
            st=$_wayu_hl_style[reserved-word]
            [[ -n $st ]] && _wayu_hl_res+=( "$s $(( s + 1 )) $st" )
            if [[ $tok == *[^\\]\) ]]; then
              (( n > 2 )) && _wayu_hl_arg "${tok[2,-2]}" $(( s + 1 )) $lvl
              [[ -n $st ]] && _wayu_hl_res+=( "$(( e - 1 )) $e $st" )
              state=1
            else
              _wayu_hl_arg "${tok[2,-1]}" $(( s + 1 )) $lvl
            fi
          else
            _wayu_hl_arg $tok $s $lvl
          fi
          continue ;;
        (10) _wayu_hl_arg $tok $s $lvl; continue ;;
        (12)
          if [[ $tok == \)\) ]]; then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            state=2
          else
            _wayu_hl_brs $tok 1 $n $s
          fi
          continue ;;
        (11)
          if [[ $tok == [[:alpha:]_][[:alnum:]_]#(\[*\]|)(+|)=* ]]; then
            _wayu_hl_assign
            continue
          fi ;&
        (*)
          if (( casep == 1 )) && [[ $tok == in ]]; then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            casep=2 state=7
          elif [[ $tok == always && $toks[ti-1] == \} ]]; then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            state=1
          elif [[ -n $galiases[$tok] ]]; then
            [[ -n ${st::=$_wayu_hl_style[global-alias]} ]] && _wayu_hl_res+=( "$s $e $st" )
          elif [[ $tok == -?* && $tok != *[\\\'\"\$\`]* ]]; then
            [[ $tok == --* ]] && st=$_wayu_hl_style[double-hyphen-option] || st=$_wayu_hl_style[single-hyphen-option]
            [[ -n $st ]] && _wayu_hl_res+=( "$s $e $st" )
          elif [[ $tok != *[\\\'\"\$\`\*\?\[\]\(\)\{\}\!\<\>=\~]* ]] && (( e != _wayu_hl_len )); then
            # A plain word: an existing path? (cached)
            st=$_wayu_hl_paths[$tok]
            if [[ -z $st ]]; then
              st=-
              [[ -e $tok ]] && st=path
              _wayu_hl_paths[$tok]=$st
            fi
            [[ $st == path && -n ${st::=$_wayu_hl_style[path]} ]] && _wayu_hl_res+=( "$s $e $st" )
          else
            _wayu_hl_arg $tok $s $lvl
          fi
          continue ;;
      esac
      # Command position.
      if (( state == 3 )) && [[ $tok == -?* ]]; then
        _wayu_hl_arg $tok $s $lvl
        if [[ $tok == -- ]]; then state=1
        elif [[ $pre:$tok == (sudo:|doas:)-[ugCDhpRrtTU] || $pre:$tok == (env:-[uCSP]|exec:-a|nice:-n) ]]; then state=9
        fi
        continue
      fi
      if [[ $tok == [[:alpha:]_][[:alnum:]_]#(\[*\]|)(+|)=* ]]; then
        _wayu_hl_assign
        continue
      fi
      if [[ $tok == \(\(* ]]; then
        if [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]]; then
          _wayu_hl_res+=( "$s $(( s + 2 )) $st" )
          [[ $tok == *\)\) ]] && _wayu_hl_res+=( "$(( e - 2 )) $e $st" )
        fi
        if [[ $tok == *\)\) ]]; then _wayu_hl_brs $tok 3 $(( n - 2 )) $s
        else _wayu_hl_brs $tok 3 $n $s; fi
        state=2
        continue
      fi
      if (( $+_wayu_hl_resw[$tok] )); then
        state=1 st=reserved-word
        case $tok in
          (declare|export|float|integer|local|readonly|typeset) st=builtin state=11 ;;
          (\[\[) state=5 ;;
          (for|foreach|select) state=6 after=2 ;;
          (function) state=6 after=1 ;;
          (repeat) state=6 after=1 ;;
          (case) state=6 after=2 casep=1 ;;
          (time|nocorrect) st=precommand state=3 pre=$tok ;;
          (\{)
            (( braces++ ))
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s {" ) ;;
          (\})
            (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$s }" )
            state=2 ;;
          (done|fi|esac|end) state=2 ;;
        esac
        [[ -n ${st::=$_wayu_hl_style[$st]} ]] && _wayu_hl_res+=( "$s $e $st" )
        continue
      fi
      state=2 pre=
      [[ $toks[ti+1] == '()' ]] && continue # a function definition's name
      if [[ $tok == *[\$\`]* ]] || { (( _wayu_hl_bh )) && [[ $tok == \![^[:space:]=\(]* ]] }; then
        _wayu_hl_scan $tok $s $lvl
        continue
      fi
      cmd=$tok
      [[ $tok == *[\\\'\"]* ]] && cmd=${(Q)tok}
      st=$_wayu_hl_cmds[$tok]
      if [[ -z $st ]]; then
        if [[ $cmd == $tok && -n $aliases[$cmd] ]]; then st=alias
        elif [[ $cmd == $tok && -n $galiases[$cmd] ]]; then st=global-alias
        elif [[ $cmd == (command|builtin|exec|noglob|-) ]] ||
             [[ $cmd == (sudo|doas|env|nohup|nice) && -n $commands[$cmd] ]]; then
          st=precommand
        elif [[ -n $functions[$cmd] ]]; then st=function
        elif [[ -n $builtins[$cmd] ]]; then st=builtin
        elif [[ $cmd == */* ]]; then
          [[ $tok == \~* ]] && _wayu_hl_tilde $cmd && cmd=$REPLY
          if [[ -x $cmd && ! -d $cmd ]]; then st=command
          elif (( _wayu_hl_ac )) && [[ -d $cmd ]]; then st=autodirectory
          else st=unknown-token; fi
        elif [[ -n $commands[$cmd] ]]; then st=command
        elif [[ $tok == \=?* && -n $commands[${cmd#=}] ]]; then st=command # =cmd (EQUALS)
        elif [[ $cmd == ?*.?* && -n $saliases[${cmd##*.}] ]]; then st=suffix-alias
        elif (( _wayu_hl_ac )) && [[ -d $cmd ]]; then st=autodirectory
        else st=unknown-token; fi
        _wayu_hl_cmds[$tok]=$st
      fi
      if [[ $st == precommand ]]; then
        state=3 pre=$cmd
        [[ $cmd == noglob ]] && ng=1
      fi
      [[ -n ${st::=$_wayu_hl_style[$st]} ]] && _wayu_hl_res+=( "$s $e $st" )
    done
    REPLY=$#str
    return 0
  }
  # NAME=value / NAME[sub]=value / NAME=( (the word tok at s..e, in
  # _wayu_hl_line): assign, the value highlighted as an argument.
  function _wayu_hl_assign {
    local -i k=$#_wayu_hl_res q=${tok[(i)=]} b=${tok[(i)[\[]]}
    (( b < q )) && _wayu_hl_brs $tok $b $(( q - 1 )) $s
    if [[ $tok == *=\( ]]; then
      saved=$state state=8
    elif [[ $tok == *=\(*\) ]]; then
      # typeset name=(...) is one word.
      (( q + 1 < n - 1 )) && _wayu_hl_scan "${tok[q+2,-2]}" $(( s + q + 1 )) $lvl
    elif (( q < n )); then
      _wayu_hl_arg "${tok[q+1,-1]}" $(( s + q )) $lvl
    fi
    [[ -n ${st::=$_wayu_hl_style[assign]} ]] && _wayu_hl_res[k+1,k]=( "$s $e $st" )
  }
  # Take over the last run's results from word ti on (dynamic scope: the
  # locals of _wayu_hl_line): the text from pos on is unchanged, and when
  # the state before the word is the one the last run had there and the
  # words left are the same, so is everything after, shifted by delta.
  function _wayu_hl_resync {
    local -i k=$(( ti - dt )) dres dbrk
    local x
    local -a g h
    if (( k < 1 || k > $#osnap )); then
      (( k > $#osnap )) && rsfrom=-1
      return 1
    fi
    x=$osnap[k]
    [[ $x != x && ${x#* * * } == "${_wayu_hl_snap[ti]#* * * }" ]] || return 1
    g=( ${=x} ) h=( ${=_wayu_hl_snap[ti]} )
    (( g[1] + delta == pos )) || return 1
    [[ ${(pj:\0:)toks[ti,-1]} == "${(pj:\0:)otoks[k,-1]}" ]] || { rsfrom=-1; return 1 }
    (( dres = h[2] - g[2], dbrk = h[3] - g[3] ))
    # The offsets at the start of each entry, shifted (the replacement is
    # expanded per element).
    local -a match mbegin mend
    _wayu_hl_res+=( "${(@)ores[g[2]+1,-1]/(#b)(#s)(<->) (<->)/$(( match[1] + delta )) $(( match[2] + delta ))}" )
    _wayu_hl_brk+=( "${(@)obrk[g[3]+1,-1]/(#b)(#s)(<->)/$(( match[1] + delta ))}" )
    _wayu_hl_snap[ti,-1]=( "${(@)osnap[k,-1]/(#b)(#s)(<->) (<->) (<->)/$(( match[1] + delta )) $(( match[2] + dres )) $(( match[3] + dbrk ))}" )
    return 0
  }
  # Bracket entries (_wayu_hl_bres) for _wayu_hl_brk: matched pairs by
  # nesting level, the rest bracket-error; _wayu_hl_bpair: offset -> the
  # offset of its pair.
  function _wayu_hl_pair {
    local x c o st lk
    local -a sp sc lv=( bracket-level-1 bracket-level-2 bracket-level-3 )
    local -i p l
    _wayu_hl_bres=() _wayu_hl_bpair=()
    for x in "${(@on)_wayu_hl_brk}"; do
      p=${x%% *} c=${x#* }
      if [[ $c == [\(\[\{] ]]; then
        sp+=( $p ) sc+=( $c )
        continue
      fi
      if (( ! $#sp )); then
        [[ -n ${st::=$_wayu_hl_style[bracket-error]} ]] && _wayu_hl_bres+=( "$p $(( p + 1 )) $st" )
        continue
      fi
      o=$sc[-1] l=$#sp
      if [[ $o$c == (\(\)|\[\]|\{\}) ]]; then
        (( l = (l - 1) % 3 + 1 )); lk=$lv[l] st=$_wayu_hl_style[$lk]
        _wayu_hl_bpair[$p]=$sp[-1] _wayu_hl_bpair[$sp[-1]]=$p
      else
        st=$_wayu_hl_style[bracket-error]
      fi
      [[ -n $st ]] && _wayu_hl_bres+=( "$sp[-1] $(( sp[-1] + 1 )) $st" "$p $(( p + 1 )) $st" )
      sp[-1]=() sc[-1]=()
    done
    if [[ -n ${st::=$_wayu_hl_style[bracket-error]} ]]; then
      for p in $sp; do _wayu_hl_bres+=( "$p $(( p + 1 )) $st" ); done
    fi
  }
  # Brackets in $1 from index $2 to $3 (offset $4): ( ) [ ] { } as they
  # are (insides of ${...}, $((...)), subscripts).
  function _wayu_hl_brs {
    (( _wayu_hl_nobr )) && return 0
    local w=$1
    local -i i=$2 n=$3 s=$4
    while (( i <= n )); do
      i=${w[(ib:i:)[\(\)\[\]\{\}]]}
      (( i > n )) && break
      _wayu_hl_brk+=( "$(( s + i - 1 )) $w[i]" )
      (( i++ ))
    done
  }
  # REPLY: $1 with a leading ~ or ~name expanded.
  function _wayu_hl_tilde {
    local h=${1%%/*} d
    if [[ $h == \~ ]]; then d=$HOME
    else d=${nameddirs[${h#\~}]:-${userdirs[${h#\~}]}}; fi
    if [[ -n $d ]]; then REPLY=$d${1#$h}; else REPLY=$1; fi
  }
  # An argument word $1 at offset $2 ($3: depth): options, quoting,
  # expansions, globs, existing paths (path_prefix: the last word typed so
  # far starts an existing name).
  function _wayu_hl_arg {
    local w=$1 p st=
    local -i s=$2 e=$2+$#1 k=$#_wayu_hl_res
    if [[ $w == *[\\\'\"\$\`\*\?\[\]\(\)\{\}\!\<\>=]* ]]; then
      _wayu_hl_scan $w $s $3
      (( REPLY )) || p=${(Q)w}
    else
      p=$w
    fi
    if [[ $w == --?* ]]; then st=double-hyphen-option
    elif [[ $w == -?* ]]; then st=single-hyphen-option
    elif [[ -n $p ]]; then
      [[ $w == \~* ]] && _wayu_hl_tilde $p && p=$REPLY
      if [[ -e $p ]]; then st=path
      elif (( e == _wayu_hl_len )) && [[ $p != */ ]]; then
        # Names in the word's directory, read once (until a command runs).
        local dir=${p:h} ls nl=$'\n'
        ls=$_wayu_hl_dirs[$dir]
        if [[ -z $ls ]]; then
          local -a m
          m=( $dir/*(DN:t) )
          ls=$nl${(pj:\n:)m}$nl
          _wayu_hl_dirs[$dir]=$ls
        fi
        [[ $ls == *$nl${p:t}* ]] && st=path_prefix
      fi
    fi
    [[ -n $st && -n ${st::=$_wayu_hl_style[$st]} ]] && _wayu_hl_res[k+1,k]=( "$s $e $st" )
    return 0
  }
  # Quoting, expansions, history expansions and brackets inside the word
  # $1 at offset $2 ($3: depth). REPLY: 1 when it has an unquoted
  # expansion or glob (no path check).
  function _wayu_hl_scan {
    local w=$1 st
    local -i s=$2 lvl=$3 i=1 n=$#1 j k=$#_wayu_hl_res fl=0 g=0 br=1
    # [ ] [[ ]] as words are commands / test syntax, not brackets.
    [[ $w == (\[|\]|\[\[|\]\]) ]] && br=0
    while (( i <= n )); do
      i=${w[(ib:i:)[\\\'\"\$\`\*\?\[\]\(\)\{\}\!\<\>=]]}
      (( i > n )) && break
      case $w[i] in
        (\\) (( i += 2 )) ;;
        (\')
          j=${w[(ib:i+1:)[\']]}
          [[ -n ${st::=$_wayu_hl_style[single-quoted-argument]} ]] &&
            _wayu_hl_res+=( "$(( s + i - 1 )) $(( s + (j > n ? n : j) )) $st" )
          (( i = j + 1 )) ;;
        (\")
          _wayu_hl_dq $w $i $s $lvl
          i=REPLY ;;
        (\$)
          if [[ $w[i+1] == \' ]]; then
            _wayu_hl_dollar_quote $w $i $s
          else
            _wayu_hl_dollar $w $i $s $lvl 0
            fl=1
          fi
          i=REPLY ;;
        (\`)
          _wayu_hl_bq $w $i $s $lvl
          i=REPLY fl=1 ;;
        ([\<\>=])
          if (( i == 1 )) && [[ $w[2] == \( ]]; then
            _wayu_hl_sub $w 1 $s $lvl process-substitution-delimiter
            i=REPLY fl=1
          else
            (( i++ ))
          fi ;;
        (\!)
          if (( _wayu_hl_bh )); then
            _wayu_hl_hist $w $i $s
            (( REPLY > i + 1 )) && fl=1
            i=REPLY
          else
            (( i++ ))
          fi ;;
        (\[)
          [[ $w[i+1,-1] == *\]* ]] && g=1
          (( br && ! _wayu_hl_nobr )) && _wayu_hl_brk+=( "$(( s + i - 1 )) [" )
          (( i++ )) ;;
        ([\]\(\)\{\}])
          (( br && ! _wayu_hl_nobr )) && _wayu_hl_brk+=( "$(( s + i - 1 )) $w[i]" )
          (( i++ )) ;;
        (*) g=1; (( i++ )) ;;
      esac
    done
    (( g && ! ng )) && [[ -n ${st::=$_wayu_hl_style[globbing]} ]] && _wayu_hl_res[k+1,k]=( "$s $(( s + n )) $st" )
    REPLY=$(( fl || g ))
  }
  # A history expansion at the "!" at index $2 of $1 (offset $3): !! !$
  # !^ !* !# !n !-n !str !?str? !{...}; REPLY: index after it ($2 + 1 when
  # the "!" is not one).
  function _wayu_hl_hist {
    local w=$1 st
    local -i i=$2 s=$3 n=$#1 j
    case $w[i+1] in
      ([\!\$\^\*\#]) (( j = i + 2 )) ;;
      (-) j=${w[(ib:i+2:)[^0-9]]} ;;
      (\{) j=${w[(ib:i+2:)[\}]]}; (( j++ )) ;;
      (\?) j=${w[(ib:i+2:)[?]]}; (( j++ )) ;;
      ([[:space:]=\(\"]|) REPLY=$(( i + 1 )); return 0 ;;
      (*) j=${w[(ib:i+1:)[[:space:]\;\&\|\<\>\(\)\[\]\{\}\'\"\`\$:]]} ;;
    esac
    (( j > n + 1 )) && j=n+1
    if (( j <= i + 1 )); then REPLY=$(( i + 1 )); return 0; fi
    [[ -n ${st::=$_wayu_hl_style[history-expansion]} ]] && _wayu_hl_res+=( "$(( s + i - 1 )) $(( s + j - 1 )) $st" )
    REPLY=$j
  }
  # "..." at index $2 of $1 (offset $3, depth $4); REPLY: index after it.
  # Brackets inside are not counted.
  function _wayu_hl_dq {
    local w=$1 st b=$_wayu_hl_style[back-double-quoted-argument]
    local -i i=$2 s=$3 n=$#1 j=$2+1 k=$#_wayu_hl_res _wayu_hl_nobr=1
    while (( j <= n )); do
      j=${w[(ib:j:)[\"\\\$\`\!]]}
      (( j > n )) && break
      case $w[j] in
        (\") break ;;
        (\\)
          [[ $w[j+1] == [\\\$\`\"] && -n $b ]] && _wayu_hl_res+=( "$(( s + j - 1 )) $(( s + j + 1 )) $b" )
          (( j += 2 )) ;;
        (\$) _wayu_hl_dollar $w $j $s $4 1; j=REPLY ;;
        (\`) _wayu_hl_bq $w $j $s $4; j=REPLY ;;
        (\!)
          if (( _wayu_hl_bh )); then
            _wayu_hl_hist $w $j $s
            j=REPLY
          else
            (( j++ ))
          fi ;;
      esac
    done
    [[ -n ${st::=$_wayu_hl_style[double-quoted-argument]} ]] &&
      _wayu_hl_res[k+1,k]=( "$(( s + i - 1 )) $(( s + (j > n ? n : j) )) $st" )
    REPLY=$(( j + 1 ))
  }
  # $'...' at index $2 of $1 (offset $3); REPLY: index after it.
  function _wayu_hl_dollar_quote {
    local w=$1 st b=$_wayu_hl_style[back-dollar-quoted-argument]
    local -i i=$2 s=$3 n=$#1 j=$2+2 k=$#_wayu_hl_res
    while (( j <= n )); do
      j=${w[(ib:j:)[\\\']]}
      [[ $w[j] == \\ ]] || break
      [[ -n $b ]] && _wayu_hl_res+=( "$(( s + j - 1 )) $(( s + (j < n ? j + 1 : n) )) $b" )
      (( j += 2 ))
    done
    [[ -n ${st::=$_wayu_hl_style[dollar-quoted-argument]} ]] &&
      _wayu_hl_res[k+1,k]=( "$(( s + i - 1 )) $(( s + (j > n ? n : j) )) $st" )
    REPLY=$(( j + 1 ))
  }
  # $var ${...} $((...)) $[...] $(...) at index $2 of $1 (offset $3, depth
  # $4; $5: 1 inside "..."); REPLY: index after it.
  function _wayu_hl_dollar {
    local w=$1 st=$_wayu_hl_style[expansion]
    local -i i=$2 s=$3 n=$#1 j
    (( $5 )) && st=$_wayu_hl_style[dollar-double-quoted-argument]
    case $w[i+1] in
      (\()
        if [[ $w[i+2] != \( ]]; then
          _wayu_hl_sub $w $i $s $4 command-substitution-delimiter
          return 0
        fi
        _wayu_hl_close $w $(( i + 1 )) \(
        _wayu_hl_brs $w $(( i + 3 )) $(( REPLY <= n ? REPLY - 2 : n )) $s ;;
      (\{)
        _wayu_hl_close $w $(( i + 1 )) \{
        _wayu_hl_brs $w $(( i + 1 )) $(( REPLY <= n ? REPLY : n )) $s ;;
      (\[)
        _wayu_hl_close $w $(( i + 1 )) \[
        _wayu_hl_brs $w $(( i + 1 )) $(( REPLY <= n ? REPLY : n )) $s ;;
      ([[:alpha:]_]) j=${w[(ib:i+2:)[^[:alnum:]_]]}; REPLY=$(( j - 1 )) ;;
      ([0-9\#\?\$\!\*\@-]) REPLY=$(( i + 1 )) ;;
      (*) REPLY=$(( i + 1 )); return 0 ;;
    esac
    (( j = REPLY > n ? n : REPLY ))
    [[ -n $st ]] && _wayu_hl_res+=( "$(( s + i - 1 )) $(( s + j )) $st" )
    REPLY=$(( j + 1 ))
  }
  # REPLY: index of what closes the $3 ("(", "{" or "[") at index $2 of $1
  # (length + 1: unterminated).
  function _wayu_hl_close {
    local w=$1 p
    local -i i=$2 d=0 n=$#1
    case $3 in
      (\() p='[()]' ;;
      (\{) p='[{}]' ;;
      (*) p='[][]' ;;
    esac
    while (( i <= n )); do
      if [[ $w[i] == $3 ]]; then (( d++ ))
      elif (( --d == 0 )); then break; fi
      i=${w[(ib:i+1:)$~p]}
    done
    REPLY=$i
  }
  # $( <( >( =( at index $2 of $1 (offset $3, depth $4): delimiters in
  # style $5, the inside highlighted as command lines; REPLY: index after
  # the ")".
  function _wayu_hl_sub {
    local w=$1 st=$_wayu_hl_style[$5]
    local -i i=$2 s=$3 n=$#1 j
    [[ -n $st ]] && _wayu_hl_res+=( "$(( s + i - 1 )) $(( s + i + 1 )) $st" )
    (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$(( s + i )) (" )
    if (( $4 < 8 )); then
      _wayu_hl_line "${w[i+2,-1]}" $(( s + i + 1 )) 1 $(( $4 + 1 ))
      (( j = i + 2 + REPLY ))
    else
      _wayu_hl_close $w $(( i + 1 )) \(
      j=REPLY
    fi
    if (( j <= n )); then
      [[ -n $st ]] && _wayu_hl_res+=( "$(( s + j - 1 )) $(( s + j )) $st" )
      (( _wayu_hl_nobr )) || _wayu_hl_brk+=( "$(( s + j - 1 )) )" )
    fi
    REPLY=$(( j + 1 ))
  }
  # `...` at index $2 of $1 (offset $3, depth $4); REPLY: index after it.
  function _wayu_hl_bq {
    local w=$1 st=$_wayu_hl_style[back-quoted-argument-delimiter]
    local -i i=$2 s=$3 n=$#1 j=$2+1
    while (( j <= n )); do
      j=${w[(ib:j:)[\\\`]]}
      [[ $w[j] == \\ ]] || break
      (( j += 2 ))
    done
    [[ -n $st ]] && _wayu_hl_res+=( "$(( s + i - 1 )) $(( s + i )) $st" )
    (( $4 < 8 && j > i + 1 )) && _wayu_hl_line "${w[i+1,j-1]}" $(( s + i )) 0 $(( $4 + 1 ))
    (( j <= n )) && [[ -n $st ]] && _wayu_hl_res+=( "$(( s + j - 1 )) $(( s + j )) $st" )
    REPLY=$(( j + 1 ))
  }
  () {
    emulate -L zsh
    [[ $ZSH_VERSION == (5.<3->|<6->.)* ]] || return 0
    zmodload zsh/parameter zsh/zleparameter 2>/dev/null || return 0
    typeset -gA _wayu_hl_style=( @STYLES@ ) _wayu_hl_cmds=() _wayu_hl_paths=() _wayu_hl_dirs=() _wayu_hl_resw=() _wayu_hl_bpair=()
    typeset -ga _wayu_hl_res=() _wayu_hl_prev=() _wayu_hl_snap=() _wayu_hl_toks=() _wayu_hl_brk=() _wayu_hl_bres=()
    typeset -g _wayu_hl_buf= _wayu_hl_key=
    typeset -gi _wayu_hl_memo=0 _wayu_hl_cur=0
    local k
    for k in $reswords; do _wayu_hl_resw[$k]=1; done
    if [[ $ZSH_VERSION == (5.<9->|<6->.)* ]]; then
      _wayu_hl_memo=1
      for k in ${(k)_wayu_hl_style}; do
        [[ -n $_wayu_hl_style[$k] ]] && _wayu_hl_style[$k]+=", memo=wayu-highlight"
      done
    fi
    (( ${+widgets[_wayu_hl_redraw]} )) && return 0
    zle -N _wayu_hl_redraw
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget zle-line-pre-redraw _wayu_hl_redraw
  }
fi
