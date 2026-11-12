import Foundation
import Darwin

public enum ProcessTerminationError: Error, LocalizedError {
	case waitFailed(String)

	public var errorDescription: String? {
		switch self {
		case .waitFailed(let message):
			return "waitpid failed: \(message)"
		}
	}
}

public enum ProcessTermination {
	private static let pollInterval: TimeInterval = 0.05
	private static let longPollInterval: TimeInterval = 0.2
	private static let longPollThreshold: TimeInterval = 2.0

	@inline(__always)
	private static func waitStatusExited(_ status: Int32) -> Bool {
		(status & 0x7f) == 0
	}

	@inline(__always)
	private static func waitStatusExitCode(_ status: Int32) -> Int32 {
		(status >> 8) & 0xff
	}

	@inline(__always)
	private static func waitStatusSignaled(_ status: Int32) -> Bool {
		let signal = status & 0x7f
		return signal != 0 && signal != 0x7f
	}

	@inline(__always)
	private static func waitStatusSignal(_ status: Int32) -> Int32 {
		status & 0x7f
	}

	@inline(__always)
	private static func normalizedExitCode(_ rawStatus: Int32) -> Int32 {
		if waitStatusExited(rawStatus) { return waitStatusExitCode(rawStatus) }
		if waitStatusSignaled(rawStatus) { return 128 &+ waitStatusSignal(rawStatus) }
		return rawStatus
	}

