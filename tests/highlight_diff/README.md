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
