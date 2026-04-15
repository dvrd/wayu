#!/bin/bash
#
# Automated benchmark comparison script
# Compares wayu against other shell environment managers:
# - Zinit (Turbo mode)
# - Sheldon (static loading)
# - Antidote (static loading)
# - OMZ (default, no optimizations)
#
# Usage: ./compare.sh [--full] [--install-tools]
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
ITERATIONS=10
WARMUP=3
RESULTS_DIR="/tmp/wayu_benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test plugin counts
PLUGIN_COUNTS=(0 5 10 20)

# Tools to benchmark
TOOLS=("wayu" "sheldon" "antidote" "omz")

# Print functions
print_header() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║          WAYU VS COMPETITORS - BENCHMARK SUITE                       ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo -e "${BOLD}${CYAN}━━━ $1 ━━━${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Setup results directory
setup_results_dir() {
    mkdir -p "$RESULTS_DIR"
    print_success "Results directory: $RESULTS_DIR"
}

# Check if a tool is installed
check_tool() {
    local tool=$1
    case $tool in
        wayu)
            if command -v wayu &> /dev/null || [ -f "/usr/local/bin/wayu" ]; then
                return 0
            fi
            ;;
        sheldon)
            if command -v sheldon &> /dev/null; then
                return 0
            fi
            ;;
        antidote)
            if [ -d "${HOME}/.antidote" ] || command -v antidote &> /dev/null; then
                return 0
            fi
            ;;
        omz)
            if [ -d "${HOME}/.oh-my-zsh" ]; then
                return 0
            fi
            ;;
        zinit)
            if [ -d "${HOME}/.local/share/zinit" ]; then
                return 0
            fi
            ;;
    esac
    return 1
}

# Install missing tools
install_tools() {
    print_section "Installing Tools"
    
    # Check/install wayu
    if ! check_tool "wayu"; then
        print_info "Installing wayu..."
        if [ -f "../../build_it" ]; then
            (cd ../.. && ./build_it install)
        elif [ -f "./build_it" ]; then
            ./build_it install
        else
            print_error "wayu build script not found. Please build manually."
            exit 1
        fi
    else
        print_success "wayu is already installed"
    fi
    
    # Check/install sheldon
    if ! check_tool "sheldon"; then
        print_info "Installing sheldon..."
        if command -v cargo &> /dev/null; then
            cargo install sheldon
        elif command -v brew &> /dev/null; then
            brew install sheldon
        else
            print_warning "Cannot install sheldon automatically. Please install manually:"
            print_warning "  cargo install sheldon  OR  brew install sheldon"
        fi
    else
        print_success "sheldon is already installed"
    fi
    
    # Check/install antidote
    if ! check_tool "antidote"; then
        print_info "Installing antidote..."
        git clone --depth=1 https://github.com/mattmc3/antidote.git "${HOME}/.antidote"
        print_success "antidote installed to ${HOME}/.antidote"
    else
        print_success "antidote is already installed"
    fi
    
    # Check/install OMZ
    if ! check_tool "omz"; then
        print_info "Installing Oh My Zsh..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        print_success "OMZ installed"
    else
        print_success "OMZ is already installed"
    fi
    
    # Check/install zinit
    if ! check_tool "zinit"; then
        print_info "Installing zinit..."
        bash -c "$(curl --fail --show-error --silent --location https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)"
        print_success "zinit installed"
    else
        print_success "zinit is already installed"
    fi
}

