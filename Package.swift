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
/// A second, separately-linkable product carries the neutral byte-framing
/// layer that sits directly above those chunk streams:
///
/// - `ProcessStreamFraming` — NDJSON `LineFramer` (quote/escape-aware line
///   splitting with carry limits and overflow diagnostics),
///   `JSONStreamFramer` (concatenated top-level-object splitting), and the
///   raw-byte helpers `appendTail` / `makeUTF8Sample` /
///   `isASCIIWhitespace` / `trimmedASCIIWhitespace` /
///   `repairJSONStringControlCharacters`. Promoted out of RepoPromptCore's
///   `ProcessCore` target on 2026-07-24 so a second package
///   (`CodexAppServerKit`) could reach it without duplicating the
///   implementation; RepoPromptCore re-exports it, so its five in-app
///   consumers (Claude, ACP, Gemini, Codex exec, CLIProcessRunner) are
///   unchanged. It is a SEPARATE target/product: the `ProcessKit` product
///   stays pure process primitives and CodeEditorPlugin links no framing
///   code it does not use.
///
/// Deliberately OUT of scope: *protocol* framing and decoding — LSP
/// Content-Length lives in CodeEditorLSP's `LSPFrameCodec`, and the
/// Codex/Claude JSON-RPC decoders live in their provider packages
/// (`CodexAppServerKit.CodexJSONStreamDecoder`) — plus executable
/// resolution / login-shell PATH policy, environment composition policy,
/// and application logging (all functions accept a plain
/// `(String) -> Void` logger).
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
        ),
        // Neutral NDJSON/byte framing above the chunk streams. Separate from
        // the `ProcessKit` product on purpose: consumers that only spawn and
        // reap processes never link it.
        .library(
            name: "ProcessStreamFraming",
            targets: ["ProcessStreamFraming"]
        )
    ],
    targets: [
        .target(
            name: "ProcessKit",
            swiftSettings: swiftSettings
        ),
        // Zero dependencies (Foundation only) — deliberately does NOT depend
        // on the ProcessKit target: framing is pure byte work and must stay
        // usable without the spawn/lifecycle surface.
        .target(
            name: "ProcessStreamFraming",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ProcessKitTests",
            dependencies: ["ProcessKit"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ProcessStreamFramingTests",
            dependencies: ["ProcessStreamFraming"],
            swiftSettings: swiftSettings
        )
    ]
)
