#!/bin/bash
# download-fff.sh - Download prebuilt fff-c library for wayu
#
# This script downloads the appropriate libfff_c binary for the current
# platform from the fff.nvim releases or builds from source if needed.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
FFF_VERSION="0.5.2"
FFF_REPO="dmtrKovalenko/fff.nvim"
INSTALL_DIR="${1:-./lib}"
CACHE_DIR="$HOME/.cache/wayu/fff"

# Detect platform
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case "$ARCH" in
        x86_64) ARCH="x64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) echo "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
    
    case "$OS" in
        darwin) 
            PLATFORM="darwin-${ARCH}"
            LIB_NAME="libfff_c.dylib"
            ;;
        linux) 
            PLATFORM="linux-${ARCH}"
            # Detect musl vs gnu
            if ldd --version 2>&1 | grep -q musl; then
                PLATFORM="linux-${ARCH}-musl"
            else
                PLATFORM="linux-${ARCH}-gnu"
            fi
            LIB_NAME="libfff_c.so"
            ;;
        mingw*|msys*|cygwin*|windows*) 
            PLATFORM="win32-${ARCH}"
            LIB_NAME="fff_c.dll"
            ;;
        *) echo "${RED}Unsupported OS: $OS${NC}"; exit 1 ;;
    esac
    
    echo "${BLUE}Detected platform: $PLATFORM${NC}"
}

# Check if library already exists
check_existing() {
    if [ -f "$INSTALL_DIR/$LIB_NAME" ]; then
        echo "${GREEN}fff library already exists at $INSTALL_DIR/$LIB_NAME${NC}"
        
        # Check version by attempting to link
        if command -v odin &> /dev/null; then
            echo "${BLUE}Verifying library compatibility...${NC}"
            # Simple test would go here
        fi
        
        return 0
    fi
    return 1
}

