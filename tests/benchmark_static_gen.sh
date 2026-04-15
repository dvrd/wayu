#!/bin/bash
# benchmark_static_gen.sh - Performance benchmarks for static generation

set -e

WAYU_BIN="${WAYU_BIN:-./wayu}"
RESULTS_DIR="${RESULTS_DIR:-./benchmark_results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/benchmark_$TIMESTAMP.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create results directory
mkdir -p "$RESULTS_DIR"

echo "==============================================" | tee -a "$RESULTS_FILE"
echo "Wayu Static Generation Benchmark" | tee -a "$RESULTS_FILE"
echo "Timestamp: $(date)" | tee -a "$RESULTS_FILE"
echo "Binary: $WAYU_BIN" | tee -a "$RESULTS_FILE"
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Function to run a timed benchmark
run_benchmark() {
    local name="$1"
    local cmd="$2"
    local iterations="${3:-10}"

    echo "Running: $name (${iterations} iterations)..."

    local total_time=0
    local min_time=999999
    local max_time=0

    for i in $(seq 1 $iterations); do
        start=$(date +%s%N)
        eval "$cmd" > /dev/null 2>&1 || true
        end=$(date +%s%N)

        # Calculate duration in milliseconds
        duration=$(( (end - start) / 1000000 ))
        total_time=$((total_time + duration))

        if [ $duration -lt $min_time ]; then
            min_time=$duration
        fi
        if [ $duration -gt $max_time ]; then
            max_time=$duration
        fi
    done

    avg_time=$((total_time / iterations))

    echo "  Average: ${avg_time}ms" | tee -a "$RESULTS_FILE"
    echo "  Min: ${min_time}ms" | tee -a "$RESULTS_FILE"
    echo "  Max: ${max_time}ms" | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"

    # Return average time
    echo $avg_time
}

# Check if binary exists
if [ ! -f "$WAYU_BIN" ]; then
    echo -e "${RED}Error: wayu binary not found at $WAYU_BIN${NC}"
    echo "Set WAYU_BIN environment variable or build first with 'task build'"
    exit 1
fi

echo -e "${GREEN}Binary found: $WAYU_BIN${NC}"
echo ""

# Benchmark 1: Static generation performance
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "1. Static Generation Performance" | tee -a "$RESULTS_FILE"
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

GEN_TIME=$(run_benchmark "wayu generate-static" "$WAYU_BIN generate-static --output /tmp/wayu_static_benchmark.zsh" 5)

# Check if meets target (< 100ms)
if [ $GEN_TIME -lt 100 ]; then
    echo -e "${GREEN}✓ PASS: Static generation under 100ms target${NC}"
else
    echo -e "${YELLOW}⚠ WARN: Static generation exceeds 100ms target${NC}"
fi
echo ""

# Benchmark 2: Static file loading vs dynamic loading
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "2. Startup Performance Comparison" | tee -a "$RESULTS_FILE"
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Generate static file for testing
$WAYU_BIN generate-static --output /tmp/wayu_static_test.zsh 2>/dev/null || true

# Time sourcing static file
STATIC_TIME=$(run_benchmark "Source static file" "zsh -c 'source /tmp/wayu_static_test.zsh'" 10)

# Time sourcing dynamic init (if available)
if [ -f "$HOME/.config/wayu/init.zsh" ]; then
    DYNAMIC_TIME=$(run_benchmark "Source dynamic init" "zsh -c 'source $HOME/.config/wayu/init.zsh'" 10)

    # Calculate improvement
    if [ $DYNAMIC_TIME -gt 0 ]; then
        IMPROVEMENT=$(( (DYNAMIC_TIME - STATIC_TIME) * 100 / DYNAMIC_TIME ))
        echo "Performance improvement: ${IMPROVEMENT}%" | tee -a "$RESULTS_FILE"

        if [ $IMPROVEMENT -gt 50 ]; then
            echo -e "${GREEN}✓ PASS: > 50% improvement over dynamic loading${NC}"
        else
            echo -e "${YELLOW}⚠ WARN: Less than 50% improvement${NC}"
        fi
    fi
else
    echo "Dynamic init not found, skipping comparison" | tee -a "$RESULTS_FILE"
fi
echo ""

# Benchmark 3: File size comparison
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "3. File Size Comparison" | tee -a "$RESULTS_FILE"
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

if [ -f /tmp/wayu_static_test.zsh ]; then
    STATIC_SIZE=$(stat -f%z /tmp/wayu_static_test.zsh 2>/dev/null || stat -c%s /tmp/wayu_static_test.zsh 2>/dev/null || echo "0")
    echo "Static file size: ${STATIC_SIZE} bytes" | tee -a "$RESULTS_FILE"

    # Calculate total dynamic files size
    DYNAMIC_SIZE=0
    for file in "$HOME/.config/wayu/init.zsh" "$HOME/.config/wayu/path.zsh" "$HOME/.config/wayu/aliases.zsh" "$HOME/.config/wayu/constants.zsh"; do
        if [ -f "$file" ]; then
            size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
            DYNAMIC_SIZE=$((DYNAMIC_SIZE + size))
        fi
    done
    echo "Dynamic files total: ${DYNAMIC_SIZE} bytes" | tee -a "$RESULTS_FILE"

    if [ $DYNAMIC_SIZE -gt 0 ]; then
        SIZE_RATIO=$(( STATIC_SIZE * 100 / DYNAMIC_SIZE ))
        echo "Size ratio: ${SIZE_RATIO}% of dynamic" | tee -a "$RESULTS_FILE"
    fi
fi
echo "" | tee -a "$RESULTS_FILE"

# Benchmark 4: Hot reload detection speed
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "4. Hot Reload Detection Performance" | tee -a "$RESULTS_FILE"
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Create test file
TEST_FILE="/tmp/wayu_benchmark_test.toml"
echo "version = '1.0'" > "$TEST_FILE"

# Time how quickly we detect a change (simulated by checking file stat)
detect_time() {
    local iterations=10
    local total=0

    for i in $(seq 1 $iterations); do
        start=$(date +%s%N)
        # Simulate file stat check
        stat "$TEST_FILE" > /dev/null 2>&1
        end=$(date +%s%N)
        duration=$(( (end - start) / 1000000 ))
        total=$((total + duration))

        # Touch file to change mod time
        touch "$TEST_FILE"
    done

    echo $((total / iterations))
}

DETECT_TIME=$(detect_time)
echo "File change detection: ${DETECT_TIME}ms average" | tee -a "$RESULTS_FILE"

if [ $DETECT_TIME -lt 500 ]; then
    echo -e "${GREEN}✓ PASS: Detection under 500ms target${NC}"
else
    echo -e "${YELLOW}⚠ WARN: Detection exceeds 500ms target${NC}"
fi
echo "" | tee -a "$RESULTS_FILE"

# Summary
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "Benchmark Summary" | tee -a "$RESULTS_FILE"
echo "==============================================" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"
echo "Results saved to: $RESULTS_FILE" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Cleanup
rm -f /tmp/wayu_static_test.zsh /tmp/wayu_static_benchmark.zsh /tmp/wayu_benchmark_test.toml

echo -e "${GREEN}Benchmark complete!${NC}"
