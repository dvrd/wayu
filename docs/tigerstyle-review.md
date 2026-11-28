# TigerStyle in practice, compared with Wayu

Research snapshot · 27 November 2026 · TigerBeetle `0aeb30656136` · Wayu `121485099a0b` (`develop`).

**Wayu's first opportunity is to define what a successful configuration change guarantees.** A fresh build
returned success after saving an alias even though it could not publish the Bash runtime. Bash could not see
the alias. Its second opportunity is to budget the parts of a long-lived shell that retain user data. In a
local experiment, streaming a 4 MiB file through a pipeline took about 5.4 MiB peak RSS as reported for the
Wayu command. Capturing that file into a variable took about 24.5 MiB. The two findings call for different
fixes and different tests.

TigerBeetle starts with a particular promise. Acknowledged financial transactions must survive failures
within the stated fault model, with a serial order all replicas agree on. That promise determines how many
messages can coexist, what evidence permits discarding a damaged write, when the primary may reply, and what
the simulator must check. Wayu has a different set of promises. A child must receive the intended arguments
and file descriptors. The terminal must be restored. A reported alias change must have a precise meaning.
History, completions and command output have different lifetimes. In each case the useful exercise is to
trace the promise through the implementation to an observable failure or a test.
[TigerBeetle architecture](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/ARCHITECTURE.md#L7-L89)
· [Wayu stability contract](STABILITY.md) · [Wayu CLI contract](cli.md)

| Decision for Wayu | Evidence behind it | First observable result |
|---|---|---|
| Make partial publication explicit | The alias was present in the canonical store while a fresh Bash could not load it. | A caller can tell what was saved, what failed, and whether a later repair succeeded. |
| Budget capture, editing and history separately | Captured data survives a read, an undo record survives a keystroke, and history survives a command. An 8 KiB read buffer bounds only one read. | Streaming and captured workloads have separate measurements. Oversized input has a documented outcome. |
| Add deterministic interruption points to the existing failure campaign | The current OS-level tests exercise real failures. A seeded sleep cannot tell us precisely where a writer died. | A test reaches a named phase, interrupts the writer, and checks the complete previous and resulting states. |
| Keep executable compatibility checks | Wayu tests actual host-shell interpretation, CLI JSON, exit status, PTY behavior and previous-release upgrades. | A new contract has at least one consumer-level example that fails if it is broken. |
| Keep replica-specific mechanisms upstream | Financial events have a protocol for retransmission and ordering. Arbitrary shell commands can have external side effects. | Budget or reject work before spawning when possible. Recovery of derived files can be retried independently of executing user commands. |

**Reading route.** [Resource budgets](#where-tigerbeetle-spends-its-memory) · [Wayu measurements](#where-wayu-already-has-budgets-and-where-it-grows) · [Write and recovery guarantees](#what-a-successful-write-promises) · [Verification and delivery](#verification-and-delivery) · [Code and design practices](#code-and-design-practices) · [Priorities and scope](#what-i-would-do-in-wayu)

## Why the database is built this way

A transfer touches two accounts, and unrelated clients can contend for a popular account. More threads
cannot make two conflicting balance updates independent. TigerBeetle orders the updates, groups homogeneous
operations in batches, prefetches the required data with parallel I/O, and executes the accounting step
synchronously. A primary can pipeline replication for later requests while a previous request commits.
Batching amortizes the work of replication and storage, and moves the operation-kind branch outside the
per-record loop. Fixed-size values in separate LSM trees and compact cache metadata reflect that particular
access pattern. The relevant design question for Wayu is which operations must be serialized. Serializing
changes to one entries store prevents lost updates. Starting a pipeline one process at a time *and waiting
for each before starting the next* could prevent the producer and consumer from making progress together.
Wayu already starts the stages and then waits for the job.
[Contention and ordering](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/ARCHITECTURE.md#L7-L58)
·
[Batching and layout](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/ARCHITECTURE.md#L329-L396)
·
[Prefetch and execution](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/ARCHITECTURE.md#L424-L465)
· [Wayu pipeline](../src/native_shell.odin#L704)

TigerBeetle also budgets *when* work is done. Its LSM merge tracks how much work remains and the beats left
to perform it. It asserts that current-beat progress fits total progress and the overall quota. Pacing
maintenance reduces the amount it can push into a single execution interval. In Wayu, incremental history
refresh and the file watcher's debounced generation serve related purposes. The most useful native-shell
latency measurement would distinguish waiting for the first prompt, handling a typical keystroke, and
handling one just as expensive history or suggestion work becomes due. A median of shell startups cannot
answer the latter question.
[Compaction quotas](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/lsm/compaction.zig#L370-L391)
· [Wayu history](../src/native_history.odin) · [Watcher](../src/hot_reload.odin#L324-L369) ·
[Recorded startup methodology](benchmarks.md)

## Where TigerBeetle spends its memory

TigerBeetle answers three different questions about memory. How much useful data should fit in a cache? How
many objects must coexist for a replica to keep moving? Which allocations are legal after startup? Each
answer lives at a different layer. Keeping those questions separate is especially valuable for Wayu, where
an interactive session, one command, and a child process have different owners and lifetimes.

**From a CLI flag to physical storage.** When an operator supplies `--memory`, TigerBeetle divides those
bytes among four cache payloads. The grid gets 64%, accounts 32%, transfers 0%, and pending transfers 4%.
The percentages must sum to 100 at compile time. The CLI rejects individual cache overrides alongside this
flag. Without it, the process uses the individual overrides or the defaults for the selected operating mode.
The calculation widens the byte count to 128 bits before multiplying. For an object cache, the code divides
by object size, rounds the count down to the multiple required by that cache layout, rejects counts outside
the 32-bit range, and asserts that the resulting payload fits the original byte allowance. A zero
transfer-cache share concerns caching. Transfers still exist in the database.
[Split and invariant](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle/cli.zig#L503-L520),
[option resolution](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle/cli.zig#L891-L921),
[byte-to-capacity conversion](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle/cli.zig#L1437-L1476).

The process also needs messages, manifest nodes, compaction workspace, and cache metadata. Startup wraps its
allocator in a counter and logs the live bytes allocated during initialization. The counter tracks allocated
bytes less freed bytes. The log explicitly excludes page rounding. An operator who wants a bound on resident
memory needs measurements for the whole process in addition to the cache settings. The replica separately
wraps its own allocator in a state machine. Initialization permits allocation and resizing, serving denies
calls through the wrapper, and teardown permits freeing. A free during partial initialization switches the
wrapper to teardown so that an error can unwind previously acquired resources. This is an executable
ownership rule with a precise scope.
[Startup ownership](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle/main.zig#L318-L341),
[reported usage](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle/main.zig#L496-L506),
[counter](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/counting_allocator.zig#L25-L38),
[phase checks](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/static_allocator.zig#L14-L82),
[replica transition](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L664-L739).

**Count simultaneous owners.** The client message pool gives a worked example small enough to check on
paper. Six potential replica connections each need one receive buffer. Each connection can queue two
outgoing messages. The client holds one in-flight request, and a transient operation such as parsing a
message or sending a ping can need one spare. That yields `6 + 6 × 2 + 1 + 1 = 20` slots. With the default 1
MiB message size, the pool allocates 20 MiB of payload buffers plus metadata. On the server the formula
includes outstanding storage reads and writes, repair reads, the pipeline, a loopback message, quorum work
and TCP connections. There are separate slots for a burst and a commit reply because they can happen at the
same time. The final sanity check is explicitly a necessary condition for progress. The ownership argument
does the heavier work.
[Client and replica derivations](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/message_pool.zig#L27-L102),
[replica count](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/constants.zig#L23-L28),
[client send depth](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/constants.zig#L419-L428),
[message size](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/config.zig#L153-L161).

The pool allocates one sector-aligned array of payloads and one array of message descriptors. It pairs them
once. Getting a slot pops the free list and installs its first reference. Releasing the last reference
returns the slot. Teardown asserts that every slot came back. A full network send queue drops the outgoing
message before acquiring a queue reference. A full primary pipeline ignores an arriving request. The client
owns the in-flight request, backs off on timeout and resends it. These policies work together because the
replication protocol permits retransmission. A shell cannot make the same assumption about a child program
that appends to a file. Replaying a partially executed pipeline could repeat its side effects.
[Pool construction and teardown](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/message_pool.zig#L194-L241),
[slot reuse](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/message_pool.zig#L252-L299),
[send queue](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/message_bus.zig#L940-L966),
[pipeline saturation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L6777-L6783),
[retry ownership](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/client.zig#L666-L682).

**Choose a layout from its access pattern.** The default set-associative cache has 16 candidate slots per
set, 8-bit hash tags, 2-bit access counters, and a 64-byte cache line assumption. The tags, values, counters
and rotating eviction hands have separate storage. Four sets' tag groups fit in a cache line. Most
nonmatching keys can be ruled out from compact tags before comparing the full key. Compile-time checks
enforce the size relationships, and hits and misses are counted. This level of specialization has a clear
workload behind it. Wayu has a cheaper first opportunity in the interactive editor, where the source itself
reveals avoidable copying.
[Layout constraints](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/lsm/set_associative_cache.zig#L15-L106),
[metadata and allocation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/lsm/set_associative_cache.zig#L108-L180),
[lookup metrics](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/lsm/set_associative_cache.zig#L228-L244).

## Where Wayu already has budgets, and where it grows

Wayu has several explicit contracts today. The shell keeps at most 256 completed background-job statuses,
evicts the oldest and frees reaped job members. Its source builtin reports an error at 32 nested files, and
native functions have a depth guard of 64. A subprocess helper retains at most 64 KiB of stdout and 64 KiB
of stderr and continues draining both pipes so the child can finish. Native pipelines use OS pipes, close
the previous descriptor as they advance and store bookkeeping for each launched member. The interactive
shell distinguishes prompt configuration that lives for the session from scratch storage reclaimed after
each submitted command. Releasing scratch space limits lifetime. A single large command can still set the
high-water mark. [Completed jobs](../src/native_jobs.odin#L167-L189),
[source](../src/native_config.odin#L182-L198), [function depth](../src/native_shell.odin#L494-L512),
[subprocess capture](../src/subprocess.odin#L622-L705),
[pipeline descriptors](../src/native_shell.odin#L895-L926),
[prompt and command lifetimes](../src/native_shell.odin#L1094-L1163).

**Command substitution already costs enough to measure.** The parent reads the substitution child's pipe
into an 8 KiB buffer, appends each chunk to a growing builder, waits for the child, propagates a nonzero
status and trims trailing newlines. The read buffer limits each system call. The builder retains the whole
result, and the assignment path can create additional copies. A fresh optimized build of the reviewed
revision ran on Darwin arm64, each invocation in a temporary HOME. Three alternating observations per path
and file size gave the median peak RSS in MiB reported by Darwin’s `wait4` for the Wayu invocation. All 18
commands exited zero. A reaped descendant can contribute to this high-water mark.
[Substitution](../src/native_bindings.odin#L95-L160), [assignment](../src/native_shell.odin#L742-L755).

| Input | `/bin/cat FILE \| /usr/bin/wc -c >/dev/null` | `v=$(/bin/cat FILE)` |
|---|---:|---:|
| Empty | 5.38 | 5.44 |
| 1 MiB | 5.39 | 9.47 |
| 4 MiB | 5.39 | 24.48 |

A separate run using the checkout’s existing binary gave 5.41 and 24.47 MiB at 4 MiB of input. Both
measurements include startup and intermediate storage. Neither isolates the cost of an individual copy.
Start by measuring the allocator high-water mark separately for capture, expansion and assignment. If Wayu
adopts a configurable maximum for substitutions, test one byte below it, exactly at it, and one byte over
it. Overflow must fail the command explicitly before its consumer runs. Quiet truncation is acceptable only
for a stream documented as diagnostic. Include a writer that produces beyond pipe capacity, exercise
interruption and child reaping, and verify that an ordinary streaming pipeline can still pass more data than
the substitution budget. A default that changes previously successful scripts belongs in the CLI contract
and upgrade notes. [Current substitution tests](../tests/integration/native_shell.odin#L312-L339),
[failure propagation](../tests/integration/native_shell.odin#L472-L499).

**Interactive editing and history have different remedies.** Each editor replacement saves the old line and
cursor on the undo stack and constructs a new complete string from prefix, insertion and suffix. For a line
typed one ASCII byte at a time from empty, the successive new strings contain `1 + 2 + … + n` bytes. At
4,096 characters that is approximately 8 MiB of line payload within one prompt before undo metadata,
suggestions or redraws. This is a source-derived cost, independent of the RSS experiment. A mutable line
plus reversible edit deltas could preserve today’s undo steps while reducing retained copies. Give rendering
a short-lived scratch allocator. Test sequential typing, bracketed paste as a single edit, cursor movement
through multibyte text, undo/redo and redraw latency at increasing sizes.
[Editor ownership and redraw](../src/native_editor.odin#L8-L63),
[undo and paste](../src/native_editor.odin#L433-L463),
[keystroke insertion](../src/native_editor.odin#L505-L516),
[existing PTY undo test](../tests/integration/native_shell_pty.odin#L97-L105).

Native history tracks an inode and file offset. During an incremental refresh it reads new bytes and
advances its offset through the last complete record, so a partial tail can be read again. Rotation and
truncation trigger a fresh scan. On first load it still scans the full file and clones every valid command.
External shell history for suggestions reads the entire file, splits it, decodes shell-specific multiline
representations and retains the accepted strings. A recent-command window with both entry and byte budgets
could keep interactive memory predictable while retaining the on-disk record. Preserve access to older
history via on-demand reads. Include an oversized single record, an interrupted append, rotation and
concurrent sessions in tests. Filtering suggestions only after loading the whole source would leave the
startup peak in place. [Native history synchronization](../src/native_history.odin#L19-L113),
[external history input](../src/native_history.odin#L116-L167),
[decoded storage](../src/native_history.odin#L208-L236).

Wayu already measures startup with a useful control. Its benchmark checks that initialization actually
loaded the fixture, then compares interleaved zsh/bash startups against equivalent empty configurations. The
default allowance for added time is the greater of 30 ms and twice the baseline median. Add a companion
native-shell workload that measures first prompt with small and large histories, keystroke-to-redraw
latency, and memory after repeated commands. Keep deterministic byte/entry limits in correctness tests.
Collect per-platform baselines before gating noisy timing or RSS. These changes preserve the flexibility
that shell workloads require while making their largest costs observable.
[Existing benchmark and calibration](../tests/benchmark/budget.sh#L10-L51).

### How to work out an upfront budget for a shell

Start with one process and one ownership table. For a command substitution, the 8 KiB read buffer, the
capacity of the output builder, the string produced during expansion, and the variable's stored value
represent different possible charges. Determine which refer to the same backing memory and which remain live
together. For a retained builder, count its **capacity**, including spare bytes. At a reallocation, the old
and new allocations may coexist. Multiplying final output length by the number of source variables would get
the accounting wrong in both directions. Instrument allocation and release across these transitions, then
vary quoting, concatenation and assignment separately. The two RSS measurements above provide a check on
scale. [Wayu capture](../src/native_bindings.odin#L95-L160) ·
[Expansion and assignment](../src/native_shell.odin#L742-L755) ·
[TigerBeetle allocation counter](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/counting_allocator.zig)

For an initial design, define three separately observable quantities. Let **H** be the maximum retained
bytes for the in-memory history window, **U** the maximum retained undo bytes, and **C** the maximum
parent-side scratch capacity charged to captures in one evaluation. Then `H + U + C` bounds those three
ownership classes *only if admission checks cover every allocation charged to them*. It excludes persistent
variables, the editor's current line, ordinary evaluator scratch, allocator overhead, the OS and child
processes. A per-capture limit also needs an explicit scope when commands nest or fork. There is no basis in
this review for assigning production defaults to H, U or C. The first useful deliverable is the measured
peak for each class, its release point, and the behavior when that class is full.

| Owner | When capacity is exhausted | Observable acceptance test |
|---|---|---|
| A streaming pipe | Allow the kernel to slow the producer. The consumer may close early. | Move more data than the capture budget, keep results correct and reap the producer. Preserve the distinction between SIGPIPE and a deliberate exit 141. |
| Captured substitution output | If an explicit budget is adopted, fail the enclosing expansion, release scratch and finish child cleanup. A partial value could change the meaning of the command. | Test exactly-at-limit, one byte over, interruption, nested use and a following command in the same session. |
| An undo or suggestion window | Choose which old entries may be evicted. The current input and its cursor must remain usable. History on disk has a separate retention policy. | Reach both byte and entry limits using a long single entry and many small entries. Exercise undo and retrieval of older history. |
| Completed-job records | Wayu already evicts the oldest result at 256 retained completions. This is a count of completed records. Active jobs and their children have separate lifetimes. | Exercise the oldest and newest retained statuses across eviction and continue reaping new children. [Existing job bookkeeping](../src/native_jobs.odin#L169-L190) |

## What a successful write promises

### From a transfer to an acknowledged result

TigerBeetle defines success at several boundaries. Suppose a user submits a transfer, the database records
it, and the application restarts before showing a receipt. The caller is responsible for generating and
persisting the transfer ID before sending the first request. Reusing that ID lets the caller find out
whether the transfer was created. Within a live client session the protocol can also recognize the same
request number and checksum and return the earlier reply. Those mechanisms solve different failure windows.
The application ID survives the loss of the client session. The session machinery can reproduce an earlier
reply without executing that request again. The public result distinguishes an existing transfer from reuse
of its ID with, for example, a different amount or debit account.
[Submission contract](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/coding/reliable-transaction-submission.md#L9-L54)
·
[Session replay](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L6655-L6699)
·
[Transfer results](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle.zig#L220-L253)

Follow one ordinary write. The primary accepts a request in its normal state. Replicas append the prepared
operation to their journals. A callback with a completed write asks to send a prepare acknowledgement. The
primary matches the acknowledgement to the prepare and checkpoint, counts each responding replica once, and
marks the operation ready when its configured replication quorum is reached. Even if a later operation
becomes ready first, execution takes the **head** of the queue, checks that its operation number is exactly
the committed number plus one, and waits for that head's quorum. Execution advances the committed position,
updates the client session as appropriate and sends the reply. This is how concurrent disk and network work
can deliver ordered, repeatable results. It also explains where waiting is deliberate when replicas or
storage fall behind.
[Request handling](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L1937-L1991)
·
[Journal completion](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L11255-L11270)
·
[Quorum accounting](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L2266-L2313)
·
[Ordered commit](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L4602-L4628)
·
[Client reply](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/replica.zig#L5474-L5561)

The state machine separately defines **which business changes succeed together**. A request may contain
independently successful events. Events explicitly linked into a chain open a mutation scope. The first
failure discards the scope and changes the results of earlier events that were rolled back. The failing
event retains its own reason. An unterminated chain has its own error. A successful chain persists its
changes on the closing event, allowing later independent events in the same request to see them. A caller
can therefore batch work for throughput and still express its actual atomicity requirement.
[Public example](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/coding/linked-events.md#L3-L41)
·
[Opening the scope](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/state_machine.zig#L2992-L3022)
·
[Discard and result repair](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/state_machine.zig#L3090-L3123)
·
[Successful close](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/state_machine.zig#L3170-L3186)

TigerBeetle makes the public representation executable at compile time. Both account and transfer records
must occupy 128 bytes, align to 16 bytes and have no implicit padding. Its 256-byte message header has a
separate body checksum, explicit reserved fields and a protocol version. Decoding validates size, reserved
bits, and version before command-specific checks. Wayu's compatibility surface is text, JSON, exit codes and
host-shell behavior. Its own tests compare command documentation against the live command table and execute
example commands from the documented exit-code table against the binary. That is the practical analogue of a
wire-layout assertion. A new partially successful mutation should gain a real example and a test for its
recovery semantics as well as its number.
[Account and transfer layouts](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle.zig#L10-L115)
·
[Header layout](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/message_header.zig#L17-L76)
·
[Frame validation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/message_header.zig#L165-L192)
· [Command specs](../tests/unit/test_cli_doc.odin#L40-L65) ·
[Executable exit-code examples](../tests/integration/exit_codes.odin#L10-L43)

### How recovery earns the right to discard data

The on-disk database combines a checkpoint with subsequent journal operations. New grid blocks are written
before the superblock publishes the roots through which a reader reaches them. References contain both a
block address and its expected checksum. Reading a different, internally valid block at that address can
still be detected. The superblock is the root of this scheme and has its own failure model. With four local
copies, verification after writing needs three and opening needs two. The two sets must intersect. The
recovery code also checks for conflicting histories, disconnected parents and regressions in replication
state. These are copies on **one replica's disk**, distinct from the network replication quorum above.
[Data-file layout](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/internals/data_file.md#L32-L96)
·
[Local copy thresholds](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/superblock_quorums.zig#L38-L76)
·
[History checks](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/superblock_quorums.zig#L153-L196)

A partially written journal entry at the tail and corruption of an older committed entry can both produce an
invalid checksum. Discarding the second could lose an acknowledged transaction. On restart TigerBeetle reads
full prepare slots, checks header and body checksums and sector padding, and compares the prepare with a
separately stored header. It restricts automatic truncation by log position, the evidence for the head, and
the maximum number of journal writes that could have been in flight. More suspicious slots than the real
concurrency bound can explain invalidate that inference. Uncertain slots can require peer repair. A single
replica can have to stop when no peer can supply the missing evidence.
[Prepare validation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/journal.zig#L1123-L1167)
·
[Recovery rationale](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/journal.zig#L1170-L1204)
·
[Truncation conditions](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/journal.zig#L1345-L1423)

The storage layer makes that recovery possible even when the OS reports an I/O error for a large read. It
subdivides a failing read down to a logical sector, preserves the surrounding readable bytes, and zeroes the
unreadable region **in the read buffer** so that the higher layer's checksum validation can identify the
affected data. The source describes the cost of retries and explicitly acknowledges that a transient I/O
error and persistent corruption then reach the same validation path. The corresponding Wayu boundary is its
store reader, which treats a missing path as empty and reports read and parse failures separately. Sector
recovery belongs to TigerBeetle's storage engine.
[Read alignment](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/storage.zig#L24-L77)
·
[Read error handling](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/storage.zig#L245-L309)
· [Wayu store reader](../src/entries.odin#L647-L678)

### What actually happens when Wayu saves an alias

Wayu uses one advisory lock around a cooperating writer's read, modification, save and regeneration.
Concurrent first-time writers choose the same lock path in the data directory. Nested acquisitions reuse the
open descriptor because closing another descriptor for the same file can release a process's POSIX record
lock. The alias update preserves the position of an existing name and appends a new one. A malformed store
returns a configuration error. A valid store is checked before serialization and the previous version is
backed up before replacement. A retry with the same alias and value converges to one entry in the same
position. This property applies to the stored alias and says nothing about rerunning arbitrary user hooks or
commands. [Lock lifetime](../src/atomic_io.odin#L211-L288) ·
[Store validation and save](../src/entries.odin#L826-L857) · [Alias update](../src/entries.odin#L959-L1002)
· [Mutation boundary](../src/entries.odin#L1044-L1068)

For the canonical file itself, Wayu exclusively creates a same-directory temporary file, loops through
partial writes, sets permissions, checks the file sync, then renames it into place. Readers can see the old
complete file or the new complete file. After rename, opening and syncing the parent directory is best
effort. The power-loss guarantee for the directory entry therefore depends on the filesystem and on whether
that last sync succeeded. Ordinary process termination exercises a different boundary. The existing failure
campaign correctly distinguishes a file-size limit, an isolated Linux filesystem actually running out of
space, and a seeded sequence of process kills whose precise write phase is uncontrolled.
[Atomic replacement](../src/atomic_io.odin#L33-L124) ·
[Partial write and controls](../tests/scenarios/failure_campaign.scenario.test.rb#L102-L137) ·
[Process termination and ENOSPC](../tests/scenarios/failure_campaign.scenario.test.rb#L171-L225)

**Observed on Wayu v8.0.0, including a fresh build of the inspected source.** In a disposable home I
initialized Bash, moved the generated `core.bash` aside and created a directory at its former path, making
file replacement fail. Then I ran `wayu alias add durability_probe 'printf ok'`. The process exited **0**,
stdout said **Alias added**, and stderr warned that it failed to write `core.bash`. The alias was in
`entries.json`, but a fresh Bash sourcing `init.bash` could not find it. Even `wayu build` returned **0**
and warned while the obstruction remained. After removing the directory and rebuilding, a new Bash returned
`alias durability_probe='printf ok'`. A caller using status alone cannot tell these two builds apart. The
core writer returns no result. Regeneration drops the per-shell result it does receive, and the mutation
then reports success. [Core writer](../src/init_generator.odin#L21-L38) ·
[Runtime generation](../src/init_generator.odin#L223-L251) ·
[Regeneration loop](../src/init_generator.odin#L254-L291) · [Caller result](../src/entries.odin#L1054-L1068)

Wayu already has two models for handling the interval between actions. The background zsh bytecode compiler
uses a private snapshot and rechecks the source under the lock before publishing its digest. Comparing the
content matters because two different source versions can share a whole-second timestamp. Ordinary shell
text remains usable if compilation fails. Secret rekeying has a stronger requirement because the keystore
and `secrets.json` must agree. Wayu writes the pending ciphertext, replaces the key, and promotes the
pending file. A later load with a pending file takes the lock and checks which store actually opens with the
available key. An unavailable key backend leaves the evidence intact for a later retry. Integration tests
reconstruct the states immediately before and after key replacement and retrieve the original secret through
the CLI. [Bytecode publication](../src/init_generator.odin#L147-L181) ·
[Key replacement](../src/secrets_store.odin#L1996-L2034) ·
[Rekey recovery](../src/secrets_store.odin#L506-L548) ·
[Restart fixtures](../tests/integration/test_secrets_store.rb#L434-L470)

### A shell-sized change and a testable contract

Have the mutation report whether Wayu saved the canonical change and which initialized shells received their
required text files. A regeneration failure could then say “Alias saved. Bash setup could not be refreshed.
Run `wayu build` after correcting the path.” Keep the bytecode optimization independent. Decide explicitly
which exit status means the command has unfinished required work, and apply Wayu's existing compatibility
policy if changing a published status. Initialization-free native sessions already skip generation when
there is no `wayu.toml`. They should continue to succeed. A rollback of a valid alias edit to compensate for
a derived file failure would lose a user's desired configuration and make repair harder.
[Generation precondition](../src/init_generator.odin#L254-L281) ·
[Published contracts](../docs/STABILITY.md#L8-L27)

Test three boundaries through the binary. First, force the canonical write to fail and verify the old store
and runtime still agree. The file-size-limit campaign already does this. Second, allow that write and fail
only one required generated file. Check the exact status and channels, read the saved alias, repair the
obstruction, rebuild, then source the result in that host shell and query the alias. Third, initialize two
shells, fail publication for just one, and establish what a newly started process sees in each. Add a
repeated repair to establish that the same desired state converges. The existing source-of-truth file and
rebuild command supply the two pieces needed for recovery. Exposing the publication outcome would let a
caller decide when to invoke it.
[Existing negative and positive controls](../tests/scenarios/failure_campaign.scenario.test.rb#L102-L123) ·
[Initialized-shell selection](../src/init_generator.odin#L201-L221) ·
[Generated-file contract](../docs/STABILITY.md#L20-L27)

## Verification and delivery

### What counts as evidence of correctness

TigerBeetle gives different tests different jobs. Its merge algorithm has a test that enumerates both sort
directions and every combination of up to three streams, each with up to two keys from a small range. These
bounds include empty streams, duplicate keys, and ties across streams. For a much larger state space, its
cache fuzzer instead drives the real cache and a simpler model through inserts, removals, compactions, and
commit/discard of scopes. The model even allows a legitimate eviction after compaction. A rule that required
every inserted key to remain cached would flag correct behavior.
[Exhaustive merge test](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/lsm/k_way_merge.zig#L541-L568)
·
[Cache fuzzer and model](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/lsm/cache_map_fuzz.zig#L63-L142)

The VOPR simulator instantiates the replication algorithm with a simulated message bus, storage, and clocks.
A seed drives the workload and fault choices. The harness advances virtual time and delivers events, so a
run at a particular revision and configuration can revisit the same sequence without relying on an OS
scheduler. Its packet simulator can replay packets and partition peers. Its storage model specifies where
corruption is permitted and how many good copies should remain. For example, the grid fault model preserves
a copy of a block and disables these faults for clusters of two or fewer. The storage code also spells out
simplifications such as restricting a misdirected write to the same zone. Those boundaries determine what a
successful run establishes.
[Cluster construction](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/cluster.zig#L59-L78)
·
[Cluster ticks](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/cluster.zig#L526-L575)
·
[Packet faults](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/packet_simulator.zig#L15-L47)
·
[Storage fault assumptions](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/storage.zig#L5-L24)
·
[Misdirected writes](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/storage.zig#L162-L186)

Two questions govern the simulation. **Safety** asks whether observations can fit a single valid history
while faults are occurring. The state checker retains the committed headers it has observed across replicas.
A replica that reaches an already-observed commit must agree on its checksum. A newly observed commit must
link to its predecessor. **Liveness** asks whether work finishes once the environment meets the recovery
assumptions. In a full run, the VOPR connects a core of replicas and advances a bounded number of ticks. If
progress stalls, it checks whether the surviving data was recoverable before reporting a liveness failure
and its seed. An indefinitely unavailable network cannot promise progress. An idle but recoverable cluster
deserves a failing test.
[Commit history checks](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/cluster/state_checker.zig#L213-L270)
·
[VOPR recovery decision](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vopr.zig#L295-L367)

TigerBeetle also tests the actual process boundary. Vortex launches replica and client-driver processes,
supervises them, and can restart replicas and disrupt the network. A workload owns a small account model.
For one supported transfer type it updates the expected debit and credit balances, then compares a later
account lookup to its own totals. This can catch a consistent arithmetic error across replicas that a check
of replica agreement would miss. The build exposes a short Vortex integration smoke case. Its separate CI
test mode includes a bounded fuzzer smoke pass, then seeds two VOPR runs from the Git commit, one with a
testing state machine and one with the accounting state machine. The fuzzer runner also has an intentionally
failing canary, excluded from smoke, for checking the machinery that reports failures.
[Vortex supervisor](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/vortex/supervisor.zig#L1-L24)
·
[Account model](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/testing/vortex/workload.zig#L120-L171)
·
[CI build graph](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/build.zig#L629-L655)
·
[Fuzzer seeds and canary](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/fuzz_tests.zig#L91-L160)

### What Wayu already verifies

Wayu already has an independent check on an important user promise. Its generated-shell fuzzer constructs
alias bodies, environment values, and paths in Ruby, compiles them with Wayu, asks the available target
shells to syntax-check the generated files, then sources those files and reads the resulting values with NUL
delimiters. A quoting regression that produces valid but incorrect shell code can fail this test. It has a
fixed default seed and an explicit replay seed. Its subject is the generated Bash, Zsh, and Fish
environments. The native interpreter separately has behavior tests for status propagation, diagnostic
ownership, execution permissions, and real PTY interactions including short-lived pipelines. Those public
interfaces make good observation points for additional models.
[Shell fuzzer](../tests/integration/test_shell_fuzz.rb#L135-L190) ·
[Seed selection](../tests/integration/test_shell_fuzz.rb#L41-L49) ·
[Native failure assertions](../tests/integration/native_pipeline_failures.odin#L23-L69) ·
[Real PTY pipeline](../tests/integration/native_shell_pty.odin#L114)

The filesystem campaign delivers genuine OS failures. A kernel file-size limit interrupts a large store
write. The test requires normal exit 74 with a diagnostic, checks the previous store and core byte-for-byte,
checks temporary-file cleanup, and retries the exact same payload with the restriction lifted. Linux CI
fills a dedicated small tmpfs to induce actual ENOSPC. Another case holds the real interprocess lock and
terminates a waiting writer. Separate concurrency tests already check that all acknowledged concurrent
additions land, including the first run against an absent data directory. These are strong checks to retain
alongside simulation.
[Write-limit test and positive control](../tests/scenarios/failure_campaign.scenario.test.rb#L99-L124) ·
[Lock and full disk](../tests/scenarios/failure_campaign.scenario.test.rb#L140-L218) ·
[Concurrent writers](../tests/integration/test_write_integrity.rb#L199-L232)

One gap is visible directly in the crash test. It makes twenty attempts to kill a writer after a seeded
sleep. It checks that the original anchor survives and that each visible crash-created alias has a complete
value. The OS chooses which instruction ran before the signal. The test does not establish that it reached
the interval between replacing the store and regenerating the core. A previously acknowledged crash-created
alias could also disappear without violating those particular assertions. The current assertions leave those
outcomes unmeasured. For the entries store and generated core, Wayu writes and syncs a temporary file,
renames it, and attempts a parent-directory sync. The store update and generated files are separate
operations. Process death and machine power loss have different recovery assumptions.
[SIGKILL assertions and recorded limitation](../tests/scenarios/failure_campaign.scenario.test.rb#L171-L191)
· [Atomic replacement](../src/atomic_io.odin#L89-L125) ·
[Store and regeneration order](../src/entries.odin#L1044-L1068)

### A small model Wayu could actually use

Start with alias and plain environment entry edits. A Ruby test can maintain an ordered list of expected
name/value pairs driven by an explicit command trace. Replacing an existing name keeps its position,
removing it drops it, and a completed dry run leaves the list intact. Restrict random generation to
documented operations with known results. Read the resulting file through Ruby's JSON parser, compare
ordered entries after each acknowledged edit, and use a fresh Bash, Zsh, or Fish process to inspect the
actual runtime after a successful build. Expected values should originate in the command trace. Computing
them by calling Wayu's parser or shell-code generator would reproduce the implementation's own mistakes. The
existing persistence and quoting tests supply fixtures for both halves.
[Wayu entry update semantics](../src/entries.odin#L958-L1003) ·
[Existing runtime probes](../tests/integration/test_shell_fuzz.rb#L165-L190)

Give a test build synchronization points before the store rename, after the rename, and before and after the
generated runtime replacement. A parent process waits for the child to announce its phase and then releases
or terminates it. This stays off the release path. Upon restarting, compare the whole ordered store,
including every previously acknowledged edit. Before the store rename it should match the old state. After
that rename, a process kill on the same mounted filesystem should expose the complete new state. If no phase
was observed, accept either complete state for the interrupted operation. A core may lag a committed store
during interruption. Once faults cease, require a fresh build to succeed, then verify that a newly started
host shell observes the model. Finally issue another edit to demonstrate that the lock and normal command
path work again. This defines a testable recovery promise without presuming a transaction across several
files or promising power-loss durability. [Store persistence](../src/entries.odin#L827-L857) ·
[Existing recovery probe](../tests/scenarios/failure_campaign.scenario.test.rb#L66-L80) ·
[Generated-file contract](../docs/STABILITY.md#L20-L28)

Enumerate the phases for one edit first. Add seeded edit sequences once the phase assertions hold. Record
the source revision, binary hash, OS and shell versions, complete operation list, observed phases, and the
first expected/actual difference. Keep tiny fixed traces on pull requests, explore additional seeds
periodically, and reduce each failing trace to a regression case. Exact phase replay can establish ordering
among the modeled events. Real tmpfs, lock, signal, PTY, and cross-platform runs still exercise kernel
behavior outside that model. A later native-language model could generate tiny expressions and predict
status, stdout, and stderr from Wayu's own documented rules. Existing native tests already demonstrate why
using another shell as the universal oracle would be misleading.
[Wayu pipeline diagnostics and handling](../tests/integration/native_pipeline_failures.odin#L23-L39)

### Measuring the binary people run

TigerBeetle's DevHub script extracts a packaged release binary, runs a validated sequential-ID benchmark,
then inspects integrity on the resulting datafile. It records accepted transactions per second, observed
maximum batch and query latency, RSS, datafile size, and checksum timing. This ties throughput to other
resources and a correctness check. Wayu already applies that reasoning to host-shell startup. Its fixture
must actually load a PATH entry, alias, environment value, decrypted secret, and tool. It interleaves
startup runs with and without Wayu, compares medians, and gates added time against the larger of 30 ms and
twice the baseline. CI requests 100 samples per side. This gate measures host-shell startup. For the native
interpreter, a complementary benchmark would time repeated commands in one live session, verify their actual
outputs, record peak RSS and prompt-latency percentiles on a fixed workload, and establish runner-specific
baselines before setting a threshold.
[TigerBeetle DevHub measurements](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/scripts/devhub.zig#L171-L212)
· [Wayu fixture and budget](../tests/benchmark/budget.sh#L10-L42) ·
[Wayu CI sampling](../.github/workflows/startup-budget.yml#L60-L64)

TigerBeetle treats upgrades and publication as executable tests. Its multi-version binary can include older
executables so a replica can restart against data at a supported earlier version and coordinate activation
with peers. A release validation workflow also runs after the release workflow and every six hours. On Linux
it checks expected archive presence, rebuilds from the published tag, compares all non-debug server archive
digests, and runs the matching host executable. Additional checks cover published packages with named
exceptions. This distinguishes verifying a download against its checksum from independently rebuilding the
same bytes.
[Upgrade design](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/internals/upgrades.md#L6-L46)
·
[Validation schedule](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/.github/workflows/release_validate.yml#L4-L19)
·
[Rebuild and compare](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/scripts/ci.zig#L127-L186)
·
[Host and package checks](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/scripts/ci.zig#L206-L240)

Wayu's compatibility boundary is a user's persisted state and existing shell setup. Its upgrade trial starts
with the previous published binary, writes entries and secrets, swaps in the candidate, then uses the old
generated init before rebuilding. It verifies decrypted and run-only values and rekeys the store. The
release pipeline normalizes archive timestamps, ownership, permissions, and gzip headers, smoke-tests the
archives on their target architectures, and requires attestations before publication. CI also exercises the
installer against the latest release in an empty HOME and verifies rejection of a tampered checksum. I did
not find a separate tagged-source rebuild compared byte-for-byte with the published archives. A small
follow-up would compare one clean Linux rebuild with its published archive and report the first differing
layer, executable or packaging, before extending that check to other targets.
[Previous-release upgrade trial](../tests/release/upgrade.rb#L33-L69) ·
[Archive creation](../.github/workflows/release-build.yml#L102-L132) ·
[Target smoke tests](../.github/workflows/release-build.yml#L177-L214) ·
[Attestations](../.github/workflows/bump.yml#L298-L345) ·
[Installer checks](../.github/workflows/ci.yml#L288-L345)

## Code and design practices

### Put an invariant where both sides can check it

TigerStyle distinguishes an operating error, which a caller must be able to handle, from an impossible
internal state, which should stop the program before it does more damage. Its assertion-density target is an
average across functions. More informative are the placement rules. Check the caller and callee, the write
and read, the normal case and the forbidden case. Assert relationships among constants at compile time. Keep
separate predicates separate so a failure names the violated assumption. In the repair scheduler, the
selector checks its invariants on entry and again on exit, including early returns. In the I/O slot pool, an
ordinary attempt to acquire a fifth slot from a pool of four returns an empty result. Releasing a slot whose
busy bit is clear violates ownership. Computing a slot index requires an exact division and an in-range
result. The test exhausts the pool, returns one slot, reacquires that slot, and finishes with all four
available.
[Assertion rules](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L103-L149)
·
[Repair scheduler](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/repair_budget.zig#L108-L136)
·
[I/O pool](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/stdx/iops.zig#L7-L40)
·
[Four-slot test](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/stdx/iops.zig#L89-L127)

Wayu has an equally good example at the process boundary. The integer 141 can come from a program explicitly
exiting 141 or from the OS reporting termination by SIGPIPE. The shell keeps the signal alongside the
integer. It can ignore a genuine upstream SIGPIPE when a downstream reader finishes early while still
propagating a deliberate exit 141. The same distinction matters when deferred cleanup runs. Cleanup saves
the original failure state, runs pending actions in reverse order, and restores the appropriate outcome.
User input follows a different path. Arithmetic overflow, division by zero or a nesting limit produce a
shell error. A user should never be able to trip an internal assertion merely by typing a large integer.
[Wait status and pipeline outcome](../src/native_jobs.odin#L73-L106) ·
[Deferred cleanup](../src/native_defer.odin#L51-L86) ·
[Checked arithmetic](../src/native_arithmetic.odin#L111-L146) ·
[Job unit tests](../tests/unit/test_native_jobs.odin) ·
[SIGPIPE integration tests](../tests/integration/native_pipeline_failures.odin#L11-L25)

### Make units, state and ownership visible in the representation

TigerBeetle has separate types for a monotonic instant and a duration. Subtracting instants asserts their
order. Converting a duration to milliseconds uses an explicit downward rounding operation. The distributed
clock goes further. Each clock contributes an interval of uncertainty. A quorum of compatible intervals can
justify a timestamp, and the clock can report that synchronization has failed. For Wayu the practical
distinction is elapsed time versus wall time. Subprocess timeouts already use monotonic ticks. The reload
debounce stores wall time and subtracts a later wall time. Moving that elapsed-time decision to the
monotonic clock would give it the same behavior under a clock correction as the timeout code. A test can
advance elapsed time across the threshold independently of a wall-clock step.
[Time units](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/stdx/time_units.zig#L5-L71)
·
[Distributed clock rationale](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/clock.zig#L45-L76)
· [Wayu subprocess timeout](../src/subprocess.odin#L634-L658) ·
[Wayu debounce](../src/hot_reload.odin#L324-L365)

The style guide also distinguishes index, count and byte size, calls for explicit rounding and unit
suffixes, and encourages named options where arguments share a type. It asks for stable addresses when
constructing larger objects, short lifetimes for references, and explicit handling of reserved bytes so old
data cannot escape into a new message. The C binding test gives this a consequence across compilers. It
imports the generated header and checks enum values, type sizes, alignment, and individual field types
against the Zig definitions. Wayu's equivalent boundary is the text another program will interpret. Deferred
commands clone their source location and quote each expanded argument before outliving the parser arena. The
command table supplies reusable definitions, the CLI documentation test checks the correspondence, and JSON
integration tests check the fields seen by a consumer. A spelling policy alone would catch none of those
failures.
[Representation and ownership rules](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L372-L454)
·
[C header conformance](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/clients/c/tb_client_header_test.zig#L20-L124)
· [Deferred command capture](../src/native_defer.odin#L12-L49) ·
[Command table](../src/completions.odin#L91) · [CLI documentation test](../tests/unit/test_cli_doc.odin) ·
[JSON contract](../tests/integration/cli_output.odin#L99-L135)

### Keep state changes legible and the error useful to its recipient

TigerStyle favors simple control flow, minimum variable scope, bounded loops, explicit options, and a parent
function that owns the branching while helpers do focused work. It discourages recursion and sets a 70-line
function limit. It asks authors to explain why a design works and how a test detects failure. These are
written guidelines. A shell has recursive syntax and intentionally unbounded user loops. Wayu already limits
nesting in several places, including shell-word parsing, arithmetic and functions. A limit on nesting
protects the interpreter stack. A limit on the total number of user loop iterations would change the
language. For large procedures such as pipeline launching, a more informative review question than the line
count is whether each failure path says who closes the descriptor, who waits for a partially launched group,
and who restores the terminal.
[Control flow and function shape](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L89-L192)
·
[Naming and rationale](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L271-L370)
· [Wayu parser bounds](../src/native_language.odin#L132-L164) · [Word nesting](../src/shell_words.odin#L373)
· [Pipeline launcher](../src/native_shell.odin#L704) · [Terminal exit](../src/tui_io.odin#L288)

TigerBeetle reports domain outcomes precisely. ID reuse with different fields, an unterminated chain, and a
transfer that would overflow have different results. At the broker boundary it explicitly documents that a
crash can replay an already-delivered message and that a consumer must handle duplicates. The guarantee
changes with the boundary. Wayu can apply that precision without adding exception syntax. For an arbitrary
child, preserve the returned number, identify the command and source line, and let the child's own message
explain its private code. For errors Wayu owns, say what operation failed and what has already taken effect.
The native reporter already avoids duplicate explanations from pipeline children. A configuration edit with
partial publication is a particularly good place to put the missing information.
[Transfer outcomes](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/state_machine.zig#L3836-L3868)
·
[Broker delivery contract](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/operating/cdc.md#L172-L179)
· [Wayu reporter](../src/native_diagnostics.odin#L39-L67) ·
[Observed output contracts](../tests/integration/native_diagnostics.odin)

### Treat performance, tooling and operations as engineering decisions

| Upstream practice | What the repository actually does | Wayu application |
|---|---|---|
| Sketch demand on network, storage, memory and CPU before optimizing | The design identifies the bottleneck, batches the slow operation, and separates control decisions from tight data loops. A small LLVM IR tool reports large fixed-size copies and aggregate code size from generic specialization. Its scope excludes runtime-size copies. [Performance rules](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L231-L264) · [Copyhound](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/copyhound.zig#L1-L28) | Start with bytes copied per keystroke or captured byte. Measure real process creation and host-shell startup separately. Cache-line specialization is worth considering only after finding a hot lookup. [Editor](../src/native_editor.odin) · [Benchmark design](benchmarks.md) |
| Keep critical runtime dependencies and build modes deliberate | The architecture identifies the kernel, compiler and selected standard-library code as dependencies. The build prefers ReleaseSafe, production artifact validation checks it, and additional verification assertions can be configured separately. Client SDK tests still use their ecosystems' own tools. [Dependency boundary](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/ARCHITECTURE.md#L232-L249) · [Build mode](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/build.zig#L85-L92) · [Extra checks](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/build.zig#L196-L206) · [Artifact validation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/scripts/ci.zig#L207-L212) · [Client tooling](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/internals/HACKING.md#L64-L86) | Wayu pins the Odin release and its archive checksums. CI builds with vet and warnings as errors and separately uses AddressSanitizer. Keep real Bash, Fish, Zsh and external executables in integration tests because their behavior is part of the product. [Compiler pin](../.github/odin-release) · [Compiler digests](../.github/odin-release.sha256) · [CI checks](../.github/workflows/ci.yml#L166-L215) |
| Give operators observations with a defined scope | Metrics distinguish replica status, sync stage, time inside the replica, and additional latency a client must measure. An offline integrity command opens and checks the superblock before it can check dependent storage. [Monitoring contract](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/operating/monitoring.md#L24-L55) · [Integrity checker](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/tigerbeetle/inspect_integrity.zig#L24-L60) | Wayu already has `doctor` and per-phase startup profiling. A partial-publication diagnostic should identify the failing file and affected shell. A probe that starts that shell and resolves the alias checks something a store parser cannot. [Doctor](../src/doctor.odin) · [Profiler](../src/profile.odin#L43-L53) |
| Use documentation, formatting and review to preserve decisions | The guide covers naming, units, callback order, explanatory comments, formatting, 100-column lines and deliberate tooling. User docs distinguish tutorials, guides, reference and design rationale. SDK READMEs share a generator. The contributor guide asks for a designated reviewer and an additional reviewer for changes with version-compatibility implications. [Style](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L266-L371) · [Formatting and tools](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L456-L500) · [Documentation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/internals/docs.md#L3-L42) · [SDK docs](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/clients/README.md#L3-L22) · [Review practice](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/internals/HACKING.md#L117-L144) | Wayu has a quickstart, CLI reference, stability rules, upgrade notes, an Odin formatter and a generated-site check. A concrete inconsistency deserves attention. `CODE_STYLE.md` teaches direct `os.exit` and shows a fixed temporary filename. The repository instructions and tests require a terminal-restoring exit path and per-process scratch directories. Align the examples with the working code. [Style examples](../CODE_STYLE.md#L176-L187) · [Temporary-file example](../CODE_STYLE.md#L320-L344) · [Exit guard](../tests/unit/test_exit_paths.odin) · [Test scratch helper](../tests/unit/test_tmp.odin) |

The upstream aspiration to avoid technical debt describes how the team makes decisions. It does not
establish that every function satisfies every rule. The message header itself records future work around
layout and validation, and a command-line analysis tool legitimately uses its own allocator. For Wayu, pick
a few rules with observable consequences and keep the language's existing formatting conventions. A
terminal-restore test, a checked memory limit and a reproducible recovery example each give the next
contributor a reason to preserve the rule.
[Technical-debt policy](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/docs/TIGER_STYLE.md#L62-L79)
·
[Header constraints](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vsr/message_header.zig#L18-L31)
·
[Analysis tool](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/copyhound.zig#L44-L53)
· [Wayu repository guidance](../AGENTS.md)

## What I would do in Wayu

1. **Make configuration publication observable.** Start with the alias reproduction above. Define one result for saving the authoritative data and one result for each required runtime file. Carry them back through both the mutation command and `wayu build`. Preserve a successfully saved edit. On a failure, tell the user which shell needs repair and what action to take. Verify a fresh host shell and a second repair. A change to a published exit status goes through Wayu's breaking-change and upgrade-note process. [Runtime generator](../src/init_generator.odin) · [Stability rules](STABILITY.md#stable-changes-only-in-a-major-release)
2. **Budget captured data before choosing a default.** Measure bytes read, retained and copied during substitution, expansion and assignment. Keep regular pipes streaming. Exercise the boundary in a fresh process and repeatedly in a live shell. Test cancellation, cleanup, and an output-producing child that runs past the proposed limit. Treat a hard default as a compatibility decision. Read-buffer size and process RSS each answer a different question. [Capture implementation](../src/native_bindings.odin#L95-L160) · [Native shell](../src/native_shell.odin)
3. **Give the editor and history their own memory and latency workloads.** Measure typing, paste, undo, cold history load, incremental refresh and first suggestion. Use byte counts alongside record counts. Verify that an optimization preserves Unicode cursor movement, undo granularity, and access to older history. Publish observations by platform before turning timing measurements into CI limits. [Editor](../src/native_editor.odin) · [Native history](../src/native_history.odin) · [Recorded benchmark conventions](benchmarks.md)
4. **Extend the crash campaign with a small reference model.** Keep the real kernel tests. Add named test-only synchronization points around store and runtime publication and retain all previously acknowledged edits in the model. An interrupted attempt may have multiple valid outcomes. After faults stop, require a new invocation to repair the runtime, expose the expected value in a real shell and accept the next mutation. This is a tractable application of TigerBeetle's distinction between safety and eventual progress. [Existing Wayu campaign](../tests/scenarios/failure_campaign.scenario.test.rb) · [Upstream simulation](https://github.com/tigerbeetle/tigerbeetle/blob/0aeb306561365e21b97775c729bfc439f6c16d72/src/vopr.zig)
5. **Make focused maintenance changes as the relevant code is touched.** Correct the exit and scratch-file examples, use monotonic time for elapsed-time decisions, and consider an independent tagged rebuild of one published archive. Each change can be accepted with a small demonstration. A repository-wide rewrite to impose a static heap, a line-count gate, a replicated log or a virtual operating system would have much higher cost and much less direct benefit for this shell.

### Scope and how to interpret the evidence

The upstream
[source tree](https://github.com/tigerbeetle/tigerbeetle/tree/0aeb306561365e21b97775c729bfc439f6c16d72) was
examined at `0aeb306561365e21b97775c729bfc439f6c16d72`. The Wayu comparison uses
`121485099a0b2c629588d0ae8fe708b211ca7a42`. The inventory used `git ls-files` in both checkouts. It covers
all **639 tracked TigerBeetle paths**, including all 69 Markdown documents under `docs/` and all 558 paths
under `src/`. Of the latter, 297 belong to clients, 46 to `stdx`, 40 to the LSM, 33 to the testing subtree
and 28 to VSR. Wayu had **344 tracked paths** before this note, including 70 under `src/` and 186 under
`tests/`. All **69 top-level Odin source files** had a same-named `tests/unit/test_<module>.odin` containing
a test annotation. That confirms file pairing. The alias example shows why a cross-file contract still needs
its own integration test.

| Area | Material read closely | What the examination establishes |
|---|---|---|
| Stated principles and architecture | TigerStyle, the architecture overview, internals and operations guidance, linked events and retry contracts | The intended failure model, hardware assumptions, style policy and public semantics. |
| Bounded execution | Static/counting allocators, CLI capacity calculations, message pool, set-associative cache, pool ownership at clients, replicas and the network boundary, compaction quotas | Which limits are enforced and where overload can be dropped, retried or reported. |
| Persistence | Replica receive, journal completion, quorum, commit and reply paths, linked-event handling, storage error handling, superblock histories and restart inference | Which pieces of evidence justify acknowledgement, rollback, truncation or repair. |
| Test, build and release | Simulation and its models, Vortex process tests, fuzz/exhaustive tests, C bindings, performance collectors, release/upgrade checks and contributor guidance | Which properties a test can detect, what the model assumes, and which assertions are exercised at an external boundary. |
| Wayu | Native evaluation, process and terminal handling, editor, capture, history, config locks and stores, generation, backup and rekey recovery, tests, benchmarks, CI and release workflows | Implemented strengths, a reproduced mismatch in observable outcomes, and measurements specific to this checkout. |

The close reading followed these paths through actual calls and tests. Every tracked path was inventoried.
The line-by-line review was selective across the SDKs, examples, website, banking recipes and OS backends.
All 700 Wayu unit tests passed with memory tracking enabled. Two integration tests passed against the
fresh binary, covering
[pipeline failures](../tests/integration/native_pipeline_failures.odin) and
[source-located diagnostics](../tests/integration/native_diagnostics.odin). The upstream simulations,
database performance suite and release reproducibility jobs were examined in source. Their results are not
measurements from this review.

**Local measurement notes.** The fresh binary used for the independent capture run was built on macOS arm64
with `odin build src -o:speed`. The compiler identified itself as `dev-2026-11-nightly:9a69916`. The
binary's SHA-256 was `5d5f0c19214ab3d1448c62eec051e1e78ab007edaffac63772ca6540ede875ca`. The fixture was an
ordinary file containing 0, 1 or 4 MiB of ASCII `x`. An external parent alternated the two commands shown in
the table, used a fresh temporary home for each Wayu process, and collected the median of three `wait4`
observations per cell. A control with a parent shell reaping a memory-using child confirmed that Darwin's
reported peak can reflect a descendant. The figure is neither a sum of live processes nor a measurement of
bytes allocated by Wayu alone.

A separate check looked for a reason to introduce more scratch arenas throughout the interpreter. The
`while` implementation resets an arena per iteration. The `for` implementation expands the input words once
and walks them. At 4,096 identical one-byte words, a script assigning `v=$((1+2))` on every iteration gave a
median peak of **7.05 MiB**. The same word list with a `break` after the first assignment gave **6.92 MiB**.
There were five fresh invocations per variant in alternating order. A separate counter check confirmed that
the variants executed 4,096 and one iteration respectively. The small difference on this workload makes
capture and editor copying better first investigations. Larger loop bodies or nested captures may behave
differently. [Loop implementations](../src/native_language.odin#L363-L450)