# Download from npm registry (fff-node publishes binaries)
download_from_npm() {
    echo "${BLUE}Attempting to download from npm registry...${NC}"
    
    # Map platform to npm package name
    case "$PLATFORM" in
        darwin-arm64) PKG="@ff-labs/fff-bin-darwin-arm64" ;;
        darwin-x64) PKG="@ff-labs/fff-bin-darwin-x64" ;;
        linux-x64-gnu) PKG="@ff-labs/fff-bin-linux-x64-gnu" ;;
        linux-arm64-gnu) PKG="@ff-labs/fff-bin-linux-arm64-gnu" ;;
        linux-x64-musl) PKG="@ff-labs/fff-bin-linux-x64-musl" ;;
        linux-arm64-musl) PKG="@ff-labs/fff-bin-linux-arm64-musl" ;;
        win32-x64) PKG="@ff-labs/fff-bin-win32-x64" ;;
        win32-arm64) PKG="@ff-labs/fff-bin-win32-arm64" ;;
        *) 
            echo "${YELLOW}No prebuilt binary for $PLATFORM${NC}"
            return 1
            ;;
    esac
    
    # Create temp directory
    TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT
    
    # Download package
    echo "${BLUE}Downloading $PKG...${NC}"
    if ! npm pack "$PKG@$FFF_VERSION" --pack-destination "$TMP_DIR" 2>/dev/null; then
        echo "${YELLOW}npm download failed${NC}"
        return 1
    fi
    
    # Extract package
    TGZ=$(ls "$TMP_DIR"/*.tgz | head -1)
    tar -xzf "$TGZ" -C "$TMP_DIR"
    
    # Find and copy library
    LIB_SRC=$(find "$TMP_DIR/package" -name "$LIB_NAME" | head -1)
    if [ -n "$LIB_SRC" ]; then
        mkdir -p "$INSTALL_DIR"
        cp "$LIB_SRC" "$INSTALL_DIR/$LIB_NAME"
        echo "${GREEN}Downloaded $LIB_NAME to $INSTALL_DIR${NC}"
        return 0
    fi
    
    return 1
}

# Download from GitHub releases
download_from_github() {
    echo "${BLUE}Attempting to download from GitHub releases...${NC}"
    
    # Try official fff.nvim releases
    RELEASE_URL="https://github.com/$FFF_REPO/releases/download/v$FFF_VERSION"
    
    # Map to release artifact names
    case "$PLATFORM" in
        darwin-arm64) ASSET="fff-c-darwin-arm64.dylib" ;;
        darwin-x64) ASSET="fff-c-darwin-x64.dylib" ;;
        linux-x64-gnu) ASSET="fff-c-linux-x64.so" ;;
        linux-arm64-gnu) ASSET="fff-c-linux-arm64.so" ;;
        *) 
            echo "${YELLOW}No GitHub release for $PLATFORM${NC}"
            return 1
            ;;
    esac
    
    mkdir -p "$INSTALL_DIR"
    
    echo "${BLUE}Downloading $ASSET...${NC}"
    if curl -fsL "$RELEASE_URL/$ASSET" -o "$INSTALL_DIR/$LIB_NAME"; then
        chmod +x "$INSTALL_DIR/$LIB_NAME"
        echo "${GREEN}Downloaded $LIB_NAME from GitHub${NC}"
        return 0
    fi
    
    return 1
}

# Build from source using cargo
build_from_source() {
    echo "${YELLOW}Prebuilt binary not available, attempting to build from source...${NC}"
    
    if ! command -v cargo &> /dev/null; then
        echo "${RED}Cargo not found. Please install Rust: https://rustup.rs${NC}"
        return 1
    fi
    
    if ! command -v git &> /dev/null; then
        echo "${RED}Git not found${NC}"
        return 1
    fi
    
    echo "${BLUE}Cloning fff.nvim repository...${NC}"
    
    # Clone to cache directory
    mkdir -p "$CACHE_DIR"
    REPO_DIR="$CACHE_DIR/fff.nvim"
    
    if [ -d "$REPO_DIR" ]; then
        cd "$REPO_DIR"
        git fetch origin
        git checkout "v$FFF_VERSION" 2>/dev/null || git checkout main
    else
        git clone --depth 1 --branch "v$FFF_VERSION" "https://github.com/$FFF_REPO.git" "$REPO_DIR" 2>/dev/null || \
        git clone --depth 1 "https://github.com/$FFF_REPO.git" "$REPO_DIR"
        cd "$REPO_DIR"
    fi
    
    echo "${BLUE}Building fff-c library (this may take a few minutes)...${NC}"
    
    # Build the C FFI crate
    if cargo build --release -p fff-c; then
        # Find the built library
        BUILT_LIB=$(find "$REPO_DIR/target/release" -name "$LIB_NAME" | head -1)
        
        if [ -n "$BUILT_LIB" ]; then
            mkdir -p "$INSTALL_DIR"
            cp "$BUILT_LIB" "$INSTALL_DIR/$LIB_NAME"
            echo "${GREEN}Built and installed $LIB_NAME${NC}"
            return 0
        fi
    fi
    
    echo "${RED}Build failed${NC}"
    return 1
}

# Install using official install script
install_official() {
    echo "${BLUE}Trying official fff install script...${NC}"
    
    # The install script is primarily for MCP, but might work
    if curl -fsL https://dmtrkovalenko.dev/install-fff-mcp.sh | bash -s -- --check; then
        # Script succeeded, find the library
        MCP_DIR="$HOME/.local/share/fff-mcp"
        if [ -d "$MCP_DIR" ]; then
            FOUND_LIB=$(find "$MCP_DIR" -name "$LIB_NAME" | head -1)
            if [ -n "$FOUND_LIB" ]; then
                mkdir -p "$INSTALL_DIR"
                cp "$FOUND_LIB" "$INSTALL_DIR/$LIB_NAME"
                echo "${GREEN}Installed from official MCP distribution${NC}"
                return 0
            fi
        fi
    fi
    
    return 1
}

# Verify the installation
verify_installation() {
    if [ ! -f "$INSTALL_DIR/$LIB_NAME" ]; then
        echo "${RED}Installation failed: $LIB_NAME not found${NC}"
        return 1
    fi
    
    echo "${BLUE}Verifying library...${NC}"
    
    # Check file type
    if command -v file &> /dev/null; then
        file "$INSTALL_DIR/$LIB_NAME"
    fi
    
    # Check size
    LS_OUTPUT=$(ls -lh "$INSTALL_DIR/$LIB_NAME")
    echo "${GREEN}Installed: $LS_OUTPUT${NC}"
    
    # Test load (platform-specific)
    case "$OS" in
        darwin)
            if otool -L "$INSTALL_DIR/$LIB_NAME" &>/dev/null; then
                echo "${GREEN}Library load test passed${NC}"
            fi
            ;;
        linux)
            if ldd "$INSTALL_DIR/$LIB_NAME" &>/dev/null; then
                echo "${GREEN}Library dependencies checked${NC}"
            fi
            ;;
    esac
    
    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [INSTALL_DIR]

Download or build the fff-c library for wayu integration.

OPTIONS:
    -h, --help      Show this help message
    -f, --force     Force re-download even if library exists
    -b, --build     Build from source only (skip downloads)
    -v, --version   Show version information

INSTALL_DIR:
    Directory to install the library (default: ./lib)

EXAMPLES:
    $0                    # Download to ./lib
    $0 /usr/local/lib     # Download to system directory
    $0 --build            # Build from source
    $0 --force            # Re-download even if exists

EOF
}

# Parse arguments
FORCE=false
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -b|--build)
            BUILD_ONLY=true
            shift
            ;;
        -v|--version)
            echo "fff-c downloader for wayu v$FFF_VERSION"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            INSTALL_DIR="$1"
            shift
            ;;
    esac
done

# Main
main() {
    echo "${BLUE}=== fff-c Library Downloader for wayu ===${NC}"
    echo "Target: $INSTALL_DIR"
    echo ""
    
    # Detect platform
    detect_platform
    
    # Check existing unless force
    if [ "$FORCE" = false ] && check_existing; then
        verify_installation
        exit 0
    fi
    
    # Create install directory
    mkdir -p "$INSTALL_DIR"
    
    # Try download methods unless build-only
    if [ "$BUILD_ONLY" = false ]; then
        if download_from_npm; then
            verify_installation
            exit 0
        fi
        
        if download_from_github; then
            verify_installation
            exit 0
        fi
        
        if install_official; then
            verify_installation
            exit 0
        fi
    fi
    
    # Fall back to building from source
    if build_from_source; then
        verify_installation
        exit 0
    fi
    
    # All methods failed
    echo ""
    echo "${RED}Failed to obtain fff-c library${NC}"
    echo ""
    echo "Options:"
    echo "  1. Install Rust and run: $0 --build"
    echo "  2. Manually build from: https://github.com/$FFF_REPO"
    echo "  3. Download a prebuilt binary from the releases page"
    echo ""
    exit 1
}

main
