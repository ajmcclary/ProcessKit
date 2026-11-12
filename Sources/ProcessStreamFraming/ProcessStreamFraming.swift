import Foundation

@inline(__always)
public func appendTail(_ buffer: inout Data, chunk: Data, limit: Int) {
	guard limit > 0, !chunk.isEmpty else { return }
	buffer.append(chunk)
	if buffer.count > limit {
		let overflow = buffer.count - limit
		buffer.removeSubrange(0..<overflow)
	}
}

@inline(__always)
public func makeUTF8Sample(from data: Data, limit: Int) -> (String, Bool)? {
	guard limit > 0, !data.isEmpty else { return nil }
	var sample = Data(data.prefix(limit))
	while !sample.isEmpty && String(data: sample, encoding: .utf8) == nil {
		sample.removeLast()
	}
	guard !sample.isEmpty, let string = String(data: sample, encoding: .utf8) else {
		return nil
	}
	let truncated = data.count > sample.count
	return (string, truncated)
}

// SEARCH-HELPER: LineFramer, NDJSON, framing, newline, JSON string, quote tracking, carry buffer
/// Splits a raw byte stream into NDJSON lines.
///
/// Tracks JSON string state (quote/escape) so that literal newline bytes embedded
/// inside JSON string values do not prematurely split a record. To avoid poisoning
/// from non-JSON garbage that happens to contain quote characters, quote/escape
/// tracking is only active when the current line begins with `{` or `[` (a "JSON
/// candidate"). Lines that start with any other non-whitespace byte are split on
/// every `\n` unconditionally.
///
/// A JSON candidate whose string never closes (an odd-quote log line such as
/// `[WARN] "abc`, or a truncated record) would otherwise keep the framer
/// "inside a string" for every later line. So once a logical line has spanned
/// a raw newline, each further physical line is checked as it completes: if it
/// is on its own a complete JSON object or array that contains a string, the
/// quote tracking that joined it was wrong, and the framer resplits — every
/// physical line before it is emitted on its own, then the line itself. A
/// string whose raw newlines are its only defect cannot trigger this: inside
/// it every `"` is escaped, so no physical line of it parses as JSON with a
/// string in it (except a contrived array/object whose second string begins
/// right where the first ends, e.g. `["x⏎{",":1}⏎"]`). Well-formed NDJSON
/// never has a raw newline inside a string and is not affected.
///
/// Performance: uses `withUnsafeBytes` + slice appends to avoid per-byte Data.append
/// overhead on large chunks.
///
/// Related:
/// - Consumer: ClaudeNativeProcessSessionController.handleStdoutChunk
/// - Codec:    ClaudeSDKProtocolCodec.decodeLine
/// - Tests:    RepoPromptTests/Process/ProcessCoreTests.swift (LineFramer section)
/// `Sendable` is declared explicitly (all stored properties already are):
/// public types get no implicit conformance, so before the 2026-07-24
/// promotion out of RepoPromptCore a Swift 6 consumer could not pass a
/// framer across an actor boundary. Additive only — no behavior change.
public struct LineFramer: Sendable {
	public struct Limits: Sendable {
		/// Maximum bytes allowed in a single logical line before overflow handling.
		public var maxLineBytes: Int
		/// Maximum bytes the carry buffer may accumulate across chunks before overflow.
		public var maxCarryBytes: Int
		/// When overflow occurs, retain this many trailing bytes so downstream tail-recovery can still find embedded JSON.
		public var tailRetainBytes: Int

		public init(maxLineBytes: Int, maxCarryBytes: Int, tailRetainBytes: Int) {
			self.maxLineBytes = maxLineBytes
			self.maxCarryBytes = maxCarryBytes
			self.tailRetainBytes = tailRetainBytes
		}

		public static let `default` = Limits(
			maxLineBytes: 8 * 1024 * 1024,     // 8 MB
			maxCarryBytes: 16 * 1024 * 1024,    // 16 MB
			tailRetainBytes: 128 * 1024          // 128 KB
		)
	}

	public enum Diagnostic: Sendable {
		/// Carry buffer exceeded limits; prefix was discarded, tail retained, quote state reset.
		case overflow(droppedBytes: Int, retainedBytes: Int)
		/// Quote-tracking state was force-reset because the line is not a JSON candidate.
		case nonJSONCandidateQuoteStateReset
	}

