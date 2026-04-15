//! C FFI bindings for fff-core
//!
//! This crate provides C-compatible FFI exports that can be used from any language
//! with C FFI support (Bun, Node.js, Python, Ruby, etc.).
//!
//! # Instance-based API
//!
//! All state is owned by an opaque \`FffInstance\` fff\_handle. Callers create an instance
//! with \`fff\_create\_instance\`, pass the fff\_handle to every subsequent call, and free it with
//! \`fff\_destroy\`. Multiple independent instances can coexist in the same process.
//!
//! # Memory management
//!
//! \\* Every \`fff\_\*\` function that returns \`\*mut FffResult\` requires the caller to
//! free the result with \`fff\_free\_result\`.
//! \\* The instance itself must be freed with \`fff\_destroy\`.
//!
//! # Parameter conventions
//!
//! \\* Optional \`\*const c\_char\` parameters: pass NULL or an empty string to omit.
//! \\* Numeric parameters: 0 means "use default" unless documented otherwise.
//! \\* Grep mode (\`u8\`): 0 = plain text, 1 = regex, 2 = fuzzy.
//! \\* Multi-grep patterns are passed as a single newline-separated (\`\\n\`) string.

use std::ffi::{CStr, CString, c\_char, c\_void};
use std::path::PathBuf;
use std::time::Duration;

use fff::shared::SharedQueryTracker;

mod ffi\_types;

use fff::file\_picker::FilePicker;
use fff::frecency::FrecencyTracker;
use fff::query\_tracker::QueryTracker;
use fff::{DbHealthChecker, FFFMode, FuzzySearchOptions, PaginationArgs, QueryParser};
use fff::{SharedFrecency, SharedPicker};
use ffi\_types::{
 FffFileItem, FffGrepMatch, FffGrepResult, FffResult, FffScanProgress, FffScore, FffSearchResult,
};

/// Opaque fff\_handle holding all per-instance state.
///
/// The caller receives this as \`\*mut c\_void\` and must pass it to every FFI call.
/// The fff\_handle is freed by \`fff\_destroy\`.
struct FffInstance {
 picker: SharedPicker,
 frecency: SharedFrecency,
 query\_tracker: SharedQueryTracker,
}

/// Helper to convert C string to Rust &str.
///
/// Returns \`None\` if the pointer is null or the string is not valid UTF-8.
unsafe fn cstr\_to\_str<'a>(s: \*const c\_char) -> Option<&'a str> {
 if s.is\_null() {
 None
 } else {
 unsafe { CStr::from\_ptr(s).to\_str().ok() }
 }
}

/// Helper to convert an optional C string parameter.
///
/// Returns \`None\` if the pointer is null, empty, or not valid UTF-8.
unsafe fn optional\_cstr<'a>(s: \*const c\_char) -> Option<&'a str> {
 unsafe { cstr\_to\_str(s) }.filter(\|s\| !s.is\_empty())
}

/// Recover a \`&FffInstance\` from the opaque pointer.
///
/// Returns an error \`FffResult\` if the pointer is null.
unsafe fn instance\_ref<'a>(fff\_handle: \*mut c\_void) -> Result<&'a FffInstance, \*mut FffResult> {
 if fff\_handle.is\_null() {
 Err(FffResult::err(
 "Instance handle is null. Create one with fff\_create\_instance first.",
 ))
 } else {
 Ok(unsafe { &\*(fff\_handle as \*const FffInstance) })
 }
}

/// Decode a \`u8\` grep mode into the core enum.
fn grep\_mode\_from\_u8(mode: u8) -> fff::GrepMode {
 match mode {
 1 => fff::GrepMode::Regex,
 2 => fff::GrepMode::Fuzzy,
 \_ => fff::GrepMode::PlainText,
 }
}

/// Apply "0 means default" convention.
fn default\_u32(val: u32, default: u32) -> u32 {
 if val == 0 { default } else { val }
}

fn default\_u64(val: u64, default: u64) -> u64 {
 if val == 0 { default } else { val }
}

fn default\_i32(val: i32, default: i32) -> i32 {
 if val == 0 { default } else { val }
}

