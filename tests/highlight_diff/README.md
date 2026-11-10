# Highlighter differential test

Compares wayu's built-in zsh highlighter (`src/highlight.zsh`) with
fast-syntax-highlighting (the commit pinned in `tests/benchmark/compare.sh`)
over `corpus.txt`, by token category, and checks the result against
`expected.txt`:

```bash
ruby tests/highlight_diff/run.rb                 # compare (clones FSH into $TMPDIR once: git + network)
ruby tests/highlight_diff/run.rb --update        # accept the current differences
FSH_DIR=~/src/fast-syntax-highlighting ruby tests/highlight_diff/run.rb   # use a checkout
```

Needs zsh >= 5.9; runs in a temp HOME. Not run by CI (network). A change
to either highlighter that alters a category shows up as a diff against
`expected.txt`; `run.rb` explains the method.

## Intended differences (what `expected.txt` still lists)

- FSH-only styles: arithmetic inside `$((...))` / `((...))` (`math`),
  `for ((...))` parts (`for-loop`), case input / patterns (`case`),
  here-string text (`here-string`). wayu colors `$((...))` as one expansion
  and patterns as arguments (globs).
- `;;` `;&` `;|` are command separators in wayu, plain in FSH.
- Precommands: wayu follows zsh-syntax-highlighting (`env`, `nohup`, `nice`,
  `time`, `-` are precommands and the next word is a command); FSH colors
  them as plain commands and their arguments as arguments.
- Substitutions: wayu highlights the inside of `$(...)` in double quotes
  and of `<(...)` `>(...)` `=(...)` as command lines and colors `$(` as a
  delimiter; FSH colors `$` as a variable and leaves process substitutions
  plain. FSH also mis-nests `"$(echo "x $(y)")"`.
- `$PATH` in `NAME=$PATH:...` and `$(...)` in `x=$(...)` keep their own
  colors (FSH: the whole word is `assign`).
- `\`` and `\\` inside `"..."` are escapes in wayu (zsh-syntax-highlighting);
  FSH colors only `\"` and `\$`. `!!` inside `"..."` is a history expansion
  (zsh expands it there).
- `$'...'` directly after other quoting in one word: wayu colors it as
  `$'...'`, FSH as `$` + `'...'`.
- Heredoc bodies are not highlighted (FSH colors their lines as commands).
- `&>`, the descriptor in `2>&1` / `>&-` and `{fd}`: wayu's `redirection` /
  `numeric-fd` / `named-fd`; FSH leaves them plain (`-` as an option).
- `[ ... ]`: `[` is a builtin (FSH: reserved word); `]]` `[[` as arguments
  outside `[[ ]]` are plain (FSH: errors); an unterminated `` ` `` is a
  delimiter (FSH: error).