	private var carry = Data()
	private var inJSONString = false
	private var isEscapingJSONStringCharacter = false
	/// Whether the current line-in-progress is a JSON candidate (starts with `{` or `[`).
	/// Only JSON candidates get quote/escape tracking applied; all other lines split on `\n` unconditionally.
	private var isJSONCandidate = false
	/// Whether we've seen the first non-whitespace byte of the current line (to determine JSON candidacy).
	private var hasSeenLineStart = false
	/// Offset in `carry` of the current physical line, set once the current
	/// logical line has crossed a raw newline inside a JSON string; `nil`
	/// while the logical line is still on its first physical line.
	private var physicalLineStart: Int?

	public let limits: Limits

	public init(limits: Limits = .default) {
		self.limits = limits
	}

	public mutating func feed(_ chunk: Data, onDiagnostic: (Diagnostic) -> Void = { _ in }, onLine: (Data) -> Void) {
		guard !chunk.isEmpty else { return }

		var pending: [Data] = []
		var diagnostics: [Diagnostic] = []

		chunk.withUnsafeBytes { rawBuffer in
			guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			let count = rawBuffer.count
			// `sliceStart` tracks the beginning of the current un-appended slice within `chunk`.
			// We batch-append bytes from sliceStart..<i instead of appending one byte at a time.
			var sliceStart = 0

			for i in 0..<count {
				let byte = base[i]

				// Determine JSON candidacy from first non-whitespace byte of a new line.
				if !hasSeenLineStart, !isASCIIWhitespace(byte) {
					hasSeenLineStart = true
					isJSONCandidate = (byte == 0x7B /* { */ || byte == 0x5B /* [ */)
					if !isJSONCandidate, (inJSONString || isEscapingJSONStringCharacter) {
						inJSONString = false
						isEscapingJSONStringCharacter = false
						diagnostics.append(.nonJSONCandidateQuoteStateReset)
					}
				}

				if isJSONCandidate {
					switch byte {
					case 0x22: // '"'
						if inJSONString {
							if isEscapingJSONStringCharacter {
								isEscapingJSONStringCharacter = false
							} else {
								inJSONString = false
							}
						} else {
							inJSONString = true
						}
					case 0x5C: // '\\'
						if inJSONString {
							if isEscapingJSONStringCharacter {
								isEscapingJSONStringCharacter = false
							} else {
								isEscapingJSONStringCharacter = true
							}
						}
					case 0x0A: // '\n'
						// Append everything up to and including this byte.
						let slice = UnsafeBufferPointer(start: base + sliceStart, count: i + 1 - sliceStart)
						carry.append(slice)
						sliceStart = i + 1
						if resplitIfPhysicalLineIsStandaloneRecord(&pending) {
							// Quote tracking was wrong; state is reset for a new line.
						} else if inJSONString {
							isEscapingJSONStringCharacter = false
							physicalLineStart = carry.endIndex
						} else {
							emitLine(&pending)
						}
					default:
						if inJSONString, isEscapingJSONStringCharacter {
							isEscapingJSONStringCharacter = false
						}
					}
				} else {
					// Non-JSON candidate: split on every newline, no quote tracking.
					if byte == 0x0A {
						let slice = UnsafeBufferPointer(start: base + sliceStart, count: i + 1 - sliceStart)
						carry.append(slice)
						sliceStart = i + 1
						emitLine(&pending)
					}
				}
			}

			// Append any remaining un-appended bytes from the chunk.
			if sliceStart < count {
				let slice = UnsafeBufferPointer(start: base + sliceStart, count: count - sliceStart)
				carry.append(slice)
			}
		}

		// Check carry size limits after processing the full chunk (amortized).
		if carry.count > limits.maxCarryBytes || carry.count > limits.maxLineBytes {
			let retained = min(carry.count, limits.tailRetainBytes)
			let dropped = carry.count - retained
			if retained > 0 {
				carry = Data(carry.suffix(retained))
			} else {
				carry.removeAll(keepingCapacity: true)
			}
			inJSONString = false
			isEscapingJSONStringCharacter = false
			hasSeenLineStart = false
			isJSONCandidate = false
			physicalLineStart = nil
			diagnostics.append(.overflow(droppedBytes: dropped, retainedBytes: retained))
		}

		for line in pending {
			onLine(line)
		}
		for diagnostic in diagnostics {
			onDiagnostic(diagnostic)
		}
	}

	public mutating func flush(_ onLine: (Data) -> Void) {
		if !carry.isEmpty {
			onLine(carry)
			carry.removeAll(keepingCapacity: false)
		}
		inJSONString = false
		isEscapingJSONStringCharacter = false
		hasSeenLineStart = false
		isJSONCandidate = false
		physicalLineStart = nil
	}

	// MARK: - Private

