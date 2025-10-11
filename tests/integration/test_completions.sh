#!/bin/bash
# Integration tests for completions command

set -e

echo "📋 Testing completions command integration..."
echo ""

# Build the project first
echo "Building wayu..."
task build > /dev/null 2>&1
echo "✓ Build successful"
echo ""

# Create test completion file
echo "Creating test completion file..."
cat > /tmp/_testcomp << 'EOF'
#compdef testcomp
# Test completion for wayu integration test

_testcomp() {
    local context state line
    _arguments -C \
        '1:command:(init add remove list help)' \
        '*::arg:->args'

    case $state in
        args)
            case $line[1] in
                add)
                    _arguments '1:name:' '2:file:_files'
                    ;;
                remove)
                    _arguments '1:name:(foo bar baz)'
                    ;;
            esac
            ;;
    esac
}

_testcomp "$@"
EOF
echo "✓ Test completion file created"
echo ""

# Test 1: Add completion
echo "Test 1: Add completion"
output=$(./bin/wayu completions add testcomp /tmp/_testcomp 2>&1)
if [ -f ~/.config/wayu/completions/_testcomp ]; then
    echo "✓ Test 1 passed: Completion file added successfully"
else
    echo "✗ Test 1 failed: Completion file not found"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 2: List completions
echo "Test 2: List completions"
output=$(./bin/wayu completions list 2>&1)
if [[ $output == *"_testcomp"* ]] && [[ $output == *"Shell Completions"* ]]; then
    echo "✓ Test 2 passed: Completion appears in list"
else
    echo "✗ Test 2 failed: Completion not found in list"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 3: Add completion without underscore prefix
echo "Test 3: Add completion without underscore prefix"
./bin/wayu completions add mycomp /tmp/_testcomp > /dev/null 2>&1
if [ -f ~/.config/wayu/completions/_mycomp ]; then
    echo "✓ Test 3 passed: Underscore prefix added automatically"
else
    echo "✗ Test 3 failed: File not created with underscore prefix"
    exit 1
fi
echo ""

# Test 4: List shows multiple completions
echo "Test 4: List shows multiple completions"
output=$(./bin/wayu completions list 2>&1)
count=$(echo "$output" | grep -c "^\s*[0-9]*\.\s*_.*" || true)
if [ "$count" -ge 2 ]; then
    echo "✓ Test 4 passed: Multiple completions listed"
else
    echo "✗ Test 4 failed: Expected at least 2 completions, found $count"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 5: Remove specific completion
echo "Test 5: Remove specific completion"
./bin/wayu completions rm testcomp > /dev/null 2>&1
if [ ! -f ~/.config/wayu/completions/_testcomp ]; then
    echo "✓ Test 5 passed: Specific completion removed"
else
    echo "✗ Test 5 failed: Completion file still exists"
    exit 1
fi
echo ""

# Test 6: Try to remove non-existent completion
echo "Test 6: Try to remove non-existent completion"
output=$(./bin/wayu completions rm nonexistent 2>&1) || true
if [[ $output == *"Completion not found"* ]]; then
    echo "✓ Test 6 passed: Proper error for non-existent completion"
else
    echo "✗ Test 6 failed: Expected 'not found' error"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 7: Add completion with invalid source file
echo "Test 7: Add completion with invalid source file"
output=$(./bin/wayu completions add invalid /tmp/nonexistent-file 2>&1) || true
if [[ $output == *"File not found"* ]]; then
    echo "✓ Test 7 passed: Proper error for missing source file"
else
    echo "✗ Test 7 failed: Expected 'file not found' error"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 8: Help command
echo "Test 8: Help command"
output=$(./bin/wayu completions help 2>&1)
if [[ $output == *"Completions Command"* ]] && [[ $output == *"EXAMPLES"* ]]; then
    echo "✓ Test 8 passed: Help shows proper information"
else
    echo "✗ Test 8 failed: Help output incomplete"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 9: Verify completion file content
echo "Test 9: Verify completion file content preservation"
if [ -f ~/.config/wayu/completions/_mycomp ]; then
    if grep -q "#compdef testcomp" ~/.config/wayu/completions/_mycomp; then
        echo "✓ Test 9 passed: Completion file content preserved"
    else
        echo "✗ Test 9 failed: Completion file content corrupted"
        exit 1
    fi
else
    echo "✗ Test 9 failed: Completion file missing"
    exit 1
fi
echo ""

# Test 10: List empty completions after cleanup
echo "Test 10: Clean up and verify empty state"
./bin/wayu completions rm mycomp > /dev/null 2>&1
output=$(./bin/wayu completions list 2>&1)
if [[ $output == *"No completions installed"* ]]; then
    echo "✓ Test 10 passed: Empty state handled correctly"
else
    echo "✗ Test 10 failed: Should show 'No completions installed'"
    echo "Output: $output"
    exit 1
fi
echo ""

# Cleanup
rm -f /tmp/_testcomp

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ All completions integration tests passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"