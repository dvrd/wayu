#!/bin/bash
# Integration tests for enhanced error messages

set -e

echo "🔥 Testing enhanced error messages..."
echo ""

# Build the project first
echo "Building wayu..."
task build > /dev/null 2>&1
echo "✓ Build successful"
echo ""

# Test 1: Config not initialized error
echo "Test 1: Config not initialized error"
# Safely backup config if it exists
mv ~/.config/wayu ~/.config/wayu.backup 2>/dev/null || true
output=$(./bin/wayu path list 2>&1) || true
if [[ $output == *"wayu init"* ]] && [[ $output == *"First time using wayu"* ]]; then
    echo "✓ Test 1 passed: Config not found shows init suggestion"
else
    echo "✗ Test 1 failed"
    echo "Output: $output"
    # Restore config if test failed
    mv ~/.config/wayu.backup ~/.config/wayu 2>/dev/null || true
    exit 1
fi
echo ""

# Initialize for next tests
echo "Initializing wayu for further tests..."
./bin/wayu init <<< "y" > /dev/null 2>&1
echo ""

# Test 2: Permission error
echo "Test 2: Permission denied error"
chmod 000 ~/.config/wayu/path.zsh
output=$(./bin/wayu path list 2>&1) || true
if [[ $output == *"Permission denied"* ]] && [[ $output == *"chmod"* ]]; then
    echo "✓ Test 2 passed: Permission error shows chmod suggestion"
else
    echo "✗ Test 2 failed"
    echo "Output: $output"
    exit 1
fi
chmod 644 ~/.config/wayu/path.zsh
echo ""

# Test 3: Non-existent directory
echo "Test 3: Non-existent directory"
# Create a directory that doesn't exist but has valid parent
mkdir -p /tmp/test-parent
output=$(./bin/wayu path add /tmp/test-parent/nonexistent 2>&1) || true
rmdir /tmp/test-parent
if [[ $output == *"Directory not found"* ]]; then
    echo "✓ Test 3 passed: Non-existent directory shows error"
else
    echo "✗ Test 3 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 4: Invalid path handling
echo "Test 4: Invalid path handling"
output=$(./bin/wayu path add "" 2>&1) || true
if [[ $output == *"cannot be empty"* ]]; then
    echo "✓ Test 4 passed: Empty path validation works"
else
    echo "✗ Test 4 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 5: Invalid input with specific help suggestion
echo "Test 5: Invalid input with help suggestion"
output=$(./bin/wayu alias add "bad-name" "echo test" 2>&1) || true
if [[ $output == *"wayu alias help"* ]]; then
    echo "✓ Test 5 passed: Invalid alias shows alias help suggestion"
else
    echo "✗ Test 5 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 6: File write error (simulate by making directory read-only)
echo "Test 6: File write error"
chmod 555 ~/.config/wayu/
output=$(./bin/wayu alias add testalias "echo test" 2>&1) || true
if [[ $output == *"Failed to write"* ]] || [[ $output == *"Permission denied"* ]]; then
    echo "✓ Test 6 passed: Write permission error shown"
else
    echo "✗ Test 6 failed"
    echo "Output: $output"
    exit 1
fi
chmod 755 ~/.config/wayu/
echo ""

# Test 7: Validation error with proper formatting
echo "Test 7: Validation error formatting"
output=$(./bin/wayu constants add "123invalid" "value" 2>&1) || true
if [[ $output == *"ERROR:"* ]] && [[ $output == *"must start with a letter"* ]]; then
    echo "✓ Test 7 passed: Validation error properly formatted"
else
    echo "✗ Test 7 failed"
    echo "Output: $output"
    exit 1
fi
echo ""

# Test 8: Valid operation still works
echo "Test 8: Valid operations still work"
./bin/wayu path add /usr/local/bin > /dev/null 2>&1
if grep -q "/usr/local/bin" ~/.config/wayu/path.zsh; then
    echo "✓ Test 8 passed: Valid operations work normally"
    ./bin/wayu path rm /usr/local/bin > /dev/null 2>&1
else
    echo "✗ Test 8 failed"
    exit 1
fi
echo ""

# Restore original config if it existed
if [ -d ~/.config/wayu.backup ]; then
    rm -rf ~/.config/wayu
    mv ~/.config/wayu.backup ~/.config/wayu
    echo "Restored original wayu configuration"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ All enhanced error message tests passed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"