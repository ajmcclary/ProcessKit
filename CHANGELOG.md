# Changelog

All notable changes to ProcessKit are documented in this file.

## [Unreleased]

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
