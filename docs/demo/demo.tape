# wayu demo: entries, an encrypted run-only secret, a script, doctor, the TUI.
#
# Record (from the repo root, after ./build_it):
#
#   vhs docs/demo/demo.tape
#
# Writes docs/demo/demo.gif (README) and docs/demo/demo.mp4 (website), then
# docs/demo/poster.webp is cut from the mp4 (cwebp: brew install webp):
#
#   ffmpeg -y -loglevel error -ss 13 -i docs/demo/demo.mp4 -frames:v 1 /tmp/poster.png
#   cwebp -q 85 /tmp/poster.png -o docs/demo/poster.webp
#
# docs/demo/setup.sh builds a throwaway HOME in /tmp/wayu-demo (HOME,
# WAYU_CONFIG_DIR, WAYU_DATA_DIR and XDG dirs all inside it; key-file
# secrets backend; fake values only) and uses the repo's bin/wayu. Your real
# ~/.config/wayu and ~/.local/share/wayu are not touched. $EDITOR there is a
# stand-in that writes the script body, since typing into an editor would
# double the length. The doctor summary icon needs a Nerd Font for its
# glyph ("Symbols Nerd Font Mono" here; without it a box is drawn).

Output docs/demo/demo.gif
Output docs/demo/demo.mp4

Require zsh

Set Shell zsh
Set FontFamily "Menlo, Symbols Nerd Font Mono"
Set FontSize 19
Set LineHeight 1.25
Set Width 1200
Set Height 720
Set Padding 28
Set Margin 0
Set WindowBar Colorful
Set BorderRadius 10
Set Theme "Catppuccin Mocha"
Set TypingSpeed 38ms
Set CursorBlink false

# --- setup, not recorded ---------------------------------------------------
Hide
Type "docs/demo/setup.sh /tmp/wayu-demo > /tmp/wayu-demo.env && source /tmp/wayu-demo.env"
Enter
Sleep 2.5s
Ctrl+L
Sleep 300ms
Show

# --- entries ---------------------------------------------------------------
Type "wayu path add ~/.cargo/bin"
Sleep 300ms
Enter
Sleep 1.4s
Type "wayu alias add gs 'git status -sb'"
Sleep 300ms
Enter
Sleep 1.2s

# --- a secret that never reaches the shell --------------------------------
Type "wayu const add OPENAI_API_KEY --run-only"
Sleep 300ms
Enter
Sleep 700ms
Set TypingSpeed 12ms
Type "sk-demo-4f9a2c7e1b8d6a3f0e5c9b2a7d4f1e8c"
Set TypingSpeed 38ms
Sleep 300ms
Enter
Sleep 1.4s
Ctrl+L
Type "wayu const list"
Sleep 300ms
Enter
Sleep 2.8s
Type "echo ${OPENAI_API_KEY:-not set in this shell}"
Sleep 300ms
Enter
Sleep 1.4s
Ctrl+L

# --- a script on PATH, given the secret for one run -----------------------
Type "wayu script new ask --lang python"
Sleep 300ms
Enter
Sleep 1.8s
Type "wayu secrets run OPENAI_API_KEY -- ask"
Sleep 300ms
Enter
Sleep 2.2s
Ctrl+L

# --- health check ----------------------------------------------------------
Type "wayu doctor"
Sleep 300ms
Enter
Sleep 3.5s
Ctrl+L

# --- TUI -------------------------------------------------------------------
Type "wayu"
Sleep 300ms
Enter
Sleep 1.8s
Enter
Sleep 1.8s
Escape
Sleep 500ms
Down
Sleep 500ms
Enter
Sleep 1.4s
Type "a"
Sleep 700ms
Type "lg"
Sleep 300ms
Tab
Sleep 300ms
Type "lazygit"
Sleep 600ms
Enter
Sleep 2s
Escape
Sleep 500ms
Type "q"
Sleep 1.5s