/// Create a new file finder instance.
///
/// Returns an opaque pointer that must be passed to all other \`fff\_\*\` calls
/// and eventually freed with \`fff\_destroy\`.
///
/// # Parameters
///
/// \\* \`base\_path\` – directory to index (required)
/// \\* \`frecency\_db\_path\` – path to frecency LMDB database (NULL/empty to skip)
/// \\* \`history\_db\_path\` – path to query history LMDB database (NULL/empty to skip)
/// \\* \`use\_unsafe\_no\_lock\` – use MDB\_NOLOCK for LMDB (useful in single-process setups)
/// \\* \`warmup\_mmap\_cache\` – pre-populate mmap caches after the initial scan
/// \\* \`ai\_mode\` – enable AI-agent optimizations (auto-track frecency on modifications)
///
/// ## Safety
/// String parameters must be valid null-terminated UTF-8 or NULL.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_create\_instance(
 base\_path: \*const c\_char,
 frecency\_db\_path: \*const c\_char,
 history\_db\_path: \*const c\_char,
 use\_unsafe\_no\_lock: bool,
 warmup\_mmap\_cache: bool,
 ai\_mode: bool,
) -\> \*mut FffResult {
 let base\_path\_str = match unsafe { cstr\_to\_str(base\_path) } {
 Some(s) if !s.is\_empty() => s.to\_string(),
 \_ => return FffResult::err("base\_path is null or empty"),
 };

 let frecency\_path = unsafe { optional\_cstr(frecency\_db\_path) }.map(\|s\| s.to\_string());
 let history\_path = unsafe { optional\_cstr(history\_db\_path) }.map(\|s\| s.to\_string());

 // Create shared state that background threads will write into.
 let shared\_picker = SharedPicker::default();
 let shared\_frecency = SharedFrecency::default();
 let query\_tracker = SharedQueryTracker::default();

 // Initialize frecency tracker if path is provided
 if let Some(ref frecency\_path) = frecency\_path {
 if let Some(parent) = PathBuf::from(frecency\_path).parent() {
 let \_ = std::fs::create\_dir\_all(parent);
 }

 match FrecencyTracker::new(frecency\_path, use\_unsafe\_no\_lock) {
 Ok(tracker) => {
 if let Err(e) = shared\_frecency.init(tracker) {
 return FffResult::err(&format!("Failed to acquire frecency lock: {}", e));
 }
 let \_ = shared\_frecency.spawn\_gc(frecency\_path.clone(), use\_unsafe\_no\_lock);
 }
 Err(e) => return FffResult::err(&format!("Failed to init frecency db: {}", e)),
 }
 }

 // Initialize query tracker if path is provided
 if let Some(ref history\_path) = history\_path {
 if let Some(parent) = PathBuf::from(history\_path).parent() {
 let \_ = std::fs::create\_dir\_all(parent);
 }

 match QueryTracker::new(history\_path, use\_unsafe\_no\_lock) {
 Ok(tracker) => {
 if let Err(e) = query\_tracker.init(tracker) {
 return FffResult::err(&format!("Failed to acquire query tracker lock: {}", e));
 }
 }
 Err(e) => return FffResult::err(&format!("Failed to init query tracker db: {}", e)),
 }
 }

 let mode = if ai\_mode {
 FFFMode::Ai
 } else {
 FFFMode::Neovim
 };

 // Initialize file picker (writes directly into shared\_picker)
 if let Err(e) = FilePicker::new\_with\_shared\_state(
 shared\_picker.clone(),
 shared\_frecency.clone(),
 fff::FilePickerOptions {
 base\_path: base\_path\_str,
 warmup\_mmap\_cache,
 mode,
 cache\_budget: None,
 ..Default::default()
 },
 ) {
 return FffResult::err(&format!("Failed to init file picker: {}", e));
 }

 let instance = Box::new(FffInstance {
 picker: shared\_picker,
 frecency: shared\_frecency,
 query\_tracker,
 });

 let fff\_handle = Box::into\_raw(instance) as \*mut c\_void;
 FffResult::ok\_handle(fff\_handle)
}

/// Destroy a file finder instance and free all its resources.
///
/// ## Safety
/// \`fff\_handle\` must be a valid pointer returned by \`fff\_create\_instance\`, or null (no-op).
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_destroy(fff\_handle: \*mut c\_void) {
 if fff\_handle.is\_null() {
 return;
 }

 let instance = unsafe { Box::from\_raw(fff\_handle as \*mut FffInstance) };

 if let Ok(mut guard) = instance.picker.write()
 && let Some(mut picker) = guard.take()
 {
 picker.stop\_background\_monitor();
 }

 if let Ok(mut guard) = instance.frecency.write() {
 \*guard = None;
 }
 if let Ok(mut guard) = instance.query\_tracker.write() {
 \*guard = None;
 }
}

