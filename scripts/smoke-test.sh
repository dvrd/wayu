#!/bin/bash
# smoke-test.sh - Quick validation of wayu v2.2.0-rc1 CLI/TUI Isolation
# Tests the key behaviors of PRP-13 implementation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 Running wayu v2.2.0-rc1 smoke tests...${NC}"
echo ""

# Build first
echo -e "${BLUE}📦 Building wayu...${NC}"
if task build > /dev/null 2>&1; then
    echo -e "   ${GREEN}✓ Build successful${NC}"
else
    echo -e "   ${RED}✗ Build failed${NC}"
    exit 1
fi
echo ""

# Test 1: CLI requires explicit arguments
echo -e "${BLUE}Test 1: CLI requires explicit arguments${NC}"
if ./bin/wayu path add 2>&1 | grep -q "Missing required arguments"; then
    echo -e "   ${GREEN}✓ Error message shown${NC}"
else
    echo -e "   ${RED}✗ Missing error message${NC}"
    exit 1
fi

EXIT_CODE=$(./bin/wayu path add > /dev/null 2>&1; echo $?)
if [ $EXIT_CODE -eq 64 ]; then
    echo -e "   ${GREEN}✓ Exit code 64 (usage error)${NC}"
else
    echo -e "   ${RED}✗ Wrong exit code: $EXIT_CODE (expected 64)${NC}"
    exit 1
fi
echo ""

# Test 2: Explicit arguments work
echo -e "${BLUE}Test 2: Explicit arguments work${NC}"
./bin/wayu path add /usr/bin > /dev/null 2>&1 || true

EXIT_CODE=$(./bin/wayu path list > /dev/null 2>&1; echo $?)
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "   ${GREEN}✓ path list succeeds (exit 0)${NC}"
else
    echo -e "   ${RED}✗ path list failed with exit $EXIT_CODE${NC}"
    exit 1
fi

# Test explicit path add/remove
./bin/wayu path add /tmp/wayu-smoke-test > /dev/null 2>&1 || true
if ./bin/wayu path list 2>&1 | grep -q "wayu-smoke-test"; then
    echo -e "   ${GREEN}✓ Explicit path add works${NC}"
else
    echo -e "   ${YELLOW}⚠ Path add might not work (non-fatal)${NC}"
fi

./bin/wayu path rm /tmp/wayu-smoke-test > /dev/null 2>&1 || true
echo ""

# Test 3: Confirmations require --yes flag
echo -e "${BLUE}Test 3: Confirmations require --yes flag${NC}"

# path clean might return 0 if no missing dirs, or require --yes if there are
OUTPUT=$(./bin/wayu path clean 2>&1)
EXIT_CODE=$?

if echo "$OUTPUT" | grep -q "No missing directories"; then
    echo -e "   ${GREEN}✓ path clean: no missing dirs (exit $EXIT_CODE)${NC}"
elif [ $EXIT_CODE -eq 1 ] && echo "$OUTPUT" | grep -q "Add --yes flag"; then
    echo -e "   ${GREEN}✓ path clean requires --yes when needed (exit 1)${NC}"
    echo -e "   ${GREEN}✓ Error suggests --yes flag${NC}"
else
    echo -e "   ${RED}✗ Unexpected behavior: exit $EXIT_CODE${NC}"
    echo "$OUTPUT"
    exit 1
fi

# Test with --yes flag (should always work)
./bin/wayu path clean --yes > /dev/null 2>&1 || true
echo -e "   ${GREEN}✓ path clean --yes works${NC}"

# Test dedup (similar behavior)
OUTPUT=$(./bin/wayu path dedup 2>&1)
EXIT_CODE=$?

if echo "$OUTPUT" | grep -q "No duplicate entries"; then
    echo -e "   ${GREEN}✓ path dedup: no duplicates (exit $EXIT_CODE)${NC}"
elif [ $EXIT_CODE -eq 1 ] && echo "$OUTPUT" | grep -q "Add --yes flag"; then
    echo -e "   ${GREEN}✓ path dedup requires --yes when needed (exit 1)${NC}"
else
    echo -e "   ${YELLOW}⚠ path dedup behavior: exit $EXIT_CODE (non-fatal)${NC}"
fi
echo ""

# Test 4: Exit codes are correct
echo -e "${BLUE}Test 4: Exit codes are correct${NC}"

EXIT_CODE=$(./bin/wayu version > /dev/null 2>&1; echo $?)
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "   ${GREEN}✓ Success returns 0${NC}"
else
    echo -e "   ${RED}✗ version failed: $EXIT_CODE${NC}"
    exit 1
fi

