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

	func testMakeUTF8SampleTruncationFlag() {
		let data = Data("hello".utf8)
		let sample = makeUTF8Sample(from: data, limit: 3)
		XCTAssertEqual(sample?.0, "hel")
		XCTAssertEqual(sample?.1, true)
	}

	func testRepairJSONStringControlCharacters() {
		let broken = Data("{\"a\":\"x\ny\"}".utf8)
		let repaired = repairJSONStringControlCharacters(broken)
		XCTAssertNotNil(repaired)
		let obj = try? JSONSerialization.jsonObject(with: repaired!) as? [String: Any]
		XCTAssertEqual(obj?["a"] as? String, "x\ny")
	}
}
