package bld

// Odin compiler integration — the core of bld.
//
// Provides a typed Build_Config struct that maps to odin compiler flags,
// plus top-level build/run/test/check procedures.

import "core:fmt"
import "core:strings"

// Optimization level for the Odin compiler.
// Default (zero value) means "use compiler default" — no -o: flag emitted.
Opt_Level :: enum {
    Default,
    None,
    Minimal,
    Size,
    Speed,
    Aggressive,
}

// Build mode (output artifact type).
// Default (zero value) = executable, no flag emitted.
Build_Mode :: enum {
    Default,   // Executable (compiler default, no flag emitted).
    Exe,       // Explicitly request executable.
    Dll,       // Dynamically linked library.
    Lib,       // Statically linked library.
    Obj,       // Object file.
    Asm,       // Assembly file.
    LLVM_IR,   // LLVM IR file.
}

// Vet check flags — use as a bit_set.
Vet_Flag :: enum {
    Unused,
    Unused_Variables,
    Unused_Imports,
    Unused_Procedures,
    Shadowing,
    Using_Stmt,
    Using_Param,
    Style,
    Semicolon,
    Cast,
    Tabs,
    All,  // Shorthand for the standard -vet set.
}
Vet_Flags :: bit_set[Vet_Flag]

// Sanitizer flags.
Sanitize_Flag :: enum {
    Address,
    Memory,
    Thread,
}
Sanitize_Flags :: bit_set[Sanitize_Flag]

// Error position style.
Error_Pos_Style :: enum {
    Default,
    Unix,
    Odin,
}

// A collection mapping: name -> filepath.
Collection :: struct {
    name: string,
    path: string,
}

// A define mapping: name -> value (as string).
Define :: struct {
    name:  string,
    value: string,
}

// Build configuration — maps 1:1 to Odin compiler flags.
// Zero value is a sensible default (build exe, no debug, no vet).
Build_Config :: struct {
    // Required: package path or file path.
    package_path: string,

    // Output path (-out:).
    out: string,

    // Optimization level (-o:).
    opt: Opt_Level,

    // Build mode (-build-mode:).
    build_mode: Build_Mode,

    // Enable debug info (-debug).
    debug: bool,

    // Single file mode (-file).
    file_mode: bool,

    // Target triple (-target:).
    target: string,

    // Microarchitecture (-microarch:).
    microarch: string,

    // Collections (-collection:name=path).
    collections: []Collection,

    // Defines (-define:name=value).
    defines: []Define,

    // Ignore unused defineables (-ignore-unused-defineables).
    // Useful when passing defines that only some packages consume.
    ignore_unused_defineables: bool,

    // Vet flags.
    vet: Vet_Flags,

    // Sanitizers.
    sanitize: Sanitize_Flags,

    // Error position style.
    error_pos_style: Error_Pos_Style,

    // Thread count (-thread-count:). 0 = compiler default.
    thread_count: int,

    // Extra linker flags (-extra-linker-flags:).
    extra_linker_flags: string,

    // Extra assembler flags (-extra-assembler-flags:).
    extra_assembler_flags: string,

    // Show timings (-show-timings).
    show_timings: bool,

    // Show more timings (-show-more-timings).
    show_more_timings: bool,

    // Warnings as errors (-warnings-as-errors).
    warnings_as_errors: bool,

    // Terse errors (-terse-errors).
    terse_errors: bool,

    // Disable assertions (-disable-assert).
    disable_assert: bool,

    // Default to nil allocator (-default-to-nil-allocator).
    default_to_nil_allocator: bool,

    // Default to panic allocator (-default-to-panic-allocator).
    default_to_panic_allocator: bool,

    // Keep temp files (-keep-temp-files).
    keep_temp_files: bool,

    // Strict style (-strict-style).
    strict_style: bool,

    // Custom attributes (-custom-attribute:).
    custom_attributes: []string,

    // Vet specific packages (-vet-packages:).
    vet_packages: []string,

    // Additional raw flags passed verbatim.
    extra_flags: []string,
}

// Build an Odin package. Returns true on success.
build :: proc(config: Build_Config) -> bool {
    return _run_odin("build", config)
}

// Build and run an Odin package. Extra args are passed after --.
run :: proc(config: Build_Config, args: ..string) -> bool {
    return _run_odin("run", config, args)
}

// Build and run tests in an Odin package.
test :: proc(config: Build_Config) -> bool {
    return _run_odin("test", config)
}

// Type-check an Odin package without building.
check :: proc(config: Build_Config) -> bool {
    return _run_odin("check", config)
}

// Build a config with common defaults for a release build.
release_config :: proc(package_path: string, out: string) -> Build_Config {
    return Build_Config{
        package_path = package_path,
        out          = out,
        opt          = .Speed,
    }
}

// Build a config with common defaults for a debug build.
debug_config :: proc(package_path: string, out: string) -> Build_Config {
    return Build_Config{
        package_path = package_path,
        out          = out,
        debug        = true,
    }
}

