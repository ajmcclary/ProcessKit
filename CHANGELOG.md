# Changelog

All notable changes to ProcessKit are documented in this file.

## [0.1.0-beta.7] - 2026-11-17

Remediates the 2026-11-17 Ready Room review. No public API changes: every
signature is the same. The behavior changes below are ones a consumer will
notice.

- **Children now receive SIGTERM.** `ProcessLauncher` sets
  `POSIX_SPAWN_SETSIGMASK` with an empty mask, and resets SIGTERM, SIGINT,
  SIGHUP, SIGQUIT and SIGCHLD (as well as SIGPIPE) to their default
  dispositions. `posix_spawn` used to copy the spawning thread's mask, and
  Swift-concurrency and GCD worker threads block most asynchronous signals
  (20 on macOS 27, among them SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD,
  SIGALRM, SIGWINCH, SIGUSR1 and SIGUSR2), so a child spawned from one
  ignored the SIGTERM of every termination, ran out the full grace period
  and was SIGKILLed. Such children now receive SIGTERM and can shut down
  cleanly: a termination of a child that honours SIGTERM ends with exit
  code 143 (128 + SIGTERM) instead of 137 (128 + SIGKILL) after the grace,
  and no longer waits the grace out. A consumer test that relied on its
  child outliving SIGTERM (for example, a fake server that writes its pid
  only after the termination signal was sent) will need to change.
- **The reaper wakes on exit, so short children are reaped in
  milliseconds.** Between `waitpid(WNOHANG)` checks `ProcessTermination`
  used to sleep 50 ms (200 ms after the first 2 s), so every child,
  however short, was reaped at least ~50 ms after it was spawned. It now
  waits on a dispatch process source (kqueue `EVFILT_PROC`/`NOTE_EXIT`)
  and reaps as soon as the child exits, in `waitForTermination` (with and
  without a timeout) and in the SIGTERM and SIGKILL grace waits of
  `terminateAndReap`. The old interval remains as a fallback wake, so a
  missed event is never slower than polling was. The exit watch never
  reaps: the caller's `waitpid` is still the single reaper. Timeouts and
  grace periods now end at their deadline instead of at the next poll
  after it (up to 50 or 200 ms later). Cancellation, the SIGTERM→SIGKILL
  escalation and the returned exit codes are unchanged.
- **Termination never signals a pid that is not an unreaped child.**
  `terminateAndReap` (and the termination inside `waitForTermination`)
  used to fall back to `kill(pid, …)` when the pid was no longer this
  process's unreaped child, so a call for a child that had already been
  reaped sent SIGTERM and SIGKILL to whichever process the kernel had
  since given that pid. It now signals nothing and returns as for an
  exited child (the previous result whenever the pid was free). A pid of
  0 or below, which `kill` treats as a process group, is never signalled
  either.
- **Infinite timeouts no longer trap.** `waitForTermination(timeout:
  .infinity)` (or any timeout or grace too large to express in
  nanoseconds, such as `1e12` seconds) trapped converting the time left to
  `UInt64`. Such a timeout or grace now simply means no deadline.

## [0.1.0-beta.6] - 2026-11-12

Remediates the 2026-11-12 full review. No public API changes: every
signature is the same and no `LineFramer.Diagnostic` case was added, so
exhaustive switches over it still compile. The behavior changes below are
ones a consumer will notice.

- **Children start in their own process group.** `ProcessLauncher` sets
  `POSIX_SPAWN_SETPGROUP` (pgroup 0), so each child leads a new group. A
  child no longer receives terminal signals: Ctrl-C under `swift run` no
  longer reaches it directly, and when the app has a controlling terminal
  a descendant that reads `/dev/tty` is stopped with SIGTTIN.
- **Children inherit only stdin, stdout and stderr.** `ProcessLauncher`
  sets `POSIX_SPAWN_CLOEXEC_DEFAULT`, so no other descriptor of the
  parent leaks into the child.
- **Termination signals the whole group.** `ProcessTermination` sends
  SIGTERM and SIGKILL to the child's group, so grandchildren (MCP servers
  under an agent CLI, shell pipelines, LSP helpers) are signalled
  directly instead of only through their parent. It does so only while
  `waitid(…WNOWAIT)` confirms the pid is still an unreaped child;
  otherwise it signals the pid alone, so a reused pid is never treated as
  a group. A child that exits on its own still signals no one.

Fixes, by area:

