#!/bin/bash
# Crash diagnostic script for wayu --tui segfault
# Run this in your terminal: bash scripts/crash-test.sh

set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

echo "=== wayu TUI Crash Diagnostic ==="
echo ""

# 1. Build ASAN version
echo "[1/4] Building with address sanitizer..."
odin build src -out:bin/wayu_asan -o:speed -sanitize:address 2>&1
echo "  ✓ ASAN build complete"

# 2. Build debug version
echo "[2/4] Building debug version..."
odin build src -out:bin/wayu_debug -debug 2>&1
echo "  ✓ Debug build complete"

# 3. Build release version
echo "[3/4] Building release version..."
odin build src -out:bin/wayu_release -o:speed 2>&1
echo "  ✓ Release build complete"

echo ""
echo "[4/4] Running tests..."
echo ""

# Test 1: ASAN build
echo "--- Test A: ASAN build (address sanitizer) ---"
echo "  Running: ./bin/wayu_asan --tui"
echo "  Press 'q' to quit after interacting, or it will crash with ASAN output"
echo ""
./bin/wayu_asan --tui 2>/tmp/wayu_asan_stderr.log
ASAN_EXIT=$?
echo ""
echo "  Exit code: $ASAN_EXIT"
if [ -s /tmp/wayu_asan_stderr.log ]; then
    echo "  ASAN stderr output:"
    cat /tmp/wayu_asan_stderr.log
fi
echo ""

# Test 2: Debug build
echo "--- Test B: Debug build ---"
echo "  Running: ./bin/wayu_debug --tui"
echo "  Press 'q' to quit"
echo ""
./bin/wayu_debug --tui 2>/tmp/wayu_debug_stderr.log
DEBUG_EXIT=$?
echo ""
echo "  Exit code: $DEBUG_EXIT"
if [ -s /tmp/wayu_debug_stderr.log ]; then
    echo "  Debug stderr output:"
    cat /tmp/wayu_debug_stderr.log
fi
echo ""

# Test 3: Release build
echo "--- Test C: Release build (-o:speed) ---"
echo "  Running: ./bin/wayu_release --tui"
echo "  Press 'q' to quit"
echo ""
./bin/wayu_release --tui 2>/tmp/wayu_release_stderr.log
RELEASE_EXIT=$?
echo ""
echo "  Exit code: $RELEASE_EXIT"
if [ -s /tmp/wayu_release_stderr.log ]; then
    echo "  Release stderr output:"
    cat /tmp/wayu_release_stderr.log
fi
echo ""

# Summary
echo "=== SUMMARY ==="
echo "  ASAN build exit:    $ASAN_EXIT $([ $ASAN_EXIT -eq 139 ] && echo '⚠️  SEGFAULT' || echo '✓')"
echo "  Debug build exit:   $DEBUG_EXIT $([ $DEBUG_EXIT -eq 139 ] && echo '⚠️  SEGFAULT' || echo '✓')"
echo "  Release build exit: $RELEASE_EXIT $([ $RELEASE_EXIT -eq 139 ] && echo '⚠️  SEGFAULT' || echo '✓')"
echo ""
echo "ASAN log: /tmp/wayu_asan_stderr.log"
echo "Debug log: /tmp/wayu_debug_stderr.log"
echo "Release log: /tmp/wayu_release_stderr.log"
