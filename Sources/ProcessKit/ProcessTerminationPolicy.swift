import Foundation

/// Grace periods for cooperative child termination.
///
/// Callers own policy — ProcessKit carries no mutable application-wide
/// termination mode. An application that wants a faster shutdown path
/// (e.g. during app termination) holds its own current-policy value and
/// passes it at each call site.
public struct ProcessTerminationPolicy: Sendable {
	/// How long a caller-side cooperative cancellation wait should allow
	/// before escalating (informational for callers that gate their own
	/// waits; `ProcessTermination` itself uses the two grace periods).
	public var cooperativeWaitTimeout: Duration
	/// Grace period after SIGTERM before escalating to SIGKILL.
	public var sigtermGracePeriod: Duration
	/// Grace period after SIGKILL before giving up on reaping.
	public var sigkillGracePeriod: Duration

	public init(
		cooperativeWaitTimeout: Duration = .seconds(3),
		sigtermGracePeriod: Duration = .seconds(2),
		sigkillGracePeriod: Duration = .seconds(1)
	) {
		self.cooperativeWaitTimeout = cooperativeWaitTimeout
		self.sigtermGracePeriod = sigtermGracePeriod
		self.sigkillGracePeriod = sigkillGracePeriod
	}

	public static let `default` = ProcessTerminationPolicy()
}

extension Duration {
	/// `TimeInterval` view used by the polling arithmetic (which predates
	/// `Duration` and is kept byte-identical to the proven implementation).
	var timeInterval: TimeInterval {
		let parts = components
		return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
	}
}