- `LineFramer`: after a line with an odd number of quotes that starts with
  `{` or `[` (a bracketed log line, a truncated record), the following
  records now arrive as separate lines instead of nothing or one glued
  line. The framer resplits only on a line that is a complete JSON value
  under a strict RFC 8259 scan, so a record that is valid JSON apart from
  raw control characters in its strings is never split. Well-formed
  NDJSON is split exactly as before.
- `JSONStreamFramer`: the scan walks bytes instead of `Character`s, so a
  quote or brace followed by a combining scalar (U+0301, U+FE0F, a skin
  tone modifier, ZWJ) still delimits; such input used to give 0 frames.
  Frames and the remainder are byte slices of the input.
- `repairJSONStringControlCharacters`: input whose only raw control
  characters are tabs inside strings is now repaired instead of returning
  `nil`, and a backslash before a raw newline inside a string becomes a
  literal backslash plus an escaped newline instead of invalid JSON.
- `ProcessTermination`: a cancelled wait now sleeps between reap polls
  instead of busy-spinning through the SIGTERM grace.
- `SpawnedProcess.stdinDescriptor` documentation corrected: it is
  `stdin`'s own descriptor, not a duplicate.

`0.1.0-beta.5` (2026-07-25) raised the platform floor to macOS 27 /
iOS 27 and had no entry here.

## [0.1.0-beta.4] - 2026-07-24

Adds a second library product, `ProcessStreamFraming`, promoted from
RepoPrompt's internal `RepoPromptCore/ProcessCore` target so the newly
extracted `CodexAppServerKit` could reach the framing layer without a
second copy. Purely additive: the `ProcessKit` product is unchanged, and
consumers that do not link the new product see no difference.

- `LineFramer` (NDJSON line splitting with JSON-string-aware quote
  tracking, carry limits, and overflow diagnostics), `JSONStreamFramer`
  (concatenated top-level-object splitting), and the raw-byte helpers
  `appendTail` / `makeUTF8Sample` / `isASCIIWhitespace` /
  `trimmedASCIIWhitespace` / `repairJSONStringControlCharacters` moved
  byte-verbatim, with their characterization tests.
- Two API-completeness additions the move required, neither of which
  changes behavior: `JSONStreamFramer.FramingResult` gained an explicit
  `public init(frames:remainder:)` (the synthesized memberwise
  initializer was `internal` and unusable from another module), and
  `LineFramer` gained an explicit `Sendable` conformance (public types
  get no implicit conformance, so Swift 6 consumers could not move one
  across an actor boundary).
- A separate target with no dependency on `ProcessKit`, so process-only
  consumers link no framing code.

## [0.1.0-beta.3] - 2026-07-18

- `ProcessPipeReader`: single-use owner of one pipe's read side —
  preflight, `readabilityHandler`, FIFO channel, consumer task, ordered
  chunk + at-most-once EOF callbacks, idempotent cancel. Promoted from
  RepoPromptCore and gated across its four consumers (Codex, Claude, ACP,
  CodeEditorLSP) by the workspace's `verify-pipe-reader-ownership` check.

## [0.1.0-beta.2] - 2026-07-14

- Remove stray SwiftPM build artifacts (`.build/`) that were accidentally
  committed in the first cut; add `.gitignore`. No source changes.

## [0.1.0-beta.1] - 2026-07-14

First cut, promoted from RepoPrompt's internal `RepoPromptCore/ProcessCore`
target after incubation (local incubation → second-consumer proof →
promotion).

- `ProcessLauncher` / `SpawnedProcess`: posix_spawnp launcher with
  pipe/CLOEXEC/SIGPIPE setup and documented single-reaper ownership.
- `ProcessTermination` + `ProcessTerminationPolicy`: waitpid lifecycle with
  SIGTERM→SIGKILL escalation. The former mutable app-termination fast-path
  globals (`beginAppTerminationFastPath` / `resetAppTerminationFastPath` /
  `cooperativeCancellationWaitTimeout`) were replaced by the explicit
  policy value — applications hold their own current policy.
- `FileHandleChunkChannel`: ordered, single-consumer `AsyncStream<Data>`.
- `FDWriteSupport`: EPIPE/EINTR/EBADF-aware FD writes, no-SIGPIPE setup.
- Swift 6 language mode, strict concurrency; macOS 14+ (iOS 17+ compiles;
  spawning is `#if canImport(AppKit)`-gated).