/// Perform fuzzy search on indexed files.
///
/// # Parameters
///
/// \\* \`fff\_handle\` – instance from \`fff\_create\_instance\`
/// \\* \`query\` – search query string
/// \\* \`current\_file\` – path of the currently open file for deprioritization (NULL/empty to skip)
/// \\* \`max\_threads\` – maximum worker threads (0 = auto-detect)
/// \\* \`page\_index\` – pagination offset (0 = first page)
/// \\* \`page\_size\` – results per page (0 = default 100)
/// \\* \`combo\_boost\_multiplier\` – score multiplier for combo matches (0 = default 100)
/// \\* \`min\_combo\_count\` – minimum combo count before boost applies (0 = default 3)
///
/// ## Safety
/// \\* \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
/// \\* \`query\` and \`current\_file\` must be valid null-terminated UTF-8 strings or NULL.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_search(
 fff\_handle: \*mut c\_void,
 query: \*const c\_char,
 current\_file: \*const c\_char,
 max\_threads: u32,
 page\_index: u32,
 page\_size: u32,
 combo\_boost\_multiplier: i32,
 min\_combo\_count: u32,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let query\_str = match unsafe { cstr\_to\_str(query) } {
 Some(s) => s,
 None => return FffResult::err("Query is null or invalid UTF-8"),
 };

 let current\_file\_str = unsafe { optional\_cstr(current\_file) };
 let page\_size = default\_u32(page\_size, 100) as usize;
 let min\_combo\_count = default\_u32(min\_combo\_count, 3);
 let combo\_boost\_multiplier = default\_i32(combo\_boost\_multiplier, 100);

 let picker\_guard = match inst.picker.read() {
 Ok(g) => g,
 Err(e) => return FffResult::err(&format!("Failed to acquire file picker lock: {}", e)),
 };

 let picker = match picker\_guard.as\_ref() {
 Some(p) => p,
 None => {
 return FffResult::err("File picker not initialized. Call fff\_create\_instance first.");
 }
 };

 // Get query tracker ref for combo matching
 let qt\_guard = match inst.query\_tracker.read() {
 Ok(q) => q,
 Err(\_) => return FffResult::err("Failed to acquire query tracker lock"),
 };
 let query\_tracker\_ref = qt\_guard.as\_ref();

 let parser = QueryParser::default();
 let parsed = parser.parse(query\_str);

 let results = FilePicker::fuzzy\_search(
 picker.get\_files(),
 &parsed,
 query\_tracker\_ref,
 FuzzySearchOptions {
 max\_threads: max\_threads as usize,
 current\_file: current\_file\_str,
 project\_path: Some(picker.base\_path()),
 combo\_boost\_score\_multiplier: combo\_boost\_multiplier,
 min\_combo\_count,
 pagination: PaginationArgs {
 offset: page\_index as usize,
 limit: page\_size,
 },
 },
 );

 let search\_result = FffSearchResult::from\_core(&results);
 FffResult::ok\_handle(search\_result as \*mut c\_void)
}

/// Perform content search (grep) across indexed files.
///
/// # Parameters
///
/// \\* \`fff\_handle\` – instance from \`fff\_create\_instance\`
/// \\* \`query\` – search query (supports constraint syntax like \`\*.rs pattern\`)
/// \\* \`mode\` – 0 = plain text (SIMD), 1 = regex, 2 = fuzzy
/// \\* \`max\_file\_size\` – skip files larger than this in bytes (0 = default 10 MB)
/// \\* \`max\_matches\_per\_file\` – max matches per file (0 = unlimited)
/// \\* \`smart\_case\` – case-insensitive when query is all lowercase
/// \\* \`file\_offset\` – file-based pagination offset (0 = start)
/// \\* \`page\_limit\` – max matches to return (0 = default 50)
/// \\* \`time\_budget\_ms\` – wall-clock budget in ms (0 = unlimited)
/// \\* \`before\_context\` – context lines before each match
/// \\* \`after\_context\` – context lines after each match
/// \\* \`classify\_definitions\` – tag matches that are code definitions
///
/// ## Safety
/// \\* \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
/// \\* \`query\` must be a valid null-terminated UTF-8 string.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_live\_grep(
 fff\_handle: \*mut c\_void,
 query: \*const c\_char,
 mode: u8,
 max\_file\_size: u64,
 max\_matches\_per\_file: u32,
 smart\_case: bool,
 file\_offset: u32,
 page\_limit: u32,
 time\_budget\_ms: u64,
 before\_context: u32,
 after\_context: u32,
 classify\_definitions: bool,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let query\_str = match unsafe { cstr\_to\_str(query) } {
 Some(s) => s,
 None => return FffResult::err("Query is null or invalid UTF-8"),
 };

 let picker\_guard = match inst.picker.read() {
 Ok(g) => g,
 Err(e) => return FffResult::err(&format!("Failed to acquire file picker lock: {}", e)),
 };

 let picker = match picker\_guard.as\_ref() {
 Some(p) => p,
 None => {
 return FffResult::err("File picker not initialized. Call fff\_create\_instance first.");
 }
 };

 let is\_ai = picker.mode().is\_ai();
 let parsed = if is\_ai {
 fff::QueryParser::new(fff\_query\_parser::AiGrepConfig).parse(query\_str)
 } else {
 fff::grep::parse\_grep\_query(query\_str)
 };

 let options = fff::GrepSearchOptions {
 max\_file\_size: default\_u64(max\_file\_size, 10 \* 1024 \* 1024),
 max\_matches\_per\_file: max\_matches\_per\_file as usize,
 smart\_case,
 file\_offset: file\_offset as usize,
 page\_limit: default\_u32(page\_limit, 50) as usize,
 mode: grep\_mode\_from\_u8(mode),
 time\_budget\_ms,
 before\_context: before\_context as usize,
 after\_context: after\_context as usize,
 classify\_definitions,
 trim\_whitespace: false,
 };

 let result = picker.grep(&parsed, &options);
 let grep\_result = FffGrepResult::from\_core(&result);
 FffResult::ok\_handle(grep\_result as \*mut c\_void)
}

