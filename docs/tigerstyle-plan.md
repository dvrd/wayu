# Applying TigerStyle to Wayu

Start with the guarantee Wayu controls. When it says it updated an alias for an initialized shell, the
required generated files must be ready for a fresh shell to load. In the [review](tigerstyle-review.md#what-actually-happens-when-wayu-saves-an-alias),
the store contained the requested alias, but both the edit and the attempted rebuild returned 0 while Bash
could not load it. That is the first regression test to write.

The [task list](tigerstyle-tasks.yaml) gives the implementation order, source files, dependencies and test
commands. Test names and benchmark options identified there as new are deliverables. The rounds describe
when work can proceed in parallel. A numbered release is a separate maintainer decision.

## 1. Make a successful configuration edit trustworthy

**First pull request.** Reproduce the Bash failure in a disposable home through the real CLI. Cover a
writable store with a blocked runtime, a blocked store, and a successful edit. Introduce a result that
records whether the authoritative change was saved and, for each selected shell, which required text
files were published or failed. Keep this result valid after the generator resets its per-shell arena.

| Situation | Proposed observable behavior |
|---|---|
| Store write fails | Preserve the old store and runtime. Report the existing cause and return its existing error status. |
| Store succeeds and a required file fails | Keep the saved edit. Attempt the other selected shells. Return **74** for the publication I/O failure. On stderr name the shell, failed path, what was saved, and how to repair it. Avoid an unqualified success message. |
| Explicit build encounters the same obstruction | Return **74** and identify the failed output. Once the obstruction is removed, two successive builds succeed, and a fresh shell sees the expected alias. |
| Native-only mutation with no host configuration, or a dry run | The former may succeed without generating host files. The latter reports the preview and leaves the filesystem untouched. An explicit build with missing configuration keeps its existing diagnostic and status. |
| A host has customized its init, or an optional optimization fails | Preserve the customized init. Treat optional zsh bytecode independently of the loadable text. An existing turbo export that is due for refresh is part of publication for its consumers. |

Use the existing config/lock and shell-selection rules. Cover core, PATH sync, managed init refresh, active
turbo and applicable plugin output. Preserve the existing malformed-plugin configuration status (78) and
report any concurrent output failures. Keep terminal and lock cleanup in their current owners. Carry the
result through PATH/alias/constant edits, explicit init/build, repairs, and the watcher. A watcher can report
the affected shell and keep watching. Recover by regenerating derived files; never replay arbitrary hooks or
child commands to repair a publication failure. Ship the changed exit contract, examples, tests and upgrade
notes together. [Runtime generation](../src/init_generator.odin) · [Current exit contract](cli.md) · [Stability policy](STABILITY.md)

## 2. Measure where a long-lived shell spends memory and time

This work can start alongside the first pull request. Add a native-shell benchmark that verifies its output.
Compare a streaming pipeline with capture into a variable, quoting and concatenation, repeated commands in
one live shell, first prompt under small and large histories, keystroke-to-redraw, paste, and undo.
Use fresh homes, a real PTY for interactive measures, raw samples, binary/toolchain identity and separate
Linux/macOS baselines. Use the existing 32-iteration-and-repeat convention for published measurements.
Use counters for allocation claims and report RSS with its platform-specific interpretation. [Review measurements](tigerstyle-review.md#where-wayu-already-has-budgets-and-where-it-grows) · [Benchmark conventions](benchmarks.md)

| Owner | Implementation | Acceptance |
|---|---|---|
| Command substitution | Track raw read bytes, builder capacity, expansion scratch and the stored value. Count simultaneous allocations during a resize. Reduce redundant copies. Define whether a budget applies to one invocation, an evaluation or one process, including what happens across a nested fork. | Exact limit succeeds, one byte over fails explicitly, no partial value reaches the consumer, owned children are reaped, and a subsequent command works. A larger ordinary pipeline still streams. Test an indefinitely writing producer and Ctrl-C. |
| Line editing | Replace whole-line undo snapshots with reversible edits and short-lived redraw scratch. Charge retained bytes in both undo and redo. | At 4,096 single-byte insertions, retained edit payload grows linearly. UTF-8 motion, single-edit bracketed paste, redo invalidation and existing undo granularity still work. |
| History | Stream native and foreign history into a recent window bounded by both bytes and entries. Page older native records into recall/search on demand. Bound partial-record scratch while scanning. | Up/down and Ctrl-R can recover an older native command. A large single record, rotation, truncation, partial final line and two concurrent sessions preserve usable on-disk history. Imported host history remains suggestion-only. |

**Default policy.** Start with compatible behavior while collecting data. Record the measured workloads,
scope, exhaustion behavior and proposed value for each limit. Use a small injectable limit to test the
boundary even when the production policy is opt-in. A newly finite substitution or undo default changes
which existing commands or edits can succeed; introduce it only with measured justification and the
repository's breaking-change process. Keep deterministic capacity checks in ordinary tests. Choose timing
gates only after repeated runs establish the normal variation on each runner. [Budget design](tigerstyle-review.md#how-to-work-out-an-upfront-budget-for-a-shell)

## 3. Make crash recovery reproducible

Build an independent ordered model for aliases and plain environment entries. Drive it with add, update,
remove and dry-run operations. After an acknowledged edit, compare the whole ordered store to the model.
Verify generated behavior by starting a host shell. Expected values come from the submitted operations.

Use a separate test binary with a parent/child handshake immediately before and after the rename of the
store and of a selected shell's core. The harness can then release or terminate the writer at an observed
point. The release binary must have no active test controls. Before the store rename the old state should
survive; after rename a process kill on the same mounted filesystem should expose the complete new state.
After faults stop, rebuild twice, source the runtime in each initialized shell and perform another edit.
Keep the current real lock, full-disk and SIGKILL tests. Process death and machine power loss have different
guarantees; parent-directory sync is currently best effort. [Existing failure campaign](../tests/scenarios/failure_campaign.scenario.test.rb) · [Atomic writer](../src/atomic_io.odin)

Start with one edit and all named phases. Then use short fixed traces on pull requests and add an extended
seed mode to the campaign's existing manual dispatch. Schedule that mode once its runtime is measured.
Retain the operation trace, seed, observed phase, tool versions and first
difference for replay. Separately, use a small model of Wayu's documented arithmetic and failure semantics
to predict status, stdout and stderr. Exercise intentional exit 141, actual upstream SIGPIPE and eviction of
the oldest of 257 completed-job records. [Campaign workflow](../.github/workflows/failure-campaign.yml) · [Pipeline behavior tests](../tests/integration/native_pipeline_failures.odin)

## 4. Close three independent maintenance gaps

- Correct the contributor examples that use bare parent-process exits and fixed scratch paths. Keep the
  terminal-restoring exit and per-process test directories visible in the examples developers copy.
- Switch the watch debounce to monotonic elapsed time. Drive the test clock to just before and exactly at
  500 ms, reset it with a new event, and exercise a wall-clock correction without sleeping.
- Pilot a read-only rebuild of **one published Linux AMD64 archive** from its exact tag on a fresh runner.
  Compare the executable and the archive separately, record tool versions, and show that a changed payload
  or archive header is detected. Expand coverage after independent runs agree. [Release build recipe](../.github/workflows/release-build.yml)

## Delivery and sequencing

| Work to merge | Can begin when | Evidence required on develop |
|---|---|---|
| Publication contract | Immediately | Bash obstruction goes red on the old build and green on the candidate; mixed-shell success, normal success, dry run, repair and upgrade behavior pass. |
| Native measurements and allocation improvements | Immediately for measurement; optimize against the baseline | Published before/after workloads, observed ownership counts and passing semantic/PTY tests. |
| Fault and language models | Once the write boundaries and existing shell semantics are identified | The same trace and phase reproduce the result. Recovery restores a real shell, and the next edit succeeds. |
| Capacity defaults and CI thresholds | After ownership counts, old-history access and cross-platform calibration | One documented exhaustion policy per owner, checked boundaries, and working ordinary streaming. |
| Documentation, watch clock and release verification | Independently | Focused unit tests and a read-only archive comparison with a diagnostic on mismatch. |

The shortest path to the first fix is `pub-files` → `pub-cli` → `pub-managers` and `pub-repairs` →
`pub-contract`. The memory benchmarks and the archive pilot can run independently of that merge.

Group dependent implementation and contract tests into reviewable pull requests. Each user-visible change
gets its own applicable CLI/config reference and Unreleased entry, a breaking Conventional Commit and footer
as required, and regenerated docs in the same pull request. Run the unit and integration suites, docs
freshness check, and the existing startup budget for generated shell changes. A phase is complete after
green CI on `develop`. [Task dependencies and verification commands](tigerstyle-tasks.yaml)
