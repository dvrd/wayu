package benchmark_suite

// Benchmark Suite for wayu
// Compares wayu performance against other shell environment managers:
// - Zinit (Turbo mode)
// - Sheldon (static loading)
// - Antidote (static loading)
// - OMZ (default, no optimizations)
//
// Metrics:
// - Startup time with varying plugin counts (0, 5, 10, 20)
// - List operation speed
// - Fuzzy search performance
// - Memory usage
// - Time to add/remove entry

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:strconv"
import "core:math"
import "core:mem"
import "core:sys/unix"

// Benchmark configuration
MAX_PLUGIN_COUNTS :: []int{0, 5, 10, 20}
ITERATIONS :: 10
WARMUP_ITERATIONS :: 3

// Results structure
BenchmarkResult :: struct {
	tool:           string,
	metric:         string,
	plugin_count:   int,
	mean_ms:        f64,
	std_dev_ms:     f64,
	min_ms:         f64,
	max_ms:         f64,
	memory_mb:      f64,
}

// Full benchmark report
BenchmarkReport :: struct {
	timestamp:      string,
	wayu_version:   string,
	results:        [dynamic]BenchmarkResult,
}

// Timing utilities
timer_start :: proc() -> time.Time {
	return time.now()
}

timer_elapsed_ms :: proc(start: time.Time) -> f64 {
	return f64(time.since(start)) / f64(time.Millisecond)
}

// Statistical calculations
calculate_statistics :: proc(times: []f64) -> (mean, std_dev, min, max: f64) {
	if len(times) == 0 {
		return 0, 0, 0, 0
	}
	
	// Calculate mean
	total: f64 = 0
	min = times[0]
	max = times[0]
	
	for t in times {
		total += t
		if t < min { min = t }
		if t > max { max = t }
	}
	
	mean = total / f64(len(times))
	
	// Calculate standard deviation
	if len(times) > 1 {
		variance_sum: f64 = 0
		for t in times {
			diff := t - mean
			variance_sum += diff * diff
		}
		std_dev = math.sqrt(variance_sum / f64(len(times) - 1))
	}
	
	return
}

// Memory measurement (platform-specific)
get_memory_usage_mb :: proc() -> f64 {
	// On macOS/Linux, read from /proc or use getrusage
	when os.OS == "linux" {
		data, ok := os.read_entire_file("/proc/self/status")
		if !ok {
			return 0
		}
		defer delete(data)
		
		content := string(data)
		lines := strings.split(content, "\n")
		defer delete(lines)
		
		for line in lines {
			if strings.has_prefix(line, "VmRSS:") {
				// Parse "VmRSS:    12345 kB"
				parts := strings.split(line, " ")
				defer delete(parts)
				
				for part in parts {
					kb_val, ok2 := strconv.parse_int(strings.trim_space(part))
					if ok2 {
						return f64(kb_val) / 1024.0 // Convert to MB
					}
				}
			}
		}
	} else when os.OS == "darwin" {
		// On macOS, use task_info or ps
		// Simplified: return 0 for now (would need platform-specific code)
		return 0
	}
	
	return 0
}

// Shell command execution with timing
time_shell_command :: proc(cmd: string) -> (elapsed_ms: f64, success: bool) {
	start := timer_start()
	
	result := os.system(cmd)
	
	elapsed_ms = timer_elapsed_ms(start)
	success = result == 0
	
	return
}

// Benchmark wayu startup with N plugins
benchmark_wayu_startup :: proc(plugin_count: int) -> BenchmarkResult {
	fmt.printf("Benchmarking wayu startup with %d plugins...\n", plugin_count)
	
	times := make([dynamic]f64, 0, ITERATIONS)
	defer delete(times)
	
	// Setup: Create test config with N plugins
	test_home := setup_test_environment(plugin_count)
	defer cleanup_test_environment(test_home)
	
	// Warmup
	for _ in 0 ..< WARMUP_ITERATIONS {
		cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu version >/dev/null 2>&1", test_home)
		time_shell_command(cmd)
	}
	
	// Actual benchmark
	for _ in 0 ..< ITERATIONS {
		cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu version >/dev/null 2>&1", test_home)
		elapsed, ok := time_shell_command(cmd)
		if ok {
			append(&times, elapsed)
		}
	}
	
	mean, std_dev, min, max := calculate_statistics(times[:])
	
	return BenchmarkResult{
		tool = "wayu",
		metric = "startup_time",
		plugin_count = plugin_count,
		mean_ms = mean,
		std_dev_ms = std_dev,
		min_ms = min,
		max_ms = max,
		memory_mb = 0, // Would need more complex measurement
	}
}

