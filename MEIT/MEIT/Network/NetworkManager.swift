import Combine
import Foundation

struct AIInferenceResult: Decodable {
    let label: String
    let confidence: Double
    let inferenceMilliseconds: Double
    let direction: String?
    let directionMarginDB: Double?

    enum CodingKeys: String, CodingKey {
        case label, confidence
        case inferenceMilliseconds = "inference_ms"
        case direction
        case directionMarginDB = "direction_margin_db"
    }
}

private struct BridgeErrorResponse: Decodable {
    struct Detail: Decodable { let code: String; let message: String }
    let error: Detail
}

struct NetworkFailure: LocalizedError {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
}

// A redirect must never move a microphone snapshot to a different endpoint.
private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class NetworkManager: ObservableObject {
    @Published var serverAddress = "" {
        didSet {
            if serverAddress != oldValue {
                cancel()
                stopWearableInference()
                connectionStatus = "Not Tested"
                hasConnected = false
                errorMessage = nil
            }
        }
    }
    @Published private(set) var connectionStatus = "Not Tested"
    // A later manual timeout must not disable foreground registration recovery.
    // Cleared only when the user changes the server address.
    @Published private(set) var hasConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var isSending = false
    @Published private(set) var result: AIInferenceResult?
    @Published private(set) var errorMessage: String?

    @Published private(set) var wearable = WearableInferenceState()
    private var wearableTask: Task<Void, Never>?
    private var wearableSessionID: UUID?

    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private let session = NetworkManager.makeSession(resourceTimeout: 60)
    private let coordinationSession = NetworkManager.makeSession(resourceTimeout: 1)

    nonisolated private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = resourceTimeout > 1
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }

    // Separate from the manual operation: RMS/polls must keep running during inference.
    func coordinationRequest(path: String, body: Data? = nil,
                             query: [URLQueryItem] = []) async throws -> Data {
        try await request(path: path, body: body, query: query, coordination: true)
    }

    // Caller owns one cancellable auto task; manual UI state remains independent.
    func sendAutomaticSnapshot(_ snapshot: AIInputSnapshot, eventID: String,
                               deviceID: String, role: DeviceRole) async throws {
        guard snapshot.sampleRate == 16_000, snapshot.channels == 1,
              snapshot.sampleCount == 40_000, snapshot.byteCount == 80_000,
              snapshot.duration == 2.5 else {
            throw NetworkFailure(message: "Snapshot must be 16000 Hz / mono / PCM16LE / 2.500 s.")
        }
        _ = try await request(path: "/event/audio", body: snapshot.pcm16LittleEndian,
                              headers: ["X-Event-ID": eventID, "X-Device-ID": deviceID,
                                        "X-Device-Role": role.rawValue])
        // The central result is published to every phone through command polling.
    }

    func testConnection() {
        run(sending: false) { [self] in
            let data = try await request(path: "/health")
            try Task.checkCancellation()
            struct Health: Decodable { let status: String }
            guard let health = try? JSONDecoder().decode(Health.self, from: data),
                  health.status == "ok" else {
                throw NetworkFailure(message: "Malformed /health response.")
            }
            hasConnected = true
            connectionStatus = "Connected"
        }
    }

    func sendSnapshot(from audio: AudioCaptureManager) {
        run(sending: true) { [self] in
            guard audio.isCapturing, audio.aiBufferStatus.isReady,
                  let snapshot = await audio.makeAIInputSnapshot() else {
                throw NetworkFailure(message: "AI Buffer is not ready. Wait for a full snapshot.")
            }
            try Task.checkCancellation()
            guard snapshot.sampleRate == 16_000, snapshot.channels == 1,
                  snapshot.sampleCount == 40_000, snapshot.byteCount == 80_000,
                  snapshot.duration == 2.5 else {
                throw NetworkFailure(message: "Snapshot must be 16000 Hz / mono / PCM16LE / 2.500 s.")
            }
            let data = try await request(path: "/infer", body: snapshot.pcm16LittleEndian)
            try Task.checkCancellation()
            guard let response = try? JSONDecoder().decode(AIInferenceResult.self, from: data),
                  ["horn", "siren", "crash", "normal"].contains(response.label),
                  response.confidence.isFinite, (0...1).contains(response.confidence),
                  response.inferenceMilliseconds.isFinite, response.inferenceMilliseconds >= 0 else {
                throw NetworkFailure(message: "Malformed inference response.")
            }
            result = response
            hasConnected = true
            connectionStatus = "Connected"
        }
    }

    func cancel() {
        operationID = nil
        operation?.cancel()
        operation = nil
        isBusy = false
        isSending = false
        result = nil
    }

    private func run(sending: Bool, action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        let id = UUID()
        operationID = id
        isBusy = true
        isSending = sending
        errorMessage = nil
        if sending { result = nil }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await action()
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                connectionStatus = "Failed"
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .timedOut:
                        errorMessage = "Request timed out. Check bridge, Wi-Fi and local-network permission."
                    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                        errorMessage = "Cannot reach bridge. Check Windows IPv4, port 8765, Wi-Fi and firewall."
                    default:
                        errorMessage = urlError.localizedDescription
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            guard operationID == id else { return }
            operationID = nil
            operation = nil
            isBusy = false
            isSending = false
        }
    }

    private func endpoint(path: String, query: [URLQueryItem]) throws -> URL {
        let parts = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4,
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168) else {
            throw NetworkFailure(message: "Enter the Windows private IPv4 address only (no http:// or port).")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = octets.map { String($0) }.joined(separator: ".")
        components.port = 8765
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw NetworkFailure(message: "Invalid server address.")
        }
        return url
    }

    private func request(path: String, body: Data? = nil, query: [URLQueryItem] = [],
                         coordination: Bool = false, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: try endpoint(path: path, query: query))
        request.timeoutInterval = coordination ? 1 : (body == nil ? 10 : 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(coordination ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
            if !coordination {
                request.setValue("16000", forHTTPHeaderField: "X-Audio-Sample-Rate")
                request.setValue("1", forHTTPHeaderField: "X-Audio-Channels")
                request.setValue("pcm16le", forHTTPHeaderField: "X-Audio-Format")
                request.setValue("40000", forHTTPHeaderField: "X-Audio-Samples")
            }
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let transport = coordination ? coordinationSession : session
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 16_384,
              http.mimeType == "application/json" else {
            throw NetworkFailure(message: "Expected a small JSON response from the MEIT bridge.", code: "invalid_response")
        }
        guard http.statusCode == 200 else {
            if let failure = try? JSONDecoder().decode(BridgeErrorResponse.self, from: data) {
                throw NetworkFailure(message: "HTTP \(http.statusCode) [\(failure.error.code)]: \(failure.error.message)", code: failure.error.code)
            }
            throw NetworkFailure(message: "Bridge returned HTTP \(http.statusCode).")
        }
        return data
    }
}

