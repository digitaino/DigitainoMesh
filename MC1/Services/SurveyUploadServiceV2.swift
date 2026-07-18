import Foundation
import MC1Services
import OSLog
import SurveyKit

private let logger = Logger(subsystem: "com.mc1", category: "SurveyUploadV2")

/// v2.2 community-map upload client. Replaces the v1 per-point firehose with
/// aggregated, batched, signed uploads:
///
/// - **One aggregation path**: cells are built by `SurveyKit.CellAggregator` — the
///   same fold the server's numbers are derived from.
/// - **Anonymous by default**: no contributor identity unless the user opted into
///   attribution; every batch carries a fresh random deletion receipt that only
///   this device stores (`DELETE /api/v2/uploads/:receipt` removes the batch).
/// - **Authenticated app**: requests carry an HMAC signature computed by
///   `SurveyKit.RequestSigner` — the same code the server verifies with.
/// - **Batched live mode**: during a live-upload survey, samples buffer and flush
///   every `liveFlushInterval` or `liveFlushCellCount` dirty cells, not per packet.
actor SurveyUploadServiceV2 {

    static let shared = SurveyUploadServiceV2()

    private let baseURL = URL(string: "https://mesh.digitaino.com/api/v2")!

    /// Missing key disables uploads with a user-visible error — never a crash.
    private var apiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SurveyAPIKey") as? String
    }

    struct UploadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Receipts

    /// receipts[sessionID] = all receipt values (base64) issued for that session's
    /// uploads. Presenting one to the server deletes that batch.
    private static let receiptsKey = "surveyV2Receipts"

    private func recordReceipt(_ receiptB64: String, sessionID: String) {
        var all = UserDefaults.standard.dictionary(forKey: Self.receiptsKey) as? [String: [String]] ?? [:]
        all[sessionID, default: []].append(receiptB64)
        UserDefaults.standard.set(all, forKey: Self.receiptsKey)
    }

    func receipts(forSession sessionID: String) -> [String] {
        let all = UserDefaults.standard.dictionary(forKey: Self.receiptsKey) as? [String: [String]] ?? [:]
        return all[sessionID] ?? []
    }

    /// Deletes every batch previously uploaded for this session (used before a
    /// re-upload, and by "remove my data" for anonymous sessions).
    func deleteUploads(forSession sessionID: String) async throws {
        for receipt in receipts(forSession: sessionID) {
            let escaped = receipt.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? receipt
            var request = URLRequest(url: baseURL.appendingPathComponent("uploads/\(escaped)"))
            request.httpMethod = "DELETE"
            try await send(request, body: Data())
        }
        var all = UserDefaults.standard.dictionary(forKey: Self.receiptsKey) as? [String: [String]] ?? [:]
        all[sessionID] = nil
        UserDefaults.standard.set(all, forKey: Self.receiptsKey)
    }

    // MARK: - Batch upload

    /// Uploads a finished session's samples as one aggregated batch.
    ///
    /// - Parameters:
    ///   - samples: the session's recorded points (mapped via `surveySample`)
    ///   - probesSentPerBaseCell: probe counts keyed by base-res H3 cell (dead-zone
    ///     evidence — cells probed but silent still upload)
    ///   - sessionID: local session UUID (only used for receipt bookkeeping and,
    ///     when attributed, session-replace dedup)
    ///   - contributor: opt-in attribution; nil = anonymous
    ///   - knownRepeaters: full-pubkey repeaters from contacts for canonical binding
    @discardableResult
    func uploadSession(
        samples: [SurveySample],
        probesSentPerBaseCell: [H3Cell: Int] = [:],
        sessionID: String,
        contributor: UploadV2Contributor?,
        knownRepeaters: [UploadV2KnownRepeater]? = nil
    ) async throws -> UploadV2Response {
        // Re-uploading a session replaces its prior data. Attributed uploads get
        // that server-side (session dedup); anonymous ones delete their receipts.
        if contributor == nil {
            try? await deleteUploads(forSession: sessionID)
        }

        var cells = CellAggregator.aggregate(samples)
        for (cell, probes) in probesSentPerBaseCell {
            var aggregate = cells[cell] ?? AggregatedCell(cell: cell)
            aggregate.probesSent += probes
            cells[cell] = aggregate
        }

        let payload = makePayload(
            cells: Array(cells.values),
            mode: "batch",
            contributor: contributor,
            knownRepeaters: knownRepeaters
        )
        return try await upload(payload, sessionID: sessionID)
    }

    // MARK: - Live queue

    private var liveBuffer: [SurveySample] = []
    private var liveSessionID: String?
    private var liveContributor: UploadV2Contributor?
    private var liveFlushTask: Task<Void, Never>?

    private let liveFlushInterval: TimeInterval = 45
    private let liveFlushCellCount = 20

    /// Arms the live queue for a session. Contributor nil = anonymous.
    func startLiveQueue(sessionID: String, contributor: UploadV2Contributor?) {
        liveBuffer.removeAll()
        liveSessionID = sessionID
        liveContributor = contributor
        liveFlushTask?.cancel()
        liveFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { break }
                await self?.flushLive()
            }
        }
    }

    /// Buffers a live sample; flushes when enough distinct cells are dirty.
    func enqueueLive(_ sample: SurveySample) async {
        guard liveSessionID != nil else { return }
        liveBuffer.append(sample)
        let dirtyCells = Set(liveBuffer.compactMap { SurveyGrid.cell(containing: $0.coordinate) })
        if dirtyCells.count >= liveFlushCellCount {
            await flushLive()
        }
    }

    /// Flushes the live buffer and (on stop) tears the queue down.
    func stopLiveQueue() async {
        await flushLive()
        liveFlushTask?.cancel()
        liveFlushTask = nil
        liveSessionID = nil
        liveContributor = nil
    }

    private func flushLive() async {
        guard let sessionID = liveSessionID, !liveBuffer.isEmpty else { return }
        let samples = liveBuffer
        liveBuffer.removeAll()

        let cells = CellAggregator.aggregate(samples)
        let payload = makePayload(
            cells: Array(cells.values),
            mode: "live",
            contributor: liveContributor,
            knownRepeaters: nil
        )
        do {
            _ = try await upload(payload, sessionID: sessionID)
        } catch {
            // Return the samples to the buffer for the next flush — live upload is
            // best-effort but shouldn't silently drop data on a transient failure.
            liveBuffer.insert(contentsOf: samples, at: 0)
            logger.warning("Live flush failed (\(samples.count) samples requeued): \(error.localizedDescription)")
        }
    }

    // MARK: - Payload assembly

    private func makePayload(
        cells: [AggregatedCell],
        mode: String,
        contributor: UploadV2Contributor?,
        knownRepeaters: [UploadV2KnownRepeater]?
    ) -> UploadV2Payload {
        let wireCells = cells.map { cell in
            cell.wireCell { hexID in
                Self.observation(forRepeaterID: hexID)
            }
        }
        var receipt: String?
        if contributor == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            receipt = Data(bytes).base64EncodedString()
        }
        return UploadV2Payload(
            contributor: contributor,
            receiptB64: receipt,
            mode: mode,
            cells: wireCells,
            knownRepeaters: knownRepeaters
        )
    }

    /// Full 64-char pubkeys upload as canonical `pubkey` observations; 1–3 byte
    /// prefixes as `prefix` observations for the server's resolver.
    private static func observation(forRepeaterID hexID: String) -> UploadV2RepeaterObservation {
        if hexID.count == 64, let data = Data(hexString: hexID) {
            return UploadV2RepeaterObservation(
                kind: "pubkey",
                pubkeyB64: data.base64EncodedString(),
                packetCount: 0
            )
        }
        let prefixData = Data(hexString: hexID) ?? Data()
        return UploadV2RepeaterObservation(
            kind: "prefix",
            prefixB64: prefixData.base64EncodedString(),
            packetCount: 0
        )
    }

    // MARK: - Transport

    private func upload(_ payload: UploadV2Payload, sessionID: String) async throws -> UploadV2Response {
        if let error = SurveyLimits.validate(payload) {
            throw UploadError(message: "Payload failed validation: \(error)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)

        var request = URLRequest(url: baseURL.appendingPathComponent("survey"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data = try await send(request, body: body)
        let response = try JSONDecoder().decode(UploadV2Response.self, from: data)
        if let receipt = payload.receiptB64 {
            recordReceipt(receipt, sessionID: sessionID)
        }
        logger.info("Uploaded \(payload.cells.count) cells (\(payload.mode)): \(response.cellsUpdated) updated")
        return response
    }

    /// Signs and sends a request with retry/backoff. The signature covers
    /// timestamp ‖ body via SurveyKit's RequestSigner (verified server-side by the
    /// same code).
    @discardableResult
    private func send(_ request: URLRequest, body: Data) async throws -> Data {
        guard let apiKey else {
            throw UploadError(message: "Community uploads are not configured in this build (missing SurveyAPIKey).")
        }
        var request = request
        let timestamp = String(Int(Date().timeIntervalSince1970))
        request.setValue(timestamp, forHTTPHeaderField: RequestSigner.timestampHeader)
        request.setValue(
            RequestSigner.signature(key: apiKey, timestamp: timestamp, body: body),
            forHTTPHeaderField: RequestSigner.signatureHeader
        )
        if !body.isEmpty {
            request.httpBody = body
        }

        var lastError: Error = UploadError(message: "Upload failed")
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UploadError(message: "Invalid server response")
                }
                switch http.statusCode {
                case 200...299:
                    return data
                case 429:
                    lastError = UploadError(message: "Rate limited")
                    try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                case 400...499:
                    let detail = String(decoding: data.prefix(300), as: UTF8.self)
                    throw UploadError(message: "Server rejected upload (\(http.statusCode)): \(detail)")
                default:
                    lastError = UploadError(message: "Server error (\(http.statusCode))")
                    try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
                }
            } catch let error as UploadError {
                throw error
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
        throw lastError
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