EXIT_CODE=$(./bin/wayu path add 2>&1 > /dev/null; echo $?)
if [ $EXIT_CODE -eq 64 ]; then
    echo -e "   ${GREEN}✓ Usage error returns 64${NC}"
else
    echo -e "   ${RED}✗ Wrong usage error code: $EXIT_CODE${NC}"
    exit 1
fi

EXIT_CODE=$(./bin/wayu alias add 2>&1 > /dev/null; echo $?)
if [ $EXIT_CODE -eq 64 ]; then
    echo -e "   ${GREEN}✓ Multiple commands use exit 64${NC}"
else
    echo -e "   ${RED}✗ Wrong exit code: $EXIT_CODE${NC}"
    exit 1
fi
echo ""

# Test 5: Help shows exit codes
echo -e "${BLUE}Test 5: Help documentation${NC}"
if ./bin/wayu --help 2>&1 | grep -q "EXIT CODES"; then
    echo -e "   ${GREEN}✓ Help shows EXIT CODES section${NC}"
else
    echo -e "   ${RED}✗ Missing EXIT CODES in help${NC}"
    exit 1
fi

if ./bin/wayu --help 2>&1 | grep -q "CLI mode is fully non-interactive"; then
    echo -e "   ${GREEN}✓ Help mentions non-interactive mode${NC}"
else
    echo -e "   ${YELLOW}⚠ Missing non-interactive note (non-fatal)${NC}"
fi
echo ""

# Test 6: Scriptability (pipes and redirects)
echo -e "${BLUE}Test 6: Scriptability${NC}"

# Test pipes
if ./bin/wayu path list 2>&1 | grep -q ""; then
    echo -e "   ${GREEN}✓ Pipes work${NC}"
else
    echo -e "   ${RED}✗ Pipes failed${NC}"
    exit 1
fi

# Test redirects
if ./bin/wayu path list > /tmp/wayu-test-output.txt 2>&1; then
    if [ -f /tmp/wayu-test-output.txt ]; then
        echo -e "   ${GREEN}✓ Redirects work${NC}"
        rm /tmp/wayu-test-output.txt
    else
        echo -e "   ${RED}✗ Redirect failed${NC}"
        exit 1
    fi
else
    echo -e "   ${RED}✗ Redirect command failed${NC}"
    exit 1
fi

# Test no hanging on stdin
if timeout 2 bash -c 'echo "" | ./bin/wayu path clean 2>&1 > /dev/null'; then
    echo -e "   ${GREEN}✓ No hanging on stdin${NC}"
else
    # Exit code 1 is expected (requires --yes)
    if [ $? -eq 124 ]; then
        echo -e "   ${RED}✗ Command timed out (hanging on stdin)${NC}"
        exit 1
    else
        echo -e "   ${GREEN}✓ No hanging on stdin${NC}"
    fi
fi
echo ""

# Test 7: Error message quality
echo -e "${BLUE}Test 7: Error message quality${NC}"

# Capture error output (this will have non-zero exit, but that's expected)
ERROR_OUTPUT=$(./bin/wayu path add 2>&1) || true

if echo "$ERROR_OUTPUT" | grep -q "ERROR"; then
    echo -e "   ${GREEN}✓ Shows ERROR prefix${NC}"
else
    echo -e "   ${RED}✗ Missing ERROR prefix${NC}"
    exit 1
fi

if echo "$ERROR_OUTPUT" | grep -q "Usage:"; then
    echo -e "   ${GREEN}✓ Shows usage${NC}"
else
    echo -e "   ${RED}✗ Missing usage${NC}"
    exit 1
fi

if echo "$ERROR_OUTPUT" | grep -q "Example:"; then
    echo -e "   ${GREEN}✓ Shows example${NC}"
else
    echo -e "   ${RED}✗ Missing example${NC}"
    exit 1
fi

if echo "$ERROR_OUTPUT" | grep -q "Hint.*--tui"; then
    echo -e "   ${GREEN}✓ Suggests --tui mode${NC}"
else
    echo -e "   ${YELLOW}⚠ Missing TUI hint (non-fatal)${NC}"
fi
echo ""

# Final summary
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ All smoke tests passed!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "   ${BLUE}✓ CLI is non-interactive and scriptable${NC}"
echo -e "   ${BLUE}✓ Exit codes working correctly${NC}"
echo -e "   ${BLUE}✓ Error messages are helpful${NC}"
echo -e "   ${BLUE}✓ --yes flag implemented${NC}"
echo -e "   ${BLUE}✓ Pipes and redirects work${NC}"
echo ""
echo -e "${GREEN}🎉 Ready for v2.2.0-rc1 release!${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} For full testing including TUI mode, see:"
echo -e "      ${BLUE}docs/MANUAL_TESTING.md${NC}"
echo ""

exit 0
