if [[ -o interactive && -o zle ]]; then
  function _wayu_hl_redraw {
    local -i _wayu_hl_ic=0 _wayu_hl_ac=0
    [[ -o interactivecomments ]] && _wayu_hl_ic=1
    [[ -o autocd ]] && _wayu_hl_ac=1
    emulate -L zsh
    setopt extendedglob
    if [[ $BUFFER != "$_wayu_hl_buf" || "$HISTCMD:$PWD:$PATH:$_wayu_hl_ic" != "$_wayu_hl_key" ]]; then
      # Text kept from the last run (typing or deleting at the end): the
      # words before it are not looked at again.
      local -i _wayu_hl_keep=0
      if [[ "$HISTCMD:$PWD:$PATH:$_wayu_hl_ic" != "$_wayu_hl_key" ]]; then
        # A command ran or the directory / PATH changed: lookups go stale.
        _wayu_hl_key="$HISTCMD:$PWD:$PATH:$_wayu_hl_ic"
        _wayu_hl_cmds=() _wayu_hl_paths=() _wayu_hl_dirs=()
      elif [[ $BUFFER == "$_wayu_hl_buf"* ]]; then
        _wayu_hl_keep=$#_wayu_hl_buf
      elif [[ $_wayu_hl_buf == "$BUFFER"* ]]; then
        _wayu_hl_keep=$#BUFFER
      fi
      _wayu_hl_buf=$BUFFER
      if (( $#BUFFER && $#BUFFER <= 20000 )); then
        [[ $BUFFER == *[^[:ascii:]]* ]] || setopt nomultibyte
        local -i _wayu_hl_len=$#BUFFER
        local REPLY
        _wayu_hl_line "$BUFFER" 0 0 0
      else
        _wayu_hl_res=() _wayu_hl_snap=()
      fi
    fi
    if (( _wayu_hl_memo )); then
      region_highlight=( "${(@)region_highlight:#*memo=wayu-highlight}" )
    elif (( $#_wayu_hl_prev )); then
      region_highlight=( "${(@)region_highlight:|_wayu_hl_prev}" )
    fi
    local -i n=$#region_highlight
    region_highlight+=( "${(@)_wayu_hl_res}" )
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
    return 0
  }
  # $1: zle_highlight context, $2: its default, $3 $4: the span.
  function _wayu_hl_zle {
    local st=${${(M)zle_highlight:#$1:*}#$1:}
    [[ ${st:=$2} == none ]] && return 0
    (( _wayu_hl_memo )) && st+=", memo=wayu-highlight"
    region_highlight+=( "$3 $4 $st" )
  }
  # Highlight $1 (at offset $2 of BUFFER) as command lines; $3: 1 inside
  # $(...) / <(...) (stop at an unmatched ")"), $4: nesting depth. Appends
  # to _wayu_hl_res; REPLY: where it stopped in $1. Words come from zsh's
  # own lexer (${(z)...}), which keeps each word as typed (unterminated
  # quotes included): each is found in $1 by skipping blanks. State: 1
  # command position, 2 arguments, 3 after a precommand (options, then a
  # command), 4 redirection target, 5 inside [[ ]], 6 a name (for, case,
  # function), 7 case patterns, 8 inside name=( ), 9 a precommand option's
  # argument.
  #
  # For BUFFER itself (top), the state before each word is kept in
  # _wayu_hl_snap ("end-of-previous-word results-count state ..."), so the
  # next run starts at the last word that ends before the changed text
  # (_wayu_hl_keep) instead of the start: a keystroke at the end of a long
  # line costs a word or two, not the whole line.
  function _wayu_hl_line {
    local str=$1 tok c st cmd pre= nt= d line nl=$'\n'
    local -i base=$2 nested=$3 lvl=$4 pos=0 s e n ti=1 p q state=1 after=2 saved=1 depth=0 casep=0 braces=0 k
    local -i top=$(( ! base && ! nested && ! lvl ))
    local -a toks hd f
    if (( _wayu_hl_ic )); then toks=( ${(Z+c+)str} ); else toks=( ${(z)str} ); fi
    if (( top )); then
      # Resume at word r: words r-1 and r (r-1 looked ahead at r) end
      # before the change, so they and everything before are unchanged.
      if (( _wayu_hl_keep )); then
        for (( k = $#_wayu_hl_snap; k > 2; k-- )); do
          (( ${_wayu_hl_snap[k]%% *} < _wayu_hl_keep )) && break
        done
        (( k-- ))
        if (( k >= 2 )) && [[ $_wayu_hl_snap[k] != x && $toks[k] == "$_wayu_hl_toks[k]" ]]; then
          f=( ${=_wayu_hl_snap[k]} )
          pos=f[1] state=f[3] after=f[4] saved=f[5] depth=f[6] casep=f[7] braces=f[8]
          pre=${f[9]#-} nt=${f[10]#-}
          _wayu_hl_res[f[2]+1,-1]=()
          _wayu_hl_snap[k,-1]=()
          ti=k
        fi
      fi
      if (( ti == 1 )); then
        _wayu_hl_res=() _wayu_hl_snap=()
      fi
      _wayu_hl_toks=( "${toks[@]}" )
    fi
    for (( ; ti <= $#toks; ti++ )); do
      tok=$toks[ti]
      if (( top )); then
        if (( $#hd )); then _wayu_hl_snap[ti]=x
        else _wayu_hl_snap[ti]="$pos $#_wayu_hl_res $state $after $saved $depth $casep $braces ${pre:--} ${nt:--}"; fi
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
        # The lexer turns a newline into ";". Anything else: lost track.
        if [[ $tok == \; && $c == $nl ]]; then n=1; else REPLY=$#str; return 0; fi
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
      if (( state == 4 )); then
        [[ -n $nt ]] && hd+=( "$nt${(Q)tok}" ) nt=
        _wayu_hl_arg $tok $s $lvl
        state=$saved
        continue
      fi
      case $tok in
        (\;|\&\&|\|\||\||\|\&|\&|\&\||\&\!|\;\;|\;\&|\;\|)
          (( state == 5 || state == 7 || state == 8 )) && continue
          [[ -n ${st::=$_wayu_hl_style[commandseparator]} ]] && _wayu_hl_res+=( "$s $e $st" )
          state=1 pre=
          (( casep == 2 )) && [[ $tok == \;[\;\&\|] ]] && state=7
          continue ;;
        ((<->|)(\&|)[\<\>][\<\>\|\!\&-]#)
          [[ -n ${st::=$_wayu_hl_style[redirection]} ]] && _wayu_hl_res+=( "$s $e $st" )
          [[ $tok == \<\< ]] && nt=0
          [[ $tok == \<\<- ]] && nt=1
          saved=$state state=4
          continue ;;
        (\))
          if (( nested && ! depth && state != 7 )); then
            REPLY=$(( pos - 1 ))
            return 0
          fi
          if (( state == 8 )); then state=$saved; continue; fi
          (( state == 5 )) && continue
          (( state == 7 )) || (( depth-- ))
          [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
          (( state == 7 )) && state=1 || state=2
          continue ;;
        (\(|\(\))
          (( state == 5 || state == 7 )) && continue
          [[ $tok == \( ]] && (( depth++ ))
          [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
          state=1
          continue ;;
        (\})
          if (( braces && state != 5 )); then
            (( braces-- ))
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
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
            [[ -n ${st::=$_wayu_hl_style[redirection]} ]] && _wayu_hl_res+=( "$s $e $st" )
            continue
          fi ;;
      esac
      case $state in
        ([13]) ;;
        (6) _wayu_hl_arg $tok $s $lvl; state=$after; continue ;;
        (9) _wayu_hl_arg $tok $s $lvl; state=3; continue ;;
        (7)
          if [[ $tok == esac ]]; then
            [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]] && _wayu_hl_res+=( "$s $e $st" )
            casep=0 state=2
          else
            _wayu_hl_arg $tok $s $lvl
          fi
          continue ;;
        (*)
          if (( casep == 1 )) && [[ $tok == in ]]; then
            casep=2 state=7
          elif [[ -n $galiases[$tok] ]]; then
            [[ -n ${st::=$_wayu_hl_style[global-alias]} ]] && _wayu_hl_res+=( "$s $e $st" )
          elif [[ $tok == -?* && $tok != *[\\\'\"\$\`]* ]]; then
            [[ $tok == --* ]] && st=$_wayu_hl_style[double-hyphen-option] || st=$_wayu_hl_style[single-hyphen-option]
            [[ -n $st ]] && _wayu_hl_res+=( "$s $e $st" )
          elif [[ $tok != *[\\\'\"\$\`\*\?\[\<\>=\~]* ]] && (( e != _wayu_hl_len )); then
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
        elif [[ $pre:$tok == command:-[vV] ]]; then state=2
        fi
        continue
      fi
      if [[ $tok == [[:alpha:]_][[:alnum:]_]#(\[*\]|)(+|)=* ]]; then
        k=$#_wayu_hl_res
        if [[ $tok == *=\( ]]; then
          saved=$state state=8
        else
          q=${tok[(i)=]}
          (( q < n )) && _wayu_hl_arg "${tok[q+1,-1]}" $(( s + q )) $lvl
        fi
        [[ -n ${st::=$_wayu_hl_style[assign]} ]] && _wayu_hl_res[k+1,k]=( "$s $e $st" )
        continue
      fi
      if [[ $tok == \(\(* ]]; then
        if [[ -n ${st::=$_wayu_hl_style[reserved-word]} ]]; then
          _wayu_hl_res+=( "$s $(( s + 2 )) $st" )
          [[ $tok == *\)\) ]] && _wayu_hl_res+=( "$(( e - 2 )) $e $st" )
        fi
        state=2
        continue
      fi
      if (( $+_wayu_hl_resw[$tok] )); then
        state=1 st=reserved-word
        case $tok in
          (declare|export|float|integer|local|readonly|typeset) st=builtin state=2 ;;
          (\[\[) state=5 ;;
          (for|foreach|select|function) state=6 after=2 ;;
          (repeat) state=6 after=1 ;;
          (case) state=6 after=2 casep=1 ;;
          (time|nocorrect) st=precommand state=3 pre=$tok ;;
          (\{) (( braces++ )) ;;
          (done|fi|esac|end|\}) state=2 ;;
        esac
        [[ -n ${st::=$_wayu_hl_style[$st]} ]] && _wayu_hl_res+=( "$s $e $st" )
        continue
      fi
      state=2 pre=
      [[ $toks[ti+1] == '()' ]] && continue # a function definition's name
      if [[ $tok == *[\$\`]* ]]; then
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
        elif [[ $cmd == ?*.?* && -n $saliases[${cmd##*.}] ]]; then st=suffix-alias
        elif (( _wayu_hl_ac )) && [[ -d $cmd ]]; then st=autodirectory
        else st=unknown-token; fi
        _wayu_hl_cmds[$tok]=$st
      fi
      [[ $st == precommand ]] && state=3 pre=$cmd
      [[ -n ${st::=$_wayu_hl_style[$st]} ]] && _wayu_hl_res+=( "$s $e $st" )
      [[ $tok == *[\'\"]* ]] && _wayu_hl_scan $tok $s $lvl
    done
    REPLY=$#str
    return 0
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
    if [[ $w == *[\\\'\"\$\`\*\?\[\<\>=]* ]]; then
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
  # Quoting and expansions inside the word $1 at offset $2 ($3: depth).
  # REPLY: 1 when it has an unquoted expansion or glob (no path check).
  function _wayu_hl_scan {
    local w=$1 st
    local -i s=$2 lvl=$3 i=1 n=$#1 j k=$#_wayu_hl_res fl=0 g=0
    while (( i <= n )); do
      i=${w[(ib:i:)[\\\'\"\$\`\*\?\[\<\>=]]}
      (( i > n )) && break
      case $w[i] in
        (\\) (( i += 2 )) ;;
        (\')
          j=${w[(ib:i+1:)\']}
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
        (\[)
          [[ $w[i+1,-1] == *\]* ]] && g=1
          (( i++ )) ;;
        (*) g=1; (( i++ )) ;;
      esac
    done
    (( g )) && [[ -n ${st::=$_wayu_hl_style[globbing]} ]] && _wayu_hl_res[k+1,k]=( "$s $(( s + n )) $st" )
    REPLY=$(( fl || g ))
  }
  # "..." at index $2 of $1 (offset $3, depth $4); REPLY: index after it.
  function _wayu_hl_dq {
    local w=$1 st b=$_wayu_hl_style[back-double-quoted-argument]
    local -i i=$2 s=$3 n=$#1 j=$2+1 k=$#_wayu_hl_res
    while (( j <= n )); do
      j=${w[(ib:j:)[\"\\\$\`]]}
      (( j > n )) && break
      case $w[j] in
        (\") break ;;
        (\\)
          [[ $w[j+1] == [\\\$\`\"] && -n $b ]] && _wayu_hl_res+=( "$(( s + j - 1 )) $(( s + j + 1 )) $b" )
          (( j += 2 )) ;;
        (\$) _wayu_hl_dollar $w $j $s $4 1; j=REPLY ;;
        (\`) _wayu_hl_bq $w $j $s $4; j=REPLY ;;
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
  # $var ${...} $((...)) $(...) at index $2 of $1 (offset $3, depth $4;
  # $5: 1 inside "..."); REPLY: index after it.
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
        _wayu_hl_close $w $(( i + 1 )) \( ;;
      (\{) _wayu_hl_close $w $(( i + 1 )) \{ ;;
      ([[:alpha:]_]) j=${w[(ib:i+2:)[^[:alnum:]_]]}; REPLY=$(( j - 1 )) ;;
      ([0-9\#\?\$\!\*\@-]) REPLY=$(( i + 1 )) ;;
      (*) REPLY=$(( i + 1 )); return 0 ;;
    esac
    (( j = REPLY > n ? n : REPLY ))
    [[ -n $st ]] && _wayu_hl_res+=( "$(( s + i - 1 )) $(( s + j )) $st" )
    REPLY=$(( j + 1 ))
  }
  # REPLY: index of what closes the $3 ("(" or "{") at index $2 of $1
  # (length + 1: unterminated).
  function _wayu_hl_close {
    local w=$1
    local -i i=$2 d=0 n=$#1
    while (( i <= n )); do
      if [[ $w[i] == $3 ]]; then (( d++ ))
      elif (( --d == 0 )); then break; fi
      if [[ $3 == \( ]]; then i=${w[(ib:i+1:)[()]]}
      else i=${w[(ib:i+1:)[{}]]}; fi
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
    if (( $4 < 8 )); then
      _wayu_hl_line "${w[i+2,-1]}" $(( s + i + 1 )) 1 $(( $4 + 1 ))
      (( j = i + 2 + REPLY ))
    else
      _wayu_hl_close $w $(( i + 1 )) \(
      j=REPLY
    fi
    (( j <= n )) && [[ -n $st ]] && _wayu_hl_res+=( "$(( s + j - 1 )) $(( s + j )) $st" )
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
    typeset -gA _wayu_hl_style=( @STYLES@ ) _wayu_hl_cmds=() _wayu_hl_paths=() _wayu_hl_dirs=() _wayu_hl_resw=()
    typeset -ga _wayu_hl_res=() _wayu_hl_prev=() _wayu_hl_snap=() _wayu_hl_toks=()
    typeset -g _wayu_hl_buf= _wayu_hl_key=
    typeset -gi _wayu_hl_memo=0
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
