# ProcessKit

Neutral POSIX process primitives shared by
[RepoPrompt](https://github.com/ajmcclary/RepoPrompt) and
[CodeEditorPlugin](https://github.com/ajmcclary/CodeEditorPlugin) — the
"proof-of-two" consumers this package was promoted for.

- **`ProcessLauncher` / `SpawnedProcess`** — `posix_spawnp` launcher with
  pipe/CLOEXEC/SIGPIPE setup. `SpawnedProcess` carries explicit
  single-reaper ownership semantics: exactly one owner may reap the PID.
- **`ProcessTermination` + `ProcessTerminationPolicy`** — `waitpid`-based
  cooperative lifecycle with SIGTERM→SIGKILL escalation. Callers own
  policy; ProcessKit carries no mutable application-wide termination mode.
- **`FileHandleChunkChannel`** — ordered, single-consumer
  `AsyncStream<Data>` over `readabilityHandler` chunks (per-chunk `Task`s
  do not preserve byte-arrival order; this does).
- **`FDWriteSupport`** — low-level FD write seam (EPIPE/EINTR/EBADF aware,
  no-SIGPIPE configuration).

Deliberately **out** of scope: protocol framing (LSP Content-Length lives
in CodeEditorLSP's `LSPFrameCodec`; NDJSON `LineFramer` lives in
RepoPromptCore), executable resolution and login-shell PATH policy,
environment composition policy, and application logging (functions accept
a plain `(String) -> Void` logger).

## Requirements

- Swift 6.3+ (Swift 6 language mode, strict concurrency)
- macOS 14+. iOS 17+ compiles the module (spawning itself is a macOS
  capability, gated `#if canImport(AppKit)`), so macOS+iOS consumers can
  depend on it unconditionally.

## Installation

```swift
dependencies: [
    // 0.1.0-beta.1 is a prerelease identifier — SwiftPM only resolves
    // prerelease tags when the lower bound itself names one.
    .package(url: "https://github.com/ajmcclary/ProcessKit.git", .upToNextMinor(from: "0.1.0-beta.1"))
]
```

## Usage

```swift
import ProcessKit

let child = try ProcessLauncher.spawn(
    command: "/usr/bin/some-server",
    arguments: ["--stdio"],
    environment: ProcessInfo.processInfo.environment,
    workingDirectory: nil
)

// Ordered stdout consumption:
let channel = FileHandleChunkChannel()
child.stdout.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty { channel.finish() } else { channel.yield(data) }
}
Task { for await chunk in channel.stream { handle(chunk) } }

// Framed/blob writes to stdin:
if let fd = child.stdinDescriptor {
    try FDWriteSupport.writeAll(payload, to: fd)
}

// Cooperative teardown (the child's single reaper):
let exitCode = await ProcessTermination.terminateAndReap(
    pid: child.pid,
    policy: .default
)
```