	/// Sleeps for the full interval even when the calling task is cancelled.
	/// Termination runs precisely because the task was cancelled, and a
	/// cancelled task's `Task.sleep` throws at once, which turned the grace
	/// period polling into a `waitpid(WNOHANG)` busy loop. A detached task
	/// does not inherit the caller's cancellation.
	private static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
		await Task.detached {
			try? await Task.sleep(nanoseconds: nanoseconds)
		}.value
	}

	/// Whether `pid` is a child of this process that has not been reaped yet
	/// (running or zombie). While that holds its pid, and so a process group
	/// with that id, cannot belong to anything else.
	private static func isUnreapedChild(_ pid: pid_t) -> Bool {
		var info = siginfo_t()
		while true {
			if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return true }
			if errno != EINTR { return false }
		}
	}

	/// Sends `signal` to the child's process group when it leads one
	/// (`ProcessLauncher` spawns each child into its own group), so
	/// grandchildren holding the child's pipes are signalled too; otherwise,
	/// or when the group is gone, to the child alone. Returns `kill(2)`'s
	/// result for the last call made, with `errno` set as it left it.
	private static func signalChild(_ pid: pid_t, _ signal: Int32) -> Int32 {
		if pid > 0, isUnreapedChild(pid), kill(-pid, signal) == 0 {
			return 0
		}
		return kill(pid, signal)
	}

	private static func waitForExitUntil(
		pid: pid_t,
		status: inout Int32,
		deadline: TimeInterval,
		pollIntervalNs: UInt64,
		logger: (String) -> Void
	) async -> Bool {
		while ProcessInfo.processInfo.systemUptime < deadline {
			let r = waitpid(pid, &status, WNOHANG)
			if r == pid { return true }
			if r == -1 && errno == EINTR { continue }
			if r == -1 && errno == ECHILD { return true }
			if r == -1 {
				let message = String(cString: strerror(errno))
				logger("waitpid failed while reaping process \(pid): \(message)")
				return false
			}
			await sleepIgnoringCancellation(nanoseconds: pollIntervalNs)
		}
		return false
	}

	private static func terminateAndReap(
		pid: pid_t,
		status: inout Int32,
		sigtermGrace: TimeInterval,
		sigkillGrace: TimeInterval,
		logger: (String) -> Void
	) async -> Int32 {
		let shortPollNs = UInt64(pollInterval * 1_000_000_000)
		var lastSignal: Int32?

		if signalChild(pid, SIGTERM) == 0 {
			lastSignal = SIGTERM
		} else if errno == ESRCH {
			return normalizedExitCode(status)
		}

		let sigtermDeadline = ProcessInfo.processInfo.systemUptime + max(sigtermGrace, 0)
		if await waitForExitUntil(
			pid: pid,
			status: &status,
			deadline: sigtermDeadline,
			pollIntervalNs: shortPollNs,
			logger: logger
		) {
			return normalizedExitCode(status)
		}

		logger("Process \(pid) did not exit after SIGTERM; sending SIGKILL")
		if signalChild(pid, SIGKILL) == 0 {
			lastSignal = SIGKILL
		} else if errno == ESRCH {
			return normalizedExitCode(status)
		}

		let sigkillDeadline = ProcessInfo.processInfo.systemUptime + max(sigkillGrace, 0)
		if await waitForExitUntil(
			pid: pid,
			status: &status,
			deadline: sigkillDeadline,
			pollIntervalNs: shortPollNs,
			logger: logger
		) {
			return normalizedExitCode(status)
		}

		if let signal = lastSignal {
			return 128 &+ signal
		}
		return normalizedExitCode(status)
	}

	public static func waitForTermination(
		pid: pid_t,
		timeout: TimeInterval?,
		policy: ProcessTerminationPolicy = .default,
		logger: (String) -> Void = { _ in }
	) async throws -> (exitCode: Int32, timedOut: Bool) {
		var status: Int32 = 0
		let start = ProcessInfo.processInfo.systemUptime
		let shortPollNs = UInt64(pollInterval * 1_000_000_000)
		let longPollNs = UInt64(longPollInterval * 1_000_000_000)

		@inline(__always)
		func currentPollNs() -> UInt64 {
			let elapsed = ProcessInfo.processInfo.systemUptime - start
			return elapsed < longPollThreshold ? shortPollNs : longPollNs
		}

		if let timeout {
			let deadline = ProcessInfo.processInfo.systemUptime + timeout
			while true {
				if Task.isCancelled {
					logger("Process cancelled; terminating")
					let code = await terminateAndReap(
						pid: pid,
						status: &status,
						sigtermGrace: policy.sigtermGracePeriod.timeInterval,
						sigkillGrace: policy.sigkillGracePeriod.timeInterval,
						logger: logger
					)
					return (code, false)
				}

				let r = waitpid(pid, &status, WNOHANG)
				if r == pid { return (normalizedExitCode(status), false) }
				if r == 0 {
					if ProcessInfo.processInfo.systemUptime >= deadline {
						logger("Process timed out after \(timeout) seconds; sending SIGTERM")
						let code = await terminateAndReap(
							pid: pid,
							status: &status,
							sigtermGrace: policy.sigtermGracePeriod.timeInterval,
							sigkillGrace: policy.sigkillGracePeriod.timeInterval,
							logger: logger
						)
						return (code, true)
					}
					try? await Task.sleep(nanoseconds: currentPollNs())
					continue
				}
				if r == -1 && errno == EINTR { continue }
				if r == -1 && errno == ECHILD { return (normalizedExitCode(status), false) }
				if r == -1 {
					let message = String(cString: strerror(errno))
					throw ProcessTerminationError.waitFailed(message)
				}
			}
		}

		while true {
			if Task.isCancelled {
				logger("Process cancelled; terminating")
				let code = await terminateAndReap(
					pid: pid,
					status: &status,
					sigtermGrace: policy.sigtermGracePeriod.timeInterval,
					sigkillGrace: policy.sigkillGracePeriod.timeInterval,
					logger: logger
				)
				return (code, false)
			}

			let r = waitpid(pid, &status, WNOHANG)
			if r == pid { return (normalizedExitCode(status), false) }
			if r == 0 {
				try? await Task.sleep(nanoseconds: currentPollNs())
				continue
			}
			if r == -1 && errno == EINTR { continue }
			if r == -1 && errno == ECHILD { return (normalizedExitCode(status), false) }
			if r == -1 {
				let message = String(cString: strerror(errno))
				throw ProcessTerminationError.waitFailed(message)
			}
		}
	}

	public static func terminateAndReap(
		pid: pid_t,
		policy: ProcessTerminationPolicy = .default,
		logger: (String) -> Void = { _ in }
	) async -> Int32 {
		var status: Int32 = 0
		return await terminateAndReap(
			pid: pid,
			status: &status,
			sigtermGrace: policy.sigtermGracePeriod.timeInterval,
			sigkillGrace: policy.sigkillGracePeriod.timeInterval,
			logger: logger
		)
	}
}
