import XCTest
import Foundation
import ProcessStreamFraming

/// The framing half of RepoPromptCore's former `ProcessCoreFramingTests`,
/// moved verbatim with the implementation (2026-07-24). The sibling
/// environment-sanitizer / launch-context assertions stayed behind in
/// RepoPromptCore: those cover ProcessCore-local policy, not framing.
final class ProcessStreamFramingTests: XCTestCase {
	private func lines(_ framer: inout LineFramer, feeding chunks: [String]) -> [String] {
		var out: [String] = []
		for chunk in chunks {
			framer.feed(Data(chunk.utf8)) { line in
				out.append(String(decoding: line, as: UTF8.self))
			}
		}
		framer.flush { line in out.append(String(decoding: line, as: UTF8.self)) }
		return out
	}

	func testLineFramerSplitsOnNewline() {
		var framer = LineFramer()
		XCTAssertEqual(lines(&framer, feeding: ["a\nb\n", "c\n"]), ["a", "b", "c"])
	}

	func testLineFramerKeepsEmbeddedNewlineInsideJSONString() {
		var framer = LineFramer()
		let record = "{\"text\":\"line1\nline2\"}\n"
		XCTAssertEqual(lines(&framer, feeding: [record]), ["{\"text\":\"line1\nline2\"}"])
	}

	func testLineFramerStripsCarriageReturn() {
		var framer = LineFramer()
		XCTAssertEqual(lines(&framer, feeding: ["a\r\n"]), ["a"])
	}

	/// Feeds `input` one byte at a time, so every carry/slice boundary is exercised.
	private func linesFedBytewise(_ input: String) -> [String] {
		var framer = LineFramer()
		var out: [String] = []
		for byte in Data(input.utf8) {
			framer.feed(Data([byte])) { out.append(String(decoding: $0, as: UTF8.self)) }
		}
		framer.flush { out.append(String(decoding: $0, as: UTF8.self)) }
		return out
	}

	// MARK: Odd-quote JSON-candidate lines must not swallow the stream

	func testBracketedLogLineWithOddQuoteDoesNotSwallowFollowingRecords() {
		var framer = LineFramer()
		let input = "[WARN] could not parse \"abc\n{\"type\":\"a\"}\n{\"type\":\"b\"}\n{\"type\":\"c\"}\n"
		let expected = [
			"[WARN] could not parse \"abc",
			"{\"type\":\"a\"}",
			"{\"type\":\"b\"}",
			"{\"type\":\"c\"}"
		]
		XCTAssertEqual(lines(&framer, feeding: [input]), expected)
		XCTAssertEqual(linesFedBytewise(input), expected)
	}

	func testTruncatedJSONRecordDoesNotSwallowFollowingRecords() {
		var framer = LineFramer()
		let input = "{\"type\":\"delta\",\"text\":\"trunc\n{\"type\":\"a\"}\n{\"type\":\"b\"}\n"
		XCTAssertEqual(
			lines(&framer, feeding: [input]),
			["{\"type\":\"delta\",\"text\":\"trunc", "{\"type\":\"a\"}", "{\"type\":\"b\"}"]
		)
	}

	/// A following record with an escaped quote flips the inverted quote state
	/// back to "outside", so the glue would end at that record's newline.
	func testOddQuoteLineIsNotGluedToARecordContainingAnEscapedQuote() {
		var framer = LineFramer()
		let record = #"{"type":"text","text":"say \"hi\" now"}"#
		let input = "[ERR] \"oops\n" + record + "\n{\"type\":\"b\"}\n"
		XCTAssertEqual(
			lines(&framer, feeding: [input]),
			["[ERR] \"oops", record, "{\"type\":\"b\"}"]
		)
	}

	func testPlainLinesBetweenOddQuoteLineAndNextRecordAreEachEmitted() {
		var framer = LineFramer()
		let input = "[WARN] \"abc\nplain log line\r\n\n{\"type\":\"a\"}\r\n{\"type\":\"b\"}\n"
		XCTAssertEqual(
			lines(&framer, feeding: [input]),
			["[WARN] \"abc", "plain log line", "", "{\"type\":\"a\"}", "{\"type\":\"b\"}"]
		)
	}

	// MARK: Pinned behaviour that the odd-quote recovery must not change