/// Perform multi-pattern OR search (Aho-Corasick) across indexed files.
///
/// Searches for lines matching ANY of the provided patterns using
/// SIMD-accelerated multi-needle matching.
///
/// # Parameters
///
/// \\* \`fff\_handle\` – instance from \`fff\_create\_instance\`
/// \\* \`patterns\_joined\` – patterns separated by \`\\n\` (e.g. \`"foo\\nbar\\nbaz"\`)
/// \\* \`constraints\` – file filter like \`"\*.rs"\` or \`"/src/"\` (NULL/empty to skip)
/// \\* \`max\_file\_size\` – skip files larger than this in bytes (0 = default 10 MB)
/// \\* \`max\_matches\_per\_file\` – max matches per file (0 = unlimited)
/// \\* \`smart\_case\` – case-insensitive when all patterns are lowercase
/// \\* \`file\_offset\` – file-based pagination offset (0 = start)
/// \\* \`page\_limit\` – max matches to return (0 = default 50)
/// \\* \`time\_budget\_ms\` – wall-clock budget in ms (0 = unlimited)
/// \\* \`before\_context\` – context lines before each match
/// \\* \`after\_context\` – context lines after each match
/// \\* \`classify\_definitions\` – tag matches that are code definitions
///
/// ## Safety
/// \\* \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
/// \\* \`patterns\_joined\` and \`constraints\` must be valid null-terminated UTF-8 or NULL.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_multi\_grep(
 fff\_handle: \*mut c\_void,
 patterns\_joined: \*const c\_char,
 constraints: \*const c\_char,
 max\_file\_size: u64,
 max\_matches\_per\_file: u32,
 smart\_case: bool,
 file\_offset: u32,
 page\_limit: u32,
 time\_budget\_ms: u64,
 before\_context: u32,
 after\_context: u32,
 classify\_definitions: bool,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let patterns\_str = match unsafe { cstr\_to\_str(patterns\_joined) } {
 Some(s) if !s.is\_empty() => s,
 \_ => return FffResult::err("patterns\_joined is null or empty"),
 };

 let patterns: Vec<&str> = patterns\_str.split('\\n').collect();
 if patterns.is\_empty() \|\| patterns.iter().all(\|p\| p.is\_empty()) {
 return FffResult::err("patterns must not be empty");
 }

 let constraints\_str = unsafe { optional\_cstr(constraints) };

 let picker\_guard = match inst.picker.read() {
 Ok(g) => g,
 Err(e) => return FffResult::err(&format!("Failed to acquire file picker lock: {}", e)),
 };

 let picker = match picker\_guard.as\_ref() {
 Some(p) => p,
 None => {
 return FffResult::err("File picker not initialized. Call fff\_create\_instance first.");
 }
 };

 let is\_ai = picker.mode().is\_ai();

 // Parse constraints from the optional string (e.g. "\*.rs /src/")
 let parsed\_constraints = constraints\_str.map(\|c\| {
 if is\_ai {
 fff::QueryParser::new(fff\_query\_parser::AiGrepConfig).parse(c)
 } else {
 fff::grep::parse\_grep\_query(c)
 }
 });

 let constraint\_refs: &\[fff::Constraint<'\_>\] = match &parsed\_constraints {
 Some(q) => &q.constraints,
 None => &\[\],
 };

 let options = fff::GrepSearchOptions {
 max\_file\_size: default\_u64(max\_file\_size, 10 \* 1024 \* 1024),
 max\_matches\_per\_file: max\_matches\_per\_file as usize,
 smart\_case,
 file\_offset: file\_offset as usize,
 page\_limit: default\_u32(page\_limit, 50) as usize,
 mode: fff::GrepMode::PlainText, // ignored by multi\_grep\_search
 time\_budget\_ms,
 before\_context: before\_context as usize,
 after\_context: after\_context as usize,
 classify\_definitions,
 trim\_whitespace: false,
 };

 let overlay\_guard = picker.bigram\_overlay().map(\|o\| o.read());
 let result = fff::multi\_grep\_search(
 picker.get\_files(),
 &patterns,
 constraint\_refs,
 &options,
 picker.cache\_budget(),
 picker.bigram\_index(),
 overlay\_guard.as\_deref(),
 None,
 );
 let grep\_result = FffGrepResult::from\_core(&result);
 FffResult::ok\_handle(grep\_result as \*mut c\_void)
}