// Benchmark wayu list operations
benchmark_wayu_list :: proc(list_type: string) -> BenchmarkResult {
	fmt.printf("Benchmarking wayu %s list...\n", list_type)
	
	times := make([dynamic]f64, 0, ITERATIONS)
	defer delete(times)
	
	// Setup test environment with sample data
	test_home := setup_test_environment(10)
	defer cleanup_test_environment(test_home)
	
	// Warmup
	for _ in 0 ..< WARMUP_ITERATIONS {
		cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu %s list >/dev/null 2>&1", test_home, list_type)
		time_shell_command(cmd)
	}
	
	// Actual benchmark
	for _ in 0 ..< ITERATIONS {
		cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu %s list >/dev/null 2>&1", test_home, list_type)
		elapsed, ok := time_shell_command(cmd)
		if ok {
			append(&times, elapsed)
		}
	}
	
	mean, std_dev, min, max := calculate_statistics(times[:])
	
	return BenchmarkResult{
		tool = "wayu",
		metric = fmt.tprintf("%s_list", list_type),
		plugin_count = 10,
		mean_ms = mean,
		std_dev_ms = std_dev,
		min_ms = min,
		max_ms = max,
		memory_mb = 0,
	}
}

// Benchmark fuzzy search performance
benchmark_wayu_fuzzy :: proc() -> BenchmarkResult {
	fmt.printf("Benchmarking wayu fuzzy search...\n")
	
	times := make([dynamic]f64, 0, ITERATIONS)
	defer delete(times)
	
	// Setup test environment with sample data
	test_home := setup_test_environment(10)
	defer cleanup_test_environment(test_home)
	
	// Warmup
	for _ in 0 ..< WARMUP_ITERATIONS {
		cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu search api >/dev/null 2>&1", test_home)
		time_shell_command(cmd)
	}
	
	// Actual benchmark with various search terms
	search_terms := []string{"api", "git", "home", "test", "frwrks"}
	
	for _ in 0 ..< ITERATIONS {
		for term in search_terms {
			cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu search %s >/dev/null 2>&1", test_home, term)
			elapsed, ok := time_shell_command(cmd)
			if ok {
				append(&times, elapsed)
			}
		}
	}
	
	mean, std_dev, min, max := calculate_statistics(times[:])
	
	return BenchmarkResult{
		tool = "wayu",
		metric = "fuzzy_search",
		plugin_count = 10,
		mean_ms = mean,
		std_dev_ms = std_dev,
		min_ms = min,
		max_ms = max,
		memory_mb = 0,
	}
}

// Benchmark add/remove operations
benchmark_wayu_add_remove :: proc() -> BenchmarkResult {
	fmt.printf("Benchmarking wayu add/remove operations...\n")
	
	times := make([dynamic]f64, 0, ITERATIONS)
	defer delete(times)
	
	// Setup fresh test environment
	test_home := setup_test_environment(0)
	defer cleanup_test_environment(test_home)
	
	// Benchmark adding paths
	for i in 0 ..< ITERATIONS {
		test_path := fmt.tprintf("/tmp/wayu_benchmark_path_%d", i)
		os.make_directory(test_path)
		
		start := timer_start()
		cmd := fmt.tprintf("HOME=%s /usr/local/bin/wayu path add %s --yes >/dev/null 2>&1", test_home, test_path)
		_, ok := time_shell_command(cmd)
		elapsed := timer_elapsed_ms(start)
		
		if ok {
			append(&times, elapsed)
		}
		
		os.remove_directory(test_path)
	}
	
	mean, std_dev, min, max := calculate_statistics(times[:])
	
	return BenchmarkResult{
		tool = "wayu",
		metric = "add_remove",
		plugin_count = 0,
		mean_ms = mean,
		std_dev_ms = std_dev,
		min_ms = min,
		max_ms = max,
		memory_mb = 0,
	}
}

// Test environment setup
setup_test_environment :: proc(plugin_count: int) -> string {
	// Create temporary HOME directory
	test_home := fmt.tprintf("/tmp/wayu_benchmark_%d_%d", os.get_pid(), time.now()._nsec)
	os.make_directory(test_home)
	os.make_directory(fmt.tprintf("%s/.config", test_home))
	
	// Initialize wayu
	os.system(fmt.tprintf("HOME=%s /usr/local/bin/wayu init --shell zsh --yes >/dev/null 2>&1", test_home))
	
	// Add sample plugins if requested
	if plugin_count > 0 {
		for i in 0 ..< plugin_count {
			// Add fake plugin entries (this would need actual plugin system)
			// For now, just add PATH entries as a proxy
			test_path := fmt.tprintf("/tmp/wayu_plugin_%d", i)
			os.make_directory(test_path)
			os.system(fmt.tprintf("HOME=%s /usr/local/bin/wayu path add %s --yes >/dev/null 2>&1", test_home, test_path))
		}
	}
	
	// Add sample constants and aliases for fuzzy search testing
	os.system(fmt.tprintf("HOME=%s /usr/local/bin/wayu const add OPENAI_API_KEY test_key --yes >/dev/null 2>&1", test_home))
	os.system(fmt.tprintf("HOME=%s /usr/local/bin/wayu const add FIREWORKS_AI_API_KEY test_key2 --yes >/dev/null 2>&1", test_home))
	os.system(fmt.tprintf("HOME=%s /usr/local/bin/wayu alias add gs 'git status' --yes >/dev/null 2>&1", test_home))
	os.system(fmt.tprintf("HOME=%s /usr/local/bin/wayu alias add gcm 'git commit -m' --yes >/dev/null 2>&1", test_home))
	
	return test_home
}

