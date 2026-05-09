// exit_codes.odin - Exit codes following BSD sysexits.h conventions
//
// This module defines standard exit codes for wayu CLI commands to enable
// proper scriptability and automation. Follows BSD sysexits.h standard.
//
// See: man 3 sysexits
// See: https://manpages.ubuntu.com/manpages/lunar/man3/sysexits.h.3head.html

package wayu

// Exit codes (BSD sysexits.h compatible)
// Used for proper scripting and CI/CD integration

EXIT_SUCCESS      :: 0   // Successful termination
EXIT_GENERAL      :: 1   // General unspecified error
EXIT_FAILURE      :: 1   // General error (alias for compatibility)
EXIT_USAGE        :: 64  // Command line usage error
EXIT_DATAERR      :: 65  // Data format error
EXIT_NOINPUT      :: 66  // Cannot open input
EXIT_UNAVAILABLE  :: 69  // Service unavailable
EXIT_SOFTWARE     :: 70  // Internal software error
EXIT_OSERR        :: 71  // System error (can't fork)
EXIT_OSFILE       :: 72  // Critical OS file missing
EXIT_CANTCREAT    :: 73  // Can't create output file
EXIT_IOERR        :: 74  // Input/output error
EXIT_NOPERM       :: 77  // Permission denied
EXIT_CONFIG       :: 78  // Configuration error
