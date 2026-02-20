package bld

// Directory walking utilities.

import "base:runtime"
import "core:os"
import "core:strings"

// Action to take during directory walking.
Walk_Action :: enum {
    Continue,  // Continue into directories.
    Skip,      // Skip this directory (don't recurse into it).
    Stop,      // Stop the entire walk.
}

// Entry passed to the walk callback.
Walk_Entry :: struct {
    path:  string,
    type:  File_Type,
    level: int,
}

// Callback for directory walking.
// Return .Continue to keep going, .Skip to skip a directory, .Stop to halt.
Walk_Proc :: proc(entry: Walk_Entry, user_data: rawptr) -> Walk_Action

// Walk options.
Walk_Opt :: struct {
    user_data:  rawptr,
    post_order: bool,   // Visit children before parents.
}

// Recursively walk a directory tree.
walk_dir :: proc(root: string, callback: Walk_Proc, opt: Walk_Opt = {}) -> bool {
    return _walk_dir_impl(root, callback, opt, 0)
}

@(private = "file")
_walk_dir_impl :: proc(
    dir_path: string,
    callback: Walk_Proc,
    opt:      Walk_Opt,
    level:    int,
) -> bool {
    // Temp guard: saves temp allocator position on entry, restores on any
    // return path. Prevents unbounded accumulation in deep recursive trees.
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    f, open_err := os.open(dir_path)
    if open_err != nil {
        log_error("Could not open directory '%s': %v", dir_path, open_err)
        return false
    }
    defer os.close(f)

    infos, read_err := os.read_all_directory(f, context.temp_allocator)
    if read_err != nil {
        log_error("Could not read directory '%s': %v", dir_path, read_err)
        return false
    }
    defer os.file_info_slice_delete(infos, context.temp_allocator)

    for info in infos {
        name := info.name
        if name == "." || name == ".." do continue

        child_path := strings.join({dir_path, "/", name}, "", context.temp_allocator)

        ft: File_Type
        #partial switch info.type {
        case .Regular:   ft = .Regular
        case .Directory: ft = .Directory
        case .Symlink:   ft = .Symlink
        case:            ft = .Other
        }

        entry := Walk_Entry{
            path  = child_path,
            type  = ft,
            level = level,
        }

        if !opt.post_order {
            action := callback(entry, opt.user_data)
            switch action {
            case .Stop:     return true  // Stop requested, but not an error.
            case .Skip:     continue     // Skip this directory.
            case .Continue: // Fall through.
            }
        }

        if ft == .Directory {
            if !_walk_dir_impl(child_path, callback, opt, level + 1) {
                return false
            }
        }

        if opt.post_order {
            action := callback(entry, opt.user_data)
            switch action {
            case .Stop:     return true
            case .Skip:     continue
            case .Continue: // Fall through.
            }
        }
    }

    return true
}