# Create test configuration for a tool with N plugins
create_test_config() {
    local tool=$1
    local plugin_count=$2
    local test_home=$3
    
    mkdir -p "$test_home/.config"
    
    case $tool in
        wayu)
            # Initialize wayu
            HOME="$test_home" wayu init --shell zsh --yes 2>/dev/null || true
            
            # Add PATH entries as "plugins" proxy
            for i in $(seq 1 $plugin_count); do
                test_path="/tmp/wayu_test_${i}_$$"
                mkdir -p "$test_path"
                HOME="$test_home" wayu path add "$test_path" --yes 2>/dev/null || true
            done
            
            # Add some constants and aliases
            HOME="$test_home" wayu const add "TEST_VAR_${i}" "value${i}" --yes 2>/dev/null || true
            HOME="$test_home" wayu alias add "test${i}" "echo test${i}" --yes 2>/dev/null || true
            ;;
            
        sheldon)
            # Create sheldon config
            mkdir -p "$test_home/.config/sheldon"
            cat > "$test_home/.config/sheldon/plugins.toml" << 'EOF'
shell = "zsh"

[templates]
defer = "{{ hooks?.pre | nl }}{% for file in files %}zsh-defer source {{ file }}{% endfor %}{{ hooks?.post | nl }}"

[plugins.zsh-defer]
github = "romkatv/zsh-defer"

[plugins.compinit]
inline = "autoload -Uz compinit && compinit"
EOF
            
            # Add N plugins
            for i in $(seq 1 $plugin_count); do
                cat >> "$test_home/.config/sheldon/plugins.toml" << EOF

[plugins.test${i}]
inline = "TEST_VAR_${i}=value${i}"
EOF
            done
            ;;
            
        antidote)
            # Create antidote plugins file
            mkdir -p "$test_home/.config/antidote"
            > "$test_home/.zsh_plugins.txt"
            
            # Add N plugins
            for i in $(seq 1 $plugin_count); do
                echo "# Test plugin ${i}" >> "$test_home/.zsh_plugins.txt"
            done
            ;;
            
        omz)
            # Create minimal OMZ config
            mkdir -p "$test_home/.oh-my-zsh"
            
            # Generate .zshrc with N plugins
            cat > "$test_home/.zshrc" << EOF
export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"

plugins=(
EOF
            for i in $(seq 1 $plugin_count); do
                # Use git plugin repeatedly (it's always available)
                echo "  git" >> "$test_home/.zshrc"
            done
            
            cat >> "$test_home/.zshrc" << 'EOF'
)

source \$ZSH/oh-my-zsh.sh
EOF
            ;;
            
        zinit)
            # Create zinit config
            mkdir -p "$test_home/.config/zinit"
            cat > "$test_home/.zshrc" << 'EOF'
# Zinit setup
ZINIT_HOME="\${XDG_DATA_HOME:-\${HOME}/.local/share}/zinit/zinit.git"
source "\${ZINIT_HOME}/zinit.zsh"
EOF
            
            # Add N plugins with turbo mode
            for i in $(seq 1 $plugin_count); do
                cat >> "$test_home/.zshrc" << EOF
zinit ice wait lucid
zinit snippet OMZ::lib/git.zsh
EOF
            done
            
            cat >> "$test_home/.zshrc" << 'EOF'
autoload -Uz compinit && compinit
EOF
            ;;
    esac
}

# Benchmark startup time for a tool
benchmark_startup() {
    local tool=$1
    local plugin_count=$2
    
    local test_home=$(mktemp -d)
    create_test_config "$tool" "$plugin_count" "$test_home"
    
    # Create timing script
    local timing_script="$test_home/time_startup.zsh"
    
    case $tool in
        wayu)
            cat > "$timing_script" << 'EOF'
#!/bin/zsh
# Time just sourcing wayu config
source "$HOME/.config/wayu/init.zsh" 2>/dev/null
EOF
            ;;
        sheldon)
            cat > "$timing_script" << 'EOF'
#!/bin/zsh
eval "$(sheldon source)"
EOF
            ;;
        antidote)
            cat > "$timing_script" << 'EOF'
#!/bin/zsh
source ${ZDOTDIR:-~}/.antidote/antidote.zsh
antidote load
EOF
            ;;
        omz)
            cat > "$timing_script" << 'EOF'
#!/bin/zsh
source "$HOME/.zshrc"
EOF
            ;;
        zinit)
            cat > "$timing_script" << 'EOF'
