#!/bin/bash
# Integration tests for validation

set -e

echo "🧪 Testing validation integration..."
echo ""

# Build the project first
echo "Building wayu..."
task build > /dev/null 2>&1
echo "✓ Build successful"
echo ""

# Test 1: Invalid name with space
echo "Test 1: Invalid name with space"
output=$(./bin/wayu alias add "bad name" "ls" 2>&1) || true
if [[ $output == *"invalid character"* ]]; then
    echo "✓ Test 1 passed: Space in name rejected"
else
    echo "✗ Test 1 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 2: Invalid name starting with digit
echo "Test 2: Invalid name starting with digit"
output=$(./bin/wayu alias add "123abc" "ls" 2>&1) || true
if [[ $output == *"must start with a letter"* ]]; then
    echo "✓ Test 2 passed: Digit start rejected"
else
    echo "✗ Test 2 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 3: Reserved word
echo "Test 3: Reserved word"
output=$(./bin/wayu alias add "if" "ls" 2>&1) || true
if [[ $output == *"reserved word"* ]]; then
    echo "✓ Test 3 passed: Reserved word rejected"
else
    echo "✗ Test 3 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 4: Valid alias works
echo "Test 4: Valid alias works"
./bin/wayu alias add testvalidalias "echo test" > /dev/null 2>&1
if grep -q "testvalidalias" ~/.config/wayu/aliases.zsh; then
    echo "✓ Test 4 passed: Valid alias accepted"
    ./bin/wayu alias rm testvalidalias > /dev/null 2>&1
else
    echo "✗ Test 4 failed"
    exit 1
fi
echo ""

# Test 5: Empty alias name
echo "Test 5: Empty alias name"
output=$(./bin/wayu alias add "" "ls" 2>&1) || true
if [[ $output == *"cannot be empty"* ]]; then
    echo "✓ Test 5 passed: Empty name rejected"
else
    echo "✗ Test 5 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 6: Empty command
echo "Test 6: Empty command"
output=$(./bin/wayu alias add myalias "" 2>&1) || true
if [[ $output == *"cannot be empty"* ]]; then
    echo "✓ Test 6 passed: Empty command rejected"
else
    echo "✗ Test 6 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 7: Valid constant works
echo "Test 7: Valid constant works"
./bin/wayu constants add TEST_CONST_VAL "test value" > /dev/null 2>&1
if grep -q "TEST_CONST_VAL" ~/.config/wayu/constants.zsh; then
    echo "✓ Test 7 passed: Valid constant accepted"
    ./bin/wayu constants rm TEST_CONST_VAL > /dev/null 2>&1
else
    echo "✗ Test 7 failed"
    exit 1
fi
echo ""

# Test 8: Invalid constant name (with dash)
echo "Test 8: Invalid constant name (with dash)"
output=$(./bin/wayu constants add "BAD-CONST" "value" 2>&1) || true
if [[ $output == *"invalid character"* ]]; then
    echo "✓ Test 8 passed: Invalid constant name rejected"
else
    echo "✗ Test 8 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ All validation integration tests passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
