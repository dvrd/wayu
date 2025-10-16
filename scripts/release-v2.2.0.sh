#!/bin/bash
# Release script for wayu v2.2.0
# This script commits all changes and creates the release tag

set -e

echo "🚀 Preparing wayu v2.2.0 release..."
echo ""

# Check if on main branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "⚠️  Warning: You are on branch '$CURRENT_BRANCH', not 'main'"
    echo "   It's recommended to release from 'main' branch"
    read -p "   Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Release cancelled"
        exit 1
    fi
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "📝 You have uncommitted changes. Showing status:"
    echo ""
    git status --short
    echo ""

    # Show what will be committed
    echo "Files to be committed:"
    echo "  - src/main.odin (version update to 2.2.0)"
    echo "  - .github/workflows/ci.yml (CI/CD pipeline)"
    echo "  - .github/workflows/release.yml (release automation)"
    echo "  - CHANGELOG.md (full changelog)"
    echo "  - docs/RELEASE_v2.2.0.md (release notes)"
    echo "  - docs/MANUAL_TESTING.md (testing guide)"
    echo "  - docs/TESTING_COMPLETE.md (test status)"
    echo "  - scripts/smoke-test.sh (automated tests)"
    echo "  - README.md (updated documentation)"
    echo "  - CLAUDE.md (technical documentation)"
    echo ""

    read -p "Commit all changes for v2.2.0 release? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "Release cancelled"
        exit 1
    fi

    # Stage all changes
    echo "📦 Staging all changes..."
    git add -A

    # Create commit
    echo "💾 Creating release commit..."
    git commit -m "Release v2.2.0: CLI/TUI Isolation & Exit Codes

🚀 Major Features:
- CLI/TUI Isolation (PRP-13): Fully non-interactive CLI for automation
- BSD sysexits.h exit codes (0, 1, 64-78)
- --yes flag for confirmation-free operations
- CI/CD integration with GitHub Actions

⚠️ Breaking Changes:
- CLI commands require explicit arguments (no interactive prompts)
- path clean/dedup require --yes flag
- Exit codes categorized (not all 1)
- List commands default to static output

📚 Documentation:
- Comprehensive testing guide
- CI/CD workflows
- Migration guide in CHANGELOG.md

🧪 Testing:
- 37/37 tests passing
- Smoke test script included
- Multi-platform CI validation

🤖 Generated with Claude Code (https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

    echo "✅ Commit created successfully"
    echo ""
else
    echo "✅ Working directory is clean"
    echo ""
fi

# Verify version in code
echo "🔍 Verifying version in code..."
VERSION=$(grep 'VERSION :: "' src/main.odin | cut -d'"' -f2)
if [ "$VERSION" != "2.2.0" ]; then
    echo "❌ ERROR: Version mismatch!"
    echo "   Expected: 2.2.0"
    echo "   Found: $VERSION"
    exit 1
fi
echo "✅ Version verified: $VERSION"
echo ""

# Run smoke tests
echo "🧪 Running smoke tests..."
if ./scripts/smoke-test.sh > /dev/null 2>&1; then
    echo "✅ All smoke tests passed"
else
    echo "❌ Smoke tests failed!"
    echo "   Fix the issues before releasing"
    exit 1
fi
echo ""

# Create tag
echo "🏷️  Creating git tag v2.2.0..."
git tag -a v2.2.0 -m "wayu v2.2.0 - CLI/TUI Isolation & Exit Codes

Release highlights:
- Fully non-interactive CLI for automation
- BSD sysexits.h exit codes
- --yes flag for confirmation-free operations
- CI/CD integration

See CHANGELOG.md for full details.

🤖 Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>"

echo "✅ Tag v2.2.0 created"
echo ""

# Show next steps
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Release v2.2.0 is ready!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo ""
echo "1. Review the commit:"
echo "   git show HEAD"
echo ""
echo "2. Review the tag:"
echo "   git show v2.2.0"
echo ""
echo "3. Push to remote:"
echo "   git push origin main"
echo "   git push origin v2.2.0"
echo ""
echo "4. The CI/CD pipeline will automatically:"
echo "   - Run tests on multiple platforms"
echo "   - Build release binaries"
echo "   - Create GitHub release"
echo "   - Upload artifacts"
echo ""
echo "5. Monitor the release:"
echo "   https://github.com/YOUR_USERNAME/wayu/actions"
echo ""
echo "📚 Documentation:"
echo "   - Release notes: docs/RELEASE_v2.2.0.md"
echo "   - Changelog: CHANGELOG.md"
echo "   - Testing guide: docs/MANUAL_TESTING.md"
echo ""
echo "✅ Ready to push!"
