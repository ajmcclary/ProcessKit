import Foundation

/// Splits a `Data` blob containing one or more concatenated top-level JSON
/// **objects** (`{ ... }{ ... }`) into individual object frames, using a
/// string/escape-aware brace-depth scan.
///
/// This is the shared extraction of two byte-identical implementations that
/// previously lived in `ClaudeNativeProcessSessionController`
/// (`splitConcatenatedJSONObjectPayloads`) and `CodexAppServerClient`
/// (`splitConcatenatedJSONObjects`); promoted from the app into ProcessCore
/// (2026-07-17) as neutral stream-framing machinery alongside `LineFramer`.
/// The behavior of `frames` is identical to those originals, except that the
/// scan is byte-wise: the originals compared `Character`s and so missed a `"`,
/// `{` or `}` that a following combining scalar (accent, vowel sign,
/// variation selector, emoji modifier) joined into one grapheme.
/// - Non-UTF-8 or empty input yields no frames.
/// - Only `{`/`}` delimit frames; a top-level JSON *array* is treated as noise.
/// - Leading noise (before the first `{`) and inter-frame noise (between a
///   closed object and the next `{`) are discarded.
/// - An unterminated trailing object (a `{` that never returns to depth 0) is
///   NOT emitted as a frame.
///
/// `remainder` is additive information the legacy implementations did not expose
/// (they returned only the frames): it is the unconsumed tail after the last
/// complete frame — an unterminated trailing object and/or trailing noise — and
/// is empty when the input ends exactly on a closed frame. Callers that need the
/// exact legacy behavior use `.frames` and ignore `.remainder`.
public enum JSONStreamFramer {
	public struct FramingResult: Sendable {
		public let frames: [Data]
		public let remainder: Data

		/// Explicit because the synthesized memberwise initializer would be
		/// `internal`: once this type left RepoPromptCore (2026-07-24) an
		/// external consumer could no longer build a result for fixtures or
		/// stubs. Additive only — no behavior change.
		public init(frames: [Data], remainder: Data) {
			self.frames = frames
			self.remainder = remainder
		}
	}

	public static func splitConcatenatedObjects(_ data: Data) -> FramingResult {
		// Non-UTF-8 input yields nothing (legacy contract). The scan itself is
		// byte-wise: `"`, `\`, `{` and `}` are ASCII and never occur inside a
		// multi-byte UTF-8 sequence, whereas comparing `Character`s misses a
		// quote or brace that a following combining scalar joins into one
		// grapheme.
		guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
			return FramingResult(frames: [], remainder: Data())
		}
		var results: [Data] = []
		var start: Data.Index?
		var depth = 0
		var inString = false
		var escaping = false
		var lastFrameEnd: Data.Index?

		for index in data.indices {
			let byte = data[index]
			if start == nil {
				if byte == 0x7B { // {
					start = index
					depth = 1
					inString = false
					escaping = false
				}
				continue
			}

			if inString {
				if escaping {
					escaping = false
				} else if byte == 0x5C { // \
					escaping = true
				} else if byte == 0x22 { // "
					inString = false
				}
			} else {
				if byte == 0x22 {
					inString = true
				} else if byte == 0x7B {
					depth += 1
				} else if byte == 0x7D { // }
					depth -= 1
					if depth == 0, let segmentStart = start {
						let segmentEnd = index + 1
						results.append(data.subdata(in: segmentStart..<segmentEnd))
						start = nil
						lastFrameEnd = segmentEnd
					}
				}
			}
		}

		let remainder: Data
		if let openStart = start {
			// Unterminated trailing object: everything from its `{` to end.
			remainder = data.subdata(in: openStart..<data.endIndex)
		} else if let lastFrameEnd, lastFrameEnd < data.endIndex {
			// Trailing noise after the last complete frame.
			remainder = data.subdata(in: lastFrameEnd..<data.endIndex)
		} else {
			remainder = Data()
		}
		return FramingResult(frames: results, remainder: remainder)
	}
}
