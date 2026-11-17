import Foundation
import Darwin
import Synchronization

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

	/// Serial queue for the exit-watch and fallback-timer handlers, which
	/// only resume a continuation.
	private static let exitWatchQueue = DispatchQueue(label: "ProcessKit.ProcessTermination.exitWatch")

	/// Resumes one continuation exactly once, from whichever of the exit
	/// event, the fallback timer or cancellation comes first; a wake that
	/// arrives before the continuation is installed resumes it on install.
	private final class ExitWake: Sendable {
		private enum State {
			case idle
			case waiting(CheckedContinuation<Void, Never>)
			case fired
		}

		private let state = Mutex<State>(.idle)

		func install(_ continuation: CheckedContinuation<Void, Never>) {
			let resumeNow = state.withLock { state -> Bool in
				if case .fired = state { return true }
				state = .waiting(continuation)
				return false
			}
			if resumeNow { continuation.resume() }
		}

		func fire() {
			let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
				switch state {
				case .waiting(let continuation):
					state = .fired
					return continuation
				case .idle:
					state = .fired
					return nil
				case .fired:
					return nil
				}
			}
			continuation?.resume()
		}
	}

	/// Whether the unreaped child `pid` has already exited (is a zombie).
	/// Never reaps (`WNOWAIT`).
	private static func hasExitedUnreaped(_ pid: pid_t) -> Bool {
		var info = siginfo_t()
		while true {
			if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return info.si_pid == pid }
			if errno != EINTR { return false }
		}
	}

	/// Suspends until `pid` exits, `fallbackNanoseconds` elapse, or — only
	/// when `wakeOnCancellation` — the calling task is cancelled, whichever
	/// comes first. It never reaps: the caller's `waitpid` stays the single
	/// reaper, and calls it after every return.
	///
	/// The exit arrives through a dispatch process source (kqueue
	/// `EVFILT_PROC`/`NOTE_EXIT`), so a child that runs for a millisecond is
	/// reaped a millisecond later rather than at the next poll. A child that
	/// exits between the caller's `waitpid` and the source's registration
	/// produces no `NOTE_EXIT` edge after registration; the `WNOWAIT` check
	/// after activation catches a child that is already a zombie, and the
	/// fallback timer bounds any wake still missed to the former poll
	/// interval, so a missed event is never worse than polling was.
	///
	/// `wakeOnCancellation: false` is for the termination grace periods:
	/// termination runs precisely because the task was cancelled, and waking
	/// on that cancellation turned the grace polling into a `waitpid(WNOHANG)`
	/// busy loop.
	static func waitForExitEvent(pid: pid_t, fallbackNanoseconds: UInt64, wakeOnCancellation: Bool) async {
		let wake = ExitWake()
		let exitSource = pid > 0
			? DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: exitWatchQueue)
			: nil
		let timer = DispatchSource.makeTimerSource(queue: exitWatchQueue)
		exitSource?.setEventHandler { wake.fire() }
		timer.setEventHandler { wake.fire() }
		timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: fallbackNanoseconds)))
		exitSource?.activate()
		timer.activate()
		if pid > 0, hasExitedUnreaped(pid) { wake.fire() }

		await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				wake.install(continuation)
			}
		} onCancel: {
			if wakeOnCancellation { wake.fire() }
		}

		exitSource?.cancel()
		timer.cancel()
	}

	@inline(__always)
	private static func nanoseconds(until deadline: TimeInterval) -> UInt64 {
		let remaining = deadline - ProcessInfo.processInfo.systemUptime
		guard remaining > 0 else { return 0 }
		return UInt64(remaining * 1_000_000_000)
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
	///
	/// Signals nothing unless `pid` is still an unreaped child of this
	/// process, and then returns -1 with `errno` ESRCH as if it had exited:
	/// a pid that has been reaped (by this process's single reaper) may
	/// already belong to an unrelated process, and `kill(0, …)` or a negative
	/// pid would reach whole process groups.
	private static func signalChild(_ pid: pid_t, _ signal: Int32) -> Int32 {
		guard pid > 0, isUnreapedChild(pid) else {
			errno = ESRCH
			return -1
		}
		if kill(-pid, signal) == 0 {
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
			await waitForExitEvent(
				pid: pid,
				fallbackNanoseconds: min(pollIntervalNs, nanoseconds(until: deadline)),
				wakeOnCancellation: false
			)
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
					await waitForExitEvent(
						pid: pid,
						fallbackNanoseconds: min(currentPollNs(), nanoseconds(until: deadline)),
						wakeOnCancellation: true
					)
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
				await waitForExitEvent(pid: pid, fallbackNanoseconds: currentPollNs(), wakeOnCancellation: true)
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
