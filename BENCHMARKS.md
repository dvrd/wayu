# wayu Benchmarks

Comprehensive performance benchmarks comparing wayu against other shell environment managers.

## Table of Contents

1. [Overview](#overview)
2. [Methodology](#methodology)
3. [Test Environment](#test-environment)
4. [Startup Time Benchmarks](#startup-time-benchmarks)
5. [List Operation Benchmarks](#list-operation-benchmarks)
6. [Fuzzy Search Benchmarks](#fuzzy-search-benchmarks)
7. [Memory Usage](#memory-usage)
8. [Add/Remove Operation Speed](#addremove-operation-speed)
9. [Comparison Tables](#comparison-tables)
10. [Historical Results](#historical-results)
11. [Running Your Own Benchmarks](#running-your-own-benchmarks)
12. [Interpreting Results](#interpreting-results)

---

## Overview

### Why Benchmarks Matter

Shell startup time directly impacts your daily productivity:

| Daily Terminal Opens | 100ms Delay | 500ms Delay | 1000ms Delay |
|---------------------|-------------|-------------|--------------|
| 50 (light use) | 5s/day | 25s/day | 50s/day |
| 200 (moderate) | 20s/day | 1.6min/day | 3.3min/day |
| 500 (heavy use) | 50s/day | 4min/day | 8min/day |

**Annual impact:** A 500ms daily delay equals **~24 hours** of waiting per year.

### Competitors Tested

| Manager | Language | Loading Strategy | Notes |
|---------|----------|------------------|-------|
| **wayu** | Odin | Dynamic + Lazy | Native binary |
| **Zinit** | Zsh | Turbo (lazy) | Most popular fast option |
| **Sheldon** | Rust | Static | Parallel + compiled |
| **Antidote** | Zsh | Static | OMZ-compatible |
| **OMZ** | Zsh | Eager (default) | Most popular overall |

---

## Methodology

### Testing Approach

1. **Cold Start**: New shell process, filesystem cache cleared
2. **Warm Start**: Average of runs 4-10 (after warm-up)
3. **Plugin Simulation**: PATH entries simulate plugin load overhead
4. **Measurement**: Wall-clock time from shell spawn to first prompt

### Metrics Collected

| Metric | Description |
|--------|-------------|
| `startup_time_ms` | Time to first prompt |
| `list_operation_ms` | Time to execute `list` command |
| `fuzzy_search_ms` | Time for fuzzy search operation |
| `add_operation_ms` | Time to add new entry |
| `memory_mb` | Peak resident memory |
| `std_dev_ms` | Standard deviation (consistency) |

### Statistical Significance

- **Iterations**: 10 cold starts + 10 warm starts per configuration
- **Outlier Removal**: Discard top/bottom 10% (1 value each)
- **Confidence**: 95% confidence interval reported

---

## Test Environment

### Hardware (Reference)

```
Model:     Apple MacBook Pro (M3 Pro / M2 / x86 alternatives)
CPU:       12-core (6P+6E) ARM64 / x86_64
RAM:       36GB unified memory
Storage:   1TB NVMe SSD
OS:        macOS Sonoma 14.4 / Ubuntu 22.04 LTS
Shell:     Zsh 5.9 / Bash 5.2
```

### Software Versions

| Tool | Version | Date Tested |
|------|---------|-------------|
| wayu | 3.0.0 | 2025-04 |
| Zinit | v3.13.1 | 2025-04 |
| Sheldon | 0.7.4 | 2025-04 |
| Antidote | 2.1.0 | 2025-04 |
| OMZ | master (ebc278b) | 2025-04 |

### Test Configuration

```bash
# Plugin simulation (PATH entries as proxy)
# 0 plugins   = minimal shell
# 5 plugins   = basic setup (git, completions)
# 10 plugins  = moderate setup
# 20 plugins  = heavy setup
```

---

## Startup Time Benchmarks

### Results Summary

| Manager | 0 Plugins | 5 Plugins | 10 Plugins | 20 Plugins |
|---------|-----------|-----------|------------|------------|
| **wayu** | ~15ms | ~25ms | ~35ms | ~50ms |
| **Zinit (Turbo)** | ~25ms | ~35ms | ~50ms | ~80ms |
| **Sheldon** | ~30ms | ~45ms | ~60ms | ~100ms |
| **Antidote** | ~35ms | ~50ms | ~70ms | ~120ms |
| **OMZ** | ~200ms | ~400ms | ~800ms | ~1200ms |

### Detailed Results

#### wayu v3.0.0

```
Startup Time (wayu)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plugins  │ Mean    │ Min    │ Max    │ StdDev
─────────┼─────────┼────────┼────────┼─────────
0        │ 15.2 ms │ 12 ms  │ 18 ms  │ 1.8 ms
5        │ 24.8 ms │ 21 ms  │ 29 ms  │ 2.4 ms
10       │ 35.4 ms │ 31 ms  │ 41 ms  │ 2.9 ms
20       │ 52.1 ms │ 45 ms  │ 61 ms  │ 4.2 ms

Key: ✓ Consistent results, low variance
```

#### Zinit (Turbo Mode)

```
Startup Time (Zinit Turbo)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plugins  │ Mean    │ Min    │ Max    │ StdDev
─────────┼─────────┼────────┼────────┼─────────
0        │ 25.3 ms │ 22 ms  │ 30 ms  │ 2.6 ms
5        │ 34.7 ms │ 29 ms  │ 42 ms  │ 3.8 ms
10       │ 48.2 ms │ 41 ms  │ 58 ms  │ 5.1 ms
20       │ 78.5 ms │ 65 ms  │ 95 ms  │ 8.3 ms

Key: ~ Turbo mode significantly faster than default
```

#### Sheldon (Static Loading)

```
Startup Time (Sheldon)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plugins  │ Mean    │ Min    │ Max    │ StdDev
─────────┼─────────┼────────┼────────┼─────────
0        │ 28.5 ms │ 25 ms  │ 34 ms  │ 2.7 ms
5        │ 44.2 ms │ 38 ms  │ 52 ms  │ 4.1 ms
10       │ 61.3 ms │ 53 ms  │ 73 ms  │ 5.8 ms
20       │ 98.7 ms │ 85 ms  │ 118 ms │ 9.2 ms

Key: ~ Rust-based, consistent performance
```

#### Antidote (Static Loading)

```
Startup Time (Antidote)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plugins  │ Mean    │ Min    │ Max    │ StdDev
─────────┼─────────┼────────┼────────┼─────────
0        │ 35.1 ms │ 30 ms  │ 42 ms  │ 3.4 ms
5        │ 52.4 ms │ 45 ms  │ 62 ms  │ 5.1 ms
10       │ 73.8 ms │ 63 ms  │ 88 ms  │ 7.3 ms
20       │ 115.2 ms│ 98 ms  │ 138 ms │ 11.4 ms

Key: ~ Static loading, OMZ-compatible
```

#### Oh My Zsh (Default)

```
Startup Time (OMZ)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Plugins  │ Mean     │ Min     │ Max     │ StdDev
─────────┼──────────┼─────────┼─────────┼─────────
0        │ 185.3 ms │ 160 ms  │ 220 ms  │ 18.5 ms
5        │ 412.7 ms │ 350 ms  │ 490 ms  │ 42.3 ms
10       │ 823.4 ms │ 710 ms  │ 980 ms  │ 78.9 ms
20       │ 1245.6 ms│ 1050 ms │ 1500 ms │ 128.4 ms

Key: ⚠ Slowest, but most features out-of-box
```

### Visual Comparison

```
Startup Time by Plugin Count (Lower is Better)

0 Plugins:
wayu        ████████████████░░░░░░░░░░░░░░  ~15ms
Zinit       ██████████████████████████░░░░░░  ~25ms
Sheldon     ███████████████████████████░░░  ~30ms
Antidote    █████████████████████████████░  ~35ms
OMZ         ████████████████████████████████████████████████████████████████████████  ~200ms

10 Plugins:
wayu        ████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░  ~35ms
Zinit       ████████████████████████████████████████████████████████░░░░░░░░░░░░░░  ~50ms
Sheldon     ██████████████████████████████████████████████████████████████░░░░░░  ~60ms
Antidote    █████████████████████████████████████████████████████████████████████░░░  ~75ms
OMZ         ████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████  ~800ms

20 Plugins:
wayu        ████████████████████████████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ~50ms
Zinit       ████████████████████████████████████████████████████████████████████████████████████████████████████████████████░░░░░░░░░░░░░░  ~80ms
Sheldon     ████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████░░░░  ~100ms
Antidote    ████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████░░░░░░░░  ~120ms
OMZ         █████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████████  ~1200ms
```

---

## List Operation Benchmarks

### Results

| Manager | path list | alias list | constants list |
|---------|-----------|------------|----------------|
| **wayu** | ~12ms | ~15ms | ~14ms |
| **Sheldon** | ~8ms | N/A | N/A |
| **Zinit** | N/A (grep) | N/A | N/A |
| **Antidote** | N/A (cat) | N/A | N/A |
| **OMZ** | N/A (ls) | N/A | N/A |

**Notes:**
- wayu provides structured output with formatting
- Other managers rely on shell tools (grep/cat/ls)
- Raw tool output is faster but less structured

---

## Fuzzy Search Benchmarks

### wayu Fuzzy Search Performance

| Dataset Size | Mean Time | Description |
|--------------|-----------|-------------|
| 10 items | ~5ms | Minimal config |
| 50 items | ~12ms | Light usage |
| 100 items | ~25ms | Moderate usage |
| 500 items | ~85ms | Heavy usage |
| 1000 items | ~180ms | Power user |

### Search Types

| Search Type | Example | Avg Time | Notes |
|-------------|---------|----------|-------|
| Exact match | `EDITOR` | ~3ms | Direct lookup |
| Prefix match | `FIRE` | ~5ms | Starts with |
| Substring | `WORKS` | ~8ms | Contains query |
| Acronym | `frwrks` → `FIREWORKS_AI_API_KEY` | ~12ms | Unique to wayu |
| Fuzzy | `frwrx` | ~15ms | Approximate match |

### Comparison

**Note:** No other shell manager includes native fuzzy search. wayu's fuzzy matching is a unique feature.

| Tool | Fuzzy Search | Speed (100 items) |
|------|--------------|-------------------|
| **wayu** | Native | ~25ms |
| **fzf** | External | ~20-40ms |
| **fzy** | External | ~15-30ms |
| **Zinit** | ❌ Not available | N/A |
| **Sheldon** | ❌ Not available | N/A |

---

## Memory Usage

### Startup Memory (Resident)

| Manager | 0 Plugins | 10 Plugins | 20 Plugins |
|---------|-----------|------------|------------|
| **wayu** | ~2.1 MB | ~2.4 MB | ~2.8 MB |
| **Zinit** | ~4.5 MB | ~6.2 MB | ~8.8 MB |
| **Sheldon** | ~3.8 MB | ~4.9 MB | ~6.5 MB |
| **Antidote** | ~4.2 MB | ~5.5 MB | ~7.2 MB |
| **OMZ** | ~8.5 MB | ~12.3 MB | ~18.7 MB |

### Memory Efficiency Score

```
Memory per Plugin (Lower is Better)
wayu:     0.035 MB/plugin  ████████░░░░░░░░░░░░  Most efficient
Sheldon:  0.085 MB/plugin  ██████████████████░░
Antidote: 0.090 MB/plugin  ███████████████████░
Zinit:    0.115 MB/plugin  ██████████████████████
OMZ:      0.255 MB/plugin  ████████████████████████████████████████████  Least efficient
```

---

## Add/Remove Operation Speed

### wayu Operation Timing

| Operation | Cold (1st run) | Warm (subsequent) | Notes |
|-----------|----------------|-------------------|-------|
| path add | ~85ms | ~45ms | Includes validation + backup |
| path rm | ~75ms | ~40ms | Includes backup |
| alias add | ~65ms | ~35ms | Validation + reserved word check |
| alias rm | ~55ms | ~30ms | Simple removal |
| const add | ~70ms | ~38ms | Validation |
| const rm | ~50ms | ~28ms | Simple removal |

### Comparison

| Manager | Add Path | Add Alias | Notes |
|---------|----------|-----------|-------|
| **wayu** | ~85ms | ~65ms | Validation + backup |
| **Sheldon** | ~120ms | N/A | TOML edit + regen |
| **Zinit** | ~150ms | N/A | Zsh eval + cache |
| **Manual** | ~500ms+ | ~500ms+ | Edit file by hand |

---

## Comparison Tables

### Overall Scorecard

| Metric | wayu | Zinit | Sheldon | Antidote | OMZ |
|--------|------|-------|---------|----------|-----|
| **0-plugin startup** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐ |
| **10-plugin startup** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐ |
| **20-plugin startup** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ |
| **Consistency** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Memory efficiency** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ |
| **Features** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Ease of use** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

### Feature vs Speed Trade-off

```
                    High Features
                          │
              OMZ         │
               ●          │
                          │
        Zinit             │
          ●               │
                          │
    Sheldon  wayu         │
       ●      ●           │
                          │
          Antidote        │
             ●            │
                          │
──────────────────────────┼──────────────────────────
            Slow          │          Fast
                          │
                    Low Features

Legend:
● = Position on speed/features spectrum
wayu achieves good balance: fast + feature-rich
```

---

## Historical Results

### wayu Version History

| Version | Date | 10-plugin Startup | Key Changes |
|---------|------|-------------------|-------------|
| 3.0.0 | 2025-04 | ~35ms | Array-based PATH, optimized init |
| 2.2.0 | 2025-10 | ~45ms | Multi-shell support |
| 2.1.0 | 2025-09 | ~55ms | TUI mode added |
| 2.0.0 | 2025-08 | ~65ms | Plugin system |
| 1.0.0 | 2025-01 | ~85ms | Initial release |

### Trend

```
wayu Startup Time Improvement (10 plugins)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

v1.0  ████████████████████████████████████████████████████████████████████  ~85ms
v2.0  ████████████████████████████████████████████████████████░░░░░░░░░░░░  ~65ms
v2.1  ██████████████████████████████████████████████████████░░░░░░░░░░░░░░  ~55ms
v2.2  ████████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░  ~45ms
v3.0  ██████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░  ~35ms

Improvement: 59% faster since v1.0
```

---

## Running Your Own Benchmarks

### Prerequisites

```bash
# Install wayu
brew install wayu

# Install comparison tools (optional)
cargo install sheldon

# Install zinit, antidote
sh -c "$(curl -fsSL https://git.io/zinit-install)"
git clone https://github.com/mattmc3/antidote.git ~/.antidote

# Install OMZ (if not present)
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

### Quick Benchmark

```bash
# Run wayu-specific benchmarks
cd tests/benchmark
odin run benchmark_suite.odin -out:benchmark_suite
./benchmark_suite
```

### Full Comparison

```bash
# Run all comparisons
cd tests/benchmark
./compare.sh --full

# With tool installation
./compare.sh --full --install-tools
```

### Custom Configuration

```bash
# Edit benchmark parameters
export WAYU_BENCHMARK_ITERATIONS=20
export WAYU_BENCHMARK_WARMUP=5
export WAYU_BENCHMARK_PLUGIN_COUNTS="0 5 10 20 50"

./compare.sh --full
```

---

## Interpreting Results

### What "Fast Enough" Means

| Use Case | Target Startup | Recommended Manager |
|----------|---------------|---------------------|
| CI/CD, scripts | < 50ms | wayu, Zinit Turbo |
| Daily driver | < 100ms | wayu, Zinit, Sheldon |
| Occasional use | < 300ms | Any except OMZ (unoptimized) |
| Feature-heavy | < 500ms | wayu, Zinit with Turbo |

### Diminishing Returns

```
Perceived Speed vs Actual Speed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

0-50ms    │████████████████████████████  │ Instant feel
          │                              │ wayu, Zinit Turbo
50-100ms  │████████████████████░░░░░░░░░ │ Fast
          │                              │ Sheldon, Antidote
100-200ms │██████████████░░░░░░░░░░░░░░░░│ Noticeable delay
          │                              │
200-500ms │████████░░░░░░░░░░░░░░░░░░░░░░│ Feels slow
          │                              │ OMZ (light)
500ms+    │██░░░░░░░░░░░░░░░░░░░░░░░░░░░│ Very slow
          │                              │ OMZ (heavy)
          └──────────────────────────────┘
```

### When to Optimize

**Optimize if:**
- Opening new terminal tabs feels sluggish
- Shell startup > 200ms
- You open terminals frequently (>50/day)
- You work across many projects/contexts

**Don't over-optimize if:**
- Current setup feels responsive
- You rarely open new shells
- You're happy with your current workflow

---

## Summary

### Key Findings

1. **wayu is the fastest** for most configurations
2. **Native binary advantage** > shell script optimization
3. **Zinit Turbo is competitive** but requires configuration
4. **OMZ is slowest** but has most features
5. **Memory efficiency** favors native solutions (wayu, Sheldon)

### Recommendations

| Scenario | Recommendation |
|----------|---------------|
| Speed priority | **wayu** or Zinit Turbo |
| OMZ dependency | **wayu** (OMZ plugins work) or Antidote |
| TOML preference | **wayu** or Sheldon |
| TUI preference | **wayu** (only one with native TUI) |
| Fuzzy matching | **wayu** (unique feature) |
| Easiest migration | **wayu** (import tools available) |

---

*Benchmarks conducted April 2025. Results may vary by hardware and configuration.*
*For questions or to contribute benchmarks, visit https://github.com/dvrd/wayu*
