import XCTest
import Foundation
@testable import ProcessKit

final class ProcessPipeReaderTests: XCTestCase {

	private final class ChunkCollector: @unchecked Sendable {
		private let lock = NSLock()
		private var chunks: [Data] = []
		private var eofCount = 0

		func append(_ data: Data) {
			lock.lock()
			chunks.append(data)
			lock.unlock()
		}

		func markEOF() {
			lock.lock()
			eofCount += 1
			lock.unlock()
		}

		func joined() -> Data {
			lock.lock()
			defer { lock.unlock() }
			return chunks.reduce(Data(), +)
		}

		func eofs() -> Int {
			lock.lock()
			defer { lock.unlock() }
			return eofCount
		}
	}

	private final class SequenceCollector: @unchecked Sendable {
		private let lock = NSLock()
		private var events: [String] = []

		func append(_ event: String) {
			lock.lock()
			events.append(event)
			lock.unlock()
		}

		func snapshot() -> [String] {
			lock.lock()
			defer { lock.unlock() }
			return events
		}
	}

	@discardableResult
	private func waitUntil(
		timeout: TimeInterval = 2,
		_ condition: () -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return true }
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return condition()
	}

	func testDeliversBytesInOrderAndReportsEOFExactlyOnce() async throws {
		let pipe = Pipe()
		let reader = ProcessPipeReader()
		let collector = ChunkCollector()
		try reader.start(
			handle: pipe.fileHandleForReading,
			label: "test stdout",
			preflight: { _, _ in },
			onChunk: { collector.append($0) },
			onEOF: { collector.markEOF() }
		)
		pipe.fileHandleForWriting.write(Data("alpha-".utf8))
		pipe.fileHandleForWriting.write(Data("beta-".utf8))
		pipe.fileHandleForWriting.write(Data("gamma".utf8))
		try pipe.fileHandleForWriting.close()

		let sawEOF = await waitUntil { collector.eofs() == 1 }
		XCTAssertTrue(sawEOF, "Closing the write side must produce exactly one EOF callback")
		XCTAssertEqual(
			String(data: collector.joined(), encoding: .utf8),
			"alpha-beta-gamma",
			"Bytes must arrive complete and in write order (chunk boundaries may coalesce)"
		)
		XCTAssertEqual(collector.eofs(), 1)
		reader.cancel()
	}

	func testPreflightFailureThrowsAndLeavesReaderInert() throws {
		struct PreflightError: Error {}
		let pipe = Pipe()
		let reader = ProcessPipeReader()
		let collector = ChunkCollector()
		XCTAssertThrowsError(
			try reader.start(
				handle: pipe.fileHandleForReading,
				label: "test stdout",
				preflight: { _, _ in throw PreflightError() },
				onChunk: { collector.append($0) },
				onEOF: { collector.markEOF() }
			)
		)
		XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "A failed preflight must not install a handler")
		reader.cancel()
	}

	func testCancelSuppressesEOFAndIsIdempotent() async throws {
		let pipe = Pipe()
		let reader = ProcessPipeReader()
		let collector = ChunkCollector()
		try reader.start(
			handle: pipe.fileHandleForReading,
			label: "test stdout",
			preflight: { _, _ in },
			onChunk: { collector.append($0) },
			onEOF: { collector.markEOF() }
		)
		reader.cancel()
		reader.cancel()
		XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "cancel must detach the readability handler")
		try pipe.fileHandleForWriting.close()
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(collector.eofs(), 0, "A cancelled reader must never report EOF")
	}

	func testCancelBeforeStartLeavesReaderPermanentlyInert() async throws {
		let pipe = Pipe()
		let reader = ProcessPipeReader()
		let collector = ChunkCollector()
		reader.cancel()
		try reader.start(
			handle: pipe.fileHandleForReading,
			label: "test stdout",
			preflight: { _, _ in },
			onChunk: { collector.append($0) },
			onEOF: { collector.markEOF() }
		)
		XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "A consumed reader must not install a handler")
		pipe.fileHandleForWriting.write(Data("late".utf8))
		try pipe.fileHandleForWriting.close()
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(collector.joined().count, 0, "A consumed reader must never deliver chunks")
		XCTAssertEqual(collector.eofs(), 0, "A consumed reader must never report EOF")
	}

	func testDeinitCancelsConsumerAndDetachesHandler() async throws {
		let pipe = Pipe()
		let collector = ChunkCollector()
		var reader: ProcessPipeReader? = ProcessPipeReader()
		try reader?.start(
			handle: pipe.fileHandleForReading,
			label: "test stdout",
			preflight: { _, _ in },
			onChunk: { collector.append($0) },
			onEOF: { collector.markEOF() }
		)
		reader = nil
		XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "deinit must detach the readability handler")
		try pipe.fileHandleForWriting.close()
		try? await Task.sleep(nanoseconds: 200_000_000)
		XCTAssertEqual(collector.eofs(), 0, "A deallocated reader must never report EOF")
	}

	func testAllChunksDeliverBeforeEOFCallback() async throws {
		let pipe = Pipe()
		let reader = ProcessPipeReader()
		let sequence = SequenceCollector()
		try reader.start(
			handle: pipe.fileHandleForReading,
			label: "test stdout",
			preflight: { _, _ in },
			onChunk: { _ in sequence.append("chunk") },
			onEOF: { sequence.append("eof") }
		)
		pipe.fileHandleForWriting.write(Data("one".utf8))
		pipe.fileHandleForWriting.write(Data("two".utf8))
		try pipe.fileHandleForWriting.close()
		let done = await waitUntil { sequence.snapshot().last == "eof" }
		XCTAssertTrue(done)
		let events = sequence.snapshot()
		XCTAssertEqual(events.last, "eof")
		XCTAssertGreaterThanOrEqual(events.count, 2, "at least one chunk must precede EOF")
		XCTAssertEqual(events.filter { $0 == "eof" }.count, 1)
		XCTAssertTrue(events.dropLast().allSatisfy { $0 == "chunk" }, "every chunk callback must precede the EOF callback: \(events)")
		reader.cancel()
	}
}
