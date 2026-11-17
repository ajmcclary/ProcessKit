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

	/// A descriptor without FD_CLOEXEC — e.g. another spawn's pipe in the window
	/// between `pipe()` and `fcntl` — must not be inherited by the child.
	func testSpawnDoesNotLeakInheritableDescriptorsIntoChild() throws {
		var fds: [Int32] = [-1, -1]
		XCTAssertEqual(pipe(&fds), 0)
		// Move both ends far above the numbers `ls` itself opens (its
		// directory handle takes the lowest free descriptor). F_DUPFD
		// leaves FD_CLOEXEC clear.
		let leaked = [fcntl(fds[0], F_DUPFD, 200), fcntl(fds[1], F_DUPFD, 200)]
		close(fds[0]); close(fds[1])
		defer { close(leaked[0]); close(leaked[1]) }
		XCTAssertGreaterThanOrEqual(leaked[0], 200)
		XCTAssertEqual(fcntl(leaked[0], F_GETFD) & FD_CLOEXEC, 0)
		XCTAssertEqual(fcntl(leaked[1], F_GETFD) & FD_CLOEXEC, 0)

		let process = try ProcessLauncher.spawn(
			command: "/bin/ls",
			arguments: ["/dev/fd"],
			environment: ProcessInfo.processInfo.environment,
			workingDirectory: nil
		)
		defer { closeHandles(process) }
		let listing = String(decoding: process.stdout.readDataToEndOfFile(), as: UTF8.self)
		let open = Set(listing.split(whereSeparator: \.isNewline).compactMap { Int32($0) })

		XCTAssertTrue(open.isSuperset(of: [0, 1, 2]), "listing: \(listing)")
		XCTAssertFalse(open.contains(leaked[0]), "read end \(leaked[0]) leaked; listing: \(listing)")
		XCTAssertFalse(open.contains(leaked[1]), "write end \(leaked[1]) leaked; listing: \(listing)")
		var status: Int32 = 0
		_ = Darwin.waitpid(process.pid, &status, 0)
	}

	func testTerminationAlsoEndsGrandchildHoldingStdout() async throws {
		let process = try spawnShell("sleep 30 & wait")
		defer { closeHandles(process) }
		try await Task.sleep(nanoseconds: 200_000_000) // let the background sleep start

		_ = await ProcessTermination.terminateAndReap(
			pid: process.pid,
			policy: ProcessTerminationPolicy(sigtermGracePeriod: .milliseconds(500), sigkillGracePeriod: .milliseconds(500))
		)

		var pollDescriptor = pollfd(fd: process.stdout.fileDescriptor, events: Int16(POLLIN), revents: 0)
		guard poll(&pollDescriptor, 1, 3_000) == 1 else {
			kill(-process.pid, SIGKILL) // don't leave the grandchild behind on failure
			return XCTFail("stdout never reached EOF: a grandchild still holds it")
		}
		var byte: UInt8 = 0
		XCTAssertEqual(Darwin.read(process.stdout.fileDescriptor, &byte, 1), 0, "expected EOF")
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

	private func processCPUSeconds() -> Double {
		var usage = rusage()
		getrusage(RUSAGE_SELF, &usage)
		func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
		return seconds(usage.ru_utime) + seconds(usage.ru_stime)
	}

	/// Cancellation is what triggers termination, and a cancelled task's
	/// `Task.sleep` throws at once: the grace-period polling must still sleep.
	func testCancelledWaitSleepsBetweenPollsDuringTerminationGrace() async throws {
		let process = try spawnShell("trap '' TERM; exec sleep 30")
		defer { closeHandles(process) }
		try await Task.sleep(nanoseconds: 200_000_000) // let the trap install

		let policy = ProcessTerminationPolicy(sigtermGracePeriod: .seconds(1), sigkillGracePeriod: .seconds(1))
		let cpuBefore = processCPUSeconds()
		let wallBefore = ProcessInfo.processInfo.systemUptime
		let task = Task {
			try await ProcessTermination.waitForTermination(pid: process.pid, timeout: nil, policy: policy)
		}
		task.cancel()
		let result = try await task.value
		let cpu = processCPUSeconds() - cpuBefore

		XCTAssertEqual(result.exitCode, 128 + SIGKILL)
		XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - wallBefore, 0.9)
		XCTAssertLessThan(cpu, 0.3, "polled waitpid without sleeping for the whole SIGTERM grace")
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

	// MARK: Reap latency (review MT-01)

	private func median(_ samples: [TimeInterval]) -> TimeInterval {
		let sorted = samples.sorted()
		return sorted[sorted.count / 2]
	}

	/// The reaper polled `waitpid(WNOHANG)` and slept 50 ms between polls, so
	/// a child that exits in a millisecond was reaped no sooner than ~50 ms
	/// later. It must wake on the exit itself.
	///
	/// Measured from the moment `spawn` returns: the polling reaper's first
	/// `waitpid` ran then, while the exec'd child was still starting, so
	/// every sample it produced was at least 50 ms. The bound is the median
	/// of several runs under 40 ms, which leaves the child's own run time
	/// plenty of room on a loaded machine and which polling could not meet.
	func testShortLivedChildIsReapedWithoutWaitingOutAPollInterval() async throws {
		for timeout in [nil, 10] as [TimeInterval?] {
			var samples: [TimeInterval] = []
			for _ in 0..<9 {
				let process = try ProcessLauncher.spawn(
					command: "/usr/bin/true",
					arguments: [],
					environment: ProcessInfo.processInfo.environment,
					workingDirectory: nil
				)
				let start = ProcessInfo.processInfo.systemUptime
				let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: timeout)
				samples.append(ProcessInfo.processInfo.systemUptime - start)
				closeHandles(process)
				XCTAssertEqual(result.exitCode, 0)
				XCTAssertFalse(result.timedOut)
			}
			XCTAssertLessThan(
				median(samples), 0.040,
				"timeout \(String(describing: timeout)): spawn-to-reap samples \(samples.map { Int($0 * 1000) }) ms"
			)
		}
	}

	/// The termination grace waits must also wake on the exit, not on the
	/// next 50 ms poll. A zero SIGTERM grace goes straight to SIGKILL, so
	/// the measured time is the SIGKILL wait alone. (SIGKILL rather than
	/// SIGTERM because a child spawned from a test's worker thread inherits
	/// its blocked SIGTERM; see the remediation report.)
	func testTerminateAndReapWakesOnExitAfterSignal() async throws {
		var samples: [TimeInterval] = []
		for _ in 0..<7 {
			let process = try ProcessLauncher.spawn(
				command: "/bin/sleep",
				arguments: ["30"],
				environment: ProcessInfo.processInfo.environment,
				workingDirectory: nil
			)
			let start = ProcessInfo.processInfo.systemUptime
			let exitCode = await ProcessTermination.terminateAndReap(
				pid: process.pid,
				policy: ProcessTerminationPolicy(sigtermGracePeriod: .zero, sigkillGracePeriod: .seconds(2))
			)
			samples.append(ProcessInfo.processInfo.systemUptime - start)
			closeHandles(process)
			XCTAssertEqual(exitCode, 128 + SIGKILL)
		}
		XCTAssertLessThan(median(samples), 0.040, "signal-to-reap samples \(samples.map { Int($0 * 1000) }) ms")
	}

	/// The race the event wait must survive: the child has already exited
	/// (a zombie) when the exit watch is registered, so no NOTE_EXIT edge
	/// arrives after registration. The wait must still return at once
	/// rather than sit out its fallback.
	func testExitWaitReturnsPromptlyForChildThatExitedBeforeRegistration() async throws {
		let process = try spawnShell("exit 0")
		defer { closeHandles(process) }
		var info = siginfo_t()
		// Block until it is a zombie, without reaping it.
		XCTAssertEqual(waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOWAIT), 0)

		let start = ProcessInfo.processInfo.systemUptime
		await ProcessTermination.waitForExitEvent(pid: process.pid, fallbackNanoseconds: 10_000_000_000, wakeOnCancellation: false)
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: nil)
		XCTAssertEqual(result.exitCode, 0)
	}

	/// The exit watch never reaps: the single owner's `waitpid` still gets
	/// the child's status after the watch has fired.
	func testExitWaitDoesNotReapTheChild() async throws {
		let process = try spawnShell("exit 5")
		defer { closeHandles(process) }

		await ProcessTermination.waitForExitEvent(pid: process.pid, fallbackNanoseconds: 10_000_000_000, wakeOnCancellation: false)

		var status: Int32 = 0
		XCTAssertEqual(Darwin.waitpid(process.pid, &status, WNOHANG), process.pid)
		XCTAssertEqual((status >> 8) & 0xff, 5)
	}

	/// A long-running child: the wait returns at its fallback, and a
	/// cancelled task's wait (when asked to) returns at once.
	func testExitWaitHonoursFallbackAndCancellation() async throws {
		let process = try spawnShell("exec sleep 30")
		defer {
			kill(process.pid, SIGKILL)
			var status: Int32 = 0
			_ = Darwin.waitpid(process.pid, &status, 0)
			closeHandles(process)
		}

		var start = ProcessInfo.processInfo.systemUptime
		await ProcessTermination.waitForExitEvent(pid: process.pid, fallbackNanoseconds: 100_000_000, wakeOnCancellation: false)
		let fallbackElapsed = ProcessInfo.processInfo.systemUptime - start
		XCTAssertGreaterThanOrEqual(fallbackElapsed, 0.09)
		XCTAssertLessThan(fallbackElapsed, 5.0)

		let pid = process.pid
		let task = Task {
			await ProcessTermination.waitForExitEvent(pid: pid, fallbackNanoseconds: 10_000_000_000, wakeOnCancellation: true)
		}
		try await Task.sleep(nanoseconds: 50_000_000)
		start = ProcessInfo.processInfo.systemUptime
		task.cancel()
		await task.value
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2.0)

		// Not woken by cancellation when the caller says so (the termination
		// grace must keep waiting after the cancel that started it).
		let ignoring = Task {
			await ProcessTermination.waitForExitEvent(pid: pid, fallbackNanoseconds: 300_000_000, wakeOnCancellation: false)
		}
		start = ProcessInfo.processInfo.systemUptime
		ignoring.cancel()
		await ignoring.value
		XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.29)
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
