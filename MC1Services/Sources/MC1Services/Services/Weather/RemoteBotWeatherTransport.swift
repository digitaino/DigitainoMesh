#if DEBUG
import Foundation
import MeshCore
import MeshWX

/// A `WeatherTransport` that speaks to a real MeshWX bot over its debug bridge instead of over
/// a radio: the simulator becomes a live client of the bot on the Pi, with no BLE and no mesh.
///
/// Debug builds only, and only when the launch environment asks for it — see
/// ``fromEnvironment()`` and the branch in `ServiceContainer`. Nothing about the app's own
/// channel table, contacts or message service is involved.
///
/// The bot's side is `meshcore_weather/portal/routes/bridge.py`:
///
/// - `GET  <base>/api/bridge/stream?since=<cursor>` — SSE, one JSON frame per datagram the bot
///   transmits (`cursor`, `ts`, `data_type`, `hex`, `length`, `resend`, `attempt`). Each frame
///   becomes the `MeshEvent.channelDataReceived` the service expects, on ``channelIndex``.
/// - `POST <base>/api/bridge/request` — `{"text": ">o KAUS", "client": …}` run through the same
///   `AppResponder.handle_request` a DM takes, so the bot's own spacing and hourly budget apply.
///   Its answer goes on the air and therefore arrives on the stream.
///
/// Every call carries `X-Bridge-Token`; the POST also carries the portal's
/// `X-Requested-With: meshcore-portal`, like every other state-changing portal call.
///
/// What it fakes, and why that is honest enough for development:
///
/// - **The slot.** The datagrams claim ``channelIndex`` and ``channelSecret(at:)`` reports
///   `WeatherChannel.secret` for it, so the service's slot check passes without a radio.
/// - **The delivery confirmation.** A real radio confirms a DM reached the bot's node; here the
///   bridge's "accepted" stands in for it, under a code derived exactly as `AckCodeBuilder`
///   derives the firmware's (over a fixed stand-in sender key: only this transport's own
///   `sendRequest` and `acknowledgements` ever compare it). A request the bot refused —
///   rate-limited, or out of hourly budget — gets no confirmation, so it times out in the app
///   the way an unanswered request does.
/// - **SNR** is a plausible constant: there is no radio to measure.
public actor RemoteBotWeatherTransport: WeatherTransport {
  /// Launch environment: the portal's base URL (`http://127.0.0.1:8080` through an SSH tunnel)
  /// and the bot's `MCW_BRIDGE_TOKEN`.
  public static let urlVariable = "MESHWX_BRIDGE_URL"
  public static let tokenVariable = "MESHWX_BRIDGE_TOKEN"
  /// Optional: how this client names itself to the bot. The bot's per-sender spacing is keyed
  /// on it, so two simulators with different names are two senders.
  public static let clientVariable = "MESHWX_BRIDGE_CLIENT"

  /// The slot the bridge's datagrams claim to have arrived on. Any slot would do — the app's
  /// own table is not consulted — but 1 is what a phone that joined `#meshwx` usually holds.
  public static let channelIndex: UInt8 = 1
  /// There is no radio to measure: a plausible mid-range value, the same for every datagram.
  static let syntheticSNR = 6.5
  /// Reconnect backoff for the stream.
  static let firstRetry: Duration = .milliseconds(500)
  static let maxRetry: Duration = .seconds(30)
  /// Stand-in for this phone's public key in the ACK derivation. Only ever compared with codes
  /// this transport itself produced.
  static let syntheticSenderKey = Data(repeating: 0xBD, count: 32)

  private let baseURL: URL
  private let token: String
  private let clientID: String
  private let session: URLSession
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "WeatherBridge")

  /// Live datagram subscribers. The reader task runs while at least one is listening.
  private var datagramContinuations: [UUID: AsyncStream<MeshEvent>.Continuation] = [:]
  private var readerTask: Task<Void, Never>?
  /// The last cursor seen, so a reconnect resumes rather than replays.
  private var cursor: Int?

  private var acknowledgementContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

  /// Who the bridge is bridging to, from `GET /api/bridge/info`: the bot the tool treats as
  /// announced while this transport is in use. Read on the first ask and again whenever the
  /// feed reconnects, since a restarted bridge may be pointing at another bot.
  private var link: WeatherTransportLink?
  /// One info fetch at a time. A second caller arriving during one goes without rather than
  /// waiting: the next build has it.
  private var isFetchingLink = false

  /// - Parameters:
  ///   - baseURL: the portal root (`http://127.0.0.1:8080`) or its `/api` (either works).
  ///   - token: the bot's `MCW_BRIDGE_TOKEN`.
  ///   - clientID: how this client names itself; the bot's per-sender spacing is keyed on it.
  public init(
    baseURL: URL,
    token: String,
    clientID: String = "sim",
    session: URLSession = .shared
  ) {
    self.baseURL = baseURL
    self.token = token
    self.clientID = clientID
    self.session = session
  }

  /// The transport the launch environment asks for, or nil when it does not.
  ///
  /// `xcrun simctl launch` passes nothing of its own environment to the app, so the variables
  /// travel with a `SIMCTL_CHILD_` prefix:
  ///
  /// ```
  /// SIMCTL_CHILD_MESHWX_BRIDGE_URL=http://127.0.0.1:8080 \
  /// SIMCTL_CHILD_MESHWX_BRIDGE_TOKEN=… \
  ///   xcrun simctl launch --terminate-running-process <udid> com.digitaino.PocketMesh
  /// ```
  public static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RemoteBotWeatherTransport? {
    guard let raw = environment[urlVariable]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
          let url = URL(string: raw),
          let token = environment[tokenVariable]?.trimmingCharacters(in: .whitespaces),
          !token.isEmpty
    else { return nil }
    let client = environment[clientVariable]?.trimmingCharacters(in: .whitespaces)
    return RemoteBotWeatherTransport(
      baseURL: url, token: token, clientID: client?.isEmpty == false ? client! : "sim")
  }

  // MARK: - WeatherTransport

  public func datagramEvents() async -> AsyncStream<MeshEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: MeshEvent.self)
    let id = UUID()
    datagramContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeDatagramListener(id) }
    }
    startReaderIfNeeded()
    return stream
  }

  public func acknowledgements() async -> AsyncStream<Data> {
    let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
    let id = UUID()
    acknowledgementContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeAcknowledgementListener(id) }
    }
    return stream
  }

  /// The bridge has no route to forget: every request is an HTTP call to the bot itself.
  public func resetPath(to publicKey: Data) async throws {}

  /// Posts the request to the bridge and, when the bot accepted it, confirms it the way the
  /// radio would. The public key is the bot the app picked; the bridge has exactly one bot, so
  /// it rides along only in the log.
  public func sendRequest(
    to publicKey: Data, text: String, timestamp: Date, attempt: UInt8
  ) async throws -> Data {
    let code = Self.acknowledgementCode(text: text, timestamp: timestamp, attempt: attempt)
    if try await post(text) { yieldAcknowledgement(code) }
    return code
  }

  /// The same POST, for a request the app would have flooded on `#meshwx` (spec §7B).
  ///
  /// The bridge is an HTTP connection to one bot: there is no channel between here and it and
  /// nothing to address, so `botID` and `seq` ride along only in the log, and the answer comes
  /// back on the feed exactly as it does for a DM. Nothing is confirmed either way — a datagram
  /// has no acknowledgement — so unlike ``sendRequest(to:text:timestamp:attempt:)`` this one
  /// pushes no stand-in code.
  ///
  /// Returns nil for the same reason: no datagram goes on any channel, so there are no bytes and
  /// no slot for the channel traffic log to show (docs/MESHWX_UI.md §12).
  @discardableResult
  public func sendChannelRequest(
    text: String, botID: UInt16, timestamp: Date, seq: UInt8
  ) async throws -> WeatherChannelRequestSent? {
    let accepted = try await post(text)
    logger.info("Bridge took channel request \(text) for bot \(botID) seq \(seq): accepted=\(accepted)")
    return nil
  }

  /// Posts one `>` request through the bridge. Returns whether the bot accepted it; a refusal
  /// (its per-sender spacing, or its hourly budget) is not an error — on the air it is silence,
  /// and the app must time out exactly as it would there.
  private func post(_ text: String) async throws -> Bool {
    var request = URLRequest(url: endpoint("bridge/request"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("meshcore-portal", forHTTPHeaderField: "X-Requested-With")
    request.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
    request.setValue(clientID, forHTTPHeaderField: "X-Bridge-Client")
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["text": text, "client": clientID])

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw BridgeError.badResponse("no HTTP response")
    }
    guard http.statusCode == 200 else {
      throw BridgeError.badResponse("bridge answered \(http.statusCode) — \(Self.detail(data))")
    }
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let outcome = body["outcome"] as? String ?? "unknown"
    guard body["accepted"] as? Bool == true else {
      // The bot heard it and chose not to answer. No confirmation: the request times out in
      // the app exactly as one the bot ignored on the air does.
      logger.notice("Bridge refused \(text): \(outcome)")
      return false
    }
    logger.info("Bridge accepted \(text) (\(body["packets"] as? Int ?? 0) packet(s))")
    return true
  }

  /// The bridge's own slot carries `#meshwx`; nothing else is known, and nil means "unreadable",
  /// which the service treats as "accept and ask again".
  public func channelSecret(at index: UInt8) async -> Data? {
    index == Self.channelIndex ? WeatherChannel.secret : nil
  }

  /// There is no firmware queue to drain: everything the bridge delivers is live.
  public func isDrainingBacklog() async -> Bool { false }

  /// This transport *is* a link to one bot: the HTTP connection to the bridge stands in for
  /// both the radio and the bot's advert, so the tool can ask without a radio and without a
  /// contact for the bot (`WeatherTransportLink`).
  public func linkState() async -> WeatherTransportLink? {
    if let link { return link }
    return await fetchLink()
  }

  /// `GET /api/bridge/info` — the bot's own name and public key. A failure is not remembered:
  /// the next ask tries again, so a bridge that comes up later still names its bot.
  @discardableResult
  private func fetchLink() async -> WeatherTransportLink? {
    guard !isFetchingLink else { return link }
    isFetchingLink = true
    defer { isFetchingLink = false }
    var request = URLRequest(url: endpoint("bridge/info"))
    request.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
    request.setValue(clientID, forHTTPHeaderField: "X-Bridge-Client")
    request.timeoutInterval = 10
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.warning("Bridge info answered \(code)")
        return link
      }
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      guard let bot = Self.bot(from: body) else {
        logger.warning("Bridge info named no bot: \(Self.detail(data))")
        return link
      }
      if let stated = body["bot_id"] as? Int, UInt16(truncatingIfNeeded: stated) != bot.botID {
        // The id the app uses always comes from the key (spec §2.2); a disagreement means the
        // bridge is misreporting one of the two and is worth seeing in the log.
        logger.warning("Bridge info says bot \(stated) but its key derives \(bot.botID)")
      }
      logger.info("Bridge is bridging to \(bot.name) (bot \(bot.botID))")
      link = .up(bot: bot)
      return link
    } catch {
      logger.warning("Bridge info: \(error.localizedDescription)")
      return link
    }
  }

  /// The bot an info body describes. The advert position is unknown here — the bridge reports
  /// the radio's identity, not its place — so it reads as no position, which is what an advert
  /// without one reports too.
  static func bot(from body: [String: Any]) -> WeatherBot? {
    guard let name = body["name"] as? String, !name.isEmpty,
          let hex = body["public_key"] as? String,
          let key = Data(hexString: hex), key.count >= 2
    else { return nil }
    return WeatherBot(publicKey: key, name: name, latitude: 0, longitude: 0, lastAdvert: nil)
  }

  // MARK: - The feed

  private func startReaderIfNeeded() {
    guard readerTask == nil, !datagramContinuations.isEmpty else { return }
    readerTask = Task { [weak self] in
      await self?.readLoop()
    }
  }

  /// Reads the SSE feed for as long as anybody is listening, reconnecting with backoff.
  private func readLoop() async {
    var retry = Self.firstRetry
    while !Task.isCancelled, !datagramContinuations.isEmpty {
      do {
        try await readOnce { retry = Self.firstRetry }        // progress resets the backoff
        logger.notice("Bridge feed closed by the bot; reconnecting")
      } catch is CancellationError {
        return
      } catch {
        logger.warning("Bridge feed: \(error.localizedDescription)")
      }
      guard !Task.isCancelled, !datagramContinuations.isEmpty else { return }
      try? await Task.sleep(for: retry)
      retry = min(retry * 2, Self.maxRetry)
    }
  }

  /// One connection to the stream, resuming at the last cursor seen.
  private func readOnce(onFrame: () -> Void) async throws {
    var components = URLComponents(url: endpoint("bridge/stream"), resolvingAgainstBaseURL: false)
    if let cursor { components?.queryItems = [URLQueryItem(name: "since", value: String(cursor))] }
    guard let url = components?.url else { throw BridgeError.badURL }
    var request = URLRequest(url: url)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
    request.setValue(clientID, forHTTPHeaderField: "X-Bridge-Client")
    request.timeoutInterval = 3600

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw BridgeError.badResponse("stream answered \(code)")
    }
    logger.info("Bridge feed open at \(self.baseURL.absoluteString) (since \(self.cursor.map(String.init) ?? "start"))")
    // Who the feed belongs to, re-read on every connect: a bridge restarted against another
    // bot would otherwise keep the name the tool learned at the first one.
    await fetchLink()
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }          // ": ping" and blank lines
      let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
      guard let data = payload.data(using: .utf8),
            let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { continue }
      onFrame()
      if frame["hello"] as? Bool == true { continue }
      deliver(frame)
      if datagramContinuations.isEmpty { return }
    }
  }

  /// One feed frame as the datagram the service would have heard on `#meshwx`.
  private func deliver(_ frame: [String: Any]) {
    guard let hex = frame["hex"] as? String, let data = Data(hexString: hex) else {
      logger.warning("Bridge feed frame without usable hex")
      return
    }
    if let cursor = frame["cursor"] as? Int { self.cursor = cursor }
    let datagram = ChannelDatagram(
      channelIndex: Self.channelIndex,
      pathLength: 0xFF,
      dataType: UInt16(truncatingIfNeeded: frame["data_type"] as? Int ?? Int(MeshWXWire.dataType)),
      data: data,
      snr: Self.syntheticSNR
    )
    for continuation in datagramContinuations.values {
      continuation.yield(.channelDataReceived(datagram))
    }
  }

  private func removeDatagramListener(_ id: UUID) {
    datagramContinuations.removeValue(forKey: id)
    if datagramContinuations.isEmpty {
      readerTask?.cancel()
      readerTask = nil
    }
  }

  private func removeAcknowledgementListener(_ id: UUID) {
    acknowledgementContinuations.removeValue(forKey: id)
  }

  private func yieldAcknowledgement(_ code: Data) {
    for continuation in acknowledgementContinuations.values { continuation.yield(code) }
  }

  /// The firmware's derivation (`AckCodeBuilder`) over a stand-in sender key, so each
  /// transmission of a request has its own code and a retry's differs from the first send's.
  static func acknowledgementCode(text: String, timestamp: Date, attempt: UInt8) -> Data {
    AckCodeBuilder.expectedAck(
      timestamp: UInt32(truncatingIfNeeded: Int64(timestamp.timeIntervalSince1970)),
      attempt: attempt & 0x03,
      text: text,
      senderPublicKey: syntheticSenderKey)
  }

  /// `<base>/api/<path>`, whether the base already ends in `/api` or not.
  private func endpoint(_ path: String) -> URL {
    var url = baseURL
    if url.lastPathComponent != "api" { url.appendPathComponent("api") }
    for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
    return url
  }

  private static func detail(_ data: Data) -> String {
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return body?["detail"] as? String ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
  }

  enum BridgeError: LocalizedError {
    case badURL
    case badResponse(String)

    var errorDescription: String? {
      switch self {
      case .badURL: "the bridge URL could not be built"
      case let .badResponse(detail): detail
      }
    }
  }
}
#endif