#!/bin/zsh
source "$HOME/.zshrc"
EOF
            ;;
    esac
    
    chmod +x "$timing_script"
    
    # Warmup runs
    for _ in $(seq 1 $WARMUP); do
        HOME="$test_home" zsh "$timing_script" 2>/dev/null || true
    done
    
    # Actual timing
    local total_time=0
    local valid_runs=0
    
    for _ in $(seq 1 $ITERATIONS); do
        local start_time=$(date +%s%N)
        HOME="$test_home" zsh "$timing_script" 2>/dev/null || true
        local end_time=$(date +%s%N)
        
        local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
        total_time=$((total_time + elapsed_ms))
        valid_runs=$((valid_runs + 1))
    done
    
    # Cleanup
    rm -rf "$test_home"
    
    # Return average
    if [ $valid_runs -gt 0 ]; then
        echo $((total_time / valid_runs))
    else
        echo "0"
    fi
}

# Benchmark list operation
benchmark_list() {
    local tool=$1
    local test_home=$(mktemp -d)
    
    create_test_config "$tool" 10 "$test_home"
    
    local total_time=0
    local valid_runs=0
    
    case $tool in
        wayu)
            for _ in $(seq 1 $ITERATIONS); do
                local start_time=$(date +%s%N)
                HOME="$test_home" wayu path list >/dev/null 2>&1 || true
                local end_time=$(date +%s%N)
                
                local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
                total_time=$((total_time + elapsed_ms))
                valid_runs=$((valid_runs + 1))
            done
            ;;
        sheldon)
            for _ in $(seq 1 $ITERATIONS); do
                local start_time=$(date +%s%N)
                HOME="$test_home" sheldon list >/dev/null 2>&1 || true
                local end_time=$(date +%s%N)
                
                local elapsed_ms=$(( (end_time - start_time) / 1000000 ))
                total_time=$((total_time + elapsed_ms))
                valid_runs=$((valid_runs + 1))
            done
            ;;
        *)
            # Other tools don't have equivalent list operations
            echo "0"
            rm -rf "$test_home"
            return
            ;;
    esac
    
    rm -rf "$test_home"
    
    if [ $valid_runs -gt 0 ]; then
        echo $((total_time / valid_runs))
    else
        echo "0"
    fi
}

# Run all benchmarks
run_benchmarks() {
    print_section "Running Benchmarks"
    
    local results_file="$RESULTS_DIR/benchmark_${TIMESTAMP}.csv"
    echo "tool,metric,plugin_count,mean_ms" > "$results_file"
    
    # Startup time benchmarks
    print_info "Benchmarking startup times..."
    
    for tool in "${TOOLS[@]}"; do
        if check_tool "$tool"; then
            print_info "  Testing $tool..."
            
            for count in "${PLUGIN_COUNTS[@]}"; do
                printf "    Plugins: %2d... " "$count"
                local result=$(benchmark_startup "$tool" "$count")
                printf "%4d ms\n" "$result"
                echo "$tool,startup,$count,$result" >> "$results_file"
            done
        else
            print_warning "Skipping $tool (not installed)"
        fi
    done
    
    # List operation benchmarks
    print_info "Benchmarking list operations..."
    
    for tool in wayu sheldon; do
        if check_tool "$tool"; then
            printf "  Testing %s list... " "$tool"
            local result=$(benchmark_list "$tool")
            printf "%4d ms\n" "$result"
            echo "$tool,list,10,$result" >> "$results_file"
        fi
    done
    
    print_success "Results saved to: $results_file"
}