	/// Extracts the completed line from carry (stripping the trailing newline and optional CR), appends to pending, and resets line state.
	private mutating func emitLine(_ pending: inout [Data]) {
		var line = carry
		line.removeLast() // remove the \n
		if line.last == 0x0D {
			line.removeLast() // remove optional \r
		}
		pending.append(line)
		carry.removeAll(keepingCapacity: true)
		resetLineState()
	}

	private mutating func resetLineState() {
		inJSONString = false
		isEscapingJSONStringCharacter = false
		hasSeenLineStart = false
		isJSONCandidate = false
		physicalLineStart = nil
	}

	/// Called with `carry` ending in the `\n` that just completed a physical
	/// line. When the logical line already spans a raw newline and this
	/// physical line is on its own a complete JSON record, emits every earlier
	/// physical line separately, then this one, and resets line state.
	private mutating func resplitIfPhysicalLineIsStandaloneRecord(_ pending: inout [Data]) -> Bool {
		guard let start = physicalLineStart else { return false }
		var end = carry.endIndex - 1 // exclude the \n
		if end > start, carry[end - 1] == 0x0D {
			end -= 1
		}
		let segment = carry[start..<end]
		guard Self.isStandaloneJSONRecord(segment) else { return false }

		var lineStart = carry.startIndex
		for index in carry.startIndex..<start where carry[index] == 0x0A {
			var lineEnd = index
			if lineEnd > lineStart, carry[lineEnd - 1] == 0x0D {
				lineEnd -= 1
			}
			pending.append(carry.subdata(in: lineStart..<lineEnd))
			lineStart = index + 1
		}
		pending.append(Data(segment))
		carry.removeAll(keepingCapacity: true)
		resetLineState()
		return true
	}

	/// A complete JSON object or array containing at least one string. The
	/// string requirement is what rules out lines of a string's own content:
	/// those can contain `"` only escaped, which is invalid outside a string.
	private static func isStandaloneJSONRecord(_ segment: Data) -> Bool {
		guard let first = segment.first(where: { !isASCIIWhitespace($0) }),
			first == 0x7B || first == 0x5B,
			segment.contains(0x22)
		else {
			return false
		}
		return (try? JSONSerialization.jsonObject(with: Data(segment))) != nil
	}
}

@inline(__always)
public func isASCIIWhitespace(_ byte: UInt8) -> Bool {
	switch byte {
	case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
		return true
	default:
		return false
	}
}

@inline(__always)
public func trimmedASCIIWhitespace(_ data: Data) -> Data? {
	var start = data.startIndex
	var end = data.endIndex
	while start < end, isASCIIWhitespace(data[start]) {
		start = data.index(after: start)
	}
	while end > start, isASCIIWhitespace(data[data.index(before: end)]) {
		end = data.index(before: end)
	}
	if start == end {
		return nil
	}
	return data.subdata(in: start..<end)
}

/// Repairs raw control characters that appear inside JSON strings (for example
/// unescaped LF/CR bytes) so `JSONSerialization` can decode the payload.
///
/// Returns `nil` when no repair is needed or when the payload is not a JSON
/// candidate (`{...}` / `[...]`).
public func repairJSONStringControlCharacters(_ data: Data) -> Data? {
	guard !data.isEmpty else { return nil }
	guard data.contains(0x0A) || data.contains(0x0D) else { return nil }

	var firstIndex = data.startIndex
	while firstIndex < data.endIndex, isASCIIWhitespace(data[firstIndex]) {
		firstIndex = data.index(after: firstIndex)
	}
	guard firstIndex < data.endIndex else { return nil }
	let firstByte = data[firstIndex]
	guard firstByte == 0x7B || firstByte == 0x5B else { return nil }

	var repaired = Data()
	repaired.reserveCapacity(data.count + 64)
	var inString = false
	var escaping = false

	for byte in data {
		if inString {
			if escaping {
				escaping = false
				repaired.append(byte)
				continue
			}
			if byte == 0x5C {
				escaping = true
				repaired.append(byte)
				continue
			}
			if byte == 0x22 {
				inString = false
				repaired.append(byte)
				continue
			}
			switch byte {
			case 0x0A:
				repaired.append(contentsOf: [0x5C, 0x6E])
				continue
			case 0x0D:
				repaired.append(contentsOf: [0x5C, 0x72])
				continue
			default:
				if byte < 0x20 {
					let escape = String(format: "\\u00%02X", byte)
					repaired.append(contentsOf: escape.utf8)
					continue
				}
				repaired.append(byte)
				continue
			}
		}
		if byte == 0x22 {
			inString = true
		}
		repaired.append(byte)
	}

	return repaired == data ? nil : repaired
}
