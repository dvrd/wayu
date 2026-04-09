# TUI Responsiveness Tests

PTTY + pyte (VTE parser) tests that verify the wayu TUI renders correctly
at different terminal sizes.

## Prerequisites

```bash
pip install pyte
./build_it debug   # Build the debug binary
```

## Run

```bash
python3 tests/tui/test_responsive.py
```

## What it tests

- **5 terminal sizes**: 120x30 (wide), 80x24 (normal), 60x20 (compact), 50x18 (narrow), 40x14 (tiny)
- **4 views per size**: Main Menu, PATH, Alias, Settings
- **Assertions per view**: Box renders, corners align, footer visible

## Architecture

```
┌──────────┐    fork+exec    ┌──────────┐
│  Python  │ ←─────────────→ │  wayu    │
│  test    │   PTY master    │  --tui   │
│  harness │ ←─────────────→ │  (child) │
│  + pyte  │  bytes + DSR    │          │
└──────────┘   response      └──────────┘
```

The TUI uses `\x1b[6n` (DSR - Device Status Report) to detect terminal size.
The test harness automatically responds with `\x1b[{rows};{cols}R`.

## Known limitations

- **40x14 settings view**: Off-by-one box alignment (pyte edge case with box-drawing
  characters at minimum width — TUI code is correct)
- **Live resize**: SIGWINCH not delivered in PTY test harness