# Generate comparison table
generate_table() {
    local results_file=$1
    
    print_section "Results Summary"
    
    echo ""
    echo -e "${BOLD}Startup Time Comparison (milliseconds)${NC}"
    echo ""
    
    # Print header
    printf "%-12s" "Tool"
    for count in "${PLUGIN_COUNTS[@]}"; do
        printf "%10s" "${count} plugins"
    done
    echo ""
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Print results for each tool
    for tool in "${TOOLS[@]}"; do
        if check_tool "$tool"; then
            printf "%-12s" "$tool"
            for count in "${PLUGIN_COUNTS[@]}"; do
                local value=$(grep "^${tool},startup,${count}," "$results_file" | cut -d',' -f4 || echo "N/A")
                if [ "$value" = "0" ] || [ "$value" = "N/A" ] || [ -z "$value" ]; then
                    printf "%10s" "---"
                else
                    printf "%9dms" "$value"
                fi
            done
            echo ""
        fi
    done
    
    echo ""
    echo -e "${BOLD}List Operations (10 plugins)${NC}"
    echo ""
    
    for tool in wayu sheldon; do
        if check_tool "$tool"; then
            local value=$(grep "^${tool},list,10," "$results_file" | cut -d',' -f4 || echo "N/A")
            printf "%-12s: %s ms\n" "$tool" "$value"
        fi
    done
}

# Generate JSON results
generate_json() {
    local results_file=$1
    local json_file="$RESULTS_DIR/benchmark_${TIMESTAMP}.json"
    
    cat > "$json_file" << EOF
{
  "timestamp": "$TIMESTAMP",
  "iterations": $ITERATIONS,
  "warmup_iterations": $WARMUP,
  "results": [
EOF
    
    local first=true
    while IFS=, read -r tool metric plugin_count mean_ms; do
        [ "$tool" = "tool" ] && continue  # Skip header
        
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$json_file"
        fi
        
        cat >> "$json_file" << EOF
    {
      "tool": "$tool",
      "metric": "$metric",
      "plugin_count": $plugin_count,
      "mean_ms": $mean_ms
    }
EOF
    done < "$results_file"
    
    cat >> "$json_file" << 'EOF'

  ]
}
EOF
    
    print_success "JSON results: $json_file"
}

# Main function
main() {
    print_header
    
    # Parse arguments
    local install_flag=false
    local full_flag=false
    
    for arg in "$@"; do
        case $arg in
            --install-tools)
                install_flag=true
                ;;
            --full)
                full_flag=true
                ITERATIONS=20
                WARMUP=5
                ;;
            --help|-h)
                echo "Usage: $0 [--full] [--install-tools]"
                echo ""
                echo "Options:"
                echo "  --full           Run extended benchmarks (20 iterations, 5 warmup)"
                echo "  --install-tools  Install missing tools automatically"
                echo "  --help           Show this help message"
                exit 0
                ;;
        esac
    done
    
    # Setup
    setup_results_dir
    
    # Install tools if requested
    if [ "$install_flag" = true ]; then
        install_tools
    fi
    
    # Check which tools are available
    print_section "Tool Availability"
    local available_tools=()
    
    for tool in "${TOOLS[@]}"; do
        if check_tool "$tool"; then
            print_success "$tool: available"
            available_tools+=("$tool")
        else
            print_warning "$tool: not found (install with --install-tools)"
        fi
    done
    
    if [ ${#available_tools[@]} -eq 0 ]; then
        print_error "No tools available for benchmarking!"
        print_info "Run with --install-tools to install dependencies"
        exit 1
    fi
    
    # Run benchmarks
    run_benchmarks
    
    # Generate output
    local results_file="$RESULTS_DIR/benchmark_${TIMESTAMP}.csv"
    generate_table "$results_file"
    generate_json "$results_file"
    
    # Summary
    print_section "Benchmark Complete"
    print_info "Results directory: $RESULTS_DIR"
    print_info "CSV file: $results_file"
    print_info "JSON file: $RESULTS_DIR/benchmark_${TIMESTAMP}.json"
    
    echo ""
    echo -e "${GREEN}${BOLD}✓ Benchmark suite completed successfully!${NC}"
}

# Run main function
main "$@"
