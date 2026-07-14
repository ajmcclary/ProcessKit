import Darwin
import Foundation
import XCTest
@testable import ProcessKit

#if canImport(AppKit)

final class ProcessLifecycleTests: XCTestCase {
	private func spawnShell(_ script: String) throws -> SpawnedProcess {
		try ProcessLauncher.spawn(
			command: "/bin/sh",
			arguments: ["-c", script],
			environment: ProcessInfo.processInfo.environment,
			workingDirectory: nil
		)
	}

	private func closeHandles(_ process: SpawnedProcess) {
		process.stdin?.closeFile()
		process.stdout.closeFile()
		process.stderr.closeFile()
	}

	// MARK: Launcher

	func testSpawnRunsCommandAndCapturesStdout() throws {
		let process = try ProcessLauncher.spawn(
			command: "/bin/echo",
			arguments: ["processkit"],
			environment: ProcessInfo.processInfo.environment,
			workingDirectory: nil
		)
		defer { closeHandles(process) }

		let output = process.stdout.readDataToEndOfFile()
		XCTAssertEqual(String(data: output, encoding: .utf8), "processkit\n")
	}

	func testSpawnHonorsWorkingDirectory() throws {
		let process = try ProcessLauncher.spawn(
			command: "/bin/pwd",
			arguments: [],
			environment: ProcessInfo.processInfo.environment,
			workingDirectory: "/private/tmp"
		)
		defer { closeHandles(process) }

		let output = process.stdout.readDataToEndOfFile()
		XCTAssertEqual(String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "/private/tmp")
	}

	// MARK: Termination (ported from RepoPrompt's real-process suite)

	func testWaitForTerminationReturnsExitCodeForNormalExit() async throws {
		let process = try spawnShell("exit 7")
		defer { closeHandles(process) }

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: 2)

		XCTAssertEqual(result.exitCode, 7)
		XCTAssertFalse(result.timedOut)
	}

	func testWaitForTerminationTimesOutAndTerminatesProcess() async throws {
		let process = try spawnShell("sleep 30")
		defer { closeHandles(process) }

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: 0.1)

		XCTAssertTrue(result.timedOut)
		XCTAssertGreaterThanOrEqual(result.exitCode, 128)
	}

	func testWaitForTerminationCancellationTerminatesProcess() async throws {
		let process = try spawnShell("sleep 30")
		defer { closeHandles(process) }

		let task = Task {
			try await ProcessTermination.waitForTermination(pid: process.pid, timeout: nil)
		}
		try await Task.sleep(nanoseconds: 100_000_000)
		task.cancel()

		let result = try await task.value
		XCTAssertFalse(result.timedOut)
		XCTAssertGreaterThanOrEqual(result.exitCode, 128)
	}

	func testTerminateAndReapEscalatesToSigkillWhenSigtermIgnored() async throws {
		let process = try spawnShell("trap '' TERM; while true; do sleep 1; done")
		defer { closeHandles(process) }

		let exitCode = await ProcessTermination.terminateAndReap(
			pid: process.pid,
			policy: ProcessTerminationPolicy(
				sigtermGracePeriod: .milliseconds(50),
				sigkillGracePeriod: .milliseconds(50)
			)
		)

		XCTAssertEqual(exitCode, 128 + SIGKILL)
	}

	func testTerminateAndReapReturnsOriginalExitCodeForAlreadyExitedChild() async throws {
		let process = try spawnShell("exit 11")
		defer { closeHandles(process) }
		try await Task.sleep(nanoseconds: 100_000_000)

		let exitCode = await ProcessTermination.terminateAndReap(pid: process.pid)
		XCTAssertEqual(exitCode, 11)
	}

	func testWaitForTerminationHandlesAlreadyReapedChildWithoutHanging() async throws {
		let process = try spawnShell("exit 0")
		defer { closeHandles(process) }

		var status: Int32 = 0
		let waitedPID = Darwin.waitpid(process.pid, &status, 0)
		XCTAssertEqual(waitedPID, process.pid)

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: 0.2)
		XCTAssertFalse(result.timedOut)
		XCTAssertEqual(result.exitCode, 0)
	}

	// MARK: Single-reaper / exactly-once

	func testSecondReapAfterTerminateAndReapReturnsPromptly() async throws {
		let process = try spawnShell("exit 3")
		defer { closeHandles(process) }

		let first = await ProcessTermination.terminateAndReap(pid: process.pid)
		XCTAssertEqual(first, 3)

		// The child is reaped exactly once; a second attempt must not hang
		// or crash — waitpid reports ECHILD and the call returns.
		let start = ProcessInfo.processInfo.systemUptime
		_ = await ProcessTermination.terminateAndReap(pid: process.pid)
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)
	}

	func testStdoutDescriptorReportsEOFAfterChildExitAndClose() throws {
		let process = try spawnShell("exit 0")

		// Drain to EOF, then close: subsequent descriptor use must fail —
		// i.e. the parent-side pipe is fully released.
		_ = process.stdout.readDataToEndOfFile()
		let fd = process.stdout.fileDescriptor
		closeHandles(process)
		XCTAssertEqual(fcntl(fd, F_GETFD), -1)
		XCTAssertEqual(errno, EBADF)
	}
}

final class FileHandleChunkChannelOrderingTests: XCTestCase {
	func testChunksAreDeliveredInYieldOrder() async {
		let channel = FileHandleChunkChannel()
		let total = 500

		for index in 0..<total {
			var value = UInt32(index).bigEndian
			channel.yield(Data(bytes: &value, count: 4))
		}
		channel.finish()

		var received: [UInt32] = []
		for await chunk in channel.stream {
			let value = chunk.withUnsafeBytes { $0.load(as: UInt32.self) }
			received.append(UInt32(bigEndian: value))
		}
		XCTAssertEqual(received, Array(0..<UInt32(total)))
	}
}

#endif

final class FDWriteSupportTests: XCTestCase {
	func testWriteAllRoundTripsThroughPipe() throws {
		var fds: [Int32] = [-1, -1]
		XCTAssertEqual(pipe(&fds), 0)
		defer { close(fds[0]) }

		let payload = Data("processkit-fd-write".utf8)
		try FDWriteSupport.writeAll(payload, to: fds[1])
		close(fds[1])

		var buffer = Data(count: payload.count)
		let read = buffer.withUnsafeMutableBytes { raw in
			Darwin.read(fds[0], raw.baseAddress, payload.count)
		}
		XCTAssertEqual(read, payload.count)
		XCTAssertEqual(buffer, payload)
	}

	func testWriteAllThrowsBrokenPipeWhenReadEndClosed() throws {
		var fds: [Int32] = [-1, -1]
		XCTAssertEqual(pipe(&fds), 0)
		close(fds[0])
		defer { close(fds[1]) }
		_ = FDWriteSupport.configureNoSigPipe(fd: fds[1])

		XCTAssertThrowsError(try FDWriteSupport.writeAll(Data("x".utf8), to: fds[1])) { error in
			guard case .brokenPipe = error as? FDWriteError else {
				return XCTFail("expected .brokenPipe, got \(error)")
			}
		}
	}

	func testWriteAllThrowsBadDescriptor() {
		XCTAssertThrowsError(try FDWriteSupport.writeAll(Data("x".utf8), to: -1)) { error in
			guard case .badDescriptor = error as? FDWriteError else {
				return XCTFail("expected .badDescriptor, got \(error)")
			}
		}
	}
}
