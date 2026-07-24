# Changelog

All notable changes to ProcessKit are documented in this file.

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
