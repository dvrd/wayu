package bld

// Timing utilities for build scripts.

import "core:time"

NANOS_PER_SEC :: 1_000_000_000

// Get a monotonic timestamp in nanoseconds. Useful for benchmarking build steps.
nanos_now :: proc() -> i64 {
    tick := time.tick_now()
    return tick._nsec
}

// Measure the duration of a block in seconds (as f64).
// Usage:
//   start := bld.timer_start()
//   // ... do work ...
//   elapsed := bld.timer_elapsed(start)
//   bld.log_info("Build took %.2f seconds", elapsed)
timer_start :: proc() -> time.Tick {
    return time.tick_now()
}

timer_elapsed :: proc(start: time.Tick) -> f64 {
    d := time.tick_since(start)
    return time.duration_seconds(d)
}