// Internal: build the command and execute it.
@(private = "file")
_run_odin :: proc(
    verb:   string,
    config: Build_Config,
    run_args: []string = nil,
) -> bool {
    if len(config.package_path) == 0 {
        log_error("Build_Config.package_path is required")
        return false
    }

    cmd := cmd_create(context.temp_allocator)

    cmd_append(&cmd, "odin", verb, config.package_path)

    // -file
    if config.file_mode {
        cmd_append(&cmd, "-file")
    }

    // -out:
    if len(config.out) > 0 {
        cmd_append(&cmd, fmt.tprintf("-out:%s", config.out))
    }

    // -o: (Default/zero = don't emit, use compiler default.)
    #partial switch config.opt {
    case .None:       cmd_append(&cmd, "-o:none")
    case .Minimal:    cmd_append(&cmd, "-o:minimal")
    case .Size:       cmd_append(&cmd, "-o:size")
    case .Speed:      cmd_append(&cmd, "-o:speed")
    case .Aggressive: cmd_append(&cmd, "-o:aggressive")
    // .Default: no flag emitted.
    }

    // -build-mode: (Default/zero = don't emit.)
    #partial switch config.build_mode {
    case .Exe:     cmd_append(&cmd, "-build-mode:exe")
    case .Dll:     cmd_append(&cmd, "-build-mode:dll")
    case .Lib:     cmd_append(&cmd, "-build-mode:lib")
    case .Obj:     cmd_append(&cmd, "-build-mode:obj")
    case .Asm:     cmd_append(&cmd, "-build-mode:asm")
    case .LLVM_IR: cmd_append(&cmd, "-build-mode:llvm-ir")
    // .Default: no flag emitted.
    }

    // -debug
    if config.debug {
        cmd_append(&cmd, "-debug")
    }

    // -target:
    if len(config.target) > 0 {
        cmd_append(&cmd, fmt.tprintf("-target:%s", config.target))
    }

    // -microarch:
    if len(config.microarch) > 0 {
        cmd_append(&cmd, fmt.tprintf("-microarch:%s", config.microarch))
    }

    // -collection:name=path
    for c in config.collections {
        cmd_append(&cmd, fmt.tprintf("-collection:%s=%s", c.name, c.path))
    }

    // -define:name=value
    for d in config.defines {
        cmd_append(&cmd, fmt.tprintf("-define:%s=%s", d.name, d.value))
    }

    // -ignore-unused-defineables
    if config.ignore_unused_defineables {
        cmd_append(&cmd, "-ignore-unused-defineables")
    }

    // Vet flags.
    if .All in config.vet {
        cmd_append(&cmd, "-vet")
    } else {
        if .Unused           in config.vet do cmd_append(&cmd, "-vet-unused")
        if .Unused_Variables in config.vet do cmd_append(&cmd, "-vet-unused-variables")
        if .Unused_Imports   in config.vet do cmd_append(&cmd, "-vet-unused-imports")
        if .Unused_Procedures in config.vet do cmd_append(&cmd, "-vet-unused-procedures")
        if .Shadowing        in config.vet do cmd_append(&cmd, "-vet-shadowing")
        if .Using_Stmt       in config.vet do cmd_append(&cmd, "-vet-using-stmt")
        if .Using_Param      in config.vet do cmd_append(&cmd, "-vet-using-param")
        if .Style            in config.vet do cmd_append(&cmd, "-vet-style")
        if .Semicolon        in config.vet do cmd_append(&cmd, "-vet-semicolon")
        if .Cast             in config.vet do cmd_append(&cmd, "-vet-cast")
        if .Tabs             in config.vet do cmd_append(&cmd, "-vet-tabs")
    }

    // -vet-packages:
    if len(config.vet_packages) > 0 {
        joined := strings.join(config.vet_packages, ",", context.temp_allocator)
        cmd_append(&cmd, fmt.tprintf("-vet-packages:%s", joined))
    }

    // Sanitizers.
    if .Address in config.sanitize do cmd_append(&cmd, "-sanitize:address")
    if .Memory  in config.sanitize do cmd_append(&cmd, "-sanitize:memory")
    if .Thread  in config.sanitize do cmd_append(&cmd, "-sanitize:thread")

    // Error pos style.
    #partial switch config.error_pos_style {
    case .Unix: cmd_append(&cmd, "-error-pos-style:unix")
    case .Odin: cmd_append(&cmd, "-error-pos-style:odin")
    }

    // -thread-count:
    if config.thread_count > 0 {
        cmd_append(&cmd, fmt.tprintf("-thread-count:%d", config.thread_count))
    }

    // -extra-linker-flags:
    if len(config.extra_linker_flags) > 0 {
        cmd_append(&cmd, fmt.tprintf("-extra-linker-flags:%s", config.extra_linker_flags))
    }

    // -extra-assembler-flags:
    if len(config.extra_assembler_flags) > 0 {
        cmd_append(&cmd, fmt.tprintf("-extra-assembler-flags:%s", config.extra_assembler_flags))
    }

    // Boolean flags.
    if config.show_timings             do cmd_append(&cmd, "-show-timings")
    if config.show_more_timings        do cmd_append(&cmd, "-show-more-timings")
    if config.warnings_as_errors       do cmd_append(&cmd, "-warnings-as-errors")
    if config.terse_errors             do cmd_append(&cmd, "-terse-errors")
    if config.disable_assert           do cmd_append(&cmd, "-disable-assert")
    if config.default_to_nil_allocator do cmd_append(&cmd, "-default-to-nil-allocator")
    if config.default_to_panic_allocator do cmd_append(&cmd, "-default-to-panic-allocator")
    if config.keep_temp_files          do cmd_append(&cmd, "-keep-temp-files")
    if config.strict_style             do cmd_append(&cmd, "-strict-style")

    // Custom attributes.
    for attr in config.custom_attributes {
        cmd_append(&cmd, fmt.tprintf("-custom-attribute:%s", attr))
    }

    // Extra raw flags.
    for flag in config.extra_flags {
        cmd_append(&cmd, flag)
    }

    // For `odin run`, append -- and args.
    if verb == "run" && len(run_args) > 0 {
        cmd_append(&cmd, "--")
        for arg in run_args {
            cmd_append(&cmd, arg)
        }
    }

    return cmd_run(&cmd)
}
