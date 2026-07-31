import Foundation

/// How a benchmark run is written into — and read back out of — a saved trace path's name.
///
/// A benchmark result *is* a trace path with runs, so it is stored as one rather than in a
/// schema of its own. That leaves nowhere to put the user's note (`TracePathRunDTO` carries
/// only id/date/success/rtt/hops), so the note travels in the name alongside the save's own
/// stamp and the two endpoints:
///
/// ```text
/// [Benchmark] stock whip antenna · #1700000000000 · Tower → Ridge
/// ```
///
/// The prefix is what separates benchmark paths from hand-saved ones in the same store, the
/// stamp is what keeps each save its own group in history — the note is optional and cleared
/// after every save, so grouping by it alone merged consecutive runs — and the arrow pair is
/// what matches targets between two runs during comparison. Paths written before either
/// field was encoded (`[Benchmark] Tower → Ridge`, `[Benchmark] note · Tower → Ridge`) still
/// parse; stampless ones group by note as they always did.
public enum BenchmarkNaming {
  /// Marks a saved trace path as belonging to the benchmark tool.
  public static let prefix = "[Benchmark]"

  /// Separates the note, the run stamp and the endpoint pair. Chosen because it does not
  /// occur in node names in practice; notes containing it are rewritten on save so parsing
  /// stays total.
  public static let noteSeparator = " · "

  /// Separates the test repeater from the target.
  public static let endpointSeparator = " → "

  /// Marks the run-stamp segment. A note that happens to look like one is disambiguated by
  /// position — the stamp is always the last such segment.
  static let runStampMarker: Character = "#"

  /// The fields a benchmark path name carries.
  public struct Components: Sendable, Equatable {
    public let note: String
    /// The save this path belongs to, `nil` for paths written before stamps existed.
    public let runStamp: String?
    public let testRepeater: String
    public let target: String

    public init(note: String, runStamp: String? = nil, testRepeater: String, target: String) {
      self.note = note
      self.runStamp = runStamp
      self.testRepeater = testRepeater
      self.target = target
    }

    /// What history groups this path under: its save, or its note on a pre-stamp path.
    public var groupKey: String {
      runStamp ?? note
    }
  }

  /// Whether a saved path was written by this tool.
  public static func isBenchmarkPath(_ name: String) -> Bool {
    name.hasPrefix(prefix)
  }

  /// The stamp identifying one save. Milliseconds, so two saves a moment apart still differ.
  public static func runStamp(for date: Date) -> String {
    "\(runStampMarker)\(Int((date.timeIntervalSince1970 * 1000).rounded()))"
  }

  /// Builds the stored name for one target of a run.
  public static func pathName(
    note: String,
    runStamp: String? = nil,
    testRepeater: String,
    target: String
  ) -> String {
    let segments = [sanitize(note), runStamp ?? ""]
      .filter { !$0.isEmpty }
      + ["\(testRepeater)\(endpointSeparator)\(target)"]
    guard segments.count > 1 else { return "\(prefix)\(noteSeparator)\(segments[0])" }
    return "\(prefix) \(segments.joined(separator: noteSeparator))"
  }

  /// Reads a stored name back, or `nil` when it was not written by this tool.
  public static func components(from name: String) -> Components? {
    guard isBenchmarkPath(name) else { return nil }
    var segments = String(name.dropFirst(prefix.count))
      .components(separatedBy: noteSeparator)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let body = segments.removeLast()

    var runStamp: String?
    if let index = segments.lastIndex(where: isRunStamp) {
      runStamp = segments.remove(at: index)
    }
    let note = segments.filter { !$0.isEmpty }.joined(separator: " ")

    guard let arrow = body.range(of: endpointSeparator) else {
      return Components(note: note, runStamp: runStamp, testRepeater: "", target: body)
    }
    return Components(
      note: note,
      runStamp: runStamp,
      testRepeater: String(body[body.startIndex..<arrow.lowerBound]),
      target: String(body[arrow.upperBound...])
    )
  }

  private static func isRunStamp(_ segment: String) -> Bool {
    guard segment.first == runStampMarker else { return false }
    let digits = segment.dropFirst()
    return !digits.isEmpty && digits.allSatisfy(\.isNumber)
  }

  /// Strips the delimiter and surrounding whitespace so a note can never break parsing.
  public static func sanitize(_ note: String) -> String {
    note
      .replacingOccurrences(of: noteSeparator, with: " ")
      .replacingOccurrences(of: "·", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