	func testWellFormedNDJSONIsSplitIdenticallyAcrossChunkings() {
		let records = (0..<200).map { index -> String in
			switch index % 4 {
			case 0: return #"{"type":"delta","index":\#(index),"text":"tab\tquote\" brace{ [x] \\ done"}"#
			case 1: return #"[{"a":\#(index)},{"b":"é é 🙂 ́x"}]"#
			case 2: return #"  {"nested":{"array":[1,2,{"s":"}{"}]},"empty":""}"#
			default: return #"{"text":"\u000A escaped newline, not raw"}"#
			}
		}
		let input = records.joined(separator: "\n") + "\n"
		var whole = LineFramer()
		XCTAssertEqual(lines(&whole, feeding: [input]), records)
		XCTAssertEqual(linesFedBytewise(input), records)

		let crlfInput = records.joined(separator: "\r\n") + "\r\n"
		var crlf = LineFramer()
		XCTAssertEqual(lines(&crlf, feeding: [crlfInput]), records)
	}

	/// Raw newlines inside a JSON string stay tolerated (the record is emitted
	/// whole for `repairJSONStringControlCharacters`), including when a
	/// physical line inside the string starts with `{` or `[`.
	func testRawNewlinesInsideAStringStayInOneRecord() {
		let records = [
			"{\"text\":\"line1\nline2\"}",
			"{\"code\":\"func f()\n{\n  return [1, 2]\n}\n{}\n[]\",\"k\":1}",
			"{\"json\":\"example:\n{\\\"a\\\":1}\n[\\\"x\\\"]\nend\"}",
			"[{\"text\":\"array\nrecord\"}]",
			"{\"crlf\":\"a\r\nb\"}"
		]
		let input = records.joined(separator: "\n") + "\n"
		var framer = LineFramer()
		XCTAssertEqual(lines(&framer, feeding: [input]), records)
		XCTAssertEqual(linesFedBytewise(input), records)
	}

	/// Same input as RepoPrompt's `testLineFramerStressInterleavedJSONAndGarbageAcrossChunkBoundaries`:
	/// raw-newline records and odd-quote garbage lines, fed in random chunk sizes.
	func testInterleavedRawNewlineRecordsAndGarbageAcrossRandomChunks() {
		var records: [String] = []
		for index in 0..<400 {
			switch index % 3 {
			case 0: records.append("{\"index\":\(index),\"text\":\"line \(index) a\nline \(index) b\",\"kind\":\"object\"}")
			case 1: records.append("garbage \"quoted fragment \(index)")
			default: records.append("[{\"index\":\(index),\"text\":\"array \(index) a\narray \(index) b\"}]")
			}
		}
		let input = Data((records.joined(separator: "\n") + "\n").utf8)
		var framer = LineFramer()
		var emitted: [String] = []
		var offset = 0
		var seed: UInt64 = 0xC0D3_510F
		while offset < input.count {
			seed = seed &* 6_364_136_223_846_793_005 &+ 1
			let upperBound = min(offset + Int((seed >> 33) % 31) + 1, input.count)
			framer.feed(input.subdata(in: offset..<upperBound)) { emitted.append(String(decoding: $0, as: UTF8.self)) }
			offset = upperBound
		}
		framer.flush { emitted.append(String(decoding: $0, as: UTF8.self)) }
		XCTAssertEqual(emitted, records)
	}

	func testMakeUTF8SampleTruncationFlag() {
		let data = Data("hello".utf8)
		let sample = makeUTF8Sample(from: data, limit: 3)
		XCTAssertEqual(sample?.0, "hel")
		XCTAssertEqual(sample?.1, true)
	}

	func testRepairEscapesRawTabWhenItIsTheOnlyControlCharacter() throws {
		let broken = Data("{\"a\":\"x\ty\"}".utf8)
		let repaired = try XCTUnwrap(repairJSONStringControlCharacters(broken))
		let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: repaired) as? [String: Any])
		XCTAssertEqual(obj["a"] as? String, "x\ty")
	}

	func testRepairKeepsBackslashBeforeRawNewlineAsALiteralBackslash() throws {
		let broken = Data("{\"cmd\":\"ls \\\n  -la \\\r\nend\"}".utf8)
		let repaired = try XCTUnwrap(repairJSONStringControlCharacters(broken))
		let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: repaired) as? [String: Any])
		XCTAssertEqual(obj["cmd"] as? String, "ls \\\n  -la \\\r\nend")
	}

	func testRepairLeavesWhitespaceOutsideStringsAlone() {
		XCTAssertNil(repairJSONStringControlCharacters(Data("{\t\"a\":\r\n\t1,\"b\":\"\\t\\n\"}".utf8)))
		XCTAssertNil(repairJSONStringControlCharacters(Data("\t[1,\t2]".utf8)))
	}

	func testRepairJSONStringControlCharacters() {
		let broken = Data("{\"a\":\"x\ny\"}".utf8)
		let repaired = repairJSONStringControlCharacters(broken)
		XCTAssertNotNil(repaired)
		let obj = try? JSONSerialization.jsonObject(with: repaired!) as? [String: Any]
		XCTAssertEqual(obj?["a"] as? String, "x\ny")
	}
}