/// Trigger a rescan of the file index.
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_scan\_files(fff\_handle: \*mut c\_void) -> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let mut guard = match inst.picker.write() {
 Ok(g) => g,
 Err(e) => return FffResult::err(&format!("Failed to acquire file picker lock: {}", e)),
 };

 let picker = match guard.as\_mut() {
 Some(p) => p,
 None => return FffResult::err("File picker not initialized"),
 };

 match picker.trigger\_rescan(&inst.frecency) {
 Ok(\_) => FffResult::ok\_empty(),
 Err(e) => FffResult::err(&format!("Failed to trigger rescan: {}", e)),
 }
}

/// Check if a scan is currently in progress.
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_is\_scanning(fff\_handle: \*mut c\_void) -> bool {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(\_) => return false,
 };

 inst.picker
 .read()
 .ok()
 .and\_then(\|guard\| guard.as\_ref().map(\|p\| p.is\_scan\_active()))
 .unwrap\_or(false)
}

/// Get scan progress information.
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_get\_scan\_progress(fff\_handle: \*mut c\_void) -> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let guard = match inst.picker.read() {
 Ok(g) => g,
 Err(e) => return FffResult::err(&format!("Failed to acquire file picker lock: {}", e)),
 };

 let picker = match guard.as\_ref() {
 Some(p) => p,
 None => return FffResult::err("File picker not initialized"),
 };

 let result = Box::into\_raw(Box::new(FffScanProgress::from(picker.get\_scan\_progress())));
 FffResult::ok\_handle(result as \*mut c\_void)
}

/// Wait for initial scan to complete.
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_wait\_for\_scan(
 fff\_handle: \*mut c\_void,
 timeout\_ms: u64,
) -\> \*mut FffResult {
 let FffInstance { picker, .. } = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let completed = picker.wait\_for\_scan(Duration::from\_millis(timeout\_ms));
 FffResult::ok\_int(completed as i64)
}

/// Wait for the background file watcher to be ready.
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_wait\_for\_watcher(
 fff\_handle: \*mut c\_void,
 timeout\_ms: u64,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let completed = inst
 .picker
 .wait\_for\_watcher(Duration::from\_millis(timeout\_ms));
 FffResult::ok\_int(completed as i64)
}

/// Restart indexing in a new directory.
///
/// ## Safety
/// \\* \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
/// \\* \`new\_path\` must be a valid null-terminated UTF-8 string.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_restart\_index(
 fff\_handle: \*mut c\_void,
 new\_path: \*const c\_char,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let path\_str = match unsafe { cstr\_to\_str(new\_path) } {
 Some(s) => s,
 None => return FffResult::err("Path is null or invalid UTF-8"),
 };

 let path = PathBuf::from(&path\_str);
 if !path.exists() {
 return FffResult::err(&format!("Path does not exist: {}", path\_str));
 }

 let canonical\_path = match fff::path\_utils::canonicalize(&path) {
 Ok(p) => p,
 Err(e) => return FffResult::err(&format!("Failed to canonicalize path: {}", e)),
 };

 let mut guard = match inst.picker.write() {
 Ok(g) => g,
 Err(e) => return FffResult::err(&format!("Failed to acquire file picker lock: {}", e)),
 };

 let (warmup\_caches, mode) = if let Some(mut picker) = guard.take() {
 let warmup = picker.need\_warmup\_mmap\_cache();
 let mode = picker.mode();
 picker.stop\_background\_monitor();
 (warmup, mode)
 } else {
 (false, FFFMode::default())
 };

 drop(guard);

 match FilePicker::new\_with\_shared\_state(
 inst.picker.clone(),
 inst.frecency.clone(),
 fff::FilePickerOptions {
 base\_path: canonical\_path.to\_string\_lossy().to\_string(),
 warmup\_mmap\_cache: warmup\_caches,
 mode,
 cache\_budget: None,
 ..Default::default()
 },
 ) {
 Ok(()) => FffResult::ok\_empty(),
 Err(e) => FffResult::err(&format!("Failed to init file picker: {}", e)),
 }
}

/// Refresh git status cache.
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_refresh\_git\_status(fff\_handle: \*mut c\_void) -> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 match inst.picker.refresh\_git\_status(&inst.frecency) {
 Ok(count) => FffResult::ok\_int(count as i64),
 Err(e) => FffResult::err(&format!("Failed to refresh git status: {}", e)),
 }
}

