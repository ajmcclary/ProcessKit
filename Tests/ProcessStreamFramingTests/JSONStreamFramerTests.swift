//
//  JSONStreamFramerTests.swift
//  ProcessStreamFramingTests
//
//  Characterization tests for JSONStreamFramer — the shared extraction of the
//  byte-identical concatenated-JSON-object splitters from the Claude and Codex
//  transports. Pins both `.frames` (legacy behavior) and the additive
//  `.remainder`, plus the caller-gate difference the framer must not collapse.
//

import XCTest
import ProcessStreamFraming

final class JSONStreamFramerTests: XCTestCase {

	private func split(_ s: String) -> (frames: [String], remainder: String) {
		let r = JSONStreamFramer.splitConcatenatedObjects(Data(s.utf8))
		return (r.frames.map { String(decoding: $0, as: UTF8.self) },
				String(decoding: r.remainder, as: UTF8.self))
	}

	func testEmptyInput() {
		let r = JSONStreamFramer.splitConcatenatedObjects(Data())
		XCTAssertTrue(r.frames.isEmpty)
		XCTAssertTrue(r.remainder.isEmpty)
	}

	func testNonUTF8Input() {
		let r = JSONStreamFramer.splitConcatenatedObjects(Data([0xFF, 0xFE]))
		XCTAssertTrue(r.frames.isEmpty)
		XCTAssertTrue(r.remainder.isEmpty)
	}

	func testSingleCleanObject() {
		let (frames, remainder) = split(#"{"a":1}"#)
		XCTAssertEqual(frames, [#"{"a":1}"#])
		XCTAssertEqual(remainder, "")
	}

	func testLeadingNoiseDiscardedNotInRemainder() {
		let (frames, remainder) = split(#"xx{"a":1}"#)
		XCTAssertEqual(frames, [#"{"a":1}"#])
		XCTAssertEqual(remainder, "")
	}

	func testTrailingNoiseInRemainder() {
		let (frames, remainder) = split(#"{"a":1}xx"#)
		XCTAssertEqual(frames, [#"{"a":1}"#])
		XCTAssertEqual(remainder, "xx")
	}

	func testInterObjectNoiseDiscarded() {
		let (frames, remainder) = split(#"{"a":1}yy{"b":2}"#)
		XCTAssertEqual(frames, [#"{"a":1}"#, #"{"b":2}"#])
		XCTAssertEqual(remainder, "")
	}

	func testTwoConcatenatedObjects() {
		let (frames, _) = split(#"{"a":1}{"b":2}"#)
		XCTAssertEqual(frames, [#"{"a":1}"#, #"{"b":2}"#])
	}

	func testNestedObject() {
		let (frames, _) = split(#"{"a":{"b":1}}"#)
		XCTAssertEqual(frames, [#"{"a":{"b":1}}"#])
	}

	func testBraceInsideStringValue() {
		let s = #"{"a":"}{"}"#
		let (frames, remainder) = split(s)
		XCTAssertEqual(frames, [s])
		XCTAssertEqual(remainder, "")
	}

	func testEscapedQuoteInsideString() {
		let s = #"{"a":"he said \"hi\""}"#
		let (frames, _) = split(s)
		XCTAssertEqual(frames, [s])
	}

	func testEscapedBackslashInsideString() {
		let s = #"{"a":"c:\\path"}"#
		let (frames, _) = split(s)
		XCTAssertEqual(frames, [s])
	}

	func testNestedArrayInsideObject() {
		let s = #"{"a":[1,2,3]}"#
		let (frames, _) = split(s)
		XCTAssertEqual(frames, [s])
	}

	func testTopLevelArrayYieldsNoFrames() {
		let (frames, _) = split("[1,2,3]")
		XCTAssertTrue(frames.isEmpty)
	}

	func testUnterminatedTrailingObjectGoesToRemainder() {
		let (frames, remainder) = split(#"{"a":1}{"b":"#)
		XCTAssertEqual(frames, [#"{"a":1}"#])
		XCTAssertEqual(remainder, #"{"b":"#)
	}

	/// The two former callers apply DIFFERENT gates over these frames. Leading
	/// noise yields exactly one frame whose byte length differs from the input:
	/// Claude's `segments.count > 1` gate is FALSE (no-op) while Codex's
	/// `count == 1 && frames[0].count != lineData.count` gate is TRUE (recovers).
	/// A shared framer must preserve enough information for both.
	func testCallerGateDifferenceIsPreserved() {
		let input = Data(#"xx{"a":1}"#.utf8)
		let r = JSONStreamFramer.splitConcatenatedObjects(input)
		XCTAssertEqual(r.frames.count, 1)
		XCTAssertFalse(r.frames.count > 1)                        // Claude: no-op
		XCTAssertNotEqual(r.frames[0].count, input.count)         // Codex: recovers
	}
}