// Wearable uses the existing HTTP transport and immutable AI snapshot, with independent UI state.
struct WearableInferenceResult: Decodable {
    let label: String
    let confidence: Double
    let inference_ms: Double
    let danger: Bool
    let direction: String?
}

struct WearableInferenceState {
    var connectionStatus = "Not Tested"
    var inFlight = false
    var result: WearableInferenceResult?
    var sentDirection: String?
    var resultTime: Date?
    var requestBytes = 0
    var latencyMilliseconds: Double?
    var errorMessage: String?
    var errorKey: String?
}

extension NetworkManager {
    func startWearableInference(from audio: AudioCaptureManager) {
        stopWearableInference()
        guard audio.isCapturing, audio.captureOwner == .wearableMode,
              !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID()
        wearableSessionID = id
        wearableTask = Task { [weak self, weak audio] in
            guard let self, let audio else { return }
            while wearableIsCurrent(id, audio) {
                var delay: UInt64 = 200_000_000
                do {
                    struct Observation: Encodable {
                        let session_id: String
                        let rms_dbfs: Double
                        let buffer_ready: Bool
                    }
                    struct Event: Decodable { let session_id: String; let event_id: String? }
                    let body = try JSONEncoder().encode(Observation(
                        session_id: id.uuidString.lowercased(), rms_dbfs: audio.rmsDBFS,
                        buffer_ready: audio.aiBufferStatus.isReady))
                    // Only the bridge evaluates the shared RMS/quiet/cooldown gate.
                    let data = try await request(path: "/wearable/observe", body: body, coordination: true)
                    guard wearableIsCurrent(id, audio) else { return }
                    guard let event = try? JSONDecoder().decode(Event.self, from: data),
                          UUID(uuidString: event.session_id) == id,
                          (event.event_id.map({ UUID(uuidString: $0) != nil }) ?? true) else {
                        throw NetworkFailure(message: "Invalid Wearable observation response.", code: "invalid_response")
                    }
                    wearable.connectionStatus = "Connected"
                    if let eventID = event.event_id {
                        try await inferWearableEvent(eventID, sessionID: id, audio: audio)
                    }
                } catch {
                    guard wearableIsCurrent(id, audio) else { return } // Stale/cancelled response: discard.
                    wearable.inFlight = false
                    wearable.errorMessage = error.localizedDescription
                    if let failure = error as? NetworkFailure {
                        let codes = ["invalid_response", "incomplete_pcm", "inference_failed", "unsupported_label", "stale_event"]
                        let code = failure.code ?? "request"
                        wearable.errorKey = "wearable.ai.error." + (codes.contains(code) ? code : "request")
                    } else if let failure = error as? URLError {
                        wearable.errorKey = failure.code == .timedOut ? "wearable.ai.error.timeout" : "wearable.ai.error.unreachable"
                    } else {
                        wearable.errorKey = "wearable.ai.error.invalid_response"
                    }
                    wearable.connectionStatus = "Failed"
                    delay = 1_000_000_000
                    // Never stop microphone capture or retry a consumed audio event.
                }
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
        }
    }

    func stopWearableInference() {
        wearableSessionID = nil
        wearableTask?.cancel()
        wearableTask = nil
        wearable = WearableInferenceState()
    }

    private func wearableIsCurrent(_ id: UUID, _ audio: AudioCaptureManager) -> Bool {
        !Task.isCancelled && wearableSessionID == id && audio.isCapturing && audio.captureOwner == .wearableMode
    }

    private func inferWearableEvent(_ eventID: String, sessionID id: UUID,
                                    audio: AudioCaptureManager) async throws {
        guard !wearable.inFlight else { return }
        wearable.inFlight = true
        wearable.errorMessage = nil
        wearable.errorKey = nil
        // Freeze stable direction together with the snapshot request, never with the later reply.
        let direction = audio.wearableMic.direction
        let sentDirection = direction == .unavailable ? nil : direction.rawValue
        guard let snapshot = await audio.makeAIInputSnapshot() else {
            throw NetworkFailure(message: "A complete AI PCM snapshot is not ready.", code: "incomplete_pcm")
        }
        guard wearableIsCurrent(id, audio) else { return }
        guard snapshot.sampleRate == 16_000, snapshot.channels == 1,
              snapshot.sampleFormat == "Int16 (PCM16LE)", snapshot.sampleCount == 40_000,
              snapshot.byteCount == 80_000, snapshot.duration == 2.5 else {
            throw NetworkFailure(message: "Expected 16000 Hz / mono / PCM16LE / 40000 samples / 80000 bytes.", code: "incomplete_pcm")
        }
        wearable.sentDirection = sentDirection
        wearable.requestBytes = snapshot.byteCount
        let started = Date()
        let data = try await request(path: "/wearable/infer", body: snapshot.pcm16LittleEndian,
                                    headers: ["X-Wearable-Session": id.uuidString.lowercased(),
                                              "X-Wearable-Event": eventID,
                                              "X-Wearable-Direction": sentDirection ?? "unavailable"])
        guard wearableIsCurrent(id, audio) else { return }
        guard let response = try? JSONDecoder().decode(WearableInferenceResult.self, from: data),
              response.confidence.isFinite, (0...1).contains(response.confidence),
              response.inference_ms.isFinite, response.inference_ms >= 0,
              response.direction == sentDirection else {
            throw NetworkFailure(message: "Invalid Wearable inference response.", code: "invalid_response")
        }
        guard ["horn", "siren", "crash", "normal"].contains(response.label) else {
            throw NetworkFailure(message: "Unsupported classifier label.", code: "unsupported_label")
        }
        wearable.result = response
        wearable.resultTime = Date()
        wearable.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
        wearable.connectionStatus = "Connected"
        wearable.inFlight = false
        // No DeviceCoordinator, command polling, or HapticManager call on this path.
    }
}