/// Track query completion for smart suggestions.
///
/// ## Safety
/// \\* \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
/// \\* \`query\` and \`file\_path\` must be valid null-terminated UTF-8 strings.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_track\_query(
 fff\_handle: \*mut c\_void,
 query: \*const c\_char,
 file\_path: \*const c\_char,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let query\_str = match unsafe { cstr\_to\_str(query) } {
 Some(s) => s,
 None => return FffResult::err("Query is null or invalid UTF-8"),
 };

 let path\_str = match unsafe { cstr\_to\_str(file\_path) } {
 Some(s) => s,
 None => return FffResult::err("File path is null or invalid UTF-8"),
 };

 let file\_path = match fff::path\_utils::canonicalize(path\_str) {
 Ok(p) => p,
 Err(e) => return FffResult::err(&format!("Failed to canonicalize path: {}", e)),
 };

 let project\_path = {
 let guard = match inst.picker.read() {
 Ok(g) => g,
 Err(\_) => return FffResult::ok\_int(0),
 };
 match guard.as\_ref() {
 Some(p) => p.base\_path().to\_path\_buf(),
 None => return FffResult::ok\_int(0),
 }
 };

 let mut qt\_guard = match inst.query\_tracker.write() {
 Ok(q) => q,
 Err(\_) => return FffResult::ok\_int(0),
 };

 if let Some(ref mut tracker) = \*qt\_guard
 && let Err(e) = tracker.track\_query\_completion(query\_str, &project\_path, &file\_path)
 {
 return FffResult::err(&format!("Failed to track query: {}", e));
 }

 FffResult::ok\_int(1)
}

/// Get historical query by offset (0 = most recent).
///
/// ## Safety
/// \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_get\_historical\_query(
 fff\_handle: \*mut c\_void,
 offset: u64,
) -\> \*mut FffResult {
 let inst = match unsafe { instance\_ref(fff\_handle) } {
 Ok(i) => i,
 Err(e) => return e,
 };

 let project\_path = {
 let guard = match inst.picker.read() {
 Ok(g) => g,
 Err(\_) => return FffResult::ok\_empty(),
 };
 match guard.as\_ref() {
 Some(p) => p.base\_path().to\_path\_buf(),
 None => return FffResult::ok\_empty(),
 }
 };

 let qt\_guard = match inst.query\_tracker.read() {
 Ok(q) => q,
 Err(\_) => return FffResult::ok\_empty(),
 };

 let tracker = match qt\_guard.as\_ref() {
 Some(t) => t,
 None => return FffResult::ok\_empty(),
 };

 match tracker.get\_historical\_query(&project\_path, offset as usize) {
 Ok(Some(query)) => FffResult::ok\_string(&query),
 Ok(None) => FffResult::ok\_empty(),
 Err(e) => FffResult::err(&format!("Failed to get historical query: {}", e)),
 }
}

