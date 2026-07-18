import Foundation

// SEARCH-HELPER: pipe reader, readabilityHandler, FIFO chunk channel, EOF, cancel
/// Owns the read side of one child-process pipe: the FD preflight, the
/// `readabilityHandler` installation, the FIFO chunk channel, and the single
/// consumer task that delivers chunks in the exact order the OS produced
/// them. Every chunk is delivered (in order) before the EOF callback — the
/// consumer drains the FIFO channel, then reports genuine EOF at most once.
/// A cancelled reader never reports EOF, and a reader cancelled before
/// `start` stays permanently inert.
///
/// Policy stays with the owner: no process handling, no protocol framing,
/// no logging, and no termination policy live here. One instance reads one
/// handle for one child lifetime — owners create a fresh reader per spawn.
///
/// Not thread-safe by itself: `start`/`cancel` are expected to run under the
/// owner's isolation (an actor or actor-confined component), matching how
/// the chunk-channel fields it replaces were used. `deinit` runs `cancel()`
/// so a dropped reader cannot leak its handler or consumer task.
public final class ProcessPipeReader {
	private let channel = FileHandleChunkChannel()
	private var consumerTask: Task<Void, Never>?
	private var handle: FileHandle?
	private var isStarted = false
	private var isCancelledForever = false

	public init() {}

	/// Runs `preflight` against the handle's descriptor and `label` (its error
	/// propagates and leaves the reader inert), then installs the readability
	/// handler and starts the FIFO consumer task.
	public func start(
		handle: FileHandle,
		label: String,
		preflight: (Int32, String) throws -> Void,
		onChunk: @escaping @Sendable (Data) async -> Void,
		onEOF: (@Sendable () async -> Void)? = nil
	) throws {
		precondition(!isStarted, "ProcessPipeReader.start called twice; create a fresh reader per spawn")
		// A reader cancelled before start is consumed: stay inert rather than
		// running callbacks against a channel that can never deliver.
		guard !isCancelledForever else { return }
		try preflight(handle.fileDescriptor, label)
		isStarted = true
		self.handle = handle
		let channel = channel
		handle.readabilityHandler = { readable in
			let data = readable.availableData
			if data.isEmpty {
				channel.finish()
				readable.readabilityHandler = nil
			} else {
				channel.yield(data)
			}
		}
		consumerTask = Task {
			for await chunk in channel.stream {
				await onChunk(chunk)
			}
			// Stream ended — genuine EOF or a cancel() from teardown. Only
			// genuine EOF is reported; owners scope any further teardown.
			guard !Task.isCancelled else { return }
			await onEOF?()
		}
	}

	/// Finishes the channel, cancels the consumer task, and detaches the
	/// readability handler. Idempotent; safe to call before `start` (which
	/// then renders the reader permanently inert).
	public func cancel() {
		isCancelledForever = true
		channel.finish()
		consumerTask?.cancel()
		consumerTask = nil
		handle?.readabilityHandler = nil
		handle = nil
	}

	deinit {
		cancel()
	}
}
