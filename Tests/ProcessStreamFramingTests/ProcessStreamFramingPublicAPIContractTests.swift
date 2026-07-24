//
//  ProcessStreamFramingPublicAPIContractTests.swift
//  ProcessStreamFramingTests
//
//  Public-API contract for the promoted framing layer. Deliberately imports
//  WITHOUT `@testable`: everything asserted here must be reachable by an
//  external consumer (RepoPromptCore's ProcessCore re-export and
//  CodexAppServerKit's CodexJSONStreamDecoder both depend on exactly this
//  surface). A symbol that stops compiling here is a breaking change.
//

import XCTest
import Foundation
import ProcessStreamFraming

final class ProcessStreamFramingPublicAPIContractTests: XCTestCase {

	// MARK: - LineFramer

	func testLineFramerDefaultLimitsArePinned() {
		let limits = LineFramer.Limits.default
		XCTAssertEqual(limits.maxLineBytes, 8 * 1024 * 1024)
		XCTAssertEqual(limits.maxCarryBytes, 16 * 1024 * 1024)
		XCTAssertEqual(limits.tailRetainBytes, 128 * 1024)
	}

	func testLineFramerPublicSurfaceIsConstructibleAndDrivable() {
		var framer = LineFramer(limits: LineFramer.Limits(
			maxLineBytes: 1024,
			maxCarryBytes: 1024,
			tailRetainBytes: 64
		))
		XCTAssertEqual(framer.limits.maxLineBytes, 1024)

		var lines: [String] = []
		var diagnostics: [LineFramer.Diagnostic] = []
		framer.feed(
			Data("{\"a\":1}\n{\"b\":2}\n".utf8),
			onDiagnostic: { diagnostics.append($0) },
			onLine: { lines.append(String(decoding: $0, as: UTF8.self)) }
		)
		framer.flush { lines.append(String(decoding: $0, as: UTF8.self)) }

		XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}"])
		XCTAssertTrue(diagnostics.isEmpty)
	}

	func testLineFramerDiagnosticCasesAreMatchable() {
		let overflow = LineFramer.Diagnostic.overflow(droppedBytes: 3, retainedBytes: 4)
		let reset = LineFramer.Diagnostic.nonJSONCandidateQuoteStateReset
		if case .overflow(let dropped, let retained) = overflow {
			XCTAssertEqual(dropped, 3)
			XCTAssertEqual(retained, 4)
		} else {
			XCTFail("Expected .overflow")
		}
		if case .nonJSONCandidateQuoteStateReset = reset {} else {
			XCTFail("Expected .nonJSONCandidateQuoteStateReset")
		}
	}

	/// Every value an external consumer may move across an isolation
	/// boundary is `Sendable`. `LineFramer` and `FramingResult` gained the
	/// explicit conformance when the layer left RepoPromptCore: public types
	/// get no implicit conformance, and Swift 6 consumers hit a hard
	/// RegionIsolation error without it.
	func testPublicValuesAreSendable() {
		func requireSendable<T: Sendable>(_ value: T) -> T { value }
		_ = requireSendable(LineFramer.Limits.default)
		_ = requireSendable(LineFramer.Diagnostic.nonJSONCandidateQuoteStateReset)
		_ = requireSendable(LineFramer())
		_ = requireSendable(JSONStreamFramer.FramingResult(frames: [], remainder: Data()))
	}

	/// `FramingResult`'s memberwise initializer is explicitly public — the
	/// synthesized one would be `internal` and unusable outside the module.
	func testFramingResultIsConstructibleByConsumers() {
		let result = JSONStreamFramer.FramingResult(
			frames: [Data("{}".utf8)],
			remainder: Data("tail".utf8)
		)
		XCTAssertEqual(result.frames.count, 1)
		XCTAssertEqual(String(decoding: result.remainder, as: UTF8.self), "tail")
	}

	// MARK: - JSONStreamFramer

	func testJSONStreamFramerResultExposesFramesAndRemainder() {
		let result = JSONStreamFramer.splitConcatenatedObjects(Data("{\"a\":1}{\"b\":2}xx".utf8))
		XCTAssertEqual(result.frames.count, 2)
		XCTAssertEqual(String(decoding: result.frames[0], as: UTF8.self), "{\"a\":1}")
		XCTAssertEqual(String(decoding: result.remainder, as: UTF8.self), "xx")
	}

	// MARK: - Raw-byte helpers

	func testAppendTailKeepsTrailingBytesWithinLimit() {
		var buffer = Data()
		appendTail(&buffer, chunk: Data("abcdef".utf8), limit: 4)
		XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "cdef")
	}

	func testMakeUTF8SampleReportsTruncation() {
		let sample = makeUTF8Sample(from: Data("hello".utf8), limit: 3)
		XCTAssertEqual(sample?.0, "hel")
		XCTAssertEqual(sample?.1, true)
	}

	func testASCIIWhitespaceHelpers() {
		XCTAssertTrue(isASCIIWhitespace(0x20))
		XCTAssertFalse(isASCIIWhitespace(0x41))
		let trimmed = trimmedASCIIWhitespace(Data("  {}\n".utf8))
		XCTAssertEqual(trimmed.map { String(decoding: $0, as: UTF8.self) }, "{}")
		XCTAssertNil(trimmedASCIIWhitespace(Data("   ".utf8)))
	}

	func testRepairJSONStringControlCharactersEscapesRawNewlines() throws {
		let broken = Data("{\"text\":\"a\nb\"}".utf8)
		let repaired = try XCTUnwrap(repairJSONStringControlCharacters(broken))
		let json = try XCTUnwrap(
			try JSONSerialization.jsonObject(with: repaired) as? [String: Any]
		)
		XCTAssertEqual(json["text"] as? String, "a\nb")
		XCTAssertNil(
			repairJSONStringControlCharacters(Data("{\"text\":\"ab\"}".utf8)),
			"No control characters means no repair"
		)
	}
}