/// Get health check information.
///
/// ## Safety
/// \\* \`fff\_handle\` must be a valid instance pointer from \`fff\_create\_instance\`, or null for
/// a limited health check (version + git only).
/// \\* \`test\_path\` can be null or a valid null-terminated UTF-8 string.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_health\_check(
 fff\_handle: \*mut c\_void,
 test\_path: \*const c\_char,
) -\> \*mut FffResult {
 let test\_path = unsafe { optional\_cstr(test\_path) }
 .map(PathBuf::from)
 .unwrap\_or\_else(\|\| std::env::current\_dir().unwrap\_or\_default());

 let mut health = serde\_json::Map::new();
 health.insert(
 "version".to\_string(),
 serde\_json::Value::String(env!("CARGO\_PKG\_VERSION").to\_string()),
 );

 // Git info
 let mut git\_info = serde\_json::Map::new();
 let git\_version = git2::Version::get();
 let (major, minor, rev) = git\_version.libgit2\_version();
 git\_info.insert(
 "libgit2\_version".to\_string(),
 serde\_json::Value::String(format!("{}.{}.{}", major, minor, rev)),
 );

 match git2::Repository::discover(&test\_path) {
 Ok(repo) => {
 git\_info.insert("available".to\_string(), serde\_json::Value::Bool(true));
 git\_info.insert(
 "repository\_found".to\_string(),
 serde\_json::Value::Bool(true),
 );
 if let Some(workdir) = repo.workdir() {
 git\_info.insert(
 "workdir".to\_string(),
 serde\_json::Value::String(workdir.to\_string\_lossy().to\_string()),
 );
 }
 }
 Err(e) => {
 git\_info.insert("available".to\_string(), serde\_json::Value::Bool(true));
 git\_info.insert(
 "repository\_found".to\_string(),
 serde\_json::Value::Bool(false),
 );
 git\_info.insert(
 "error".to\_string(),
 serde\_json::Value::String(e.message().to\_string()),
 );
 }
 }
 health.insert("git".to\_string(), serde\_json::Value::Object(git\_info));

 let inst: Option<&FffInstance> = if fff\_handle.is\_null() {
 None
 } else {
 Some(unsafe { &\*(fff\_handle as \*const FffInstance) })
 };

 // File picker info
 let mut picker\_info = serde\_json::Map::new();
 if let Some(inst) = inst {
 match inst.picker.read() {
 Ok(guard) => {
 if let Some(ref picker) = \*guard {
 picker\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(true));
 picker\_info.insert(
 "base\_path".to\_string(),
 serde\_json::Value::String(picker.base\_path().to\_string\_lossy().to\_string()),
 );
 picker\_info.insert(
 "is\_scanning".to\_string(),
 serde\_json::Value::Bool(picker.is\_scan\_active()),
 );
 let progress = picker.get\_scan\_progress();
 picker\_info.insert(
 "indexed\_files".to\_string(),
 serde\_json::Value::Number(progress.scanned\_files\_count.into()),
 );
 } else {
 picker\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 }
 }
 Err(\_) => {
 picker\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 picker\_info.insert(
 "error".to\_string(),
 serde\_json::Value::String("Failed to acquire lock".to\_string()),
 );
 }
 }
 } else {
 picker\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 }
 health.insert(
 "file\_picker".to\_string(),
 serde\_json::Value::Object(picker\_info),
 );

 // Frecency info
 let mut frecency\_info = serde\_json::Map::new();
 if let Some(inst) = inst {
 match inst.frecency.read() {
 Ok(guard) => {
 frecency\_info.insert(
 "initialized".to\_string(),
 serde\_json::Value::Bool(guard.is\_some()),
 );
 if let Some(ref frecency) = \*guard
 && let Ok(health\_data) = frecency.get\_health()
 {
 let mut db\_health = serde\_json::Map::new();
 db\_health.insert(
 "path".to\_string(),
 serde\_json::Value::String(health\_data.path),
 );
 db\_health.insert(
 "disk\_size".to\_string(),
 serde\_json::Value::Number(health\_data.disk\_size.into()),
 );
 frecency\_info.insert(
 "db\_healthcheck".to\_string(),
 serde\_json::Value::Object(db\_health),
 );
 }
 }
 Err(\_) => {
 frecency\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 }
 }
 } else {
 frecency\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 }
 health.insert(
 "frecency".to\_string(),
 serde\_json::Value::Object(frecency\_info),
 );

 // Query tracker info
 let mut query\_info = serde\_json::Map::new();
 if let Some(inst) = inst {
 match inst.query\_tracker.read() {
 Ok(guard) => {
 query\_info.insert(
 "initialized".to\_string(),
 serde\_json::Value::Bool(guard.is\_some()),
 );
 if let Some(ref tracker) = \*guard
 && let Ok(health\_data) = tracker.get\_health()
 {
 let mut db\_health = serde\_json::Map::new();
 db\_health.insert(
 "path".to\_string(),
 serde\_json::Value::String(health\_data.path),
 );
 db\_health.insert(
 "disk\_size".to\_string(),
 serde\_json::Value::Number(health\_data.disk\_size.into()),
 );
 query\_info.insert(
 "db\_healthcheck".to\_string(),
 serde\_json::Value::Object(db\_health),
 );
 }
 }
 Err(\_) => {
 query\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 }
 }
 } else {
 query\_info.insert("initialized".to\_string(), serde\_json::Value::Bool(false));
 }
 health.insert(
 "query\_tracker".to\_string(),
 serde\_json::Value::Object(query\_info),
 );

 match serde\_json::to\_string(&health) {
 Ok(json) => FffResult::ok\_string(&json),
 Err(e) => FffResult::err(&format!("Failed to serialize health check: {}", e)),
 }
}

/// Free a search result returned by \`fff\_search\`.
///
/// This frees the \`FffSearchResult\` struct, its \`items\` and \`scores\` arrays,
/// and all heap-allocated strings within each item and score.
///
/// ## Safety
/// \`result\` must be a valid pointer previously returned via \`FffResult.handle\`
/// from \`fff\_search\`, or null (no-op).
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_free\_search\_result(result: \*mut FffSearchResult) {
 if result.is\_null() {
 return;
 }

 unsafe {
 let result = Box::from\_raw(result);
 let count = result.count as usize;

 if !result.items.is\_null() {
 let mut items = Vec::from\_raw\_parts(result.items, count, count);
 for item in &mut items {
 item.free\_strings();
 }
 }
 if !result.scores.is\_null() {
 let mut scores = Vec::from\_raw\_parts(result.scores, count, count);
 for score in &mut scores {
 score.free\_strings();
 }
 }
 }
}

/// Get a pointer to the \`index\`-th \`FffFileItem\` in a search result.
///
/// Returns null if \`result\` is null or \`index >= result->count\`.
/// The returned pointer is valid until the search result is freed.
///
/// ## Safety
/// \`result\` must be a valid \`FffSearchResult\` pointer from \`fff\_search\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_search\_result\_get\_item(
 result: \*const FffSearchResult,
 index: u32,
) -\> \*const FffFileItem {
 if result.is\_null() {
 return std::ptr::null();
 }
 let result = unsafe { &\*result };
 if index >= result.count \|\| result.items.is\_null() {
 return std::ptr::null();
 }
 unsafe { result.items.add(index as usize) }
}

