// swift-tools-version: 6.3

/// ProcessKit Package Configuration
///
/// Neutral POSIX process primitives shared by RepoPrompt and
/// CodeEditorPlugin (the "proof-of-two" consumers):
///
/// - `ProcessLauncher` / `SpawnedProcess` — posix_spawnp launcher with
///   pipe/CLOEXEC/SIGPIPE setup and single-reaper ownership semantics.
/// - `ProcessTermination` + `ProcessTerminationPolicy` — waitpid-based
///   cooperative lifecycle with SIGTERM→SIGKILL escalation; callers own
///   policy (no mutable application-wide termination mode).
/// - `FileHandleChunkChannel` — ordered, single-consumer `AsyncStream<Data>`
///   over `readabilityHandler` chunks.
/// - `ProcessPipeReader` — single-use owner of one pipe's read side:
///   preflight, `readabilityHandler`, FIFO channel, consumer task, ordered
///   chunk + at-most-once EOF callbacks, idempotent cancel.
/// - `FDWriteSupport` — low-level FD write seam (EPIPE/EINTR/EBADF aware).
///
/// Deliberately OUT of scope: protocol framing (LSP Content-Length lives in
/// CodeEditorLSP's `LSPFrameCodec`; NDJSON `LineFramer` lives in
/// RepoPromptCore), executable resolution / login-shell PATH policy,
/// environment composition policy, and application logging (all functions
/// accept a plain `(String) -> Void` logger).
///
/// ## Requirements
///
/// - **Swift**: 6.3+ (Swift 6 language mode, strict concurrency)
/// - **Platforms**: macOS 14+, iOS 17+ (spawning is a macOS capability;
///   the module compiles on iOS so macOS+iOS consumers can depend on it
///   unconditionally)

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "ProcessKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(
            name: "ProcessKit",
            targets: ["ProcessKit"]
        )
    ],
    targets: [
        .target(
            name: "ProcessKit",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ProcessKitTests",
            dependencies: ["ProcessKit"],
            swiftSettings: swiftSettings
        )
    ]
)