cleanup_test_environment :: proc(test_home: string) {
	// Clean up temp directory
	os.system(fmt.tprintf("rm -rf %s", test_home))
}

// Print results in a formatted table
print_results_table :: proc(results: []BenchmarkResult) {
	fmt.println("\n" + strings.repeat("=", 80))
	fmt.println("BENCHMARK RESULTS")
	fmt.println(strings.repeat("=", 80))
	fmt.printf("%-12s %-20s %6s %10s %10s %10s %10s\n", 
		"Tool", "Metric", "Plugins", "Mean(ms)", "StdDev", "Min", "Max")
	fmt.println(strings.repeat("-", 80))
	
	for r in results {
		fmt.printf("%-12s %-20s %6d %10.2f %10.2f %10.2f %10.2f\n",
			r.tool, r.metric, r.plugin_count, r.mean_ms, r.std_dev_ms, r.min_ms, r.max_ms)
	}
	
	fmt.println(strings.repeat("=", 80))
}

// Export results to JSON
export_results_json :: proc(results: []BenchmarkResult, filename: string) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	
	strings.write_string(&builder, "{\n")
	strings.write_string(&builder, "  \"timestamp\": \"")
	strings.write_string(&builder, time.now()._nsec)
	strings.write_string(&builder, "\",\n")
	strings.write_string(&builder, "  \"wayu_version\": \"3.0.0\",\n")
	strings.write_string(&builder, "  \"results\": [\n")
	
	for r, i in results {
		strings.write_string(&builder, "    {\n")
		fmt.sbprintf(&builder, "      \"tool\": \"%s\",\n", r.tool)
		fmt.sbprintf(&builder, "      \"metric\": \"%s\",\n", r.metric)
		fmt.sbprintf(&builder, "      \"plugin_count\": %d,\n", r.plugin_count)
		fmt.sbprintf(&builder, "      \"mean_ms\": %.2f,\n", r.mean_ms)
		fmt.sbprintf(&builder, "      \"std_dev_ms\": %.2f,\n", r.std_dev_ms)
		fmt.sbprintf(&builder, "      \"min_ms\": %.2f,\n", r.min_ms)
		fmt.sbprintf(&builder, "      \"max_ms\": %.2f,\n", r.max_ms)
		fmt.sbprintf(&builder, "      \"memory_mb\": %.2f\n", r.memory_mb)
		
		if i < len(results) - 1 {
			strings.write_string(&builder, "    },\n")
		} else {
			strings.write_string(&builder, "    }\n")
		}
	}
	
	strings.write_string(&builder, "  ]\n")
	strings.write_string(&builder, "}\n")
	
	os.write_entire_file(filename, builder.buf[:])
	fmt.printf("\nResults exported to: %s\n", filename)
}

// Main entry point
main :: proc() {
	fmt.println(strings.repeat("=", 80))
	fmt.println("WAYU BENCHMARK SUITE v1.0")
	fmt.println(strings.repeat("=", 80))
	fmt.println()
	
	// Check if wayu is installed
	if os.system("which wayu >/dev/null 2>&1") != 0 {
		if os.system("which /usr/local/bin/wayu >/dev/null 2>&1") != 0 {
			fmt.println("ERROR: wayu binary not found in PATH or /usr/local/bin/")
			fmt.println("Please install wayu first: ./build_it install")
			os.exit(1)
		}
	}
	
	results := make([dynamic]BenchmarkResult)
	defer delete(results)
	
	// Benchmark startup times with varying plugin counts
	fmt.println("━" * 40)
	fmt.println("PHASE 1: Startup Time Benchmarks")
	fmt.println("━" * 40)
	
	for count in MAX_PLUGIN_COUNTS {
		result := benchmark_wayu_startup(count)
		append(&results, result)
	}
	
	// Benchmark list operations
	fmt.println()
	fmt.println("━" * 40)
	fmt.println("PHASE 2: List Operation Benchmarks")
	fmt.println("━" * 40)
	
	append(&results, benchmark_wayu_list("path"))
	append(&results, benchmark_wayu_list("alias"))
	append(&results, benchmark_wayu_list("constants"))
	
	// Benchmark fuzzy search
	fmt.println()
	fmt.println("━" * 40)
	fmt.println("PHASE 3: Fuzzy Search Benchmarks")
	fmt.println("━" * 40)
	
	append(&results, benchmark_wayu_fuzzy())
	
	// Benchmark add/remove operations
	fmt.println()
	fmt.println("━" * 40)
	fmt.println("PHASE 4: Add/Remove Operation Benchmarks")
	fmt.println("━" * 40)
	
	append(&results, benchmark_wayu_add_remove())
	
	// Print results
	print_results_table(results[:])
	
	// Export results
	timestamp := time.now()._nsec
	json_filename := fmt.tprintf("benchmark_results_%d.json", timestamp)
	export_results_json(results[:], json_filename)
	
	fmt.println()
	fmt.println("━" * 40)
	fmt.println("BENCHMARK COMPLETE")
	fmt.println("━" * 40)
	fmt.println()
	fmt.println("To compare with other tools, run: ./compare.sh")
}