/// Get a pointer to the \`index\`-th \`FffScore\` in a search result.
///
/// Returns null if \`result\` is null or \`index >= result->count\`.
/// The returned pointer is valid until the search result is freed.
///
/// ## Safety
/// \`result\` must be a valid \`FffSearchResult\` pointer from \`fff\_search\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_search\_result\_get\_score(
 result: \*const FffSearchResult,
 index: u32,
) -\> \*const FffScore {
 if result.is\_null() {
 return std::ptr::null();
 }
 let result = unsafe { &\*result };
 if index >= result.count \|\| result.scores.is\_null() {
 return std::ptr::null();
 }
 unsafe { result.scores.add(index as usize) }
}

/// Free a grep result returned by \`fff\_live\_grep\` or \`fff\_multi\_grep\`.
///
/// This frees the \`FffGrepResult\` struct, its \`items\` array, and all
/// heap-allocated strings, match ranges, and context arrays within each match.
///
/// ## Safety
/// \`result\` must be a valid pointer previously returned via \`FffResult.handle\`
/// from \`fff\_live\_grep\` or \`fff\_multi\_grep\`, or null (no-op).
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_free\_grep\_result(result: \*mut FffGrepResult) {
 if result.is\_null() {
 return;
 }

 unsafe {
 let result = Box::from\_raw(result);
 let count = result.count as usize;

 if !result.items.is\_null() {
 let mut items = Vec::from\_raw\_parts(result.items, count, count);
 for item in &mut items {
 item.free\_fields();
 }
 }
 if !result.regex\_fallback\_error.is\_null() {
 drop(CString::from\_raw(result.regex\_fallback\_error));
 }
 }
}

/// Get a pointer to the \`index\`-th \`FffGrepMatch\` in a grep result.
///
/// Returns null if \`result\` is null or \`index >= result->count\`.
/// The returned pointer is valid until the grep result is freed.
///
/// ## Safety
/// \`result\` must be a valid \`FffGrepResult\` pointer from \`fff\_live\_grep\` or \`fff\_multi\_grep\`.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_grep\_result\_get\_match(
 result: \*const FffGrepResult,
 index: u32,
) -\> \*const FffGrepMatch {
 if result.is\_null() {
 return std::ptr::null();
 }
 let result = unsafe { &\*result };
 if index >= result.count \|\| result.items.is\_null() {
 return std::ptr::null();
 }
 unsafe { result.items.add(index as usize) }
}

/// Free a scan progress result returned by \`fff\_get\_scan\_progress\`.
///
/// ## Safety
/// \`result\` must be a valid pointer previously returned via \`FffResult.handle\`
/// from \`fff\_get\_scan\_progress\`, or null (no-op).
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_free\_scan\_progress(result: \*mut FffScanProgress) {
 if !result.is\_null() {
 unsafe { drop(Box::from\_raw(result)) };
 }
}

/// Offset a pointer by \`byte\_offset\` bytes.
///
/// General-purpose utility for FFI consumers that need pointer arithmetic
/// (e.g. iterating over arrays). Returns null if \`base\` is null.
///
/// ## Safety
/// The resulting pointer must be within the bounds of the original allocation.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_ptr\_offset(base: \*const c\_void, byte\_offset: usize) -> \*const c\_void {
 if base.is\_null() {
 return std::ptr::null();
 }
 unsafe { (base as \*const u8).add(byte\_offset) as \*const c\_void }
}

/// Free a result returned by any \`fff\_\*\` function.
///
/// ## Safety
/// \`result\_ptr\` must be a valid pointer returned by a \`fff\_\*\` function.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_free\_result(result\_ptr: \*mut FffResult) {
 if result\_ptr.is\_null() {
 return;
 }

 unsafe {
 let result = Box::from\_raw(result\_ptr);
 if !result.error.is\_null() {
 drop(CString::from\_raw(result.error));
 }
 // Note: \`handle\` is NOT freed here — the caller must free it
 // with the appropriate function (fff\_destroy, fff\_free\_search\_result,
 // fff\_free\_grep\_result, fff\_free\_string, fff\_free\_scan\_progress, etc.).
 }
}

/// Free a string returned by \`fff\_\*\` functions.
///
/// ## Safety
/// \`s\` must be a valid C string allocated by this library.
#\[unsafe(no\_mangle)\]
pub unsafe extern "C" fn fff\_free\_string(s: \*mut c\_char) {
 unsafe {
 if !s.is\_null() {
 drop(CString::from\_raw(s));
 }
 }
}