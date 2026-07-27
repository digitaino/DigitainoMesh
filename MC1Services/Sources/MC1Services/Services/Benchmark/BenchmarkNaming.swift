import Foundation

/// How a benchmark run is written into — and read back out of — a saved trace path's name.
///
/// A benchmark result *is* a trace path with runs, so it is stored as one rather than in a
/// schema of its own. That leaves nowhere to put the user's note (`TracePathRunDTO` carries
/// only id/date/success/rtt/hops), so the note travels in the name alongside the two
/// endpoints:
///
/// ```text
/// [Benchmark] stock whip antenna · Tower → Ridge
/// ```
///
/// The prefix is what separates benchmark paths from hand-saved ones in the same store, the
/// note is what groups a run together in history, and the arrow pair is what matches targets
/// between two runs during comparison. Paths written before notes were encoded — plain
/// `[Benchmark] Tower → Ridge` — still parse, with an empty note.
public enum BenchmarkNaming {
  /// Marks a saved trace path as belonging to the benchmark tool.
  public static let prefix = "[Benchmark]"

  /// Separates the note from the endpoint pair. Chosen because it does not occur in node
  /// names in practice; notes containing it are rewritten on save so parsing stays total.
  public static let noteSeparator = " · "

  /// Separates the test repeater from the target.
  public static let endpointSeparator = " → "

  /// The three fields a benchmark path name carries.
  public struct Components: Sendable, Equatable {
    public let note: String
    public let testRepeater: String
    public let target: String

    public init(note: String, testRepeater: String, target: String) {
      self.note = note
      self.testRepeater = testRepeater
      self.target = target
    }
  }

  /// Whether a saved path was written by this tool.
  public static func isBenchmarkPath(_ name: String) -> Bool {
    name.hasPrefix(prefix)
  }

  /// Builds the stored name for one target of a run.
  public static func pathName(note: String, testRepeater: String, target: String) -> String {
    let cleanNote = sanitize(note)
    let endpoints = "\(testRepeater)\(endpointSeparator)\(target)"
    guard !cleanNote.isEmpty else { return "\(prefix)\(noteSeparator)\(endpoints)" }
    return "\(prefix) \(cleanNote)\(noteSeparator)\(endpoints)"
  }

  /// Reads a stored name back, or `nil` when it was not written by this tool.
  public static func components(from name: String) -> Components? {
    guard isBenchmarkPath(name) else { return nil }
    var body = String(name.dropFirst(prefix.count))

    var note = ""
    if let separator = body.range(of: noteSeparator) {
      note = String(body[body.startIndex..<separator.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      body = String(body[separator.upperBound...])
    }
    body = body.trimmingCharacters(in: .whitespaces)

    guard let arrow = body.range(of: endpointSeparator) else {
      return Components(note: note, testRepeater: "", target: body)
    }
    return Components(
      note: note,
      testRepeater: String(body[body.startIndex..<arrow.lowerBound]),
      target: String(body[arrow.upperBound...])
    )
  }

  /// Strips the delimiter and surrounding whitespace so a note can never break parsing.
  public static func sanitize(_ note: String) -> String {
    note
      .replacingOccurrences(of: noteSeparator, with: " ")
      .replacingOccurrences(of: "·", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
