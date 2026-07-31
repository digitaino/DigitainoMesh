import Foundation

/// Drives ``ChatNoRepeatsPolicy`` with a detection-window timer and reports prompt changes.
///
/// The only thing this adds over the policy is time: an armed message gets a single
/// cancellable task that sleeps for ``window`` and then feeds
/// ``ChatNoRepeatsInput/windowElapsed(messageID:)`` back in. Everything else is delegated,
/// which keeps the decision rules testable without a clock and leaves exactly one
/// timing-dependent seam — `sleep` — for tests to replace.
///
/// Owned by the interactive chat view model, one per conversation. It costs nothing while
/// no send is armed: no task exists, and the owner never feeds it at all when signal data
/// is unavailable for the connection.
@MainActor
public final class ChatNoRepeatsDetector {
  /// How long after a send lands we wait for a repeater echo before offering the card.
  /// Legacy used five seconds, which is comfortably longer than a neighbouring repeater's
  /// rebroadcast latency and short enough that the offer still reads as being about the
  /// message the user just sent.
  public static let defaultWindow: Duration = .seconds(5)

  /// The decision state. Exposed for tests and diagnostics; callers drive it via ``handle(_:)``.
  public private(set) var policy = ChatNoRepeatsPolicy()

  /// Fired whenever the prompted message changes, with the new value (`nil` retires the card).
  /// Never fired for a no-op input.
  public var onPromptChange: (@MainActor (UUID?) -> Void)?

  /// Whether repeater signal data is still available for the connection. Consulted when the
  /// window fires, because the owner's gate on the way in cannot see a detach that happens
  /// while the window runs: without signal data the "no repeats heard" verdict rests on
  /// nothing, so the armed slot is retired instead of prompted. Nil means available.
  public var isPromptAvailable: (@MainActor () -> Bool)?

  /// The message currently offered the retry card.
  public var promptedMessageID: UUID? {
    policy.promptedMessageID
  }

  private let window: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private var windowTask: Task<Void, Never>?

  /// - Parameters:
  ///   - window: Detection window. Injected so tests need not wait it out.
  ///   - sleep: Suspension primitive for the window. Injected rather than a `Clock` because
  ///     the only thing under test is "did the window elapse before the evidence arrived",
  ///     which a controllable suspension expresses directly.
  public init(
    window: Duration = ChatNoRepeatsDetector.defaultWindow,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.window = window
    self.sleep = sleep
  }

  deinit {
    windowTask?.cancel()
  }

  /// Folds an input into the policy, restarts or cancels the window timer to match, and
  /// reports a prompt change to ``onPromptChange``.
  public func handle(_ input: ChatNoRepeatsInput) {
    let previousPrompt = policy.promptedMessageID
    let previousArmed = policy.armedMessageID
    let previousArmSequence = policy.armSequence

    policy.handle(input)

    if policy.armSequence != previousArmSequence || policy.armedMessageID != previousArmed {
      restartWindow()
    }
    if policy.promptedMessageID != previousPrompt {
      onPromptChange?(policy.promptedMessageID)
    }
  }

  /// Cancels the pending window without touching the policy. Used on teardown, where the
  /// owner is going away and a late verdict would write into a released timeline.
  public func cancel() {
    windowTask?.cancel()
    windowTask = nil
  }

  #if DEBUG
    /// Test-only: awaits the pending detection window so a test can synchronise on the
    /// verdict instead of polling.
    public func awaitWindowForTesting() async {
      await windowTask?.value
    }

    /// Test-only: delivers the window's verdict now, exactly as the timer would. Lets an
    /// owner-level test exercise the fire-time availability re-check without a real window.
    public func fireWindowForTesting() {
      guard let armed = policy.armedMessageID else { return }
      fireWindow(for: armed)
    }
  #endif

  private func restartWindow() {
    windowTask?.cancel()
    windowTask = nil
    guard let armed = policy.armedMessageID else { return }

    let window = window
    let sleep = sleep
    windowTask = Task { [weak self] in
      do {
        try await sleep(window)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.fireWindow(for: armed)
    }
  }

  private func fireWindow(for messageID: UUID) {
    guard isPromptAvailable?() ?? true else {
      handle(.detectionUnavailable(messageID: messageID))
      return
    }
    handle(.windowElapsed(messageID: messageID))
  }
}
