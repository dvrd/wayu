/\\*\\*
 \\* Node.js FFI bindings for the fff-c native library using ffi-rs
 \\*
 \\* This module uses ffi-rs to call into the Rust C library.
 \\* All functions follow the Result pattern for error handling.
 \\*
 \\* The API is instance-based: \`ffiCreate\` returns an opaque handle that must
 \\* be passed to all subsequent calls and freed with \`ffiDestroy\`.
 \\*
 \\* ## Memory management
 \\*
 \\* Every \`fff\_\*\` function returning \`\*mut FffResult\` allocates with Rust's Box.
 \\* We MUST call \`fff\_free\_result\` to properly deallocate (not libc::free).
 \\*
 \\* ## FffResult struct reading
 \\*
 \\* The FffResult struct layout (#\[repr(C)\]):
 \\* offset 0: success (bool, 1 byte + 7 padding)
 \\* offset 8: data pointer (8 bytes) - \*mut c\_char (JSON string or null)
 \\* offset 16: error pointer (8 bytes) - \*mut c\_char (error message or null)
 \\* offset 24: handle pointer (8 bytes) - \*mut c\_void (instance handle or null)
 \\*
 \\* ## Two-step approach for reading + freeing
 \\*
 \\* ffi-rs auto-dereferences struct retType pointers, losing the original pointer.
 \\* We solve this by:
 \\* 1\. Calling the C function with \`retType: DataType.External\` to get the raw pointer
 \\* 2\. Using \`restorePointer\` to read the struct fields from the raw pointer
 \\* 3\. Calling \`fff\_free\_result\` with the original raw pointer
 \\*
 \\* ## Null pointer detection
 \\*
 \\* \`isNullPointer\` from ffi-rs correctly detects null C pointers wrapped as
 \\* V8 External objects. We use this instead of truthy checks.
 \*/

import {
 close,
 DataType,
 isNullPointer,
 type JsExternal,
 load,
 open,
 restorePointer,
 wrapPointer,
} from "ffi-rs";
import { findBinary } from "./binary.js";
import type {
 FileItem,
 GrepMatch,
 GrepResult,
 Location,
 Result,
 Score,
 SearchResult,
} from "./types.js";
import { createGrepCursor, err } from "./types.js";

const LIBRARY\_KEY = "fff\_c";

/\\*\\* Grep mode constants matching the C API (u8). \*/
const GREP\_MODE\_PLAIN = 0;
const GREP\_MODE\_REGEX = 1;
const GREP\_MODE\_FUZZY = 2;

/\\*\\* Map string mode to u8 \*/
function grepModeToU8(mode?: string): number {
 switch (mode) {
 case "regex":
 return GREP\_MODE\_REGEX;
 case "fuzzy":
 return GREP\_MODE\_FUZZY;
 default:
 return GREP\_MODE\_PLAIN;
 }
}

// Track whether the library is loaded
let isLoaded = false;

/\\*\\*
 \\* Struct type definition for FffResult used with restorePointer.
 \\*
 \\* Uses U8 for the bool success field (correct alignment with ffi-rs).
 \\* Uses External for ALL pointer fields to avoid hangs on null char\* pointers
 \\* (ffi-rs hangs when trying to read DataType.String from null char\*).
 \*/
const FFF\_RESULT\_STRUCT = {
 success: DataType.U8,
 error: DataType.External,
 handle: DataType.External,
 int\_value: DataType.I64,
};

interface FffResultRaw {
 success: number;
 error: JsExternal;
 handle: JsExternal;
 int\_value: number;
}

/\\*\\*
 \\* Load the native library using ffi-rs
 \*/
function loadLibrary(): void {
 if (isLoaded) return;

 const binaryPath = findBinary();
 if (!binaryPath) {
 throw new Error(
 "fff native library not found. Run \`npx @ff-labs/fff-node download\` or build from source with \`cargo build --release -p fff-c\`",
 );
 }

 open({ library: LIBRARY\_KEY, path: binaryPath });
 isLoaded = true;
}

/\\*\\*
 \\* Convert snake\_case keys to camelCase recursively
 \*/
function snakeToCamel(obj: unknown): unknown {
 if (obj === null \|\| obj === undefined) return obj;
 if (typeof obj !== "object") return obj;
 if (Array.isArray(obj)) return obj.map(snakeToCamel);

 const result: Record = {};
 for (const \[key, value\] of Object.entries(obj as Record)) {
 const camelKey = key.replace(/\_(\[a-z\])/g, (\_, letter: string) =>
 letter.toUpperCase(),
 );
 result\[camelKey\] = snakeToCamel(value);
 }
 return result;
}

/\\*\\*
 \\* Read a C string (char\*) from an ffi-rs External pointer.
 \\*
 \\* Uses restorePointer + wrapPointer to dereference the char\* and read the
 \\* null-terminated string. Returns null if the pointer is null.
 \*/
function readCString(ptr: JsExternal): string \| null {
 if (isNullPointer(ptr)) return null;
 try {
 const \[str\] = restorePointer({
 retType: \[DataType.String\],
 paramsValue: wrapPointer(\[ptr\]),
 });
 return str as string;
 } catch {
 return null;
 }
}

/\\*\\*
 \\* Call a C function that returns \`\*mut FffResult\` and get both the raw pointer
 \\* (for freeing) and the parsed struct fields.
 \\*
 \\* Step 1: Call function with \`DataType.External\` retType → raw pointer
 \\* Step 2: Use \`restorePointer\` to read struct fields from the raw pointer
 \*/
function callRaw(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): { rawPtr: JsExternal; struct: FffResultRaw } {
 const rawPtr = load({
 library: LIBRARY\_KEY,
 funcName,
 retType: DataType.External,
 paramsType,
 paramsValue,
 freeResultMemory: false,
 }) as JsExternal;

 const \[structData\] = restorePointer({
 retType: \[FFF\_RESULT\_STRUCT\],
 paramsValue: wrapPointer(\[rawPtr\]),
 }) as unknown as \[FffResultRaw\];

 return { rawPtr, struct: structData };
}

/\\*\\*
 \\* Free a FffResult pointer by calling fff\_free\_result.
 \\*
 \\* This frees the FffResult struct and its data/error strings using Rust's
 \\* Box::from\_raw and CString::from\_raw. The handle field is NOT freed.
 \*/
function freeResult(resultPtr: JsExternal): void {
 try {
 load({
 library: LIBRARY\_KEY,
 funcName: "fff\_free\_result",
 retType: DataType.Void,
 paramsType: \[DataType.External\],
 paramsValue: \[resultPtr\],
 });
 } catch {
 // Ignore cleanup errors
 }
}

/\\*\\*
 \\* Read the FffResult envelope from a raw call. Returns the parsed struct + raw pointer.
 \\* On error, frees the result and returns a Result error.
 \*/
function readResultEnvelope(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): { rawPtr: JsExternal; struct: FffResultRaw } \| Result {
 loadLibrary();
 const { rawPtr, struct: structData } = callRaw(funcName, paramsType, paramsValue);

 if (structData.success === 0) {
 const errorStr = readCString(structData.error);
 freeResult(rawPtr);
 return err(errorStr \|\| "Unknown error");
 }

 return { rawPtr, struct: structData };
}

/\\*\\* Call a function returning FffResult with void payload. \*/
function callVoidResult(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): Result {
 const res = readResultEnvelope(funcName, paramsType, paramsValue);
 if ("ok" in res) return res;
 freeResult(res.rawPtr);
 return { ok: true, value: undefined };
}

/\\*\\* Call a function returning FffResult with int\_value payload. \*/
function callIntResult(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): Result {
 const res = readResultEnvelope(funcName, paramsType, paramsValue);
 if ("ok" in res) return res;
 const value = Number(res.struct.int\_value);
 freeResult(res.rawPtr);
 return { ok: true, value };
}

/\\*\\* Call a function returning FffResult with bool in int\_value. \*/
function callBoolResult(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): Result {
 const res = readResultEnvelope(funcName, paramsType, paramsValue);
 if ("ok" in res) return res;
 const value = Number(res.struct.int\_value) !== 0;
 freeResult(res.rawPtr);
 return { ok: true, value };
}

/\\*\\* Call a function returning FffResult with a C string in handle. \*/
function callStringResult(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): Result {
 const res = readResultEnvelope(funcName, paramsType, paramsValue);
 if ("ok" in res) return res;
 const handlePtr = res.struct.handle;
 freeResult(res.rawPtr);
 if (isNullPointer(handlePtr)) return { ok: true, value: null };
 const str = readCString(handlePtr);
 freeString(handlePtr);
 return { ok: true, value: str };
}

/\\*\\* Call a function returning FffResult with a JSON string in handle. \*/
function callJsonResult(
 funcName: string,
 paramsType: DataType\[\],
 paramsValue: unknown\[\],
): Result {
 const res = readResultEnvelope(funcName, paramsType, paramsValue);
 if ("ok" in res) return res;
 const handlePtr = res.struct.handle;
 freeResult(res.rawPtr);
 if (isNullPointer(handlePtr)) return { ok: true, value: undefined as T };
 const jsonStr = readCString(handlePtr);
 freeString(handlePtr);
 if (jsonStr === null \|\| jsonStr === "") return { ok: true, value: undefined as T };
 try {
 return { ok: true, value: snakeToCamel(JSON.parse(jsonStr)) as T };
 } catch {
 return { ok: true, value: jsonStr as T };
 }
}

/\\*\\* Free a C string via fff\_free\_string. \*/
function freeString(ptr: JsExternal): void {
 try {
 load({
 library: LIBRARY\_KEY,
 funcName: "fff\_free\_string",
 retType: DataType.Void,
 paramsType: \[DataType.External\],
 paramsValue: \[ptr\],
 });
 } catch {
 // Ignore
 }
}

/\\*\\*
 \\* Opaque native handle type. Callers must not inspect or modify this value.
 \*/
export type NativeHandle = JsExternal;

/\\*\\*
 \\* Create a new file finder instance.
 \*/
export function ffiCreate(
 basePath: string,
 frecencyDbPath: string,
 historyDbPath: string,
 useUnsafeNoLock: boolean,
 warmupMmapCache: boolean,
 aiMode: boolean,
): Result {
 loadLibrary();

 const { rawPtr, struct: structData } = callRaw(
 "fff\_create\_instance",
 \[\
 DataType.String, // base\_path\
 DataType.String, // frecency\_db\_path\
 DataType.String, // history\_db\_path\
 DataType.Boolean, // use\_unsafe\_no\_lock\
 DataType.Boolean, // warmup\_mmap\_cache\
 DataType.Boolean, // ai\_mode\
 \],
 \[basePath, frecencyDbPath, historyDbPath, useUnsafeNoLock, warmupMmapCache, aiMode\],
 );

 const success = structData.success !== 0;

 try {
 if (success) {
 const handle = structData.handle;
 if (isNullPointer(handle)) {
 return err("fff\_create\_instance returned null handle");
 }
 return { ok: true, value: handle };
 } else {
 const errorStr = readCString(structData.error);
 return err(errorStr \|\| "Unknown error");
 }
 } finally {
 freeResult(rawPtr);
 }
}

/\\*\\*
 \\* Destroy and clean up an instance.
 \*/
export function ffiDestroy(handle: NativeHandle): void {
 loadLibrary();
 load({
 library: LIBRARY\_KEY,
 funcName: "fff\_destroy",
 retType: DataType.Void,
 paramsType: \[DataType.External\],
 paramsValue: \[handle\],
 });
}

// ---------------------------------------------------------------------------
// Struct type definitions for restorePointer (must match #\[repr(C)\] layout)
// ---------------------------------------------------------------------------

const FFF\_FILE\_ITEM\_STRUCT = {
 path: DataType.External,
 relative\_path: DataType.External,
 file\_name: DataType.External,
 git\_status: DataType.External,
 size: DataType.U64,
 modified: DataType.U64,
 access\_frecency\_score: DataType.I64,
 modification\_frecency\_score: DataType.I64,
 total\_frecency\_score: DataType.I64,
 is\_binary: DataType.U8,
};

interface FffFileItemRaw {
 path: JsExternal;
 relative\_path: JsExternal;
 file\_name: JsExternal;
 git\_status: JsExternal;
 size: number;
 modified: number;
 access\_frecency\_score: number;
 modification\_frecency\_score: number;
 total\_frecency\_score: number;
 is\_binary: number;
}

const FFF\_SCORE\_STRUCT = {
 total: DataType.I32,
 base\_score: DataType.I32,
 filename\_bonus: DataType.I32,
 special\_filename\_bonus: DataType.I32,
 frecency\_boost: DataType.I32,
 distance\_penalty: DataType.I32,
 current\_file\_penalty: DataType.I32,
 combo\_match\_boost: DataType.I32,
 exact\_match: DataType.U8,
 match\_type: DataType.External,
};

interface FffScoreRaw {
 total: number;
 base\_score: number;
 filename\_bonus: number;
 special\_filename\_bonus: number;
 frecency\_boost: number;
 distance\_penalty: number;
 current\_file\_penalty: number;
 combo\_match\_boost: number;
 exact\_match: number;
 match\_type: JsExternal;
}

const FFF\_SEARCH\_RESULT\_STRUCT = {
 items: DataType.External,
 scores: DataType.External,
 count: DataType.U32,
 total\_matched: DataType.U32,
 total\_files: DataType.U32,
 // FffLocation inlined (flattened)
 location\_tag: DataType.U8,
 location\_line: DataType.I32,
 location\_col: DataType.I32,
 location\_end\_line: DataType.I32,
 location\_end\_col: DataType.I32,
};

interface FffSearchResultRaw {
 items: JsExternal;
 scores: JsExternal;
 count: number;
 total\_matched: number;
 total\_files: number;
 location\_tag: number;
 location\_line: number;
 location\_col: number;
 location\_end\_line: number;
 location\_end\_col: number;
}

// FffGrepMatch (144 bytes) — ordered by alignment: ptrs, u64s, u32s, u16, bools
const FFF\_GREP\_MATCH\_STRUCT = {
 path: DataType.External,
 relative\_path: DataType.External,
 file\_name: DataType.External,
 git\_status: DataType.External,
 line\_content: DataType.External,
 match\_ranges: DataType.External,
 context\_before: DataType.External,
 context\_after: DataType.External,
 size: DataType.U64,
 modified: DataType.U64,
 total\_frecency\_score: DataType.I64,
 access\_frecency\_score: DataType.I64,
 modification\_frecency\_score: DataType.I64,
 line\_number: DataType.U64,
 byte\_offset: DataType.U64,
 col: DataType.U32,
 match\_ranges\_count: DataType.U32,
 context\_before\_count: DataType.U32,
 context\_after\_count: DataType.U32,
 fuzzy\_score: DataType.U32, // actually u16 in C, but ffi-rs doesn't have U16 — reads as u32 with padding
 has\_fuzzy\_score: DataType.U8,
 is\_binary: DataType.U8,
 is\_definition: DataType.U8,
};

interface FffGrepMatchRaw {
 path: JsExternal;
 relative\_path: JsExternal;
 file\_name: JsExternal;
 git\_status: JsExternal;
 line\_content: JsExternal;
 match\_ranges: JsExternal;
 context\_before: JsExternal;
 context\_after: JsExternal;
 size: number;
 modified: number;
 total\_frecency\_score: number;
 access\_frecency\_score: number;
 modification\_frecency\_score: number;
 line\_number: number;
 byte\_offset: number;
 col: number;
 match\_ranges\_count: number;
 context\_before\_count: number;
 context\_after\_count: number;
 fuzzy\_score: number;
 has\_fuzzy\_score: number;
 is\_binary: number;
 is\_definition: number;
}

const FFF\_GREP\_RESULT\_STRUCT = {
 items: DataType.External,
 count: DataType.U32,
 total\_matched: DataType.U32,
 total\_files\_searched: DataType.U32,
 total\_files: DataType.U32,
 filtered\_file\_count: DataType.U32,
 next\_file\_offset: DataType.U32,
 regex\_fallback\_error: DataType.External,
};

interface FffGrepResultRaw {
 items: JsExternal;
 count: number;
 total\_matched: number;
 total\_files\_searched: number;
 total\_files: number;
 filtered\_file\_count: number;
 next\_file\_offset: number;
 regex\_fallback\_error: JsExternal;
}

const FFF\_MATCH\_RANGE\_STRUCT = {
 start: DataType.U32,
 end: DataType.U32,
};

interface FffMatchRangeRaw {
 start: number;
 end: number;
}

// ---------------------------------------------------------------------------
// Struct reading helpers
// ---------------------------------------------------------------------------

function readFileItemFromRaw(raw: FffFileItemRaw): FileItem {
 return {
 path: readCString(raw.path) ?? "",
 relativePath: readCString(raw.relative\_path) ?? "",
 fileName: readCString(raw.file\_name) ?? "",
 gitStatus: readCString(raw.git\_status) ?? "",
 size: Number(raw.size),
 modified: Number(raw.modified),
 accessFrecencyScore: Number(raw.access\_frecency\_score),
 modificationFrecencyScore: Number(raw.modification\_frecency\_score),
 totalFrecencyScore: Number(raw.total\_frecency\_score),
 };
}

function readScoreFromRaw(raw: FffScoreRaw): Score {
 return {
 total: raw.total,
 baseScore: raw.base\_score,
 filenameBonus: raw.filename\_bonus,
 specialFilenameBonus: raw.special\_filename\_bonus,
 frecencyBoost: raw.frecency\_boost,
 distancePenalty: raw.distance\_penalty,
 currentFilePenalty: raw.current\_file\_penalty,
 comboMatchBoost: raw.combo\_match\_boost,
 exactMatch: raw.exact\_match !== 0,
 matchType: readCString(raw.match\_type) ?? "",
 };
}

/\\*\\*
 \\* Call an accessor function that returns a pointer to a struct element,
 \\* then read the struct from that pointer.
 \*/
function callAccessor(
 funcName: string,
 resultPtr: JsExternal,
 index: number,
 structDef: Record,
): T {
 loadLibrary();
 const elemPtr = load({
 library: LIBRARY\_KEY,
 funcName,
 retType: DataType.External,
 paramsType: \[DataType.External, DataType.U32\],
 paramsValue: \[resultPtr, index\],
 }) as JsExternal;

 const \[raw\] = restorePointer({
 retType: \[structDef\],
 paramsValue: wrapPointer(\[elemPtr\]),
 }) as unknown as \[T\];

 return raw;
}

/\\*\\*
 \\* Offset a pointer by \`bytes\` using the C API helper.
 \*/
function ptrOffset(base: JsExternal, bytes: number): JsExternal {
 return load({
 library: LIBRARY\_KEY,
 funcName: "fff\_ptr\_offset",
 retType: DataType.External,
 paramsType: \[DataType.External, DataType.U64\],
 paramsValue: \[base, bytes\],
 }) as JsExternal;
}

/\\*\\*
 \\* Read a C string array (char\*\*) of \`count\` elements.
 \*/
function readCStringArray(ptrArray: JsExternal, count: number): string\[\] {
 if (count === 0 \|\| isNullPointer(ptrArray)) return \[\];
 const result: string\[\] = \[\];
 for (let i = 0; i < count; i++) {
 const elemPtr = ptrOffset(ptrArray, i \* 8);
 const \[charPtr\] = restorePointer({
 retType: \[DataType.External\],
 paramsValue: \[elemPtr\],
 }) as unknown as \[JsExternal\];
 result.push(readCString(charPtr) ?? "");
 }
 return result;
}

function readGrepMatchFromRaw(raw: FffGrepMatchRaw): GrepMatch {
 // Read match\_ranges array via pointer offsets
 const matchRanges: \[number, number\]\[\] = \[\];
 for (let i = 0; i < raw.match\_ranges\_count; i++) {
 const rangePtr = ptrOffset(raw.match\_ranges, i \* 8); // FffMatchRange is 8 bytes
 const \[rangeRaw\] = restorePointer({
 retType: \[FFF\_MATCH\_RANGE\_STRUCT\],
 paramsValue: wrapPointer(\[rangePtr\]),
 }) as unknown as \[FffMatchRangeRaw\];
 matchRanges.push(\[rangeRaw.start, rangeRaw.end\]);
 }

 const match: GrepMatch = {
 path: readCString(raw.path) ?? "",
 relativePath: readCString(raw.relative\_path) ?? "",
 fileName: readCString(raw.file\_name) ?? "",
 gitStatus: readCString(raw.git\_status) ?? "",
 lineContent: readCString(raw.line\_content) ?? "",
 size: Number(raw.size),
 modified: Number(raw.modified),
 totalFrecencyScore: Number(raw.total\_frecency\_score),
 accessFrecencyScore: Number(raw.access\_frecency\_score),
 modificationFrecencyScore: Number(raw.modification\_frecency\_score),
 isBinary: raw.is\_binary !== 0,
 lineNumber: Number(raw.line\_number),
 col: raw.col,
 byteOffset: Number(raw.byte\_offset),
 matchRanges,
 };

 if (raw.has\_fuzzy\_score !== 0) {
 match.fuzzyScore = raw.fuzzy\_score;
 }
 if (raw.context\_before\_count > 0) {
 match.contextBefore = readCStringArray(raw.context\_before, raw.context\_before\_count);
 }
 if (raw.context\_after\_count > 0) {
 match.contextAfter = readCStringArray(raw.context\_after, raw.context\_after\_count);
 }

 return match;
}

/\\*\\*
 \\* Parse an FffGrepResult from \`FffResult.handle\`, then free native memory.
 \*/
function parseGrepResult(rawPtr: JsExternal): Result {
 loadLibrary();

 const \[envelope\] = restorePointer({
 retType: \[FFF\_RESULT\_STRUCT\],
 paramsValue: wrapPointer(\[rawPtr\]),
 }) as unknown as \[FffResultRaw\];

 const success = envelope.success !== 0;

 if (!success) {
 const errorMsg = readCString(envelope.error) \|\| "Unknown error";
 freeResult(rawPtr);
 return err(errorMsg);
 }

 const handlePtr = envelope.handle;
 freeResult(rawPtr);

 if (isNullPointer(handlePtr)) {
 return err("grep returned null result");
 }

 const \[gr\] = restorePointer({
 retType: \[FFF\_GREP\_RESULT\_STRUCT\],
 paramsValue: wrapPointer(\[handlePtr\]),
 }) as unknown as \[FffGrepResultRaw\];

 const count = gr.count;
 const regexFallbackError = readCString(gr.regex\_fallback\_error) ?? undefined;

 const items: GrepMatch\[\] = \[\];
 for (let i = 0; i < count; i++) {
 const rawMatch = callAccessor(
 "fff\_grep\_result\_get\_match",
 handlePtr,
 i,
 FFF\_GREP\_MATCH\_STRUCT,
 );
 items.push(readGrepMatchFromRaw(rawMatch));
 }

 // Free native grep result
 load({
 library: LIBRARY\_KEY,
 funcName: "fff\_free\_grep\_result",
 retType: DataType.Void,
 paramsType: \[DataType.External\],
 paramsValue: \[handlePtr\],
 });

 const grepResult: GrepResult = {
 items,
 totalMatched: gr.total\_matched,
 totalFilesSearched: gr.total\_files\_searched,
 totalFiles: gr.total\_files,
 filteredFileCount: gr.filtered\_file\_count,
 nextCursor: gr.next\_file\_offset > 0 ? createGrepCursor(gr.next\_file\_offset) : null,
 };
 if (regexFallbackError) {
 grepResult.regexFallbackError = regexFallbackError;
 }
 return { ok: true, value: grepResult };
}

/\\*\\*
 \\* Parse an FffSearchResult from \`FffResult.handle\`, then free native memory.
 \*/
function parseSearchResult(rawPtr: JsExternal): Result {
 loadLibrary();

 // Read FffResult envelope
 const \[envelope\] = restorePointer({
 retType: \[FFF\_RESULT\_STRUCT\],
 paramsValue: wrapPointer(\[rawPtr\]),
 }) as unknown as \[FffResultRaw\];

 const success = envelope.success !== 0;

 if (!success) {
 const errorMsg = readCString(envelope.error) \|\| "Unknown error";
 freeResult(rawPtr);
 return err(errorMsg);
 }

 const handlePtr = envelope.handle;
 // Free the FffResult envelope (does NOT free handle)
 freeResult(rawPtr);

 if (isNullPointer(handlePtr)) {
 return err("fff\_search returned null search result");
 }

 // Read FffSearchResult struct
 const \[sr\] = restorePointer({
 retType: \[FFF\_SEARCH\_RESULT\_STRUCT\],
 paramsValue: wrapPointer(\[handlePtr\]),
 }) as unknown as \[FffSearchResultRaw\];

 const count = sr.count;

 // Read location
 let location: Location \| undefined;
 if (sr.location\_tag === 1) {
 location = { type: "line", line: sr.location\_line };
 } else if (sr.location\_tag === 2) {
 location = { type: "position", line: sr.location\_line, col: sr.location\_col };
 } else if (sr.location\_tag === 3) {
 location = {
 type: "range",
 start: { line: sr.location\_line, col: sr.location\_col },
 end: { line: sr.location\_end\_line, col: sr.location\_end\_col },
 };
 }

 // Read items and scores via accessor functions
 const items: FileItem\[\] = \[\];
 const scores: Score\[\] = \[\];

 for (let i = 0; i < count; i++) {
 const rawItem = callAccessor(
 "fff\_search\_result\_get\_item",
 handlePtr,
 i,
 FFF\_FILE\_ITEM\_STRUCT,
 );
 items.push(readFileItemFromRaw(rawItem));

 const rawScore = callAccessor(
 "fff\_search\_result\_get\_score",
 handlePtr,
 i,
 FFF\_SCORE\_STRUCT,
 );
 scores.push(readScoreFromRaw(rawScore));
 }

 // Free native search result
 load({
 library: LIBRARY\_KEY,
 funcName: "fff\_free\_search\_result",
 retType: DataType.Void,
 paramsType: \[DataType.External\],
 paramsValue: \[handlePtr\],
 });

 const result: SearchResult = {
 items,
 scores,
 totalMatched: sr.total\_matched,
 totalFiles: sr.total\_files,
 };
 if (location) {
 result.location = location;
 }
 return { ok: true, value: result };
}

/\\*\\*
 \\* Perform fuzzy search.
 \*/
export function ffiSearch(
 handle: NativeHandle,
 query: string,
 currentFile: string,
 maxThreads: number,
 pageIndex: number,
 pageSize: number,
 comboBoostMultiplier: number,
 minComboCount: number,
): Result {
 loadLibrary();

 const rawPtr = load({
 library: LIBRARY\_KEY,
 funcName: "fff\_search",
 retType: DataType.External,
 paramsType: \[\
 DataType.External, // handle\
 DataType.String, // query\
 DataType.String, // current\_file\
 DataType.U32, // max\_threads\
 DataType.U32, // page\_index\
 DataType.U32, // page\_size\
 DataType.I32, // combo\_boost\_multiplier\
 DataType.U32, // min\_combo\_count\
 \],
 paramsValue: \[\
 handle,\
 query,\
 currentFile,\
 maxThreads,\
 pageIndex,\
 pageSize,\
 comboBoostMultiplier,\
 minComboCount,\
 \],
 freeResultMemory: false,
 }) as JsExternal;

 return parseSearchResult(rawPtr);
}

/\\*\\*
 \\* Live grep - search file contents.
 \*/
export function ffiLiveGrep(
 handle: NativeHandle,
 query: string,
 mode: string,
 maxFileSize: number,
 maxMatchesPerFile: number,
 smartCase: boolean,
 fileOffset: number,
 pageLimit: number,
 timeBudgetMs: number,
 beforeContext: number,
 afterContext: number,
 classifyDefinitions: boolean,
): Result {
 loadLibrary();

 const rawPtr = load({
 library: LIBRARY\_KEY,
 funcName: "fff\_live\_grep",
 retType: DataType.External,
 paramsType: \[\
 DataType.External, // handle\
 DataType.String, // query\
 DataType.U8, // mode\
 DataType.U64, // max\_file\_size\
 DataType.U32, // max\_matches\_per\_file\
 DataType.Boolean, // smart\_case\
 DataType.U32, // file\_offset\
 DataType.U32, // page\_limit\
 DataType.U64, // time\_budget\_ms\
 DataType.U32, // before\_context\
 DataType.U32, // after\_context\
 DataType.Boolean, // classify\_definitions\
 \],
 paramsValue: \[\
 handle,\
 query,\
 grepModeToU8(mode),\
 maxFileSize,\
 maxMatchesPerFile,\
 smartCase,\
 fileOffset,\
 pageLimit,\
 timeBudgetMs,\
 beforeContext,\
 afterContext,\
 classifyDefinitions,\
 \],
 freeResultMemory: false,
 }) as JsExternal;

 return parseGrepResult(rawPtr);
}

/\\*\\*
 \\* Multi-pattern grep - Aho-Corasick multi-needle search.
 \*/
export function ffiMultiGrep(
 handle: NativeHandle,
 patternsJoined: string,
 constraints: string,
 maxFileSize: number,
 maxMatchesPerFile: number,
 smartCase: boolean,
 fileOffset: number,
 pageLimit: number,
 timeBudgetMs: number,
 beforeContext: number,
 afterContext: number,
 classifyDefinitions: boolean,
): Result {
 loadLibrary();

 const rawPtr = load({
 library: LIBRARY\_KEY,
 funcName: "fff\_multi\_grep",
 retType: DataType.External,
 paramsType: \[\
 DataType.External, // handle\
 DataType.String, // patterns\_joined\
 DataType.String, // constraints\
 DataType.U64, // max\_file\_size\
 DataType.U32, // max\_matches\_per\_file\
 DataType.Boolean, // smart\_case\
 DataType.U32, // file\_offset\
 DataType.U32, // page\_limit\
 DataType.U64, // time\_budget\_ms\
 DataType.U32, // before\_context\
 DataType.U32, // after\_context\
 DataType.Boolean, // classify\_definitions\
 \],
 paramsValue: \[\
 handle,\
 patternsJoined,\
 constraints,\
 maxFileSize,\
 maxMatchesPerFile,\
 smartCase,\
 fileOffset,\
 pageLimit,\
 timeBudgetMs,\
 beforeContext,\
 afterContext,\
 classifyDefinitions,\
 \],
 freeResultMemory: false,
 }) as JsExternal;

 return parseGrepResult(rawPtr);
}

/\\*\\*
 \\* Trigger file scan.
 \*/
export function ffiScanFiles(handle: NativeHandle): Result {
 return callVoidResult("fff\_scan\_files", \[DataType.External\], \[handle\]);
}

/\\*\\*
 \\* Check if scanning.
 \*/
export function ffiIsScanning(handle: NativeHandle): boolean {
 loadLibrary();
 return load({
 library: LIBRARY\_KEY,
 funcName: "fff\_is\_scanning",
 retType: DataType.Boolean,
 paramsType: \[DataType.External\],
 paramsValue: \[handle\],
 }) as boolean;
}

// FffScanProgress struct definition
const FFF\_SCAN\_PROGRESS\_STRUCT = {
 scanned\_files\_count: DataType.U64,
 is\_scanning: DataType.U8,
};

interface FffScanProgressRaw {
 scanned\_files\_count: number;
 is\_scanning: number;
}

/\\*\\*
 \\* Get scan progress.
 \*/
export function ffiGetScanProgress(
 handle: NativeHandle,
): Result<{ scannedFilesCount: number; isScanning: boolean }> {
 loadLibrary();
 const res = readResultEnvelope("fff\_get\_scan\_progress", \[DataType.External\], \[handle\]);
 if ("ok" in res) return res;

 const handlePtr = res.struct.handle;
 freeResult(res.rawPtr);

 if (isNullPointer(handlePtr)) return err("scan progress returned null");

 const \[sp\] = restorePointer({
 retType: \[FFF\_SCAN\_PROGRESS\_STRUCT\],
 paramsValue: wrapPointer(\[handlePtr\]),
 }) as unknown as \[FffScanProgressRaw\];

 const result = {
 scannedFilesCount: Number(sp.scanned\_files\_count),
 isScanning: sp.is\_scanning !== 0,
 };

 // Free native scan progress
 load({
 library: LIBRARY\_KEY,
 funcName: "fff\_free\_scan\_progress",
 retType: DataType.Void,
 paramsType: \[DataType.External\],
 paramsValue: \[handlePtr\],
 });

 return { ok: true, value: result };
}

/\\*\\*
 \\* Wait for a tree scan to complete.
 \*/
export function ffiWaitForScan(handle: NativeHandle, timeoutMs: number): Result {
 return callBoolResult(
 "fff\_wait\_for\_scan",
 \[DataType.External, DataType.U64\],
 \[handle, timeoutMs\],
 );
}

/\\*\\*
 \\* Restart index in new path.
 \*/
export function ffiRestartIndex(handle: NativeHandle, newPath: string): Result {
 return callVoidResult(
 "fff\_restart\_index",
 \[DataType.External, DataType.String\],
 \[handle, newPath\],
 );
}

/\\*\\*
 \\* Refresh git status.
 \*/
export function ffiRefreshGitStatus(handle: NativeHandle): Result {
 return callIntResult("fff\_refresh\_git\_status", \[DataType.External\], \[handle\]);
}

/\\*\\*
 \\* Track query completion.
 \*/
export function ffiTrackQuery(
 handle: NativeHandle,
 query: string,
 filePath: string,
): Result {
 return callBoolResult(
 "fff\_track\_query",
 \[DataType.External, DataType.String, DataType.String\],
 \[handle, query, filePath\],
 );
}

/\\*\\*
 \\* Get historical query.
 \*/
export function ffiGetHistoricalQuery(
 handle: NativeHandle,
 offset: number,
): Result {
 return callStringResult(
 "fff\_get\_historical\_query",
 \[DataType.External, DataType.U64\],
 \[handle, offset\],
 );
}

/\\*\\*
 \\* Health check.
 \\*
 \\* \`handle\` can be null for a limited check (version + git only).
 \\* When null, we pass DataType.U64 with value 0 as a null pointer workaround
 \\* since ffi-rs does not accept \`null\` for External parameters.
 \*/
export function ffiHealthCheck(
 handle: NativeHandle \| null,
 testPath: string,
): Result {
 if (handle === null) {
 // Use U64(0) as a null pointer since ffi-rs rejects null for External params
 return callJsonResult(
 "fff\_health\_check",
 \[DataType.U64, DataType.String\],
 \[0, testPath\],
 );
 }

 return callJsonResult(
 "fff\_health\_check",
 \[DataType.External, DataType.String\],
 \[handle, testPath\],
 );
}

/\\*\\*
 \\* Ensure the library is loaded.
 \\*
 \\* Loads the native library from the platform-specific npm package
 \\* or a local dev build. Throws if the binary is not found.
 \*/
export function ensureLoaded(): void {
 loadLibrary();
}

/\\*\\*
 \\* Check if the library is available.
 \*/
export function isAvailable(): boolean {
 try {
 loadLibrary();
 return true;
 } catch {
 return false;
 }
}

/\\*\\*
 \\* Close the library and release ffi-rs resources.
 \\* Call this when completely done with the library.
 \*/
export function closeLibrary(): void {
 if (isLoaded) {
 close(LIBRARY\_KEY);
 isLoaded = false;
 }
}