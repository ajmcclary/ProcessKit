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
/// The behavior of `frames` is identical to those originals:
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
		guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
			return FramingResult(frames: [], remainder: Data())
		}
		var results: [Data] = []
		var start: String.Index?
		var depth = 0
		var inString = false
		var escaping = false
		var lastFrameEnd: String.Index?

		var index = text.startIndex
		while index < text.endIndex {
			let character = text[index]
			if start == nil {
				if character == "{" {
					start = index
					depth = 1
					inString = false
					escaping = false
				}
				index = text.index(after: index)
				continue
			}

			if inString {
				if escaping {
					escaping = false
				} else if character == "\\" {
					escaping = true
				} else if character == "\"" {
					inString = false
				}
			} else {
				if character == "\"" {
					inString = true
				} else if character == "{" {
					depth += 1
				} else if character == "}" {
					depth -= 1
					if depth == 0, let segmentStart = start {
						let segmentEnd = text.index(after: index)
						let segment = String(text[segmentStart..<segmentEnd])
						if let segmentData = segment.data(using: .utf8), !segmentData.isEmpty {
							results.append(segmentData)
						}
						start = nil
						lastFrameEnd = segmentEnd
					}
				}
			}
			index = text.index(after: index)
		}

		let remainder: Data
		if let openStart = start {
			// Unterminated trailing object: everything from its `{` to end.
			remainder = String(text[openStart..<text.endIndex]).data(using: .utf8) ?? Data()
		} else if let lastFrameEnd, lastFrameEnd < text.endIndex {
			// Trailing noise after the last complete frame.
			remainder = String(text[lastFrameEnd..<text.endIndex]).data(using: .utf8) ?? Data()
		} else {
			remainder = Data()
		}
		return FramingResult(frames: results, remainder: remainder)
	}
}
